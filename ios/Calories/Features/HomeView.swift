import SwiftUI

/// 홈: 오늘의 군것질 스택.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    /// 하루 당류 권장 상한 (WHO 첨가당 기준 50g)
    private let sugarLimit = 50.0
    @State private var showManualAdd = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(Int(model.todayKcal)) kcal").font(.largeTitle.bold())
                        Gauge(value: min(model.todaySugar, sugarLimit), in: 0...sugarLimit) {
                            Text("당류")
                        } currentValueLabel: {
                            Text("\(model.todaySugar, specifier: "%.0f")g / \(Int(sugarLimit))g")
                        }
                    }
                    .padding(.vertical, 8)
                }
                Section("오늘의 스택") {
                    ForEach(model.today) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.body.weight(.medium))
                                Text([item.store, item.time.formatted(date: .omitted, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(item.kcal)) kcal").monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("오늘")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showManualAdd = true } label: { Image(systemName: "plus") }
                    NavigationLink { StatsView() } label: { Image(systemName: "chart.bar") }
                    NavigationLink { SnackListView() } label: { Image(systemName: "list.bullet") }
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showManualAdd) {
                // 현금 결제, 얻어먹은 것 등 결제 감지가 안 되는 군것질
                NavigationStack {
                    CatalogSearchView(title: "뭐 드셨어요?") { p, g in
                        showManualAdd = false
                        Task { await model.addManually([.init(product_id: p.id, name: p.name, qty: 1, grams: g)]) }
                    }
                }
            }
            .overlay {
                if model.today.isEmpty {
                    ContentUnavailableView("아직 오늘 기록이 없어요", systemImage: "takeoutbag.and.cup.and.straw",
                                           description: Text("편의점에서 결제하면 잠금화면에서 바로 기록할 수 있어요."))
                }
            }
            // 알림창(alert)이 떠 있으면 결제를 찾았을 때 확인 화면(sheet)이 뜨지 못한다 → 화면을 막지 않는 안내 띠로
            .safeAreaInset(edge: .top) {
                if let store = model.checkingStore {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("결제 내역을 확인하고 있어요").font(.subheadline.weight(.semibold))
                            Text("\(store)에서 결제한 내역을 찾으면 바로 물어볼게요").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 14))
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.checkingStore)
        }
    }
}
