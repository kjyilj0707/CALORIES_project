import Supabase
import SwiftUI

/// 카탈로그 상품 (search_products 결과)
struct CatalogProduct: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let manufacturer: String?
    let category: String?
    let kcal: Double?
    let sugar_g: Double?
    let serving_g_ml: Double?
    /// false면 영양값이 포장 1개가 아니라 100g(mL)당 값
    let per_package: Bool
    let verified: Bool

    /// "36.5g · 185kcal · 당류 17g" / "100g당 507kcal · 당류 50g"
    var summary: String {
        let amount = per_package ? serving_g_ml.map { "\($0.formatted())g" } : "100g당"
        return [manufacturer, amount, kcal.map { "\(Int($0.rounded()))kcal" }, sugar_g.map { "당류 \(Int($0.rounded()))g" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// 내 군것질 목록 (user_snacks + 상품 이름)
struct MySnack: Decodable, Identifiable {
    struct Product: Decodable { let name: String; let kcal: Double?; let sugar_g: Double? }
    let id: UUID
    let product_id: Int
    let usual_price: Int?
    let usual_stores: [String]
    let occasions: [String]
    let products: Product?
}

enum Catalog {
    static func search(_ q: String) async throws -> [CatalogProduct] {
        try await Backend.client.rpc("search_products", params: ["q": q]).execute().value
    }
}

/// 카탈로그 검색. 내 목록 추가와 "다른 거예요" 둘 다에서 쓴다.
struct CatalogSearchView: View {
    var title = "군것질 찾기"
    /// grams: 100g당 값인 상품을 골랐을 때 사용자가 입력한 1개 무게
    let onSelect: (CatalogProduct, Double?) -> Void
    @State private var query = ""
    @State private var needsWeight: CatalogProduct?
    @State private var grams = ""
    @State private var results: [CatalogProduct] = []
    @State private var searching = false

    var body: some View {
        List(results) { p in
            Button {
                if p.per_package { onSelect(p, nil) } else { grams = ""; needsWeight = p }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(p.name)
                        if p.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).font(.caption) }
                    }
                    Text(p.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        .overlay {
            if searching { ProgressView() }
            else if results.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "예: 바나나우유, 초코파이")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 1 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300)) // 입력이 멈추면 검색
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            results = (try? await Catalog.search(q)) ?? []
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("1개 무게를 알려 주세요", isPresented: Binding(get: { needsWeight != nil }, set: { if !$0 { needsWeight = nil } })) {
            TextField("예: 36.5", text: $grams).keyboardType(.decimalPad)
            Button("취소", role: .cancel) {}
            Button("확인") { if let p = needsWeight { onSelect(p, Double(grams)) } }
        } message: {
            Text("이 상품은 영양성분이 100g당 값이라, 포장에 적힌 무게로 계산해요.")
        }
    }
}

/// 내 군것질 목록
struct SnackListView: View {
    @Environment(AppModel.self) private var model
    @State private var snacks: [MySnack] = []
    @State private var adding: CatalogProduct?
    @State private var addingGrams: Double?
    @State private var showSearch = false

    var body: some View {
        List {
            if snacks.isEmpty {
                Text("자주 먹는 군것질을 추가하면, 결제 금액으로 무엇을 샀는지 맞혀 드려요.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snacks) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.products?.name ?? "")
                        Text((s.usual_stores + s.occasions).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let price = s.usual_price { Text("\(price)원").monospacedDigit() }
                }
            }
            .onDelete { idx in
                let ids = idx.map { snacks[$0].id }
                Task {
                    try? await Backend.client.from("user_snacks").delete().in("id", values: ids).execute()
                    await load()
                }
            }
        }
        .navigationTitle("내 군것질 목록")
        .toolbar {
            Button { showSearch = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                CatalogSearchView { p, g in
                    showSearch = false
                    addingGrams = g
                    adding = p
                }
            }
        }
        .sheet(item: $adding) { p in
            AddSnackSheet(product: p, initialGrams: addingGrams) { await load() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let userID = model.userID else { return }
        snacks = (try? await Backend.client.from("user_snacks")
            .select("id, product_id, usual_price, usual_stores, occasions, products(name, kcal, sugar_g)")
            .eq("user_id", value: userID).eq("is_active", value: true)
            .order("created_at", ascending: false)
            .execute().value) ?? []
    }
}

/// 군것질 추가: 가격(매칭에 꼭 필요) + 주로 사는 곳 + 먹는 상황
struct AddSnackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let product: CatalogProduct
    var initialGrams: Double?
    let onSaved: () async -> Void

    @State private var price = ""
    @State private var grams = ""
    @State private var stores: Set<String> = []
    @State private var occasions: Set<String> = []
    @State private var error: String?

    static let storeOptions = ["GS25", "CU", "세븐일레븐", "이마트24", "카페"]
    static let occasionOptions = ["출근길", "점심 후", "오후 간식", "공부·야근", "스트레스", "야식", "운동 후"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(product.name).font(.headline)
                    Text(product.summary).foregroundStyle(.secondary)
                }
                if !product.per_package {
                    Section {
                        TextField("예: 36.5", text: $grams).keyboardType(.decimalPad)
                    } header: {
                        Text("1개 무게(g)")
                    } footer: {
                        Text("영양성분이 100g당 값이라, 포장에 적힌 무게로 1개 칼로리를 계산해요.")
                    }
                }
                Section {
                    TextField("예: 1700", text: $price).keyboardType(.numberPad)
                } header: {
                    Text("보통 얼마에 사세요?")
                } footer: {
                    Text("결제 금액으로 무엇을 샀는지 맞히는 데 써요.")
                }
                Section("주로 사는 곳") { chips(Self.storeOptions, selection: $stores) }
                Section("언제 먹나요?") { chips(Self.occasionOptions, selection: $occasions) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .onAppear { if let initialGrams { grams = initialGrams.formatted() } }
            .navigationTitle("내 목록에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") { Task { await save() } }.disabled(Int(price) == nil)
                }
            }
        }
    }

    private func chips(_ options: [String], selection: Binding<Set<String>>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { o in
                let on = selection.wrappedValue.contains(o)
                Button(o) {
                    if on { selection.wrappedValue.remove(o) } else { selection.wrappedValue.insert(o) }
                }
                .buttonStyle(.bordered)
                .tint(on ? .accentColor : .secondary)
            }
        }
    }

    private struct Row: Encodable {
        let user_id: UUID
        let product_id: Int
        let usual_price: Int
        let usual_stores: [String]
        let occasions: [String]
        let serving_g: Double?
    }

    private func save() async {
        guard let userID = model.userID, let p = Int(price) else { return }
        do {
            try await Backend.client.from("user_snacks").upsert(
                Row(user_id: userID, product_id: product.id, usual_price: p,
                    usual_stores: Array(stores), occasions: Array(occasions),
                    serving_g: product.per_package ? nil : Double(grams)),
                onConflict: "user_id,product_id"
            ).execute()
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 칩을 줄바꿈하며 나열하는 레이아웃
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, point) in arrange(subviews, width: bounds.width).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}
