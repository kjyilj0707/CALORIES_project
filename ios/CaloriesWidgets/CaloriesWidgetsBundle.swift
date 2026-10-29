import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CaloriesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PaymentTapLiveActivity()
    }
}

struct PaymentTapLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PaymentTapAttributes.self) { context in
            LockScreenView(storeChain: context.attributes.storeChain, phase: context.state.phase)
                .widgetURL(DeepLink.tap(storeChain: context.attributes.storeChain))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LockScreenView(storeChain: context.attributes.storeChain, phase: context.state.phase)
                }
            } compactLeading: {
                Text("🍫")
            } compactTrailing: {
                Text(context.attributes.storeChain).font(.caption2)
            } minimal: {
                Text("🍫")
            }
            .widgetURL(DeepLink.tap(storeChain: context.attributes.storeChain))
        }
    }
}

private struct LockScreenView: View {
    let storeChain: String
    let phase: PaymentTapAttributes.ContentState.Phase

    var body: some View {
        HStack(spacing: 12) {
            Text("🍫").font(.largeTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(storeChain)에 계시네요").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var subtitle: String {
        switch phase {
        case .waiting: "결제하셨으면 탭하세요"
        case .checking: "결제 내역을 확인하고 있어요…"
        case .found: "알림을 확인해 주세요"
        }
    }
}
