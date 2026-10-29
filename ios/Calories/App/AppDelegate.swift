import UIKit
import UserNotifications

/// 푸시 알림과 [예][아니요][다른 거예요] 액션 버튼.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let snackCategory = "SNACK_CONFIRM"

    enum Action: String {
        case yes = "SNACK_YES"
        case no = "SNACK_NO"
        case different = "SNACK_DIFFERENT"
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.snackCategory,
                actions: [
                    UNNotificationAction(identifier: Action.yes.rawValue, title: "예"),
                    UNNotificationAction(identifier: Action.no.rawValue, title: "아니요"),
                    // 직접 고르는 화면이 필요하므로 앱을 연다
                    UNNotificationAction(identifier: Action.different.rawValue, title: "다른 거예요", options: [.foreground]),
                ],
                intentIdentifiers: []
            ),
        ])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // TODO: 기기 토큰을 서버에 저장 (APNs는 Apple 개발자 계정이 있어야 실제로 동작)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let action = Action(rawValue: response.actionIdentifier) else { return }
        let eventID = response.notification.request.content.userInfo["event_id"] as? String
        // TODO: confirmations 표에 응답 저장 (event_id, response)
        print("응답", action, eventID ?? "-")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
