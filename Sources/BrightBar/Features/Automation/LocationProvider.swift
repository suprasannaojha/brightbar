import Combine
import CoreLocation
import Foundation

/// One-shot CoreLocation wrapper for sunrise/sunset.
///
/// Requests When-In-Use only when the schedule is enabled *and* `useLocation`
/// is on. Caches the last fix so sun times still work offline. Re-requests
/// at most once per day.
///
/// Requires `NSLocationUsageDescription` in Info.plist (owned by another
/// target / the integrator).
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    static let cacheKey = "com.brightbar.lastLocation"

    struct CachedCoordinate: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        var timestamp: Date
    }

    @Published var coordinate: (lat: Double, lon: Double)?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastError: String?

    private let defaults: UserDefaults
    private var manager: CLLocationManager?
    private var schedule = ScheduleSettings()
    private var lastRequestAt: Date?
    private var dayObserver: NSObjectProtocol?
    private var isRunning = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let cached = loadCache() {
            coordinate = (cached.latitude, cached.longitude)
        }
    }

    deinit {
        if let dayObserver {
            NotificationCenter.default.removeObserver(dayObserver)
        }
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
    }

    func start(schedule: ScheduleSettings) {
        isRunning = true
        apply(schedule)
        if dayObserver == nil {
            dayObserver = NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshIfNeeded()
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if let dayObserver {
            NotificationCenter.default.removeObserver(dayObserver)
            self.dayObserver = nil
        }
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
    }

    func apply(_ schedule: ScheduleSettings) {
        self.schedule = schedule
        updateLastError()
        guard isRunning, schedule.enabled, schedule.useLocation else { return }
        requestAuthorizationAndLocation()
    }

    /// GPS/cache when `useLocation` is on; otherwise (or as fallback) manual lat/lon.
    func resolvedCoordinate(from schedule: ScheduleSettings? = nil) -> (lat: Double, lon: Double)? {
        let schedule = schedule ?? self.schedule
        if schedule.useLocation, let coordinate {
            return coordinate
        }
        if let lat = schedule.latitude, let lon = schedule.longitude {
            return (lat, lon)
        }
        return nil
    }

    func refreshIfNeeded() {
        guard isRunning, schedule.enabled, schedule.useLocation else { return }
        requestAuthorizationAndLocation()
    }

    // MARK: - CoreLocation

    private func requestAuthorizationAndLocation() {
        guard isRunning, schedule.enabled, schedule.useLocation else { return }
        let manager = ensureManager()
        authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .notDetermined:
            automationLogger.info("Requesting location authorization")
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            lastError = nil
            requestFixIfStale(manager)
        case .denied, .restricted:
            handleDenied()
        @unknown default:
            handleDenied()
        }
    }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager = created
        authorizationStatus = created.authorizationStatus
        return created
    }

    private func requestFixIfStale(_ manager: CLLocationManager) {
        let stale: Bool
        if let cached = loadCache() {
            stale = Date().timeIntervalSince(cached.timestamp) >= 86_400
        } else {
            stale = true
        }
        if !stale, coordinate != nil {
            return
        }
        if let lastRequestAt, Date().timeIntervalSince(lastRequestAt) < 60, coordinate != nil {
            // Avoid hammering CoreLocation if apply() is called in a tight loop.
            return
        }
        lastRequestAt = Date()
        automationLogger.info("Requesting location fix")
        manager.requestLocation()
    }

    private func handleDenied() {
        if coordinate == nil, schedule.latitude == nil || schedule.longitude == nil {
            lastError = "Location permission denied and no manual coordinates are set; sunrise/sunset entries will be skipped."
            automationLogger.error("\(self.lastError ?? "location denied", privacy: .public)")
        } else {
            lastError = nil
        }
    }

    private func updateLastError() {
        if resolvedCoordinate(from: schedule) != nil {
            lastError = nil
        }
    }

    private func accept(latitude: Double, longitude: Double) {
        coordinate = (latitude, longitude)
        lastError = nil
        saveCache(CachedCoordinate(latitude: latitude, longitude: longitude, timestamp: Date()))
        automationLogger.info("Cached location \(latitude, format: .fixed(precision: 3)), \(longitude, format: .fixed(precision: 3))")
    }

    // MARK: - Cache

    private func loadCache() -> CachedCoordinate? {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedCoordinate.self, from: data)
    }

    private func saveCache(_ value: CachedCoordinate) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.authorizationStatus = status
            self.requestAuthorizationAndLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        Task { @MainActor [weak self] in
            self?.accept(latitude: lat, longitude: lon)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.didFail(error)
        }
    }
}

extension LocationProvider {
    fileprivate func didFail(_ error: Error) {
        if coordinate != nil || (schedule.latitude != nil && schedule.longitude != nil) {
            automationLogger.error("Location request failed (using fallback): \(error.localizedDescription, privacy: .public)")
            return
        }
        lastError = error.localizedDescription
        automationLogger.error("Location request failed: \(error.localizedDescription, privacy: .public)")
    }
}
