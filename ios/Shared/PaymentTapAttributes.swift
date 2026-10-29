import ActivityKit
import Foundation

/// 편의점 진입 시 잠금화면에 띄우는 라이브 액티비티 (앱과 위젯 확장이 함께 쓴다).
/// 사용자가 탭하면 calories://tap 으로 앱이 열리고, 그때 서버가 카드 승인 내역을 1회 조회한다.
struct PaymentTapAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case waiting   // "결제하셨으면 탭하세요"
            case checking  // 탭 후 조회 중
            case found     // 승인 발견, 푸시로 질문 보냄
        }
        var phase: Phase
    }

    /// 매장 체인 ("GS25"). 좌표는 담지 않는다.
    var storeChain: String
    var enteredAt: Date
}

enum DeepLink {
    static let scheme = "calories"

    /// 라이브 액티비티 탭 → 앱 열기. 마이데이터의 "고객이 앱에 접속할 때 조회" 구조와 맞추려고 반드시 앱을 연다.
    static func tap(storeChain: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "tap"
        c.queryItems = [URLQueryItem(name: "store", value: storeChain)]
        return c.url!
    }
}
