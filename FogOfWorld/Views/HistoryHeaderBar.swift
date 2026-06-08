import SwiftUI

struct HistoryHeaderBar: View {
    @Binding var date: Date
    let dateRange: ClosedRange<Date>
    let onClose: () -> Void

    @State private var showDatePicker = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.primary)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Button {
                showDatePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .medium))
                    Text(Self.dateFormatter.string(from: date))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // 左の閉じるボタンと対称にするための余白プレースホルダ。
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .sheet(isPresented: $showDatePicker) {
            HistoryDatePickerSheet(date: $date, range: dateRange)
                .presentationDetents([.medium])
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d (E)"
        return f
    }()
}

private struct HistoryDatePickerSheet: View {
    @Binding var date: Date
    let range: ClosedRange<Date>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker(
                "日付",
                selection: $date,
                in: range,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("日付を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
