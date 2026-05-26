import Foundation
import CoreLocation
import CoreMotion
import Combine
import MapKit
import WidgetKit

final class ExplorationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var visitedTiles: Set<TileCoord> = []
    @Published private(set) var recordedPoints: [RecordedPoint] = []
    @Published private(set) var currentLocation: CLLocationCoordinate2D?
    @Published private(set) var authorizationDenied = false
    @Published var backgroundTrackingEnabled: Bool {
        didSet {
            SharedSettings.backgroundTrackingEnabled = backgroundTrackingEnabled
            applyTrackingMode()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published var trackingSettings: TrackingSettings {
        didSet {
            trackingSettings.save()
            applyTrackingMode()
        }
    }
    @Published var fogEffectsEnabled: Bool {
        didSet {
            SharedSettings.fogEffectsEnabled = fogEffectsEnabled
        }
    }
    @Published var debugSimulateBackground = false {
        didSet {
            clManager.pausesLocationUpdatesAutomatically = !isEffectivelyInForeground
            if debugSimulateBackground {
                applyTrackingMode()
            } else {
                if trackingState == .backgroundStationary {
                    resumeFromStationary()
                }
                resetStationaryCheck()
                applyTrackingMode()
            }
        }
    }

    var totalTiles: Int { visitedTiles.count }

    var exploredAreaKm2: Double {
        SharedTileStore.areaKm2(tileCount: visitedTiles.count)
    }

    var exploredAreaFormatted: String {
        SharedTileStore.areaFormatted(tileCount: visitedTiles.count)
    }

    private let clManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private var saveTask: DispatchWorkItem?
    private var isInForeground = true
    private var isEffectivelyInForeground: Bool { isInForeground && !debugSimulateBackground }
    private var lastLocation: CLLocation?
    private var isAutomotive = false
    private let interpolationMaxInterval: TimeInterval = 15 * 60
    private let interpolationMaxDistance: CLLocationDistance = 500
    private let persistenceQueue = DispatchQueue(label: "com.twogate.fogworld.persistence")

    // Stationary detection
    private enum TrackingState { case moving, backgroundStationary }
    private var trackingState: TrackingState = .moving
    private var stationaryCheckStart: Date?
    private var stationaryTimer: Timer?
    private var isMotionStationary = false
    private var awaitingFullAccuracyFix = false
    private let stationaryRegionId = "com.twogate.fogworld.stationary"
    private let stationaryConfirmationInterval: TimeInterval = 120
    private let stationaryDisplacementThreshold: CLLocationDistance = 30
    private let stationarySpeedThreshold: CLLocationSpeed = 1.0
    private let stationaryGeofenceRadius: CLLocationDistance = 100

    override init() {
        SharedSettings.migrateStandardDefaultsIfNeeded()
        self.backgroundTrackingEnabled = SharedSettings.backgroundTrackingEnabled
        self.trackingSettings = TrackingSettings.load()
        self.fogEffectsEnabled = SharedSettings.fogEffectsEnabled
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = trackingSettings.accuracy.clAccuracy
        clManager.distanceFilter = 5
        clManager.activityType = .other
        clManager.pausesLocationUpdatesAutomatically = false
        SharedTileStore.migrateFromDocumentsIfNeeded()
        loadTiles()
        // マイグレーション/読み込み完了直後にWidget Timelineを更新。
        // これがないと、初回起動より前にWidgetがリフレッシュした場合に最大1時間古いキャッシュを表示しうる。
        WidgetCenter.shared.reloadAllTimelines()

        if SharedSettings.isBackgroundStationary {
            trackingState = .backgroundStationary
            awaitingFullAccuracyFix = true
        }

        startActivityMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    // MARK: - Activity Monitoring

    private func startActivityMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            self?.isAutomotive = activity.automotive
            self?.isMotionStationary = activity.stationary && activity.confidence != .low
        }
    }

    // MARK: - Tracking Control

    private func applyTrackingMode() {
        let status = clManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }

        if backgroundTrackingEnabled {
            if status == .authorizedWhenInUse {
                clManager.requestAlwaysAuthorization()
            }
            clManager.allowsBackgroundLocationUpdates = true
            clManager.showsBackgroundLocationIndicator = true
            clManager.startMonitoringSignificantLocationChanges()
            clManager.startMonitoringVisits()
            if isEffectivelyInForeground {
                clManager.startUpdatingLocation()
            }
        } else {
            clManager.allowsBackgroundLocationUpdates = false
            clManager.showsBackgroundLocationIndicator = false
            clManager.stopMonitoringSignificantLocationChanges()
            clManager.stopMonitoringVisits()
            if isEffectivelyInForeground {
                clManager.startUpdatingLocation()
            } else {
                clManager.stopUpdatingLocation()
            }
        }
    }

    @objc private func appDidEnterBackground() {
        isInForeground = false
        clManager.pausesLocationUpdatesAutomatically = true
        if backgroundTrackingEnabled {
            clManager.desiredAccuracy = trackingSettings.accuracy.clAccuracy
        } else {
            clManager.stopUpdatingLocation()
        }
        // バックグラウンド遷移直前は同期で書き出さないとiOSがアプリをsuspendして書き込みが中断する。
        saveSynchronously()
    }

    @objc private func appWillEnterForeground() {
        isInForeground = true
        clManager.pausesLocationUpdatesAutomatically = !isEffectivelyInForeground
        if trackingState == .backgroundStationary && isEffectivelyInForeground {
            resumeFromStationary()
        }
        if isEffectivelyInForeground {
            resetStationaryCheck()
        }
        // ウィジェットから backgroundTrackingEnabled が変更されている可能性があるので再読込。
        let storedTracking = SharedSettings.backgroundTrackingEnabled
        if storedTracking != backgroundTrackingEnabled {
            backgroundTrackingEnabled = storedTracking
        }
        clManager.desiredAccuracy = trackingSettings.accuracy.clAccuracy
        clManager.startUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            authorizationDenied = false
            if backgroundTrackingEnabled {
                manager.requestAlwaysAuthorization()
            }
            applyTrackingMode()
        case .authorizedAlways:
            authorizationDenied = false
            applyTrackingMode()
        case .denied, .restricted:
            authorizationDenied = true
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if trackingState == .backgroundStationary {
            resumeFromStationary()
            return
        }

        let previousLocation = lastLocation
        var didChange = false
        for location in locations {
            guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { continue }
            currentLocation = location.coordinate

            if awaitingFullAccuracyFix {
                if location.horizontalAccuracy >= 20 { continue }
                awaitingFullAccuracyFix = false
            }

            recordedPoints.append(RecordedPoint(
                coordinate: location.coordinate,
                timestamp: location.timestamp,
                speed: location.speed,
                horizontalAccuracy: location.horizontalAccuracy,
                course: location.course,
                isAutomotive: isAutomotive
            ))

            if let prev = lastLocation,
               location.timestamp.timeIntervalSince(prev.timestamp) <= interpolationMaxInterval
                || location.distance(from: prev) <= interpolationMaxDistance {
                let interpolated = TileCoord.interpolatedTiles(from: prev.coordinate, to: location.coordinate)
                for tile in interpolated {
                    if visitedTiles.insert(tile).inserted {
                        didChange = true
                    }
                }
            }

            let tile = TileCoord(from: location.coordinate)
            if visitedTiles.insert(tile).inserted {
                didChange = true
            }
            lastLocation = location
        }
        if let location = lastLocation {
            adjustAccuracyForProximity(to: location)
            if !isEffectivelyInForeground {
                evaluateStationaryConditions(location: location, previous: previousLocation)
            }
        }
        if didChange || !locations.isEmpty {
            scheduleSave()
        }
    }

    private func adjustAccuracyForProximity(to location: CLLocation) {
        guard trackingSettings.accuracy != .standard else { return }

        let currentTile = TileCoord(from: location.coordinate)
        let userPoint = MKMapPoint(location.coordinate)
        var nearest = Double.greatestFiniteMagnitude

        for dx in -1...1 {
            for dy in -1...1 {
                let tile = TileCoord(x: currentTile.x + dx, y: currentTile.y + dy)
                guard !visitedTiles.contains(tile) else { continue }
                let rect = tile.mapRect
                let clamped = MKMapPoint(
                    x: max(rect.minX, min(rect.maxX, userPoint.x)),
                    y: max(rect.minY, min(rect.maxY, userPoint.y))
                )
                nearest = min(nearest, userPoint.distance(to: clamped))
            }
        }

        let target: CLLocationAccuracy = nearest < 50
            ? trackingSettings.accuracy.clAccuracy
            : kCLLocationAccuracyHundredMeters

        if clManager.desiredAccuracy != target {
            clManager.desiredAccuracy = target
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.horizontalAccuracy < 100, visit.horizontalAccuracy >= 0 else { return }
        let tile = TileCoord(from: visit.coordinate)
        if visitedTiles.insert(tile).inserted {
            scheduleSave()
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == stationaryRegionId else { return }
        resumeFromStationary()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - Stationary Detection

    private func evaluateStationaryConditions(location: CLLocation, previous: CLLocation?) {
        guard trackingState == .moving, backgroundTrackingEnabled else { return }

        let speedValid = location.speed >= 0
        guard !speedValid || location.speed < stationarySpeedThreshold else {
            resetStationaryCheck()
            return
        }

        guard isMotionStationary else {
            resetStationaryCheck()
            return
        }

        if let prev = previous {
            let distance = location.distance(from: prev)
            guard distance < stationaryDisplacementThreshold else {
                resetStationaryCheck()
                return
            }
        }

        if stationaryCheckStart == nil {
            stationaryCheckStart = Date()
            stationaryTimer?.invalidate()
            stationaryTimer = Timer.scheduledTimer(withTimeInterval: stationaryConfirmationInterval, repeats: false) { [weak self] _ in
                self?.completeStationaryTransitionIfValid()
            }
        }

        guard let start = stationaryCheckStart,
              Date().timeIntervalSince(start) >= stationaryConfirmationInterval else {
            return
        }

        transitionToBackgroundStationary(at: location)
    }

    private func transitionToBackgroundStationary(at location: CLLocation) {
        trackingState = .backgroundStationary
        clManager.stopUpdatingLocation()

        let region = CLCircularRegion(
            center: location.coordinate,
            radius: stationaryGeofenceRadius,
            identifier: stationaryRegionId
        )
        region.notifyOnExit = true
        region.notifyOnEntry = false
        clManager.startMonitoring(for: region)

        SharedSettings.isBackgroundStationary = true
        SharedSettings.stationaryCenterLat = location.coordinate.latitude
        SharedSettings.stationaryCenterLon = location.coordinate.longitude

        saveSynchronously()
        resetStationaryCheck()
    }

    private func resumeFromStationary() {
        guard trackingState == .backgroundStationary else { return }
        trackingState = .moving
        awaitingFullAccuracyFix = true

        for region in clManager.monitoredRegions where region.identifier == stationaryRegionId {
            clManager.stopMonitoring(for: region)
        }

        clManager.desiredAccuracy = trackingSettings.accuracy.clAccuracy
        clManager.startUpdatingLocation()

        SharedSettings.isBackgroundStationary = false
        SharedSettings.stationaryCenterLat = nil
        SharedSettings.stationaryCenterLon = nil

        resetStationaryCheck()
    }

    private func completeStationaryTransitionIfValid() {
        guard trackingState == .moving, backgroundTrackingEnabled, isMotionStationary else {
            resetStationaryCheck()
            return
        }
        guard let location = lastLocation else { return }
        transitionToBackgroundStationary(at: location)
    }

    private func resetStationaryCheck() {
        stationaryCheckStart = nil
        stationaryTimer?.invalidate()
        stationaryTimer = nil
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.saveTiles()
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    func saveTiles() {
        let tiles = visitedTiles
        let points = recordedPoints
        persistenceQueue.async {
            SharedTileStore.save(tiles)
            SharedTileStore.savePoints(points)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func saveSynchronously() {
        saveTask?.cancel()
        let tiles = visitedTiles
        let points = recordedPoints
        persistenceQueue.sync {
            SharedTileStore.save(tiles)
            SharedTileStore.savePoints(points)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func loadTiles() {
        visitedTiles = SharedTileStore.load()
        recordedPoints = SharedTileStore.loadPoints()
        SharedSettings.cachedTileCount = visitedTiles.count
    }

    // MARK: - Debug Info

    struct DebugInfo {
        let trackingState: String
        let desiredAccuracy: CLLocationAccuracy
        let distanceFilter: CLLocationDistance
        let activityType: String
        let pausesAutomatically: Bool
        let allowsBackground: Bool
        let authorizationStatus: String
        let isInForeground: Bool
        let debugSimulateBackground: Bool
        let isMotionStationary: Bool
        let isAutomotive: Bool
        let awaitingFullAccuracyFix: Bool
        let backgroundTrackingEnabled: Bool
        let accuracySetting: String
        let lastCoordinate: CLLocationCoordinate2D?
        let lastSpeed: CLLocationSpeed?
        let lastHorizontalAccuracy: CLLocationAccuracy?
        let lastTimestamp: Date?
        let stationaryCheckActive: Bool
        let stationaryCheckElapsed: TimeInterval?
        let geofenceActive: Bool
        let geofenceCenter: CLLocationCoordinate2D?
        let geofenceRadius: CLLocationDistance?
        let monitoredRegionCount: Int
        let tileCount: Int
        let pointCount: Int
    }

    func captureDebugInfo() -> DebugInfo {
        let geofenceRegion = clManager.monitoredRegions
            .compactMap { $0 as? CLCircularRegion }
            .first { $0.identifier == stationaryRegionId }

        let statusString: String
        switch clManager.authorizationStatus {
        case .notDetermined: statusString = "notDetermined"
        case .restricted: statusString = "restricted"
        case .denied: statusString = "denied"
        case .authorizedAlways: statusString = "authorizedAlways"
        case .authorizedWhenInUse: statusString = "authorizedWhenInUse"
        @unknown default: statusString = "unknown"
        }

        let activityString: String
        switch clManager.activityType {
        case .other: activityString = "other"
        case .automotiveNavigation: activityString = "automotiveNavigation"
        case .fitness: activityString = "fitness"
        case .otherNavigation: activityString = "otherNavigation"
        case .airborne: activityString = "airborne"
        @unknown default: activityString = "unknown"
        }

        return DebugInfo(
            trackingState: trackingState == .moving ? "moving" : "backgroundStationary",
            desiredAccuracy: clManager.desiredAccuracy,
            distanceFilter: clManager.distanceFilter,
            activityType: activityString,
            pausesAutomatically: clManager.pausesLocationUpdatesAutomatically,
            allowsBackground: clManager.allowsBackgroundLocationUpdates,
            authorizationStatus: statusString,
            isInForeground: isInForeground,
            debugSimulateBackground: debugSimulateBackground,
            isMotionStationary: isMotionStationary,
            isAutomotive: isAutomotive,
            awaitingFullAccuracyFix: awaitingFullAccuracyFix,
            backgroundTrackingEnabled: backgroundTrackingEnabled,
            accuracySetting: trackingSettings.accuracy.rawValue,
            lastCoordinate: lastLocation?.coordinate,
            lastSpeed: lastLocation?.speed,
            lastHorizontalAccuracy: lastLocation?.horizontalAccuracy,
            lastTimestamp: lastLocation?.timestamp,
            stationaryCheckActive: stationaryCheckStart != nil,
            stationaryCheckElapsed: stationaryCheckStart.map { Date().timeIntervalSince($0) },
            geofenceActive: geofenceRegion != nil,
            geofenceCenter: geofenceRegion?.center,
            geofenceRadius: geofenceRegion?.radius,
            monitoredRegionCount: clManager.monitoredRegions.count,
            tileCount: visitedTiles.count,
            pointCount: recordedPoints.count
        )
    }

    // MARK: - Import / Export

    func exportDocument() -> ExplorationDocument {
        ExplorationDocument(tiles: visitedTiles)
    }

    enum ImportMode {
        case merge
        case replace
    }

    func importTiles(from url: URL, mode: ImportMode) throws -> Int {
        guard url.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported = try decoder.decode(ExplorationData.self, from: data)

        let newTiles = Set(imported.tiles)
        let previousCount = visitedTiles.count

        switch mode {
        case .merge:
            visitedTiles.formUnion(newTiles)
        case .replace:
            visitedTiles = newTiles
        }

        saveTiles()
        return visitedTiles.count - previousCount
    }

}
