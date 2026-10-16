#if DEBUG
import SwiftUI

/// Clawd's own sprites, from the sheet Agent HUD bundles, through every clip Agent HUD plays: one row a clip, frames
/// sampled across its first seconds on the 1/12 s grid, baked as a mark of `side` points shows them on a Retina display.
/// It is for checking the clips by eye; published media keeps the Clawd Agent HUD draws itself, as the demo does.
struct ClawdSpritesScene: View {
    let sheet: ClawdSheet
    let side: CGFloat
    let ground: HUDLook.Appearance

    /// What a row plays, from rest, at time 0.
    enum Shot: Hashable, CaseIterable {
        case look(ClawdLook), subagents, badge, event(ClawdEvent), visit(ClawdVisit), greet, card(ClawdCard), pointing, standing

        // Built in steps: one sum of literals and maps this long is near what Xcode 16.4's type checker gives up on.
        static let allCases: [Shot] = {
            var shots: [Shot] = ClawdLook.allCases.map(Shot.look)
            shots += [.subagents, .badge]
            shots += ClawdEvent.allCases.map(Shot.event)
            shots += ClawdVisit.allCases.map(Shot.visit)
            shots.append(.greet)
            shots += ClawdCard.allCases.map(Shot.card)
            shots += [.pointing, .standing]
            return shots
        }()

        var name: String {
            switch self {
            case .look(let look): "\(look)"
            case .subagents: "sub-agents"
            case .badge: "edit with ×"
            case .event(let event): "\(event)"
            case .visit(let visit): "visit \(visit)"
            case .greet: "greet"
            case .card(let card): "card \(card)"
            case .pointing: "at its card"
            case .standing: "under its card"
            }
        }

        func start(_ player: inout ClawdPlayer) {
            switch self {
            case .look(let look): player.show(look, at: 0)
            case .subagents: player.show(.thinking, subagents: true, at: 0)
            case .badge:
                player.show(.edit, at: 0)
                player.set(badge: .failed, at: 0)
            case .event(let event): player.play(event, at: 0)
            case .visit(let visit): player.visit(visit, at: 0)
            case .greet: player.greet(at: 0)
            case .card(let card): player.card(card, at: 0)
            case .pointing: player.pointAtCard(mirrored: true, at: 0)
            case .standing: player.standAtCard(for: .permission, at: 0)
            }
        }
    }

    /// The ticks of the 1/12 s grid each column is taken at.
    static let ticks = [1, 4, 7, 10, 13, 16, 19, 22, 26, 30, 36, 48, 60]

    private var paper: Color { ground == .dark ? Color(white: 0.06) : Color(white: 0.93) }
    private var ink: Color { ground == .dark ? .white.opacity(0.6) : .black.opacity(0.6) }

    var body: some View {
        let baker = ClawdBaker(sheet: sheet, paintSign: ClawdBaker.signs)
        let cell = BotActor.extent(side: side, scale: 2, outline: 0)
        Grid(horizontalSpacing: 2, verticalSpacing: 4) {
            GridRow {
                Text("\(Int(side)) pt").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink)
                ForEach(Self.ticks, id: \.self) { tick in
                    Text(String(format: "%.2f s", Double(tick) / 12)).font(.system(size: 9)).foregroundStyle(ink)
                        .frame(width: max(cell, 40))
                }
            }
            ForEach(Shot.allCases, id: \.self) { shot in
                GridRow {
                    Text(shot.name).font(.system(size: 10)).foregroundStyle(ink).frame(width: 96, alignment: .trailing)
                    ForEach(Array(Self.frames(shot, sheet: sheet).enumerated()), id: \.offset) { _, picture in
                        Group {
                            if let picture, let image = baker.image(picture, side: side, scale: 2, ground: ground) {
                                Image(decorative: image, scale: 2)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: max(cell, 40), height: cell)
                    }
                }
            }
        }
        .padding(16)
        .background(paper)
    }

    /// What `shot` shows at each column's tick.
    private static func frames(_ shot: Shot, sheet: ClawdSheet) -> [ClawdPicture?] {
        var player = ClawdPlayer(clips: .standard, sheet: sheet, rest: .standing)
        shot.start(&player)
        return ticks.map { player.advance(to: Double($0) / 12) }
    }
}
#endif
