import Foundation
import Observation
import Supabase

/// 앱 전역 상태와 서버 연동.
@MainActor
@Observable
final class AppModel {
    var userID: UUID?
    var hasConnectedCard = false
    var today: [StackItem] = []
    /// 라이브 액티비티 탭으로 열린 경우 조회 중인 매장
    var checkingStore: String?
    /// 서버가 찾은 결제 → 확인 화면
    var pendingPrediction: Prediction?
    var errorMessage: String?

    let geofence = GeofenceManager()
    private var predictionTask: Task<Void, Never>?

    // MARK: 로그인

    /// 지금은 익명 로그인 (Sign in with Apple은 Apple 개발자 계정이 생기면 붙인다).
    func start() async {
        do {
            let session = try await Backend.client.auth.session
            userID = session.user.id
        } catch {
            do {
                userID = try await Backend.client.auth.signInAnonymously().user.id
            } catch {
                errorMessage = "로그인에 실패했어요: \(error.localizedDescription)"
                return
            }
        }
        await refresh()
        listenForPredictions()
        geofence.onVisit = { [weak self] chain, entered in
            Task { @MainActor in await self?.recordVisit(chain: chain, entered: entered) }
        }
        #if DEBUG
        // 시뮬레이터 시연용: `simctl launch <기기> com.caloriesproject.app -demoTap GS25`
        // = 라이브 액티비티 탭 (simctl openurl은 "열겠습니까?" 확인 창이 떠서 자동 시연이 멈춘다)
        if let store = UserDefaults.standard.string(forKey: "demoTap") {
            try? await Task.sleep(for: .seconds(2))
            handle(url: DeepLink.tap(storeChain: store))
        }
        #endif
    }

    // MARK: 편의점 방문 (체인 + 시각만)

    private var openVisitID: UUID?

    private struct VisitRow: Encodable {
        let user_id: UUID
        let store_chain: String
        let entered_at: Date
    }

    private struct VisitID: Decodable { let id: UUID }

    private func recordVisit(chain: String, entered: Bool) async {
        guard let userID else { return }
        do {
            if entered {
                let row: VisitID = try await Backend.client.from("location_visits")
                    .insert(VisitRow(user_id: userID, store_chain: chain, entered_at: .now))
                    .select("id").single().execute().value
                openVisitID = row.id
            } else if let id = openVisitID {
                try await Backend.client.from("location_visits")
                    .update(["exited_at": Date.now.ISO8601Format()]).eq("id", value: id).execute()
                openVisitID = nil
            }
        } catch {
            print("방문 기록 실패", error.localizedDescription)
        }
    }

