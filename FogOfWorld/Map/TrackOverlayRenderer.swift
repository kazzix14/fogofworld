import MapKit
import UIKit
import CoreLocation

final class TrackOverlayRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    let lodCache = TrackLODCache()
    var visible = true
    var displayTimeInterval: TimeInterval?
    // 履歴モード時にONにすると、軌跡線に加えて各測位点を小円で描画する。
    var showPoints = false

    private let trackColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
    private let pointFillColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
    private let pointStrokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
    private let lineWidth: CGFloat = 3
    private let stationaryDuration: TimeInterval = 30 * 60 // 30 min
    private let stationaryDistance: Double = 30 // 30m

    func updatePoints(_ points: [RecordedPoint]) {
        lock.lock()
        lodCache.setAll(points)
        lock.unlock()
        setNeedsDisplay()
    }

    func appendPoint(_ point: RecordedPoint) {
        lock.lock()
        lodCache.appendPoint(point)
        lock.unlock()
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard visible else { return }

        let region = MKCoordinateRegion(mapRect)
        let level = TrackLODCache.Level.from(latitudeDelta: region.span.latitudeDelta)

        lock.lock()
        var points = lodCache.points(for: level)
        lock.unlock()

        if let interval = displayTimeInterval {
            let cutoff = Date().addingTimeInterval(-interval)
            points = points.filter { $0.timestamp >= cutoff }
        }

        points = mergeStationary(points)

        guard !points.isEmpty else { return }

        let padding = mapRect.size.width * 0.1
        let expandedRect = mapRect.insetBy(dx: -padding, dy: -padding)

        // 1点しかない日でも測位点ドットは描画したいので、ポリライン描画だけを >=2 ガード下に置く。
        if points.count >= 2 {
            drawPolyline(points, expandedRect: expandedRect, zoomScale: zoomScale, context: context)
        }

        // 履歴モード時のみ、軌跡線上に個々の測位点を小円で描画する。
        // 1kmレベル(l3)では点が密集して潰れて意味をなさないのでスキップ。
        // ドットは描画範囲ピッタリでよい (ポリラインのexpandedRectは交差描画用なのでここでは過剰)。
        if showPoints && level != .l3 {
            drawPoints(points, mapRect: mapRect, zoomScale: zoomScale, context: context)
        }
    }

    private func drawPolyline(_ points: [RecordedPoint], expandedRect: MKMapRect, zoomScale: MKZoomScale, context: CGContext) {
        context.setStrokeColor(trackColor)
        context.setLineWidth(lineWidth / zoomScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        var isDrawing = false
        var prevInside = false

        for i in 0..<points.count {
            let mapPoint = MKMapPoint(points[i].coordinate)
            let inside = expandedRect.contains(mapPoint)

            if i == 0 {
                prevInside = inside
                if inside {
                    let cgPoint = point(for: mapPoint)
                    context.move(to: cgPoint)
                    isDrawing = true
                }
                continue
            }

            let cgPoint = point(for: mapPoint)

            if inside || prevInside {
                if !isDrawing {
                    let prevMapPoint = MKMapPoint(points[i - 1].coordinate)
                    context.move(to: point(for: prevMapPoint))
                    isDrawing = true
                }
                context.addLine(to: cgPoint)
            } else {
                if isDrawing {
                    context.strokePath()
                    isDrawing = false
                }
            }

            prevInside = inside
        }

        if isDrawing {
            context.strokePath()
        }
    }

    private func drawPoints(_ points: [RecordedPoint], mapRect: MKMapRect, zoomScale: MKZoomScale, context: CGContext) {
        // 画面上で常に約2.5ptに見えるよう zoomScale で割る。線幅と同じスケーリング戦略。
        let radius: CGFloat = 2.5 / zoomScale
        let strokeWidth: CGFloat = 0.8 / zoomScale
        let diameter = radius * 2

        context.setFillColor(pointFillColor)
        context.setStrokeColor(pointStrokeColor)
        context.setLineWidth(strokeWidth)

        for p in points {
            let mapPoint = MKMapPoint(p.coordinate)
            guard mapRect.contains(mapPoint) else { continue }
            let cg = point(for: mapPoint)
            let rect = CGRect(x: cg.x - radius, y: cg.y - radius, width: diameter, height: diameter)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    private func mergeStationary(_ points: [RecordedPoint]) -> [RecordedPoint] {
        guard points.count > 2 else { return points }

        var result: [RecordedPoint] = []
        var stationaryStart = 0

        for i in 0..<points.count {
            let distFromStart = Self.distance(from: points[stationaryStart], to: points[i])

            if distFromStart > stationaryDistance {
                if i - stationaryStart > 1 {
                    let duration = points[i - 1].timestamp.timeIntervalSince(points[stationaryStart].timestamp)
                    if duration >= stationaryDuration {
                        result.append(points[stationaryStart])
                        result.append(points[i - 1])
                    } else {
                        for j in stationaryStart..<i {
                            result.append(points[j])
                        }
                    }
                } else {
                    result.append(points[stationaryStart])
                }
                stationaryStart = i
            }
        }

        let lastDuration = points[points.count - 1].timestamp.timeIntervalSince(points[stationaryStart].timestamp)
        if points.count - stationaryStart > 1 && lastDuration >= stationaryDuration {
            result.append(points[stationaryStart])
            result.append(points[points.count - 1])
        } else {
            for j in stationaryStart..<points.count {
                result.append(points[j])
            }
        }

        return result
    }

    private static func distance(from a: RecordedPoint, to b: RecordedPoint) -> Double {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
    }
}
