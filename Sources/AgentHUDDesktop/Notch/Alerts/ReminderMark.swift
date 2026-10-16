import AgentHUDCore
import SwiftUI

/// The mark a reminder card shows beside its agent's name: the agent's bot acting out what the card is about, for as long
/// as the card shows, or its logo wearing a still sign.
enum ReminderMark: Hashable, Sendable {
    case bot(BotState)
    case logo(BotSign?)

    /// A request waiting on the user: its bot asks for an approval, an answer to a question, or a plan's review.
    static func request(_ request: PermissionRequest) -> ReminderMark {
        .bot(BotState(look: request.isPlan ? .plan : request.isQuestion ? .question : .permission))
    }

    /// A reply: its bot greets it, and dances for a turn of ten minutes or more when the reply says when it began.
    static func reply(_ completion: SessionCompletion) -> ReminderMark {
        .bot(BotState(card: .reply(from: completion.startedAt, to: completion.completedAt)))
    }

    /// A quota event: a window reset is good news its bot greets; a window used up shows the logo wearing a limit's sign,
    /// and a warning the plain logo.
    static func quota(_ alert: QuotaAlert) -> ReminderMark {
        if alert.kind == .reset { return .bot(BotState(card: .reset)) }
        let empty = alert.snapshot.remainingPct.map { $0 <= AlertPolicy.exhaustedRemaining } ?? false
        return .logo(empty ? .hourglass : nil)
    }

    /// Usage resets added to an account: good news, as a reset is.
    static let credit = ReminderMark.bot(BotState(card: .reset))
}

/// A reminder card's mark (`ReminderMark`).
struct ReminderMarkView: View {
    let vendor: String
    let size: CGFloat
    let mark: ReminderMark

    var body: some View {
        switch mark {
        case .bot(let state): BotMark(vendor: vendor, size: size, state: state)
        case .logo(let sign): StillMark(vendor: vendor, size: size, sign: sign)
        }
    }
}
