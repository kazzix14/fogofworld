import SwiftUI

struct HistoryControlBar: View {
    @Binding var sliderValue: Double
    let stats: HistoryStats
    let startLabel: String
    let endLabel: String

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(startLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if stats.pointCount >= 2 {
                    Slider(value: $sliderValue, in: 0...Double(stats.pointCount - 1), step: 1)
                } else {
                    // 0 or 1 件: スライド不可。プレースホルダで枠を保つ。
                    Slider(value: .constant(0), in: 0...1)
                        .disabled(true)
                }
                Text(endLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption2)
                Text(Self.summary(for: stats))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private static func summary(for stats: HistoryStats) -> String {
        // 距離・移動時間・件数を中黒で連結。距離/時間は値が無意味な場合は省略。
        var parts: [String] = []
        if let dist = formatDistance(stats.totalDistanceMeters) {
            parts.append(dist)
        }
        if let dur = formatDuration(stats.movingDuration) {
            parts.append(dur)
        }
        parts.append("\(stats.pointCount)件")
        return parts.joined(separator: " · ")
    }

    private static func formatDistance(_ meters: Double) -> String? {
        guard meters > 0 else { return nil }
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return "\(Int(meters.rounded())) m"
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h)h\(m)m"
        } else if m > 0 {
            return "\(m)m"
        } else {
            return "<1m"
        }
    }
}
