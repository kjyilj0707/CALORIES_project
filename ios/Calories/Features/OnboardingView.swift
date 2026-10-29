import SwiftUI

/// 온보딩: 약속 → 카드사 선택 → 연결 → 30일 리포트 → 권한.
/// 카드 연결(CODEF)과 30일 리포트는 서버 연동 단계에서 붙인다. 지금은 흐름과 문구 확인용.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = .promise
    @State private var cardCompany: CardCompany?
    @State private var loginID = ""
    @State private var password = ""
    @State private var cardNo = ""
    @State private var cardPassword = ""
    @State private var connecting = false
    @State private var connectError: String?
    @State private var backfilled = 0
    @State private var backfillReport: BackfillReport?

    enum Step { case promise, chooseCard, connect, report }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .promise: promise
                case .chooseCard: chooseCard
                case .connect: connect
                case .report: report
                }
            }
            .padding(24)
            .animation(.default, value: step)
        }
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text("🍫").font(.system(size: 64))
            Text("당신이 결제하는 순간,\n당신의 군것질을 알아차립니다.")
                .font(.title.bold())
            Text("결제하는 순간을 알아차리려면 카드 한 장이 필요해요.\n편의점에서 주로 쓰는 카드부터 연결해 주세요.")
                .foregroundStyle(.secondary)
            Spacer()
            trustNotes
            primaryButton("카드 연결하기") { step = .chooseCard }
        }
    }

    private var trustNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("조회 전용이에요. 결제·이체는 할 수 없어요", systemImage: "lock")
            Label("가맹점·금액·시각만 보관해요", systemImage: "doc.text.magnifyingglass")
            Label("언제든 연결을 해제할 수 있어요", systemImage: "xmark.circle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var chooseCard: some View {
        List(CardCompany.allCases) { company in
            Button {
                cardCompany = company
                step = .connect
            } label: {
                HStack {
                    Text(company.rawValue)
                    Spacer()
                    if let note = company.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("어느 카드사인가요?")
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(cardCompany?.rawValue ?? "")카드 연결").font(.title2.bold())
            Text("카드사 홈페이지 아이디로 연결해요. 저장된 암호가 있으면 키보드의 🔑 버튼으로 불러올 수 있어요.")
                .foregroundStyle(.secondary)
            TextField("아이디", text: $loginID)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("비밀번호", text: $password).textContentType(.password)
            if cardCompany?.needsCardPassword == true {
                TextField("카드번호", text: $cardNo).keyboardType(.numberPad).textContentType(.creditCardNumber)
                SecureField("카드 비밀번호", text: $cardPassword).keyboardType(.numberPad)
            }
            if let connectError {
                Text(connectError).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            primaryButton(connecting ? "연결하는 중…" : "연결하기") { Task { await submit() } }
                .disabled(connecting || loginID.isEmpty || password.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func submit() async {
        guard let cardCompany else { return }
        connecting = true
        connectError = nil
        defer { connecting = false }
        do {
            let result = try await model.connectCard(company: cardCompany, loginID: loginID, password: password,
                                                     cardNo: cardNo, cardPassword: cardPassword)
            password = ""
            cardPassword = ""
            backfilled = result.backfilled
            backfillReport = try? await BackfillReport.load()
            step = .report
        } catch {
            // 아이디·비밀번호 불일치, 추가 인증 필요 등은 서버가 CODEF 메시지를 그대로 돌려준다
            connectError = "연결하지 못했어요. 아이디·비밀번호를 확인해 주세요.\n(\(error.localizedDescription))"
        }
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("지난 30일").font(.headline).foregroundStyle(.secondary)
            if let r = backfillReport, r.snack_payments > 0 {
                Text("편의점·카페 결제 \(r.snack_payments)번,\n\(r.snack_amount.formatted())원").font(.title.bold())
                Text("약 \(r.est_kcal.formatted())kcal (금액 기준 추정)").font(.title3)
                if !r.top_chains.isEmpty {
                    Text("자주 간 곳: " + r.top_chains.map { "\($0.chain ?? "기타") \($0.count)번" }.joined(separator: " · "))
                }
                if let h = r.top_hours.first {
                    Text("가장 많이 산 시간: \(h.hour)시").foregroundStyle(.secondary)
                }
            } else {
                Text("결제 \(backfilled)건을 가져왔어요").font(.title.bold())
                Text("편의점·카페 결제는 아직 없어요. 이제부터 결제하는 순간 기록할게요.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            primaryButton("이제부터 결제하는 순간 물어볼게요") {
                model.geofence.requestPermission()
                Task { await model.refresh() }
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// my_backfill_report() 결과 (연결 직후 가져온 지난 30일 결제)
struct BackfillReport: Decodable {
    struct Chain: Decodable { let chain: String?; let count: Int }
    struct Hour: Decodable { let hour: Int; let count: Int }
    let total_payments: Int
    let snack_payments: Int
    let snack_amount: Int
    let est_kcal: Int
    let top_chains: [Chain]
    let top_hours: [Hour]

    static func load() async throws -> BackfillReport? {
        let rows: [BackfillReport] = try await Backend.client.rpc("my_backfill_report").execute().value
        return rows.first
    }
}

enum CardCompany: String, CaseIterable, Identifiable {
    case 신한, 삼성, KB국민, 현대, 롯데, 하나, 우리, NH농협, BC

    var id: String { rawValue }

    /// 카드번호·카드 비밀번호 입력칸을 보여 줄 카드사
    var needsCardPassword: Bool { self == .현대 || self == .KB국민 }

    /// 카드사별로 추가로 필요한 것 (CODEF 개발가이드 기준)
    var note: String? {
        switch self {
        case .현대: "카드번호·카드 비밀번호 필요"
        case .KB국민: "카드 비밀번호가 필요할 수 있어요"
        case .롯데: "문자 인증이 추가될 수 있어요"
        default: nil
        }
    }
}
