import SwiftUI
import AgentHUDCore

/// An account's quota windows side by side, `columns` to a line (the layout's, four by default), each in an equal
/// share of the width. A last line with fewer windows keeps the columns' width and stands centred under the lines
/// above it, so three windows two to a line make a triangle; a single line shares the width among its windows. The
/// gaps between lines and around the grid follow the panel's spacing; the gap between cells does not.
struct QuotaCellGrid<Cell: View>: View {
    let rows: [AgentRow]
    var columns = 4
    @ViewBuilder let cell: (AgentRow) -> Cell
    @Environment(\.panelSpacing) private var spacing

    /// Between two cells of a line.
    static var cellGap: CGFloat { 8 }

    /// The width of one cell when the grid is `width` wide.
    static func cellWidth(in width: CGFloat, columns: Int) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return (width - 2 * IslandRowLayout.inset - (count - 1) * cellGap) / count
    }

    private var lines: [[AgentRow]] {
        let perLine = max(1, columns)
        return stride(from: 0, to: rows.count, by: perLine).map { Array(rows[$0..<min($0 + perLine, rows.count)]) }
    }

    var body: some View {
        let lines = lines
        let perLine = max(1, columns)
        VStack(alignment: .leading, spacing: spacing.cellLines) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if lines.count > 1, line.count < perLine {
                    CentredGridLine(columns: perLine, gap: Self.cellGap) {
                        ForEach(line) { row in cell(row).frame(maxWidth: .infinity) }
                    }
                } else {
                    HStack(alignment: .top, spacing: Self.cellGap) {
                        ForEach(line) { row in
                            cell(row).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, IslandRowLayout.inset)
        .padding(.vertical, spacing.cellPadding)
    }
}

/// A grid's last line that is not full: its cells as wide as a full line's `columns`, `gap` apart, centred in the line
/// and set from its top, the line as tall as its tallest cell.
struct CentredGridLine: Layout {
    let columns: Int
    let gap: CGFloat

    /// The x of each of `count` cells' leading edges in a line `width` wide.
    static func origins(count: Int, columns: Int, gap: CGFloat, width: CGFloat) -> [CGFloat] {
        let cell = cellWidth(columns: columns, gap: gap, width: width)
        let used = CGFloat(count) * cell + CGFloat(max(0, count - 1)) * gap
        let start = (width - used) / 2
        return (0..<count).map { start + CGFloat($0) * (cell + gap) }
    }

    static func cellWidth(columns: Int, gap: CGFloat, width: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return max(0, (width - (count - 1) * gap) / count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews)
        let cell = Self.cellWidth(columns: columns, gap: gap, width: width)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = Self.cellWidth(columns: columns, gap: gap, width: bounds.width)
        let origins = Self.origins(count: subviews.count, columns: columns, gap: gap, width: bounds.width)
        for (subview, x) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: cell, height: proposal.height))
        }
    }

    /// With no width proposed, a full line of the widest cell.
    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let count = CGFloat(max(1, columns))
        return count * widest + (count - 1) * gap
    }
}

/// A ring's measurements at each size a layout can ask for: its diameter, its line and its figure. The figure's box
/// fits inside the ring's inner edge at "100%", corners and all, which takes a small ring of 40 pt for a 10 pt figure.
/// In a cell narrower than the diameter the ring is as wide as the cell.
extension PanelRingSize {
    var diameter: CGFloat {
        switch self {
        case .small: 40
        case .medium: 46
        case .large: 60
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .small: 3
        case .medium: 4
        case .large: 5
        }
    }

    var figureSize: CGFloat {
        switch self {
        case .small: 10
        case .medium: 11
        case .large: 13
        }
    }
}

/// One quota window as a ring or a number: the readings a bar row shows, in a cell. A ring is the share used, with
/// the selected measure in the line under its name; a number is the selected measure itself. Either keeps one height
/// in every measure, so flipping the picker never resizes the panel.
struct QuotaCell: View {
    enum Style { case ring, number }

