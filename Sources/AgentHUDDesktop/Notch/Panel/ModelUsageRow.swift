import SwiftUI
import AgentHUDCore

/// Aligned quota labels and the selected measure with a flexible progress bar between them.
struct ModelUsageRow: View {
    let row: AgentRow
    let now: Date
    var metric = PanelMeasure.quota
    let showReset: Bool
    var showVendor = true
    var insights: UsageInsights?
    var outlook: QuotaOutlook?
    var tokensPerHour: Double?
    var replyRate: QuotaReplyRate?
    var forecastHint: String?
    var consumed: QuotaConsumption?
    var cost: QuotaListCost?
    var isLoading = false
    @State private var isHovered = false
    @Environment(\.panelSpacing) private var spacing
    @Environment(\.hudTheme) private var theme
    @Environment(\.hudLook) private var look

    var body: some View {
        if let displayedForecastHint {
            content
                .background(IslandHoverPopover(content: QuotaForecastDetails(agent: row.agent, hint: displayedForecastHint),
                                               isHovered: $isHovered))
                .accessibilityElement(children: .combine)
                .accessibilityHint(displayedForecastHint)
                .onDisappear { isHovered = false }
        } else {
            content
        }
    }

    private var content: some View {
        let level = row.level ?? .ok
        let color = theme.status(level)
        let value = metricValue
        let metricLevel: StatusLevel = switch metric {
        case .quota: level
        case .burnRate: runsOut ? .warning : .ok
        case .tokens, .consumed, .cost: .ok
        }
        // The marker is filled with the level's colour; the value is text, in the level's text colour.
        let valueColor = row.level == nil ? theme.secondary : theme.statusText(metricLevel)
        let markerColor = row.level == nil || value == nil ? theme.tertiary : theme.status(metricLevel)
        return HStack(spacing: IslandRowLayout.spacing) {
            Circle()
                .fill(markerColor)
                .frame(width: IslandRowLayout.markerWidth, height: IslandRowLayout.markerWidth)
                // A lit LED on a dark HUD. On a light one a glow would only blur the dot's edge.
                .shadow(color: row.level == nil || value == nil || look.appearance == .light ? .clear : markerColor,
                        radius: 4)
            // A name is never cut: one too long for the column gives way to the window's short name.
            ViewThatFits(in: .horizontal) {
                nameText(row.agent.name)
                nameText(row.agent.shortName)
            }
            .lineLimit(1)
            .frame(width: IslandRowLayout.nameWidth, alignment: .leading)
            .accessibilityLabel(showVendor ? row.agent.displayName : row.agent.name)
            ProgressTrack(fraction: (row.usedPct ?? 0) / 100,
                          projectedFraction: metric == .burnRate ? projectedUsedPct / 100 : nil,
                          fill: isLoading || row.level == nil ? theme.secondary : color,
                          projectionFill: runsOut ? theme.status(.warning) : theme.secondary,
                          track: theme.track, isLoading: isLoading)
                .frame(height: 4)
            // A value is one line and never cut: one wider than its column, such as a burn rate of 100 %/h, takes the
            // room from the bar, so the row is as tall in every measure.
            Text(value ?? "—")
                .font(.tabular(13, .semibold))
                .foregroundStyle(value == nil ? theme.secondary : valueColor)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 62, alignment: .trailing)
                .contentTransition(.numericText())
            if showsDetail {
                Text(metricDetail)
                    .font(.tabular(12))
                    .foregroundStyle(metric == .burnRate && runsOut ? theme.statusText(.warning) : theme.secondary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .trailing)
                    .contentTransition(.numericText())
            }
        }
        .font(.ui(13))
        .padding(.vertical, spacing.rowPadding)
        .padding(.horizontal, IslandRowLayout.inset)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.text.opacity(isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var metrics: QuotaRowMetrics {
        QuotaRowMetrics(row: row, insights: insights, outlook: outlook, now: now, tokensPerHour: tokensPerHour,
                        replyRate: replyRate, consumed: consumed, cost: cost)
    }

    private var metricValue: String? { metrics.value(metric) }

    private var showsDetail: Bool { metric != .quota || showReset }

    private var metricDetail: String { metrics.detail(metric, isLoading: isLoading) }

    private var runsOut: Bool { metrics.runsOut }

    private var exhaustionTimeLabel: String? { metrics.exhaustionTimeLabel }

    private var displayedForecastHint: String? {
        guard metric == .burnRate, let exhaustionTimeLabel else { return forecastHint }
        return L10n.text("预计耗尽：\(exhaustionTimeLabel)", "Exhausts \(exhaustionTimeLabel)")
    }

    private var projectedAtReset: Double? { metrics.projectedAtReset }

    private var projectedUsedPct: Double {
        guard metric == .burnRate else { return row.usedPct ?? 0 }
        return runsOut ? 100 : projectedAtReset ?? row.usedPct ?? 0
    }

    private func nameText(_ label: String) -> Text {
        if showVendor {
            return Text(row.agent.vendorName).fontWeight(.semibold) + Text(" · \(label)").foregroundColor(theme.secondary)
        }
        return Text(label).fontWeight(.semibold)
    }
}

/// What a quota row's measures read at `now`: the share used, the burn rate from its window's insights, the rate
/// tokens are spent at and what the cycle's tokens would cost at list price, each with the detail shown beside it. The
/// burn rate's detail, colour and projection follow the window's outlook as Core weighs it
/// (`ReportView.outlook(for:)`), so the row and the hover hint agree. A row whose reading shows no level has no burn
/// rate, outlook, projection, token rate or cost.
struct QuotaRowMetrics {
    let row: AgentRow
    let insights: UsageInsights?
    let outlook: QuotaOutlook?
    let now: Date
    let tokensPerHour: Double?
    let replyRate: QuotaReplyRate?
    let consumed: QuotaConsumption?
    let cost: QuotaListCost?

