#if DEBUG
import SwiftUI

/// Every bundled mark as its bot in each of the states it can be told, at one size and on one ground, for snapshots: the
/// looks, the events part way through, the badges, a card's good news and a request turned to its card. Each cell is a
/// still frame from the renderer, placed with the pose the layer would give it and faded as it would be; Clawd is the
/// drawn one, its sprites having a sheet of their own (`ClawdSpritesScene`). A fixed seed makes it the same on every run.
struct BotStatesScene: View {
    /// Side of a mark, in points.
    let side: CGFloat
    let ground: HUDLook.Appearance

    /// One column: a state, how long it has been shown when the frame is taken, and whether the bot stays up, as on a
    /// card, or follows its agent, as on a dock.
    struct Moment: Identifiable {
        let name: String
        let state: BotState
        var event: BotEvent? = nil
        var seconds: TimeInterval = 1.6
        var staysBot = false
        var id: String { name }
    }

    static let moments: [Moment] = [
        Moment(name: "thinking", state: BotState(look: .thinking)),
        Moment(name: "held", state: BotState(look: .thinking, holds: true)),
        Moment(name: "edit", state: BotState(look: .tool(.edit)), seconds: 1.375),
        Moment(name: "long cmd", state: BotState(look: .tool(.longCommand)), seconds: 1.375),
        Moment(name: "plain", state: BotState(look: .plain)),
        Moment(name: "sub-agents", state: BotState(look: .tool(.command), subagents: true)),
        Moment(name: "compacting", state: BotState(look: .compacting)),
        Moment(name: "permission", state: BotState(look: .permission), seconds: 1.4),
        Moment(name: "question", state: BotState(look: .question), seconds: 1.7),
        Moment(name: "plan", state: BotState(look: .plan), seconds: 1.4),
        Moment(name: "at its card", state: BotState(look: .permission, facing: .left)),
        Moment(name: "under its card", state: BotState(look: .permission, facing: .up)),
        Moment(name: "no news", state: BotState(look: .noNews)),
        Moment(name: "hover", state: BotState(look: .idle, hovered: true), seconds: 0.9),
        Moment(name: "asleep", state: BotState(look: .asleep), staysBot: true),
        Moment(name: "start", state: BotState(look: .plain), event: .start, seconds: 0.15),
        Moment(name: "failed", state: BotState(look: .plain), event: .failed, seconds: 0.9),
        Moment(name: "limit hit", state: BotState(look: .plain), event: .limitHit, seconds: 0.5),
        Moment(name: "× badge", state: BotState(look: .idle, badge: .failed)),
        Moment(name: "⧗ badge", state: BotState(look: .tool(.edit), badge: .limited)),
        Moment(name: "reply", state: BotState(card: .done), seconds: 0.3, staysBot: true),
    ]

    private var cell: CGFloat { (side * (1 + 2 * BotRenderer.margin)).rounded(.up) }
    private var paper: Color { ground == .dark ? Color(white: 0.06) : Color(white: 0.93) }
    private var ink: Color { ground == .dark ? .white.opacity(0.6) : .black.opacity(0.6) }

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("\(Int(side)) pt").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink)
                ForEach(Self.moments) { moment in
                    Text(moment.name).font(.system(size: 9)).foregroundStyle(ink).lineLimit(1).fixedSize()
                        .frame(width: max(cell, 52))
                }
            }
            ForEach(AgentArtwork.allVendors, id: \.self) { vendor in
                GridRow {
                    Text(vendor).font(.system(size: 10)).foregroundStyle(ink).lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                    ForEach(Self.moments) { moment in
                        frame(vendor, moment).frame(width: max(cell, 52), height: cell)
                    }
                }
            }
        }
        .padding(16)
        .background(paper)
    }

    @ViewBuilder
    private func frame(_ vendor: String, _ moment: Moment) -> some View {
        if let form = BotForm.form(for: vendor, ground: ground) {
            let motion = Self.motion(form, moment)
            if let image = BotRenderer.image(form, motion: motion, side: side * 2) {
                let center = cell / 2
                let pose = BotActor.transform(motion.pose, side: side, yRunsDown: true)
                Image(decorative: image, scale: 2)
                    .transformEffect(CGAffineTransform(translationX: -center, y: -center).concatenating(pose)
                        .concatenating(CGAffineTransform(translationX: center, y: center)))
                    .opacity(Double(motion.opacity))
            }
        } else {
            AgentLogo(vendor: vendor, size: side)
        }
    }

    /// The motion `moment` asks for, stepped the way the clock steps it, looking a little down and aside, as at a
    /// pointer below the queue. An event plays once the bot is up.
    private static func motion(_ form: BotForm, _ moment: Moment) -> BotMotion {
        var motion = BotMotion(seed: 11)
        motion.staysBot = moment.staysBot
        motion.fit(form.spec)
        motion.set(moment.state, at: 0)
        var now: TimeInterval = 0
        func run(until end: TimeInterval) {
            while now <= end {
                motion.step(to: now, aim: CGPoint(x: 0.35, y: 0.45))
                now += BotPace.lively
            }
        }
        if let event = moment.event {
            run(until: 1)
            motion.play(event, at: now)
            run(until: now + moment.seconds)
        } else {
            run(until: moment.seconds)
        }
        return motion
    }
}
#endif
