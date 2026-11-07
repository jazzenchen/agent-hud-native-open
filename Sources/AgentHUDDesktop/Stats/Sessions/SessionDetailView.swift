import AppKit
import SwiftUI
import AgentHUDCore

/// One session in the statistics window: what it is, where its tokens went turn by turn, and what the agent last said.
struct SessionDetailView: View {
    let session: LiveSession
    let store: UsageStore
    let theme: Theme
    @State private var inspected: Int?
    @State private var inspectedCall: Int?
    @State private var measure = SessionBarMeasure.tokens

    var body: some View {
        let usage = store.sessionUsage(session)
        VStack(alignment: .leading, spacing: 12) {
            header
            figures(usage)
            if let children = session.subagentSessions { agents(children) }
            if let usage {
                tokens(usage)
                if let index = store.focusedTurn, !usage.turns.isEmpty {
                    let bars = SessionBar.turns(usage)
                    if bars.indices.contains(index) { turnCalls(usage, bar: bars[index]) }
                }
                kinds(usage)
                if usage.models.count > 1 { models(usage) }
            }
            if let message = store.sessionMessage(session) { lastMessage(message) }
        }
    }

    // MARK: Header

    private var header: some View {
        let source = store.sessionSource(session)
        let kind = Self.dot(session, store: store)
        let dot = kind == .waiting ? theme.status(.warning)
            : kind == .running ? AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(session.agentId)) : theme.dotEnded
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                if let vendor = source.agentVendor { AgentLogo(vendor: vendor, size: 14) }
                Text(store.consumerName(session.agentId)).font(.ui(12, .semibold))
                Text(source.name).font(.ui(12)).foregroundStyle(theme.secondary)
                Spacer(minLength: 8)
                Text(Self.statusLabel(session, store: store)).font(.tabular(12)).foregroundStyle(theme.secondary)
            }
            if let name = session.agentName, name != session.task {
                Text(name).font(.ui(12, .semibold)).foregroundStyle(theme.secondary).textSelection(.enabled)
            }
            Text(session.task)
                .font(.ui(16, .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text(details).font(.ui(11)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let path = session.transcriptPath {
                    Button(L10n.text("在 Finder 中显示日志", "Reveal log in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .themedLink(theme)
                    .font(.ui(11))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    /// The header's dot: blocked on the user, running in its agent's colour, else grey.
    static func dot(_ session: LiveSession, store: UsageStore) -> SessionDot {
        SessionDot(store.view.phase(of: session))
    }

    /// The header's state, as the store words it.
    static func statusLabel(_ session: LiveSession, store: UsageStore) -> String {
        store.sessionStatusLabel(session)
    }

    /// Project, start time and how long the session has run.
    private var details: String {
        [session.accountWide ? L10n.text("账户 · 跨设备", "Account · across devices") : session.displayPath,
         L10n.text("开始于 ", "Started ") + ChartData.weekdayTime(session.startedAt),
         L10n.text("时长 ", "Duration ") + Countdown.format(session.duration(now: store.now))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Direct children open the same detail surface; its selection resolves against every fresh report.
    private func agents(_ children: [LiveSession]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("子 agent（\(children.count)）", "Sub-agents (\(children.count))"))
                .font(.ui(12, .semibold))
            ForEach(children) { child in
                Button {
                    store.focusedSessionID = child.id
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        let kind = Self.dot(child, store: store)
                        Circle().fill(kind == .waiting ? theme.status(.warning)
                            : kind == .running ? AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(child.agentId)) : theme.dotEnded)
                            .frame(width: 6, height: 6).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(child.agentName ?? child.task).font(.ui(12, .semibold)).lineLimit(1)
                            if child.agentName != nil && child.agentName != child.task {
                                Text(child.task).font(.ui(11)).foregroundStyle(theme.secondary).lineLimit(2)
                            }
                            Text(store.consumerName(child.agentId) + " · " + TokenFormat.short(store.sessionTokens(child).total)
                                 + L10n.text(" Token", " tokens"))
                                .font(.ui(10)).foregroundStyle(theme.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Self.statusLabel(child, store: store)).font(.ui(10)).foregroundStyle(theme.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session-subagent-\(child.id)")
            }
        }
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    // MARK: Figures

    private func figures(_ usage: SessionUsage?) -> some View {
        let total = store.sessionTokens(session)
        var items: [(title: String, value: String, note: String, help: String)] = [
            (L10n.text("Token", "Tokens"), total.isEmpty ? "—" : TokenFormat.short(total.total),
             usage?.subagents.map { L10n.text("含子 agent ", "Sub-agents ") + TokenFormat.short($0.kinds.total) }
                ?? L10n.text("不含缓存读取 ", "Excl. cache reads ") + TokenFormat.short(total.new),
             L10n.text("五类合计，含缓存读取", "All five kinds, cache reads included")),
        ]
        if let cost {
            items.append((L10n.text("费用", "Cost"), cost.value, cost.note, cost.help))
        }
        if let share = session.pctOfWindow {
            items.append((L10n.text("额度占比", "Quota share"), TokenFormat.percent1(share), L10n.text("占当前窗口", "Of the current window"),
                          L10n.text("本会话用掉的当前额度窗口", "What this session used of the current quota window")))
        }
        if let credits = store.sessionCredits(session), credits.total > 0 {
            items.append((L10n.text("积分", "Credits"), credits.text,
                          credits.unattributed > 0.005
                              ? L10n.text("未归因 \(SessionCredits.format(credits.unattributed))", "Unattributed \(SessionCredits.format(credits.unattributed))")
                              : L10n.text("已按模型归因", "Attributed to models"),
                          L10n.text("WorkBuddy 自身计量记录的会话积分消耗；无法唯一确定模型的积分单独列为未归因",
                                    "Credits WorkBuddy's own metering charged the session; the part no one model could be pinned on shows as unattributed")))
            // The same metering records the context the session ran against, which no model call reports on its own.
            if let used = credits.used, let size = credits.size, size > 0 {
                items.append((L10n.text("计量上下文", "Metered context"), TokenFormat.short(used),
                              L10n.text("共 ", "Of ") + TokenFormat.short(size),
                              L10n.text("WorkBuddy 自身计量记录的上下文用量与上限",
                                        "The context usage and limit WorkBuddy's own metering recorded")))
            }
        }
        items.append((L10n.text("轮次", "Turns"), usage.flatMap { $0.turnCount > 0 ? $0.turnCount.formatted() : nil } ?? "—",
                      usage.map { L10n.text("\($0.calls) 次调用", $0.calls == 1 ? "1 call" : "\($0.calls.formatted()) calls") } ?? "",
                      L10n.text("每个 prompt 开始一轮", "Each prompt starts a turn")))
        items.append((L10n.text("上下文", "Context"), context(usage), usage?.contextWindow.map { L10n.text("共 ", "Of ") + TokenFormat.short($0) }
                        ?? L10n.text("最近一次调用", "Latest call"),
                      L10n.text("最近一次模型调用的输入：新输入、缓存写入与缓存读取", "The latest model call's input: fresh, cache writes and cache reads")))
        items.append((L10n.text("缓存命中", "Cache hits"), total.cacheHitRate.map { TokenFormat.percent($0 * 100) } ?? "—",
                      L10n.text("提示读自缓存", "Of prompts, from cache"),
                      L10n.text("缓存读取占全部提示的比例：新输入、缓存写入与缓存读取", "Cache reads as a share of every prompt: fresh input, cache writes and cache reads")))
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(spacing: 4) {
                    Text(item.title).font(.ui(10)).foregroundStyle(theme.secondary).lineLimit(1)
                    Text(item.value).font(.tabular(17, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(item.note).font(.ui(10)).foregroundStyle(theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .help(item.help)
                if index < items.count - 1 { Rectangle().fill(theme.divider).frame(width: 1, height: 34).padding(.top, 6) }
            }
        }
        .card(theme, padding: EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
    }

    private func context(_ usage: SessionUsage?) -> String {
        if let fill = usage?.contextFill { return TokenFormat.percent(fill * 100) }
        return usage?.contextTokens.map(TokenFormat.short) ?? "—"
    }

    /// Priced accounts show their estimated cost; other sessions what their calls would cost at the API's list price.
    private var cost: (value: String, note: String, help: String)? {
        switch store.sessionMoney(session) {
        case .listPrice?:
            return (store.sessionMoney(session)!.text, L10n.text("按 API 价", "At API prices"),
                    L10n.text("同样的调用按厂商 API 公开价计算的费用，不是实际扣费", "What the same calls cost at the vendor's API list price; not a charge"))
        case let money?:
            return (money.text, L10n.text("本会话", "This session"), L10n.text("按账户价格估算的本会话费用", "This session's cost at the account's prices"))
        case nil:
            return nil
        }
    }

    // MARK: Tokens

    private func tokens(_ usage: SessionUsage) -> some View {
        let byTurn = !usage.turns.isEmpty
        let bars = byTurn ? SessionBar.turns(usage) : SessionBar.periods(usage)
        // Cost bars only when every turn has a list price, so no turn looks free.
        let priced = byTurn && bars.allSatisfy { $0.cost != nil }
        let measure = priced ? self.measure : .tokens
        let shown = measure == .cost ? [] : SessionBarsChart.stacked.filter { kind in bars.contains { $0.kinds[kind] > 0 } }
        let hasContext = bars.contains { $0.context != nil }
        let helped = byTurn && bars.contains { $0.subagents != nil }, resent = bars.contains { $0.recached != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(!byTurn ? L10n.text("Token 消耗", "Tokens over time")
                     : measure == .cost ? L10n.text("每轮费用", "Cost per turn") : L10n.text("每轮 Token", "Tokens per turn"))
                    .font(.ui(13, .semibold))
                Spacer(minLength: 8)
                if priced {
                    SegmentedPills(options: [SegmentOption(value: SessionBarMeasure.tokens, label: "Token"),
                                             SegmentOption(value: .cost, label: L10n.text("费用", "Cost"))],
                                   selection: $measure, theme: theme)
                }
            }
            HStack(spacing: 12) {
                ForEach(shown, id: \.self) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(theme.kind(kind)).frame(width: 7, height: 7)
                        Text(kind.label)
                    }
                }
                if measure == .cost {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(SessionBarsChart.costColor(theme)).frame(width: 7, height: 7)
                        Text(L10n.text("按 API 价，含缓存读取", "At API prices, cache reads included"))
                    }
                }
                Spacer(minLength: 8)
                Text(byTurn ? L10n.text("悬停看一轮，点击看它的每次调用", "Hover a turn; click for its calls")
                     : L10n.text("悬停查看每一根柱子", "Hover a bar for details"))
            }
            .font(.ui(10))
            .foregroundStyle(theme.secondary)
            // The marks above bars get a line of their own.
            if helped || resent {
                HStack(spacing: 12) {
                    if helped {
                        HStack(spacing: 4) {
                            Image(systemName: SessionBarsChart.subagentsSymbol).font(.system(size: 8))
                            Text(measure == .cost ? L10n.text("子 agent 参与", "Sub-agents helped")
                                 : L10n.text("子 agent 参与，淡色为其部分", "Sub-agents helped, their part faded"))
                        }
                    }
                    if resent {
                        HStack(spacing: 4) {
                            Image(systemName: SessionBarsChart.resentSymbol).font(.system(size: 8, weight: .bold))
                                .foregroundStyle(theme.status(.warning))
                            Text(L10n.text("缓存读取下降", "Cache reads dropped"))
                        }
                        .help(L10n.text("本轮有调用读到的缓存比上一次少，且有较多未缓存输入",
                                        "A call in this turn read fewer tokens from cache than the previous call and had substantial uncached input"))
                    }
                }
                .font(.ui(10))
                .foregroundStyle(theme.secondary)
            }
            SessionBarsChart(bars: bars, axis: byTurn ? .turn : .time, measure: measure, running: byTurn && store.isSessionLive(session),
                             theme: theme, inspected: $inspected, selected: byTurn ? store.focusedTurn : nil,
                             onSelect: byTurn ? { index in store.focusedTurn = store.focusedTurn == index ? nil : index } : nil)
            if hasContext {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("上下文窗口", "Context window")).font(.ui(12, .semibold))
                    Spacer()
                    Text(L10n.text("缓存读取 + 新输入", "Cache read + new input")
                         + (usage.contextWindow.map { L10n.text(" · 上限 ", " · limit ") + TokenFormat.short($0) } ?? ""))
                        .font(.ui(10)).foregroundStyle(theme.secondary)
                }
                .padding(.top, 8)
                .topDivider(theme.divider)
                ContextWindowChart(bars: bars, axis: byTurn ? .turn : .time, window: usage.contextWindow, theme: theme)
            }
        }
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    // MARK: A turn's calls

    /// The picked turn's calls, one bar each, with the context the session's own calls read; they load when the turn is picked.
    private func turnCalls(_ usage: SessionUsage, bar: SessionBar) -> some View {
        let calls = store.focusedTurnCalls
        let bars = calls.map { SessionBar.forCalls($0, model: store.consumerName) } ?? []
        let measure = bars.allSatisfy({ $0.cost != nil }) ? self.measure : .tokens
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("T\(bar.id) 的每次调用", "T\(bar.id) call by call")).font(.ui(13, .semibold))
                Spacer(minLength: 8)
                Button { store.focusedTurn = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondary) }
                    .buttonStyle(.plain)
                    .help(L10n.text("收起", "Close"))
            }
            if let calls, !calls.isEmpty {
                Text(summary(calls)).font(.ui(10)).foregroundStyle(theme.secondary)
                SessionBarsChart(bars: bars, axis: .call, measure: measure, running: false, theme: theme, inspected: $inspectedCall)
                if bars.contains(where: { $0.context != nil }) {
                    Text(L10n.text("每次调用读入的上下文", "Context each call read"))
                        .font(.ui(12, .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .topDivider(theme.divider)
                    ContextWindowChart(bars: bars, axis: .call, window: usage.contextWindow, theme: theme)
                }
            } else {
                Text(calls == nil ? L10n.text("正在读取这一轮的调用…", "Reading this turn's calls…")
                     : L10n.text("用量库里没有这一轮的调用", "The usage ledger holds no calls of this turn"))
                    .font(.ui(11)).foregroundStyle(theme.secondary)
            }
        }
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .task(id: TurnKey(session: session.id, turn: store.focusedTurn)) { await store.loadFocusedTurnCalls() }
    }

    private struct TurnKey: Hashable { let session: String; let turn: Int? }

    /// How many calls and whose, how long, the price, and the call that added the most.
    private func summary(_ calls: [TurnCall]) -> String {
        let subagentCalls = calls.filter { !$0.own }, logs = Set(subagentCalls.map(\.log)).count
        let largest = calls.max { $0.tokens.kinds.new < $1.tokens.kinds.new }, added = calls.reduce(0) { $0 + $1.tokens.kinds.new }
        let prices = calls.compactMap(\.listCost)
        return [L10n.text("\(calls.count) 次调用", calls.count == 1 ? "1 call" : "\(calls.count) calls"),
                subagentCalls.isEmpty ? nil : L10n.text("其中子 agent \(subagentCalls.count) 次（\(logs) 个）",
                                                        "\(subagentCalls.count) by \(logs == 1 ? "a sub-agent" : "\(logs) sub-agents")"),
                calls.count > 1 ? Countdown.format(max(0, calls.last!.timestamp.timeIntervalSince(calls[0].timestamp))) : nil,
                prices.count == calls.count ? "≈" + MoneyFormat.amount(prices.reduce(0, +), currency: "USD") : nil,
                largest.flatMap { call in added > 0 && calls.count > 1
                    ? L10n.text("新增最多的一次 \(TokenFormat.short(call.tokens.kinds.new))，占 \(Int((Double(call.tokens.kinds.new) / Double(added) * 100).rounded()))%",
                                "Largest call added \(TokenFormat.short(call.tokens.kinds.new)), \(Int((Double(call.tokens.kinds.new) / Double(added) * 100).rounded()))%")
                    : nil }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Kinds

    private func kinds(_ usage: SessionUsage) -> some View {
        let total = usage.total.kinds, sum = max(1, total.total)
        return VStack(spacing: 0) {
            ForEach(Array(TokenKind.allCases.filter { total[$0] > 0 }.enumerated()), id: \.element) { index, kind in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2.5).fill(theme.kind(kind)).frame(width: 9, height: 9)
                    Text(kind.label).font(.ui(12))
                    Spacer()
                    Text(TokenFormat.short(total[kind])).font(.tabular(12, .semibold)).help(total[kind].formatted())
                    Text(TokenFormat.share(total[kind], of: sum)).font(.tabular(11)).foregroundStyle(theme.secondary).frame(width: 40, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(theme.divider).frame(height: 1) } }
            }
        }
        .card(theme, padding: EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
    }

    // MARK: Models

    private func models(_ usage: SessionUsage) -> some View {
        let total = max(1, usage.total.kinds.total)
        let credits = store.sessionCredits(session)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text("模型", "Models")).font(.ui(13, .semibold))
                Spacer()
                Text(L10n.text("缓存命中", "Cache hits")).frame(width: 60, alignment: .trailing)
                Text(L10n.text("占比", "Share")).frame(width: 44, alignment: .trailing)
                Text("Token").frame(width: 60, alignment: .trailing)
                if credits != nil { Text(L10n.text("积分", "Credits")).frame(width: 60, alignment: .trailing) }
            }
            .font(.ui(10)).foregroundStyle(theme.secondary)
            ForEach(usage.models, id: \.agentId) { model in
                let count = model.tokens.kinds.total
                let agent = descriptor(model.agentId)
                HStack(spacing: 8) {
                    Circle().fill(AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(model.agentId))).frame(width: 7, height: 7)
                    AgentLogo(vendor: agent.vendor, size: 12)
                    Text(store.consumerName(model.agentId)).lineLimit(1).frame(width: 150, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.track)
                            Capsule().fill(AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(model.agentId)))
                                .frame(width: proxy.size.width * CGFloat(count) / CGFloat(total))
                        }
                    }
                    .frame(height: 5)
                    Text(model.tokens.kinds.cacheHitRate.map { TokenFormat.percent($0 * 100) } ?? "—").font(.tabular(11))
                        .foregroundStyle(theme.secondary).frame(width: 60, alignment: .trailing)
                    Text(TokenFormat.share(count, of: total)).font(.tabular(11)).foregroundStyle(theme.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(TokenFormat.short(count)).font(.tabular(11)).frame(width: 60, alignment: .trailing)
                    if let credit = credits {
                        Text(credit.byModel[model.agentId].map { SessionCredits.format($0) } ?? "—")
                            .font(.tabular(11)).frame(width: 60, alignment: .trailing)
                            .help(L10n.text("WorkBuddy 计量的该模型积分；未唯一归因到模型的积分不在此列",
                                            "Credits WorkBuddy's metering pinned on this model; unattributed credits are not here"))
                    }
                }
                .font(.ui(12))
                .help(TokenKind.allCases.map { "\($0.label) \(model.tokens.kinds[$0].formatted())" }.joined(separator: " · "))
            }
            if let credits, credits.unattributed > 0.005 {
                Text(L10n.text("另有 \(SessionCredits.format(credits.unattributed)) 积分无法唯一归因到某个模型，未列入上表",
                               "Another \(SessionCredits.format(credits.unattributed)) credits could not be pinned on one model and are not listed"))
                    .font(.ui(10)).foregroundStyle(theme.secondary)
            }
            if let subagents = usage.subagents {
                Text(L10n.text("其中子 agent \(TokenFormat.short(subagents.kinds.total))，会话列表的合计同样包含这部分",
                               "Sub-agents spent \(TokenFormat.short(subagents.kinds.total)) of this, which the session list counts too"))
                    .font(.ui(10)).foregroundStyle(theme.secondary)
            }
        }
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    private func descriptor(_ id: String) -> AgentDescriptor {
        store.consumers.first { $0.id == id }
            ?? AgentDescriptor(id: id, vendor: store.sessionSource(session).vendor ?? "", model: ModelCatalog.consumerName(of: id), source: "", enabled: true)
    }

    // MARK: Last message

    private func lastMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("最近回复", "Last reply")).font(.ui(13, .semibold))
            Text(message)
                .font(.ui(12))
                .foregroundStyle(theme.secondary)
                .lineLimit(12)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }
}

/// A session's money, as its row and its page both show it; always an estimate.
enum SessionMoney {
    /// A priced account's own estimate, in the currency its balance is in.
    case account(Decimal, currency: String)
    /// A priced account with no estimate in that currency.
    case accountUnknown
    /// What the calls would cost at the vendors' API list prices, in US dollars.
    case listPrice(Decimal)

    var text: String {
        switch self {
        case .account(let amount, let currency): "≈" + MoneyFormat.amount(amount, currency: currency, estimated: true)
        case .accountUnknown: "—"
        case .listPrice(let amount): "≈" + MoneyFormat.amount(amount, currency: "USD")
        }
    }
}

extension UsageStore {
    func sessionMoney(_ session: LiveSession) -> SessionMoney? {
        if let billing = report?.billing.first(where: { $0.sessionCosts[session.id] != nil }) {
            return billing.estimatedCost(currency: billing.currency, sessionId: session.id).map { .account($0, currency: billing.currency) }
                ?? .accountUnknown
        }
        return sessionUsage(session)?.listCost.map(SessionMoney.listPrice)
    }
}