    func refresh() async {
        guard let userID else { return }
        do {
            let cards: [IDRow] = try await Backend.client.from("card_connections")
                .select("id").eq("user_id", value: userID).eq("status", value: "active").execute().value
            hasConnectedCard = !cards.isEmpty
            today = try await loadToday(userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 카드 연결

    struct ConnectResult: Decodable {
        let card_connection_id: UUID
        let backfilled: Int
    }

    func connectCard(company: CardCompany, loginID: String, password: String,
                     cardNo: String?, cardPassword: String?) async throws -> ConnectResult {
        var body = ["card_company": company.rawValue, "login_id": loginID, "password": password]
        if let cardNo, let cardPassword, !cardNo.isEmpty {
            body["card_no"] = cardNo
            body["card_password"] = cardPassword
        }
        let result: ConnectResult = try await Backend.client.functions.invoke(
            "card-connect", options: FunctionInvokeOptions(body: body))
        hasConnectedCard = true
        return result
    }

    // MARK: 라이브 액티비티 탭 → 조회

    func handle(url: URL) {
        guard url.scheme == DeepLink.scheme, url.host == "tap" else { return }
        let store = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "store" }?.value ?? "편의점"
        checkingStore = store
        geofence.updateActivity(.checking)
        Task {
            do {
                // 서버는 바로 202를 주고 백그라운드에서 0·20·45·90초에 조회한다. 결과는 Realtime으로 온다.
                try await Backend.client.functions.invoke(
                    "tap-check", options: FunctionInvokeOptions(body: ["store_chain": store]))
            } catch {
                errorMessage = "결제 내역 확인을 시작하지 못했어요: \(error.localizedDescription)"
                checkingStore = nil
            }
        }
    }

    /// predictions 에 새 행이 생기면(RLS로 내 것만) 확인 화면을 띄운다.
    private func listenForPredictions() {
        predictionTask?.cancel()
        predictionTask = Task {
            let channel = Backend.client.channel("my-predictions")
            let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "predictions")
            do {
                try await channel.subscribeWithError()
            } catch {
                errorMessage = "실시간 연결 실패: \(error.localizedDescription)"
                return
            }
            for await insert in inserts {
                guard let p = try? insert.decodeRecord(as: Prediction.self, decoder: JSONDecoder()),
                      p.is_snack_score ?? 0 > 0 else { continue }
                checkingStore = nil
                geofence.updateActivity(.found)
                pendingPrediction = p
            }
        }
    }

    // MARK: 원탭 확인

    func confirm(_ prediction: Prediction, response: String, items: [Prediction.Item]) async {
        guard let userID else { return }
        do {
            try await Backend.client.from("confirmations").insert(ConfirmationRow(
                event_id: prediction.event_id, user_id: userID, response: response,
                final_items: items.map { .init(product_id: $0.product_id, qty: $0.qty) }
            )).execute()
            if response != "no", !items.isEmpty {
                try await addToStack(items, eventID: prediction.event_id, origin: "auto_confirm")
            }
            pendingPrediction = nil
            today = try await loadToday(userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 스택 기록은 서버 함수 add_consumption 하나로 한다 (100g당 상품은 grams 또는 내 목록 serving_g로 환산).
    private func addToStack(_ items: [Prediction.Item], eventID: UUID?, origin: String) async throws {
        try await Backend.client.rpc("add_consumption", params: AddConsumption(
            items: items.map { .init(product_id: $0.product_id, qty: $0.qty, grams: $0.grams) },
            event: eventID, origin: origin
        )).execute()
    }

    /// 설정 > 내 데이터 모두 삭제: 서버 데이터를 지우고 로그아웃 → 다음 실행 때 새 익명 사용자로 시작
    func deleteAllData() async {
        do {
            try await Backend.client.rpc("delete_my_data").execute()
            try await Backend.client.auth.signOut()
            userID = nil
            hasConnectedCard = false
            today = []
            await start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 확인 화면 없이 직접 기록 (홈의 + 버튼)
    func addManually(_ items: [Prediction.Item]) async {
        guard let userID else { return }
        do {
            try await addToStack(items, eventID: nil, origin: "manual")
            today = try await loadToday(userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 오늘의 스택

    private func loadToday(userID: UUID) async throws -> [StackItem] {
        let start = Calendar.current.startOfDay(for: .now)
        let rows: [ConsumptionWithProduct] = try await Backend.client.from("consumption_log")
            .select("id, consumed_at, kcal, sugar_g, products(name), payment_events(merchant_raw)")
            .eq("user_id", value: userID)
            .gte("consumed_at", value: start.ISO8601Format())
            .order("consumed_at", ascending: false)
            .execute().value
        return rows.map {
            StackItem(name: $0.products?.name ?? "군것질", store: $0.payment_events?.merchant_raw ?? "",
                      time: $0.consumed_at, kcal: $0.kcal ?? 0, sugarG: $0.sugar_g ?? 0)
        }
    }

    var todayKcal: Double { today.reduce(0) { $0 + $1.kcal } }
    var todaySugar: Double { today.reduce(0) { $0 + $1.sugarG } }
}

// MARK: - 서버 행 모델 (칸 이름은 DB와 같게)

struct Prediction: Decodable, Identifiable {
    struct Item: Codable, Hashable {
        let product_id: Int
        let name: String
        let qty: Int
        /// 100g당 상품을 고를 때만: 실제 먹은 무게
        var grams: Double? = nil
    }
    struct Candidate: Decodable, Hashable {
        let items: [Item]
        let score: Double
    }
    let id: UUID
    let event_id: UUID
    let is_snack_score: Double?
    let candidates: [Candidate]

    /// "바나나맛우유 + 초코파이 2개"
    static func label(_ items: [Item]) -> String {
        items.map { $0.qty > 1 ? "\($0.name) \($0.qty)개" : $0.name }.joined(separator: " + ")
    }
}

private struct IDRow: Decodable { let id: UUID }

private struct ConfirmationRow: Encodable {
    struct Final: Encodable { let product_id: Int; let qty: Int }
    let event_id: UUID
    let user_id: UUID
    let response: String
    let final_items: [Final]
}

private struct AddConsumption: Encodable {
    struct Item: Encodable { let product_id: Int; let qty: Int; let grams: Double? }
    let items: [Item]
    let event: UUID?
    let origin: String
}

private struct ConsumptionWithProduct: Decodable {
    struct Product: Decodable { let name: String }
    struct Event: Decodable { let merchant_raw: String? }
    let id: UUID
    let consumed_at: Date
    let kcal: Double?
    let sugar_g: Double?
    let products: Product?
    let payment_events: Event?
}

struct StackItem: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var store: String
    var time: Date
    var kcal: Double
    var sugarG: Double
}
