import SwiftUI

/// 결제를 찾았을 때: "바나나맛우유 + 초코파이 맞죠?" [예] [아니요] [다른 거예요]
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let prediction: Prediction
    @State private var showOthers = false
    @State private var showCatalog = false

    private var top: Prediction.Candidate? { prediction.candidates.first }

    var body: some View {
        VStack(spacing: 20) {
            Text("🍫").font(.system(size: 48))
            if let top {
                Text("방금 \(Prediction.label(top.items))\n사 드셨나요?")
                    .font(.title2.bold()).multilineTextAlignment(.center)
            } else {
                // 내 목록에 금액이 맞는 조합이 없을 때
                Text("방금 결제한 거, 군것질이었나요?")
                    .font(.title2.bold()).multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                answer("예", style: .borderedProminent, disabled: top == nil) {
                    await model.confirm(prediction, response: "yes", items: top?.items ?? [])
                }
                answer("아니요", style: .bordered) {
                    await model.confirm(prediction, response: "no", items: [])
                }
            }
            Button("다른 거예요") { showOthers = true }

            if showOthers {
                // 2~3위 후보 먼저. 카탈로그 검색은 다음 단계에서 붙인다.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(prediction.candidates.dropFirst(), id: \.self) { c in
                        Button(Prediction.label(c.items)) {
                            Task { await model.confirm(prediction, response: "different", items: c.items) }
                        }
                    }
                    Button("목록에 없으면 카탈로그에서 찾기") { showCatalog = true }.font(.footnote)
                }
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .sheet(isPresented: $showCatalog) {
            NavigationStack {
                CatalogSearchView(title: "뭐 드셨어요?") { p, g in
                    showCatalog = false
                    Task {
                        await model.confirm(prediction, response: "different",
                                            items: [.init(product_id: p.id, name: p.name, qty: 1, grams: g)])
                    }
                }
            }
        }
    }

    private func answer<S: PrimitiveButtonStyle>(_ title: String, style: S, disabled: Bool = false,
                                                 action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(style)
        .controlSize(.large)
        .disabled(disabled)
    }
}
