import AgentHUDSupport
import Foundation

extension ReportView {
    /// One mark of a logo queue, as the vendors that share its artwork make it up (`VendorMark.key`): whether any of
    /// their sessions works, and what each of those sessions is doing, for the mark's bot to choose from.
    public struct QueueMark: Hashable, Sendable, Identifiable {
        /// The mark the vendors share.
        public let key: String
        /// The first of its vendors in queue order, the one the mark is drawn as.
        public let vendor: String
        /// Any of its vendors has a session in flight, as `queueVendors` says.
        public let isWorking: Bool
        /// Its vendors' sessions whose last event is at most `queueRecency` old, newest first, live status on.
        public let sessions: [SessionLiveFacts]
        /// When the last of the vendor's quota windows that ran out resets; nil while none has.
        public let exhaustedUntil: Date?

        public init(key: String, vendor: String, isWorking: Bool, sessions: [SessionLiveFacts], exhaustedUntil: Date?) {
            self.key = key; self.vendor = vendor; self.isWorking = isWorking; self.sessions = sessions
            self.exhaustedUntil = exhaustedUntil
        }

        public var id: String { key }

        /// Every request its sessions wait on, waited longest first.
        public var requests: [AttentionRequest] { sessions.flatMap(\.requests).sorted(by: AttentionRequest.waitedLonger) }

        /// The request that has waited longest; nil when none waits.
        public var waitedLongest: AttentionRequest? { requests.first }
    }

    /// The logo queue's marks, in its order: `queueVendors` collapsed onto the marks they are drawn with, as the queue
    /// draws them, each with its vendors' recent sessions and what each is doing. A mark's `isWorking` is `queueVendors`'
    /// own, so a mark works exactly when a vendor of it does.
    public var queueMarks: [QueueMark] {
        var order: [String] = [], vendors: [String: String] = [:], working: [String: Bool] = [:]
        for row in queueVendors {
            let key = VendorMark.key(row.vendor)
            if vendors[key] == nil {
                order.append(key)
                vendors[key] = row.vendor
            }
            working[key] = (working[key] ?? false) || row.isWorking
        }
        let cutoff = now.addingTimeInterval(-Self.queueRecency)
        var exhausted: [String: Date] = [:], renewed: [String: Date] = [:]
        for row in rows {
            let key = VendorMark.key(row.agent.vendor)
            if let began = windowBegan(row) { renewed[key] = max(renewed[key] ?? began, began) }
            guard row.assessment.showsLevel, let remaining = row.remainingPct, remaining <= AlertPolicy.exhaustedRemaining,
                  let reset = row.resetAt, reset > now else { continue }
            exhausted[key] = max(exhausted[key] ?? reset, reset)
        }
        // A session runs on its own vendor's windows, which for Grok's clients are the account's, drawn as the clients.
        var sessions: [String: [SessionLiveFacts]] = [:], until: [String: Date] = exhausted
        for session in self.sessions where session.liveStatus && session.lastEventAt >= cutoff {
            guard let vendor = session.source.agentVendor else { continue }
            let key = VendorMark.key(vendor), windows = VendorMark.key(session.source.vendor ?? vendor)
            sessions[key, default: []].append(facts(of: session, exhaustedUntil: exhausted[windows], renewedAt: renewed[windows]))
            if let reset = exhausted[windows] { until[key] = max(until[key] ?? reset, reset) }
        }
        return order.map { key in
            QueueMark(key: key, vendor: vendors[key] ?? key, isWorking: working[key] ?? false, sessions: sessions[key] ?? [],
                      exhaustedUntil: until[key])
        }
    }

    /// When a window of the row's account last began anew, as its reading shows: at its reset, once that has passed with
    /// no reading since, else its reset less its length. Nil for a reading of another account or one that failed.
    private func windowBegan(_ row: AgentRow) -> Date? {
        let reading = row.assessment
        guard reading.hasValue, reading.status.isNormal, reading.isCurrentAccount, reading.observedAt != nil,
              !reading.isFromFuture, let reset = row.resetAt else { return nil }
        if reading.isResetPending { return reset }
        return report?.snapshot(for: row.id)?.cycle.map(\.start).flatMap { $0 <= now ? $0 : nil }
    }

    /// What a session is doing now, as its mark's bot reads it.
    /// - exhaustedUntil: when the session's vendor's windows that ran out reset, which a limit its client gave no reset
    ///   for lasts until.
    /// - renewedAt: when one of the vendor's windows last began anew. A limit its client gave no reset for, with no
    ///   window still used up, has lifted if a window began after the turn ended; else it lasts until the next prompt.
    public func facts(of session: Session, exhaustedUntil: Date? = nil, renewedAt: Date? = nil) -> SessionLiveFacts {
        let turn = session.turn
        let ended = turn.map { !$0.state.isInFlight } == true
        let outcome = ended ? turn?.outcome : nil
        let endedAt = ended ? turn.map { RecordCoding.date($0.observedAtMs) } : nil
        var limitedUntil: Date?
        if case .limited(let resetsAt) = outcome {
            let renewed = renewedAt.flatMap { began in endedAt.map { began > $0 } == true ? began : nil }
            limitedUntil = resetsAt ?? exhaustedUntil ?? renewed
        }
        return SessionLiveFacts(
            sessionID: session.id, vendor: session.source.agentVendor, phase: session.phase,
            activity: session.session.activity, turnID: turn?.turnID,
            turnStartedAt: turn?.startedAtMs.map(RecordCoding.date), outcome: outcome,
            endedAt: endedAt, limitedUntil: limitedUntil,
            observedAt: session.session.lastActivityAt ?? session.session.observedAt, lastEventAt: session.lastEventAt,
            requests: requests(of: session))
    }
}