    init(row: AgentRow, insights: UsageInsights?, outlook: QuotaOutlook?, now: Date, tokensPerHour: Double?,
         replyRate: QuotaReplyRate? = nil, consumed: QuotaConsumption? = nil, cost: QuotaListCost? = nil) {
        self.row = row
        self.insights = row.assessment.showsLevel ? insights : nil
        self.outlook = row.assessment.showsLevel ? outlook : nil
        self.now = now
        self.tokensPerHour = row.assessment.showsLevel ? tokensPerHour : nil
        self.replyRate = row.assessment.showsLevel ? replyRate : nil
        self.consumed = row.assessment.showsLevel ? consumed : nil
        self.cost = row.assessment.showsLevel ? cost : nil
    }

    func value(_ metric: PanelMeasure) -> String? {
        switch metric {
        case .quota:
            row.usedPct.map(TokenFormat.percent) ?? row.missingQuotaLabel
        case .burnRate:
            insights?.burnRatePctPerHour.map { String(format: "%.1f%%/h", $0) }
        case .tokens:
            replyRate.map { "\($0.lowerBound ? "≥" : "")" + ($0.tokensPerSecond < 10
                ? String(format: "%.1f/s", $0.tokensPerSecond)
                : "\(Int($0.tokensPerSecond))/s") }
        case .consumed:
            consumed.map { TokenFormat.short(Int($0.used)) }
        case .cost:
            // The first currency in code order; a second one, which is rare, is the detail.
            cost.flatMap { cost in cost.currencies.first.map { MoneyFormat.short(cost.amounts[$0] ?? 0, currency: $0) } }
        }
    }

    /// The value in fewer characters, for a cell too narrow for `value(_:)`: a burn rate in whole points, a cost in
    /// thousands or millions as the interface language writes them (`$12K`, `$1.2万`). Nil where the value is short
    /// already: a share used, and tokens per hour, at most three figures and a unit.
    func shortValue(_ metric: PanelMeasure) -> String? {
        switch metric {
        case .quota, .tokens, .consumed:
            return nil
        case .burnRate:
            return insights?.burnRatePctPerHour.map { String(format: "%.0f%%/h", $0) }
        case .cost:
            guard let cost, let first = cost.currencies.first else { return nil }
            // A currency's compact notation needs macOS 15, so the narrow symbol, as `MoneyFormat.short` writes it,
            // goes before the number's compact notation.
            let locale = Locale(identifier: L10n.resolved == .zhHans ? "zh_CN" : "en_US")
            let symbol: String = Decimal(0).formatted(Decimal.FormatStyle.Currency(code: first).presentation(.narrow)
                .precision(.fractionLength(0)).locale(locale)).replacingOccurrences(of: "0", with: "")
            let amount: Double = NSDecimalNumber(decimal: cost.amounts[first] ?? 0).doubleValue
            return symbol + amount.formatted(.number.notation(.compactName).locale(locale))
        }
    }

