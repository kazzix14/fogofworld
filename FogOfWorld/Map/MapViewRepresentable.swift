import SwiftUI
import MapKit
import Combine

struct MapViewRepresentable: UIViewRepresentable {
    @ObservedObject var explorationManager: ExplorationManager
    var zoomDelta: Int
    var showTrack: Bool
    var historyDayPoints: [RecordedPoint]?
    var historyMarkerCoordinate: CLLocationCoordinate2D?
    var historyMarkerTimeString: String?
    var historyMarkerSpeedString: String?
    // 度。nil の場合はドット表示、ある場合は矢印を回転させて表示する。
    var historyMarkerCourse: Double?
    // 履歴モード時のみマップタップで最近傍点のインデックスを通知する。通常モードでは nil 化される。
    var onHistoryMapTap: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(explorationManager: explorationManager)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator

        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.showsTraffic = false
        mapView.preferredConfiguration = config

        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true

        mapView.register(HistoryAnnotationView.self, forAnnotationViewWithReuseIdentifier: HistoryAnnotationView.reuseIdentifier)

        // 履歴モード時にマップタップで最近傍ポイントへスライダを飛ばすためのジェスチャ。
        // 通常モード時は coordinator.historyDayPoints が nil で無視されるので常設してよい。
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHistoryMapTap(_:)))
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)
        context.coordinator.historyTapGesture = tap

        let trackOverlay = TrackOverlay()
        mapView.addOverlay(trackOverlay, level: .aboveRoads)

        let fogOverlay = FogOverlay()
        mapView.addOverlay(fogOverlay, level: .aboveLabels)

        context.coordinator.setupSubscription(mapView: mapView)

        if let loc = explorationManager.currentLocation {
            let region = MKCoordinateRegion(
                center: loc,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
            mapView.setRegion(region, animated: false)
        }

        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        let coord = context.coordinator

        if zoomDelta != coord.lastZoomDelta {
            coord.lastZoomDelta = zoomDelta
            var region = uiView.region
            let factor = zoomDelta > coord.previousZoomValue ? 0.5 : 2.0
            coord.previousZoomValue = zoomDelta
            region.span.latitudeDelta *= factor
            region.span.longitudeDelta *= factor
            uiView.setRegion(region, animated: true)
        }
        if showTrack != coord.trackVisible {
            coord.trackVisible = showTrack
            coord.trackRenderer?.visible = showTrack
            coord.trackRenderer?.setNeedsDisplay()
        }
        coord.fogRenderer?.effectsEnabled = explorationManager.fogEffectsEnabled
        // 履歴モード中は「直近N時間」フィルタを無効化して指定日の全軌跡を見せる。
        // 通常モードに戻ったらユーザー設定を復元する。
        let userInterval = explorationManager.trackingSettings.trackDisplayHours.timeInterval
        let effectiveInterval: TimeInterval? = (historyDayPoints != nil) ? nil : userInterval
        if effectiveInterval != coord.lastDisplayInterval {
            coord.lastDisplayInterval = effectiveInterval
            coord.trackRenderer?.displayTimeInterval = effectiveInterval
            coord.trackRenderer?.setNeedsDisplay()
        }
        // 履歴モード中のみ軌跡上に測位点ドットを描画する。通常モードでは点数が多すぎて視認性を損なう。
        let shouldShowPoints = (historyDayPoints != nil)
        if shouldShowPoints != coord.lastShowPoints {
            coord.lastShowPoints = shouldShowPoints
            coord.trackRenderer?.showPoints = shouldShowPoints
            coord.trackRenderer?.setNeedsDisplay()
        }
        // タップで最近傍点ジャンプするためのコールバックと検索対象を coordinator に流す。
        // 通常モードでは nil を渡してハンドラ内でスキップさせる。
        coord.historyDayPoints = historyDayPoints
        coord.onHistoryMapTap = (historyDayPoints != nil) ? onHistoryMapTap : nil
        coord.historyTapGesture?.isEnabled = (historyDayPoints != nil)

        applyHistoryState(mapView: uiView, coordinator: coord)
    }

    private func applyHistoryState(mapView: MKMapView, coordinator: Coordinator) {
        switch (coordinator.isHistoryMode, historyDayPoints) {
        case (false, .some(let points)):
            // enter history
            coordinator.isHistoryMode = true
            coordinator.trackRenderer?.updatePoints(points)
            coordinator.lastHistoryPointsKey = HistoryPointsKey(points)
            syncHistoryAnnotation(mapView: mapView, coordinator: coordinator)
            // 突入時は自動フィット。スクラブ追従より優先するためここで lastHistoryMarkerCoordinate を
            // 先に記録し、後段の追従ロジックでカメラを上書きさせない。
            performAutoFitIfNeeded(mapView: mapView, points: points, coordinator: coordinator)

        case (true, .some(let points)):
            // continue history — 日付が変わった or scrub
            let newKey = HistoryPointsKey(points)
            let dayChanged = coordinator.lastHistoryPointsKey != newKey
            if dayChanged {
                coordinator.trackRenderer?.updatePoints(points)
                coordinator.lastHistoryPointsKey = newKey
            }
            syncHistoryAnnotation(mapView: mapView, coordinator: coordinator)
            if dayChanged {
                performAutoFitIfNeeded(mapView: mapView, points: points, coordinator: coordinator)
            } else {
                // スクラブ — マーカー座標が変わった時だけセンタ追従。
                centerOnMarkerIfChanged(mapView: mapView, coordinator: coordinator)
            }

        case (true, .none):
            // exit history
            coordinator.isHistoryMode = false
            coordinator.lastHistoryPointsKey = nil
            coordinator.historyFitKey = nil
            coordinator.lastHistoryMarkerCoordinate = nil
            // 個別参照経由の removeAnnotation が KVO/再エンキューと競合してビューが残ることがあるため、
            // マップ上の HistoryAnnotation インスタンスを総ざらいして除去する。
            let stale = mapView.annotations.compactMap { $0 as? HistoryAnnotation }
            if !stale.isEmpty {
                mapView.removeAnnotations(stale)
            }
            coordinator.historyAnnotation = nil
            let all = explorationManager.recordedPoints
            coordinator.trackRenderer?.updatePoints(all)
            coordinator.lastPointCount = all.count
            // 履歴で動かしたカメラを現在地に戻す。userLocation の方が新鮮なので優先。
            if let coord = mapView.userLocation.location?.coordinate ?? explorationManager.currentLocation {
                mapView.setCenter(coord, animated: true)
            }

        case (false, .none):
            break
        }
    }

    private func syncHistoryAnnotation(mapView: MKMapView, coordinator: Coordinator) {
        guard let coordinate = historyMarkerCoordinate, let timeString = historyMarkerTimeString else {
            // 個別参照経由の removeAnnotation は KVO/再エンキューと競合しうるため、
            // 記録のない日に切り替わった場合も総ざらいで除去する (exit 時と同じ防御)。
            let stale = mapView.annotations.compactMap { $0 as? HistoryAnnotation }
            if !stale.isEmpty {
                mapView.removeAnnotations(stale)
            }
            coordinator.historyAnnotation = nil
            coordinator.lastHistoryMarkerCoordinate = nil
            return
        }

        if let ann = coordinator.historyAnnotation {
            ann.update(coordinate: coordinate, timeString: timeString, speedString: historyMarkerSpeedString, course: historyMarkerCourse)
        } else {
            let ann = HistoryAnnotation(coordinate: coordinate, timeString: timeString, speedString: historyMarkerSpeedString, course: historyMarkerCourse)
            mapView.addAnnotation(ann)
            coordinator.historyAnnotation = ann
        }
    }

    private func centerOnMarkerIfChanged(mapView: MKMapView, coordinator: Coordinator) {
        guard let coord = historyMarkerCoordinate else { return }
        if let last = coordinator.lastHistoryMarkerCoordinate,
           abs(last.latitude - coord.latitude) < 1e-9,
           abs(last.longitude - coord.longitude) < 1e-9 {
            return
        }
        // スライダースクラブ中に大量のアニメが積み上がるとドラッグ終了後も追従し続けるため非アニメ。
        mapView.setCenter(coord, animated: false)
        coordinator.lastHistoryMarkerCoordinate = coord
    }

    private func performAutoFitIfNeeded(mapView: MKMapView, points: [RecordedPoint], coordinator: Coordinator) {
        let key = HistoryPointsKey(points)
        guard coordinator.historyFitKey != key else { return }
        coordinator.historyFitKey = key
        guard !points.isEmpty else { return }

        if points.count == 1 {
            let region = MKCoordinateRegion(center: points[0].coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
            mapView.setRegion(region, animated: true)
            coordinator.lastHistoryMarkerCoordinate = historyMarkerCoordinate
            return
        }

        // 全点を含む MKMapRect を構築。
        var rect = MKMapRect.null
        for p in points {
            let mp = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
        }

        // 飛行機など広範囲の日はフィットすると地球規模になり実用にならない。
        // 対角距離 50km を閾値に、超えた場合は最終測位ポイント中心+半径2km にズーム。
        let nwCoord = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let seCoord = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let nw = CLLocation(latitude: nwCoord.latitude, longitude: nwCoord.longitude)
        let se = CLLocation(latitude: seCoord.latitude, longitude: seCoord.longitude)
        let diag = nw.distance(from: se)

        if diag <= 50_000 {
            // ヘッダ/コントロールバーに隠れない余白。
            let padding = UIEdgeInsets(top: 80, left: 40, bottom: 200, right: 40)
            mapView.setVisibleMapRect(rect, edgePadding: padding, animated: true)
        } else {
            let last = points[points.count - 1].coordinate
            let region = MKCoordinateRegion(center: last, latitudinalMeters: 4000, longitudinalMeters: 4000)
            mapView.setRegion(region, animated: true)
        }
        // フィット直後に centerOnMarkerIfChanged が走ってカメラを上書きしないよう、現マーカー座標で初期化。
        coordinator.lastHistoryMarkerCoordinate = historyMarkerCoordinate
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let explorationManager: ExplorationManager
        var fogRenderer: FogOverlayRenderer?
        var trackRenderer: TrackOverlayRenderer?
        var hasCenteredOnUser = false
        var lastZoomDelta = 0
        var previousZoomValue = 0
        var lastPointCount = 0
        var trackVisible = true
        var lastDisplayInterval: TimeInterval?

        var isHistoryMode = false
        var historyAnnotation: HistoryAnnotation?
        var lastHistoryPointsKey: HistoryPointsKey?
        var lastShowPoints = false
        // 自動フィットを「同じ日付スナップショットでは1回だけ」にするための鍵。
        var historyFitKey: HistoryPointsKey?
        // マーカー座標の変化検知用。座標が変わらない update でカメラを動かさないためのキャッシュ。
        var lastHistoryMarkerCoordinate: CLLocationCoordinate2D?
        // タップ→最近傍点インデックスを返すためのハンドラと、検索対象になる現在の dayPoints。
        // updateUIView で MapViewRepresentable から同期される。
        var historyDayPoints: [RecordedPoint]?
        var onHistoryMapTap: ((Int) -> Void)?
        var historyTapGesture: UITapGestureRecognizer?

        init(explorationManager: ExplorationManager) {
            self.explorationManager = explorationManager
        }

        var tilesCancellable: AnyCancellable?
        var pointsCancellable: AnyCancellable?

        func setupSubscription(mapView: MKMapView) {
            tilesCancellable = explorationManager.$visitedTiles
                .receive(on: DispatchQueue.main)
                .sink { [weak self] tiles in
                    self?.fogRenderer?.updateTiles(tiles)
                }
            pointsCancellable = explorationManager.$recordedPoints
                .receive(on: DispatchQueue.main)
                .sink { [weak self] points in
                    guard let self else { return }
                    // 履歴モード中は生 recordedPoints の追従を停止して、表示中の日付スナップショットを保つ。
                    if self.isHistoryMode { return }
                    // import.replace 等で配列が縮小した場合 points[lastPointCount...] が範囲外で trap するため
                    // 縮小・初回の両方を「全置換」経路に寄せる。
                    if self.lastPointCount == 0 || self.lastPointCount > points.count {
                        self.trackRenderer?.updatePoints(points)
                    } else {
                        for point in points[self.lastPointCount...] {
                            self.trackRenderer?.appendPoint(point)
                        }
                    }
                    self.lastPointCount = points.count
                }
        }

        @objc func handleHistoryMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard isHistoryMode, let dayPoints = historyDayPoints, !dayPoints.isEmpty else { return }
            guard let onTap = onHistoryMapTap else { return }
            guard let mapView = gesture.view as? MKMapView else { return }

            let touchPoint = gesture.location(in: mapView)
            // 履歴マーカー(円ビュー)を直接タップした場合はスライダージャンプを起こさない。
            // MKAnnotationView のヒットを除外することで、マーカー選択 UX を温存する。
            if let hit = mapView.hitTest(touchPoint, with: nil), hit is MKAnnotationView || hit.superview is MKAnnotationView {
                return
            }

            let tapCoord = mapView.convert(touchPoint, toCoordinateFrom: mapView)
            // 1日分(数千点想定)なら線形探索で十分。経緯度差の二乗和で最近傍を取る。
            // 高緯度での経度1度の縮尺差を補正するため dLon に cos(lat) をかける (距離計算より高速かつバイアス除去)。
            let cosLat = cos(tapCoord.latitude * .pi / 180)
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, p) in dayPoints.enumerated() {
                let dLat = p.latitude - tapCoord.latitude
                let dLon = (p.longitude - tapCoord.longitude) * cosLat
                let d = dLat * dLat + dLon * dLon
                if d < bestDist {
                    bestDist = d
                    bestIdx = i
                }
            }
            onTap(bestIdx)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is FogOverlay {
                let renderer = FogOverlayRenderer(overlay: overlay)
                // updateTiles 前に effectsEnabled を確定しておく。
                // (アニメ判定ロジックが effectsEnabled を参照するため順序が重要)
                renderer.effectsEnabled = explorationManager.fogEffectsEnabled
                renderer.updateTiles(explorationManager.visitedTiles)
                fogRenderer = renderer
                return renderer
            }
            if overlay is TrackOverlay {
                let renderer = TrackOverlayRenderer(overlay: overlay)
                renderer.updatePoints(explorationManager.recordedPoints)
                lastPointCount = explorationManager.recordedPoints.count
                trackRenderer = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is HistoryAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: HistoryAnnotationView.reuseIdentifier, for: annotation)
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !hasCenteredOnUser else { return }
            let region = MKCoordinateRegion(
                center: userLocation.coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
            mapView.setRegion(region, animated: true)
            hasCenteredOnUser = true
        }
    }
}

// 履歴用ポイント配列が「同じ日付の同じスナップショット」かを判定するためのキー。
// 配列同一性ではなく内容識別 (件数 + 先頭/末尾 timestamp) で十分。
struct HistoryPointsKey: Equatable {
    let count: Int
    let firstStamp: Date?
    let lastStamp: Date?

    init(_ points: [RecordedPoint]) {
        count = points.count
        firstStamp = points.first?.timestamp
        lastStamp = points.last?.timestamp
    }
}
