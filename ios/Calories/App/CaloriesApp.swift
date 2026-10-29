import SwiftUI

@main
struct CaloriesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.userID == nil {
                ProgressView()
            } else if model.hasConnectedCard {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $model.pendingPrediction) { ConfirmSheet(prediction: $0) }
        .alert("문제가 생겼어요",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
