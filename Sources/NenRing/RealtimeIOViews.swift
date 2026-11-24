import SwiftUI

/// Only these small views subscribe to the high-frequency publisher.
struct RealtimeIOLabel: View {
    @ObservedObject var monitor: RealtimeIOMonitor

    var body: some View {
        if monitor.showsInMenuBar, monitor.display != .none {
            HStack(spacing: 5) {
                if monitor.display == .read || monitor.display == .both {
                    Text("↓ " + RealtimeIOMonitor.rate(monitor.data.latest?.readRate))
                }
                if monitor.display == .write || monitor.display == .both {
                    Text("↑ " + RealtimeIOMonitor.rate(monitor.data.latest?.writeRate))
                }
            }
            .monospacedDigit()
            .help(UIString.text("OSブロックI/Oの読込・書込速度。SMART／NAND累積とは別の統計です。"))
        }
    }
}

struct RealtimeIOSettings: View {
    @ObservedObject var monitor: RealtimeIOMonitor

    var body: some View {
        Picker(UIString.text("I/O取得間隔"), selection: $monitor.interval) {
            ForEach([1, 2, 5], id: \.self) { seconds in
                Text("\(seconds) s").tag(seconds)
            }
        }
        Toggle(UIString.text("メニューバーにI/O速度を表示"), isOn: $monitor.showsInMenuBar)
        if monitor.showsInMenuBar {
            Picker(UIString.text("I/O速度の表示"), selection: $monitor.display) {
                ForEach(RealtimeIODisplay.allCases) { item in
                    Text(UIString.text(item.title)).tag(item)
                }
            }
        }
        Text(UIString.text("OSのI/Oカウンタのみを読みます。直近5分はメモリ内に保持し、SMART・FTL取得や寿命予測は増やしません。スリープ中は停止します。"))
            .font(.caption)
            .foregroundStyle(AppColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RealtimeIOPanel: View {
    @ObservedObject var monitor: RealtimeIOMonitor

    var body: some View {
        RealtimeIOContent(data: monitor.data, activity: monitor.writeActivity)
    }
}

struct RealtimeIOContent: View {
    let data: RealtimeIOAccumulator
    var activity: SystemWriteActivity.Rates?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(UIString.text("ディスクI/O"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(UIString.text("直近5分"))
                    .font(.system(size: 10))
                    .foregroundStyle(AppColor.textSecondary)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    rateRow(title: "書込", value: data.latest?.writeRate, color: .red, symbol: "arrow.up")
                    rateRow(title: "読込", value: data.latest?.readRate, color: .blue, symbol: "arrow.down")
                }
                .frame(width: 132)
                VStack(spacing: 3) {
                    RealtimeIOPlot(intervals: data.intervals)
                        .frame(height: 58)
                    HStack {
                        Text(UIString.text("5分前"))
                        Spacer()
                        Text(UIString.text("現在"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(AppColor.textSecondary)
                }
            }
            if data.latest == nil {
                Text(UIString.text("比較待ち・欠測中は速度を表示しません。"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                localizedText("書込の詳細（直近30秒）").fontWeight(.semibold)
                let totals = data.total(seconds: 30, at: ProcessInfo.processInfo.systemUptime)
                HStack {
                    localizedText("対象SSDへの書込")
                    Spacer()
                    Text(RealtimeIOMonitor.rate(totals.coverage > 0 ? totals.written / totals.coverage : nil))
                }
                localizedText("書込プロセス（Mac全体）")
                    .foregroundStyle(AppColor.textSecondary)
                if let activity {
                    ForEach(activity.writers, id: \.id) { item in
                        HStack {
                            Text(verbatim: item.name).lineLimit(1)
                            Spacer()
                            Text(RealtimeIOMonitor.rate(item.rate))
                        }
                    }
                    if activity.writers.isEmpty {
                        localizedText(activity.comparable ? "観測したプロセスの書込なし" : "プロセス情報未取得")
                    }
                    HStack {
                        localizedText("スワップアウト（換算）")
                        Spacer()
                        Text(RealtimeIOMonitor.rate(activity.swap))
                    }
                } else {
                    localizedText("比較待ち")
                }
            }
            .font(.system(size: 11))
            .help(UIString.text("取得可能なプロセスの書込速度上位3件と、システムのスワップアウトを表示します。対象SSDへの物理書込量とは異なります。"))
            VStack(alignment: .leading, spacing: 3) {
                localizedText("短期集計").fontWeight(.semibold)
                let totals = data.total(seconds: 300, at: ProcessInfo.processInfo.systemUptime)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        Text("")
                        Text(UIString.text("読込"))
                        Text(UIString.text("書込"))
                    }
                    .foregroundStyle(AppColor.textSecondary)
                    GridRow {
                        Text(UIString.text("5分間（概算）"))
                        Text(RealtimeIOMonitor.amount(totals.read))
                        Text(RealtimeIOMonitor.amount(totals.written))
                    }
                    GridRow {
                        Text(UIString.text("監視中の累積"))
                        Text(RealtimeIOMonitor.amount(data.sessionRead))
                        Text(RealtimeIOMonitor.amount(data.sessionWritten))
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(UIString.format("観測 %d秒 / 300秒", Int(totals.coverage)))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11))
        }
        .help(UIString.text("上の赤は書込、下の青は読込。同じ速度スケールで表示します。短期集計は観測できた区間のみで、SMART／NAND累積とは別の統計です。"))
    }

    private func rateRow(title: String, value: Double?, color: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(UIString.text(title))
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize()
            Spacer(minLength: 2)
            Text(RealtimeIOMonitor.rate(value))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mirrored activity chart: writes above zero, reads below. Both share one
/// scale; missing segments are never joined and rates are never added together.
private struct RealtimeIOPlot: View {
    let intervals: [RealtimeIOInterval]

    var body: some View {
        Canvas { context, size in
            let now = ProcessInfo.processInfo.systemUptime
            let midpoint = size.height / 2
            let peak = max(1, intervals.reduce(0) { max($0, $1.readRate, $1.writeRate) })
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: midpoint))
            axis.addLine(to: CGPoint(x: size.width, y: midpoint))
            context.stroke(axis, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            let segments = Dictionary(grouping: intervals, by: \.segment)
            for segment in segments.values {
                for writing in [true, false] {
                    let points = segment.map { item in
                        CGPoint(x: (item.end - (now - 300)) / 300 * size.width,
                                y: midpoint + (writing ? -1 : 1)
                                   * (writing ? item.writeRate : item.readRate) / peak * (midpoint - 2))
                    }
                    guard let first = points.first, let last = points.last else { continue }
                    let color: Color = writing ? .red : .blue
                    var fill = Path()
                    fill.move(to: CGPoint(x: first.x, y: midpoint))
                    fill.addLines(points)
                    fill.addLine(to: CGPoint(x: last.x, y: midpoint))
                    fill.closeSubpath()
                    context.fill(fill, with: .color(color.opacity(0.45)))
                    var line = Path()
                    line.addLines(points)
                    context.stroke(line, with: .color(color), lineWidth: 1.2)
                }
            }
        }
        .clipped()
        .accessibilityLabel(UIString.text("I/O推移。上が書込、下が読込。直近5分、共通スケール。"))
    }
}
