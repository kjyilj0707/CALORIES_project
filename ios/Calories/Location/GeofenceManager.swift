import ActivityKit
import CoreLocation
import Foundation
import MapKit

/// 편의점 지오펜스. 진입하면 잠금화면 라이브 액티비티를 띄우고, 이탈하면 닫는다.
/// iOS는 앱당 감시 영역 20개까지라, 크게 이동할 때마다(significant location change)
/// Apple 지도 검색으로 주변 편의점을 다시 찾아 가까운 20곳으로 갈아 끼운다.
/// 매장 좌표는 기기 안에서만 쓰고, 서버에는 체인 이름과 진입·이탈 시각만 보낸다.
final class GeofenceManager: NSObject, CLLocationManagerDelegate {
    static let maxRegions = 20
    static let radius: CLLocationDistance = 40
    static let searchRadius: CLLocationDistance = 1_000

    /// 감시할 체인과 지도 검색 결과 이름에서 찾을 표기 (merchants 표의 chain과 같은 이름을 쓴다)
    static let chains: [(chain: String, patterns: [String])] = [
        ("GS25", ["GS25", "지에스25"]),
        ("CU", ["CU", "씨유"]),
        ("세븐일레븐", ["세븐일레븐", "7-ELEVEN", "7-Eleven"]),
        ("이마트24", ["이마트24", "emart24", "EMART24"]),
    ]

    /// 진입·이탈 기록 (AppModel이 location_visits에 저장)
    var onVisit: ((_ chain: String, _ entered: Bool) -> Void)?

    private let manager = CLLocationManager()
    private var activity: Activity<PaymentTapAttributes>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestPermission() {
        manager.requestAlwaysAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let here = locations.last else { return }
        Task { await refreshStores(around: here) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("위치 오류", error.localizedDescription)
    }

    struct Store {
        let id: String
        let chain: String
        let coordinate: CLLocationCoordinate2D
    }

    /// 주변 편의점을 지도에서 찾아 가까운 순 20곳을 감시한다.
    func refreshStores(around here: CLLocation) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "편의점"
        request.region = MKCoordinateRegion(center: here.coordinate,
                                            latitudinalMeters: Self.searchRadius * 2,
                                            longitudinalMeters: Self.searchRadius * 2)
        request.resultTypes = .pointOfInterest
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return }

        let stores: [Store] = items.compactMap { item in
            guard let name = item.name, let chain = Self.chain(for: name) else { return nil }
            let c = item.placemark.coordinate
            return Store(id: "\(c.latitude),\(c.longitude)", chain: chain, coordinate: c)
        }
        .sorted {
            here.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <
            here.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude))
        }
        monitor(stores)
    }

    static func chain(for name: String) -> String? {
        chains.first { entry in entry.patterns.contains { name.localizedCaseInsensitiveContains($0) } }?.chain
    }

    /// 가까운 매장 20개로 감시 영역을 교체한다.
    func monitor(_ stores: [Store]) {
        manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
        for store in stores.prefix(Self.maxRegions) {
            // identifier에 체인을 담아 진입 시 서버로 체인만 보낸다 (좌표는 기기 밖으로 안 나감)
            let region = CLCircularRegion(center: store.coordinate, radius: Self.radius,
                                          identifier: "\(store.chain)|\(store.id)")
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let chain = Self.chainOf(region)
        startActivity(storeChain: chain)
        onVisit?(chain, true)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let ending = activity
        activity = nil
        Task { await ending?.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(120))) }
        onVisit?(Self.chainOf(region), false)
    }

    private static func chainOf(_ region: CLRegion) -> String {
        String(region.identifier.split(separator: "|").first ?? "편의점")
    }

    /// 탭 후 "확인하고 있어요…", 결제를 찾으면 "알림을 확인해 주세요"로 바꾼다.
    func updateActivity(_ phase: PaymentTapAttributes.ContentState.Phase) {
        guard let activity else { return }
        Task { await activity.update(.init(state: .init(phase: phase), staleDate: nil)) }
    }

    private func startActivity(storeChain: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = PaymentTapAttributes(storeChain: storeChain, enteredAt: .now)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: .init(phase: .waiting), staleDate: .now.addingTimeInterval(30 * 60))
        )
    }
}