    func detail(_ metric: PanelMeasure, isLoading: Bool) -> String {
        guard row.usedPct != nil else {
            return metric == .quota && !isLoading ? row.resetLabel(now: now) : "—"
        }
        switch metric {
        case .quota:
            return row.resetLabel(now: now)
        case .burnRate:
            guard let outlook else { return "—" }
            // The row gives the time the rest runs out at, where the hint gives how long it lasts.
            if let exhaustionTimeLabel { return exhaustionTimeLabel }
            if let sampling = QuotaForecast.sampling(outlook: outlook, insights: insights) { return sampling.label }
            return QuotaForecast.text(of: outlook, projectedUsedAtReset: projectedAtReset) ?? "—"
        case .tokens:
            return replyRate.map { L10n.text("\($0.calls) 次回复", "\($0.calls) replies") } ?? "—"
        case .consumed:
            // With a reported capacity the line reads "used / cap"; without one it carries the pace instead.
            if let capacity = consumed?.capacity { return "/ " + TokenFormat.short(Int(capacity)) }
            return tokensPerHour.map { TokenFormat.short(Int($0.rounded())) + "/h" } ?? "—"
        case .cost:
            guard let cost, let first = cost.currencies.first else { return "—" }
            let others = cost.currencies.dropFirst().map { MoneyFormat.short(cost.amounts[$0] ?? 0, currency: $0) }
            if !others.isEmpty { return "+ " + others.joined(separator: " + ") }
            return cost.perHour(first).map { MoneyFormat.short($0, currency: first) + "/h" } ?? "—"
        }
    }

    /// Time at which this pace consumes the rest, only when the outlook has that happen before the window resets.
    var exhaustsBeforeReset: Date? {
        guard case .exhausts(let interval, beforeReset: true) = outlook else { return nil }
        return now.addingTimeInterval(interval)
    }

    /// Whether the window has run out, or runs out before its reset at this pace: the burn rate then wears the warning
    /// colour and the projection reaches the end of the track.
    var runsOut: Bool { outlook == .exhausted || exhaustsBeforeReset != nil }

    var exhaustionTimeLabel: String? {
        guard let date = exhaustsBeforeReset else { return nil }
        if date.timeIntervalSince(now) < 7 * 86400 { return ChartData.relativeWeekdayTime(date, now: now) }
        return date.formatted(Date.FormatStyle().month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(L10n.dateLocale))
    }

    /// Used by the reset at the existing burn rate, when the outlook has the rest last past the reset; the UI does not
    /// invent a second forecast.
    var projectedAtReset: Double? {
        guard case .exhausts(_, beforeReset: false) = outlook else { return nil }
        return row.usedPct.flatMap { QuotaMath.projectedUsedAtReset(usedPct: $0, insights: insights, resetAt: row.resetAt, now: now) }
    }
}

struct ProgressTrack: View {
    var fraction: Double
    var projectedFraction: Double? = nil
    let fill: Color
    var projectionFill: Color? = nil
    let track: Color
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if isLoading {
                    if reduceMotion {
                        Capsule().fill(fill.opacity(0.3))
                    } else {
                        Capsule().fill(fill)
                            .phaseAnimator([false, true]) { content, bright in
                                content.opacity(bright ? 0.45 : 0.12)
                            } animation: { _ in
                                .easeInOut(duration: 1)
                            }
                    }
                } else {
                    if let projectedFraction, projectedFraction > fraction {
                        Capsule()
                            .fill((projectionFill ?? fill).opacity(0.38))
                            .frame(width: max(0, min(1, projectedFraction)) * proxy.size.width)
                    }
                    Capsule().fill(fill).frame(width: max(0, min(1, fraction)) * proxy.size.width)
                }
            }
        }
    }
}
