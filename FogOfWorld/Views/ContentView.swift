import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject var explorationManager: ExplorationManager
    @State private var zoomDelta = 0
    @State private var showSettings = false
    @State private var showTrack = true
    @State private var historyMode: HistoryMode?

    var body: some View {
        ZStack {
            MapViewRepresentable(
                explorationManager: explorationManager,
                zoomDelta: zoomDelta,
                showTrack: showTrack,
                historyDayPoints: historyMode?.dayPoints,
                historyMarkerCoordinate: historyMarkerPoint?.coordinate,
                historyMarkerTimeString: historyMarkerPoint.map { Self.formatTime($0.timestamp) },
                historyMarkerSpeedString: historyMarkerPoint.flatMap { Self.formatSpeed($0) },
                historyMarkerCourse: historyMarkerPoint.flatMap { Self.markerCourse(for: $0) },
                onHistoryMapTap: { idx in
                    // タップされた最近傍ポイントのインデックスを sliderValue に反映する。
                    // historyMode が nil の場合は無視 (ジェスチャ側でも無効化されている)。
                    guard var updated = self.historyMode else { return }
                    let clamped = max(0, min(updated.dayPoints.count - 1, idx))
                    updated.sliderValue = Double(clamped)
                    self.historyMode = updated
                }
            )
            .ignoresSafeArea()

            VStack {
                if historyMode != nil {
                    HistoryHeaderBar(
                        date: Binding(
                            // get クロージャは self.historyMode を直接参照する。ローカル束縛の
                            // unwrap 値をキャプチャすると DatePicker sheet が開いている間の更新で
                            // ステイル値を返しうる。
                            get: { self.historyMode?.date ?? Calendar.current.startOfDay(for: Date()) },
                            set: { changeHistoryDate(to: $0) }
                        ),
                        dateRange: historyDateRange ?? (Calendar.current.startOfDay(for: Date())...Calendar.current.startOfDay(for: Date())),
                        onClose: { exitHistoryMode() }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }

            VStack {
                Spacer()

                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        settingsButton
                        trackToggle
                        zoomButtons
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 100)
            }

            VStack {
                Spacer()
                if explorationManager.authorizationDenied {
                    permissionDeniedBanner
                } else if historyMode != nil {
                    HistoryControlBar(
                        sliderValue: Binding(
                            get: { historyMode?.sliderValue ?? 0 },
                            set: { newValue in
                                guard var updated = historyMode else { return }
                                updated.sliderValue = newValue
                                self.historyMode = updated
                            }
                        ),
                        stats: historyMode?.stats ?? HistoryStats(totalDistanceMeters: 0, movingDuration: 0, pointCount: 0),
                        startLabel: historyMode?.dayPoints.first.map { Self.formatTime($0.timestamp) } ?? "--:--",
                        endLabel: historyMode?.dayPoints.last.map { Self.formatTime($0.timestamp) } ?? "--:--"
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    statsBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - History helpers

    // 履歴モード突入時に該当日分のポイントをキャッシュする。スライダースクラブのたびに
    // 全 recordedPoints を filter するとフレームレートが破綻するため、HistoryMode に格納して再利用。
    private var historyMarkerPoint: RecordedPoint? {
        guard let historyMode, !historyMode.dayPoints.isEmpty else { return nil }
        let idx = max(0, min(historyMode.dayPoints.count - 1, Int(historyMode.sliderValue.rounded())))
        return historyMode.dayPoints[idx]
    }

    private var historyDateRange: ClosedRange<Date>? {
        // 既存セッションの earliestDay を優先。履歴突入前に呼ばれた場合のみ recordedPoints を走査する。
        let cal = Calendar.current
        if let mode = historyMode {
            return mode.earliestDay...cal.startOfDay(for: Date())
        }
        guard let earliest = explorationManager.recordedPoints.min(by: { $0.timestamp < $1.timestamp })?.timestamp else { return nil }
        return cal.startOfDay(for: earliest)...cal.startOfDay(for: Date())
    }

    private func changeHistoryDate(to newDate: Date) {
        let day = Calendar.current.startOfDay(for: newDate)
        let cal = Calendar.current
        // 同日判定でフィルタしつつ timestamp 昇順にソート。
        // バッチ配信で順序が逆転するケースがあるため明示的にソートしないと marker 検索順が壊れる。
        let points = explorationManager.recordedPoints
            .filter { cal.isDate($0.timestamp, inSameDayAs: day) }
            .sorted { $0.timestamp < $1.timestamp }
        // 初期選択はその日の最終測位ポイント。空配列なら 0 でガード済み。
        let initial = Double(max(0, points.count - 1))
        // earliestDay は同一履歴セッション中は不変扱い。新規エントリ時に1回だけ算出する。
        let earliestDay: Date = {
            if let existing = historyMode?.earliestDay { return existing }
            let earliestStamp = explorationManager.recordedPoints
                .min(by: { $0.timestamp < $1.timestamp })?.timestamp ?? Date()
            return cal.startOfDay(for: earliestStamp)
        }()
        let stats = Self.computeStats(points)
        historyMode = HistoryMode(date: day, sliderValue: initial, dayPoints: points, earliestDay: earliestDay, stats: stats)
    }

    private static func computeStats(_ points: [RecordedPoint]) -> HistoryStats {
        guard points.count >= 2 else {
            return HistoryStats(totalDistanceMeters: 0, movingDuration: 0, pointCount: points.count)
        }
        var totalMeters = 0.0
        var movingSeconds = 0.0
        for i in 1..<points.count {
            let prev = points[i - 1]
            let cur = points[i]
            let d = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: cur.latitude, longitude: cur.longitude))
            totalMeters += d
            let dt = cur.timestamp.timeIntervalSince(prev.timestamp)
            // 区間平均速度が閾値以上なら「移動中」とみなして時間を加算。
            // 片端だけ高速 / 片端のみ nil でも nil = 0 として扱う (停止扱いに寄せる)。
            // CoreLocation は速度不正時に負値 (-1) を返すため max(_, 0) で正規化。
            let prevSpeed = max(prev.speed ?? 0, 0)
            let curSpeed = max(cur.speed ?? 0, 0)
            let avgSpeed = (prevSpeed + curSpeed) / 2
            if avgSpeed >= movingSpeedThreshold {
                movingSeconds += dt
            }
        }
        return HistoryStats(totalDistanceMeters: totalMeters, movingDuration: movingSeconds, pointCount: points.count)
    }

    // スライダースクラブ中に毎フレーム生成するとフレームドロップの要因になるためキャッシュ。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // 移動判定の閾値。これ以下は停止扱いで矢印ではなくドットを出す。
    // 速度ラベル表示の閾値 (1 km/h ≈ 0.28 m/s) より高めにとってある:
    // 1 km/h 未満は誤差レベルで数値も意味がない / 矢印は向きを示すので明確に「動いている」レンジに限定する。
    private static let movingSpeedThreshold: Double = 0.5 // m/s

    private static func formatSpeed(_ point: RecordedPoint) -> String? {
        guard let kmh = point.speedKmh else { return nil }
        // 1 km/h 未満は意味のない誤差なので非表示。
        guard kmh >= 1 else { return nil }
        return "\(Int(kmh.rounded())) km/h"
    }

    private static func markerCourse(for point: RecordedPoint) -> Double? {
        // 停止中は方向不定 (CLLocation の course も意味のある値を返さないため)。
        guard let speed = point.speed, speed >= movingSpeedThreshold else { return nil }
        guard let course = point.course, course >= 0 else { return nil }
        return course
    }

    private func enterHistoryMode() {
        // 入退場アニメーション。changeHistoryDate を直接ラップすると同関数を
        // 日付変更経路 (mid-history) からも使うため、入口専用にここだけアニメ化する。
        withAnimation(.easeInOut(duration: 0.25)) {
            changeHistoryDate(to: Date())
        }
    }

    private func exitHistoryMode() {
        withAnimation(.easeInOut(duration: 0.25)) {
            historyMode = nil
        }
    }

    private var statsBar: some View {
        Button {
            guard !explorationManager.recordedPoints.isEmpty else { return }
            enterHistoryMode()
        } label: {
            HStack(spacing: 12) {
                Label(
                    "\(explorationManager.totalTiles)",
                    systemImage: "square.grid.3x3.fill"
                )
                .font(.caption)

                Text("·")
                    .foregroundStyle(.secondary)

                Label(
                    explorationManager.exploredAreaFormatted,
                    systemImage: "map.fill"
                )
                .font(.caption)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(explorationManager.recordedPoints.isEmpty)
        .padding(.bottom, 44)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 44, height: 44)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(explorationManager)
        }
    }

    private var trackToggle: some View {
        Button {
            showTrack.toggle()
        } label: {
            Image(systemName: showTrack ? "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill" : "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
                .frame(width: 44, height: 44)
                .foregroundStyle(showTrack ? .blue : .secondary)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            Button {
                zoomDelta += 1
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
            }
            Divider()
            Button {
                zoomDelta -= 1
            } label: {
                Image(systemName: "minus")
                    .frame(width: 44, height: 44)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 44)
    }

    private var permissionDeniedBanner: some View {
        VStack(spacing: 8) {
            Text("位置情報の許可が必要です")
                .font(.headline)
            Text("設定アプリから位置情報を許可してください")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 60)
        .padding(.horizontal, 20)
    }
}

struct HistoryMode {
    var date: Date
    // dayPoints 内のインデックスを表す Slider 値。Slider が BinaryFloatingPoint を要求するため Double。
    var sliderValue: Double
    var dayPoints: [RecordedPoint]
    // DatePicker 範囲下限のキャッシュ。recordedPoints.min(by:) を body 毎に走らせると
    // 大規模履歴でスクラブ時にスキャンコストが効くため、エントリ時に1回計算して保持する。
    let earliestDay: Date
    // 当該日の集計値。changeHistoryDate で1回計算してキャッシュし、スクラブ中は再計算しない。
    let stats: HistoryStats
}

struct HistoryStats {
    let totalDistanceMeters: Double
    let movingDuration: TimeInterval
    let pointCount: Int
}