    let row: AgentRow
    let metrics: QuotaRowMetrics
    let metric: PanelMeasure
    let style: Style
    let showReset: Bool
    var forecastHint: String?
    var isLoading = false
    var ringSize = PanelRingSize.medium
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Group {
            switch style {
            case .ring: ring
            case .number: number
            }
        }
        .help(metrics.hoverHint(metric, fallback: forecastHint) ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.agent.name)
        .accessibilityValue(spokenValue)
    }

    /// What the cell says in place of its parts: everything it shows. A ring shows the share used whatever the
    /// measure, so that comes first, before the selected measure and its caption.
    var spokenValue: String {
        let share = style == .ring && metric != .quota ? metrics.value(.quota) : nil
        return [share, metrics.value(metric), caption].compactMap { $0 }.joined(separator: ", ")
    }

    /// The window's level as the ring's fill, and as the figure's ink.
    private var levelColor: Color { theme.status(row.level ?? .ok) }
    private var levelText: Color { theme.statusText(row.level ?? .ok) }

    /// The selected measure's figure, which is text.
    private var metricColor: Color {
        guard row.level != nil else { return theme.secondary }
        switch metric {
        case .quota: return levelText
        case .burnRate: return metrics.runsOut ? theme.statusText(.warning) : theme.statusText(.ok)
        case .tokens, .consumed, .cost: return theme.statusText(.ok)
        }
    }

    private var captionColor: Color { metric == .burnRate && metrics.runsOut ? theme.statusText(.warning) : theme.secondary }

    /// The line beside the value: the reset for the share used, where the countdown is shown; else the measure's detail.
    private var caption: String? {
        metric == .quota && !showReset ? nil : metrics.detail(metric, isLoading: isLoading)
    }

    /// The line under the name, and its short form for a cell too narrow for it. A ring holds the share used, so
    /// under any other measure its line carries the measure's value too, and that value alone, or a dash without one,
    /// is the short form; a number's line is the caption alone.
    var captionLine: (text: String?, short: String?) {
        guard style == .ring, metric != .quota else { return (caption, nil) }
        let value: String? = metrics.value(metric)
        let text: String = [value, caption].compactMap { $0 }.joined(separator: " · ")
        let short: String = value ?? "—"
        return (text, short)
    }

    private var projectedUsedPct: Double? {
        guard metric == .burnRate, let used = row.usedPct else { return nil }
        return metrics.runsOut ? 100 : metrics.projectedAtReset ?? used
    }

    // MARK: Ring

    private var ring: some View {
        VStack(spacing: 5) {
            ZStack {
                RingTrack(fraction: (row.usedPct ?? 0) / 100, projectedFraction: projectedUsedPct.map { $0 / 100 },
                          fill: isLoading || row.level == nil ? theme.secondary : levelColor,
                          projectionFill: metrics.runsOut ? theme.status(.warning) : theme.secondary,
                          track: theme.track, lineWidth: ringSize.lineWidth, isLoading: isLoading)
                Text(row.usedPct.map(TokenFormat.percent) ?? row.missingQuotaLabel)
                    .font(.tabular(ringSize.figureSize, .semibold))
                    .foregroundStyle(row.level == nil ? theme.secondary : levelText)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: ringSize.diameter, maxHeight: ringSize.diameter)
            name(.ui(12, .medium), color: theme.text, alignment: .center)
            // The share used is in the ring, so the line under the name carries the selected measure.
            line(captionLine)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Number

    private var number: some View {
        VStack(alignment: .leading, spacing: 3) {
            name(.ui(11), color: theme.secondary, alignment: .leading)
            // A figure is never cut: one too wide for the cell gives way to its short form.
            ViewThatFits(in: .horizontal) {
                Text(metrics.value(metric) ?? "—")
                if let short = metrics.shortValue(metric) { Text(short) }
            }
            .font(.tabular(15, .semibold))
            .foregroundStyle(metrics.value(metric) == nil ? theme.secondary : metricColor)
            .lineLimit(1)
            .contentTransition(.numericText())
            line(captionLine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Parts

    /// A name is never cut: one too long for the cell gives way to the window's short name, and a short name too long
    /// for one line, as a Chinese one can be in six columns, wraps onto the lines it needs. A name is the same in every
    /// measure, so the cell is still as tall in every measure.
    private func name(_ font: Font, color: Color, alignment: TextAlignment) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(row.agent.name).lineLimit(1)
            Text(row.agent.shortName).lineLimit(1)
            Text(row.agent.shortName)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .foregroundStyle(color)
    }

    /// The caption in one line; where it is too long for the cell, its short form; where that is too long as well,
    /// nothing, so a caption never runs past its cell or is cut. The line keeps its height when it says nothing, so the
    /// cell is as tall in every measure; what it leaves out is still in the cell's spoken value.
    private func line(_ caption: (text: String?, short: String?)) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(caption.text.flatMap { $0.isEmpty ? nil : $0 } ?? " ")
            if let short = caption.short { Text(short) }
            Text(" ")
        }
        .font(.tabular(11))
        .foregroundStyle(captionColor)
        .lineLimit(1)
        .contentTransition(.numericText())
    }
}

/// A ring's used share from twelve o'clock, with the share projected by the reset under it: what `ProgressTrack` is
/// to a bar.
struct RingTrack: View {
    var fraction: Double
    var projectedFraction: Double? = nil
    let fill: Color
    var projectionFill: Color? = nil
    let track: Color
    var lineWidth: CGFloat = 4
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(track, lineWidth: lineWidth)
            if isLoading {
                if reduceMotion {
                    Circle().strokeBorder(fill.opacity(0.3), lineWidth: lineWidth)
                } else {
                    Circle().strokeBorder(fill, lineWidth: lineWidth)
                        .phaseAnimator([false, true]) { content, bright in
                            content.opacity(bright ? 0.45 : 0.12)
                        } animation: { _ in
                            .easeInOut(duration: 1)
                        }
                }
            } else {
                // The projection is always drawn, from the used share on, so it grows out of the ring's end.
                arc(to: max(projectedFraction ?? 0, fraction), color: (projectionFill ?? fill).opacity(0.38))
                arc(to: fraction, color: fill)
            }
        }
    }

    private func arc(to end: Double, color: Color) -> some View {
        Circle().inset(by: lineWidth / 2)
            .trim(from: 0, to: min(1, max(0, end)))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}
