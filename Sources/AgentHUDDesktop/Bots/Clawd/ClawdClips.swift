import Foundation

/// Every clip Clawd plays, in one place. Frames are the game's own numbers; everything plays on the 1/12 s grid.
///
/// The art is never changed: a clip only picks frames, how long they show and where the whole picture sits.
/// "Standing" is Walking frame 0, the pose the game itself draws whenever nothing plays.
struct ClawdClips: Sendable {
    var thinking, laptop, desktop, reading, meditating, pointing, waving, lightbulb: ClawdClip
    var start, failed, limitHit: ClawdShot
    var visits: [ClawdVisit: ClawdShot]
    /// Played once when the pointer comes to rest on an idle mark, before the eyes follow it.
    var greet: ClawdShot
    /// Frames of LookingAroundEyesOnly looking toward each 45° sector, counter-clockwise from the right.
    var gaze: [Int]
    var cards: [ClawdCard: ClawdShot]
    /// Held still on a dock that separates its agents while this agent's card is up beside it, turned toward the card.
    /// By a card above or below, Clawd stands instead.
    var pointsAtCard: ClawdFrame
    /// Where a sprite's sign sits, in sprite pixels from where every sign sits, for a sprite whose art is in the way.
    var signShifts: [ClawdSpriteName: ClawdOffset]
    /// How many frames each sprite the clips use had when they were written. A sheet copied from a Claude app whose
    /// sprites differ has them redrawn, and its frames may no longer be the ones these clips mean.
    var frameCounts: [ClawdSpriteName: Int]

    func clip(for look: ClawdLook) -> ClawdClip {
        switch look {
        case .thinking, .retrying: thinking
        case .edit, .command: laptop
        case .longCommand: desktop
        case .read: reading
        case .compacting: meditating
        case .permission: pointing
        case .question: waving
        case .plan: lightbulb
        }
    }

    func shot(for event: ClawdEvent) -> ClawdShot {
        switch event {
        case .start: start
        case .failed: failed
        case .limitHit: limitHit
        }
    }

    /// Every frame any clip shows.
    var frames: Set<ClawdFrame> {
        let clips = ClawdLook.allCases.map(clip(for:))
        var frames = Set<ClawdFrame>()
        for clip in clips {
            frames.formUnion(clip.intro)
            frames.formUnion(clip.entry ?? [])
            frames.formUnion(clip.loopFrames)
            frames.formUnion(clip.outro)
        }
        for clip in clips {
            guard case .replaying(_, let hold, let replay, _) = clip.pace else { continue }
            frames.formUnion(clip.sprite[replay] + [ClawdFrame(clip.sprite, hold)])
        }
        let shots = [start, failed, limitHit, greet] + Array(visits.values) + Array(cards.values)
        frames.formUnion(shots.flatMap { $0.steps.map(\.frame) })
        frames.formUnion(gaze.map { ClawdFrame(.lookingAroundEyesOnly, $0) })
        frames.formUnion([pointsAtCard, .standing])
        return frames
    }

    /// Whether `sheet` has every frame these clips show, in sprites as long as they were when the clips were written.
    func fit(_ sheet: ClawdSheet) -> Bool {
        let frames = frames
        let sprites = Set(frames.map(\.sprite))
        return sprites.allSatisfy { sheet[$0]?.frameCount == frameCounts[$0] } && frames.allSatisfy(sheet.has)
    }
}

extension ClawdClips {
    static let standard: ClawdClips = {
        let thinking = ClawdSpriteName.thinking, laptop = ClawdSpriteName.laptop, desktop = ClawdSpriteName.desktop
        let meditating = ClawdSpriteName.meditating, pointing = ClawdSpriteName.pointing
        let waving = ClawdSpriteName.waving, lightbulb = ClawdSpriteName.lightbulb
        // A working look that runs long plays one cycle, then rests on its first frame.
        let longRun = ClawdPace.resting(after: 20, hold: 3)
        // A wait loops for a while, then plays once in a while, and after two minutes more rarely still.
        let longWait = ClawdPace.waiting(after: 8, every: 2.6, slowAfter: 120, slowEvery: 8)
        // The mini Clawd of sub-agents stands to the right of the body, clear of everything but a prop on that side.
        let miniRight = 13
        return ClawdClips(
            thinking: ClawdClip(name: "thinking", sprite: thinking, intro: thinking[4...5], loop: Array(6...19),
                                outro: thinking[5, 4] + [.standing], pace: longRun, working: true, miniShift: miniRight),
            // Cut straight from standing to the laptop on the ground: its own intro takes longer than most edits. The
            // laptop is on the right, so the mini stands on the left.
            laptop: ClawdClip(name: "laptop", sprite: laptop, intro: laptop[14...16], loop: Array(17...33),
                              outro: laptop[34...42], offset: ClawdOffset(x: -1), pace: longRun, working: true,
                              miniShift: -14),
            // From the laptop, the computer slides in from behind without the turn and the reach. Its five-second cycle
            // is left from any frame, so a turn that ends does not wait for it; the desk leaves no room for the mini.
            desktop: ClawdClip(name: "desktop", sprite: desktop, intro: desktop[3...15], entry: desktop[7...15],
                               loop: Array(16...75), outro: desktop[76...87], exit: .anyFrame, offset: ClawdOffset(x: -3),
                               pace: longRun, working: true),
            // At the game's 12 fps the whole body swivels every frame, too busy for the commonest tool.
            reading: ClawdClip(name: "reading", sprite: .lookingAround, loop: Array(6...15), ticks: 2,
                               pace: longRun, working: true, miniShift: miniRight),
            // Mid-breath frames jump to the stand-up; only the still one leads into it.
            meditating: ClawdClip(name: "meditating", sprite: meditating, intro: meditating[6...13], loop: Array(23...34),
                                  outro: meditating[45...54], exit: .through(23)),
            pointing: ClawdClip(name: "pointing", sprite: pointing, intro: pointing[6...18], loop: Array(19...23),
                                outro: pointing[18] + [.standing], exit: .anyFrame, sign: .permission, pace: longWait),
            waving: ClawdClip(name: "waving", sprite: waving, intro: waving[3...6], loop: Array(7...8),
                              outro: waving[6] + [.standing], exit: .through(8), sign: .question, pace: longWait),
            // The bulb already says "plan", so it carries no sign.
            lightbulb: ClawdClip(name: "lightbulb", sprite: lightbulb, intro: lightbulb[4...10], loop: Array(11...38),
                                 outro: lightbulb[41...44], exit: .anyFrame, offset: ClawdOffset(y: 1),
                                 pace: .replaying(after: 120, hold: 11, replay: 26...29, every: 8)),
            start: ClawdShot(ClawdSpriteName.jumpingHappy[3...20]),
            failed: ClawdShot(ClawdSpriteName.facepalm[2...33], sign: .failed, signDuring: 5...31),
            // Twice round, stopping where the stagger ends, then back on its feet.
            limitHit: ClawdShot(ClawdSpriteName.dizzy[6...21] + ClawdSpriteName.dizzy[6...17]
                                + ClawdSpriteName.dizzy[30...37] + [.standing]),
            visits: [
                .swaying: ClawdShot(ClawdSpriteName.swaying[4...48]),
                .turning: ClawdShot(ClawdSpriteName.turning[2...28] + [.standing]),
                .glancing: ClawdShot(ClawdSpriteName.lookingAroundEyesOnly[0...41]),
                .dozing: ClawdShot(meditating[6...23] + meditating[45...54] + [.standing], sign: .asleep,
                                   hold: (ClawdFrame(meditating, 23), 2)),
            ],
            greet: ClawdShot(waving[3...15] + waving[6] + [.standing]),
            // Right, up-right, up, up-left, left, down-left, down, down-right. The sweep closes on 36, the same
            // picture as 6.
            gaze: [6, 9, 12, 15, 18, 21, 27, 30],
            cards: [
                .done: ClawdShot(ClawdSpriteName.excited[2...21] + [.standing]),
                .longDone: ClawdShot(ClawdSpriteName.dancingHappy[4...38] + ClawdSpriteName.dancingHappy[7] + [.standing]),
                // The card shows for four seconds: the sparkler lit, then burnt out and dropped.
                .reset: ClawdShot(ClawdSpriteName.spark[4...21] + ClawdSpriteName.spark[57...68],
                                  offset: ClawdOffset(x: -2), easeIn: 3, easeOut: 4),
            ],
            // Frame 19 has the arm out at eye height; 18, the turn before it, reads as standing at a mark's size.
            pointsAtCard: ClawdFrame(pointing, 19),
            // Clear of the claw raised to wave, and of the arms thrown up before pointing.
            signShifts: [.waving: ClawdOffset(x: 7), .pointing: ClawdOffset(x: 5)],
            frameCounts: [
                .dancingHappy: 40, .desktop: 88, .dizzy: 41, .excited: 23, .facepalm: 35, .jumpingHappy: 21,
                .laptop: 43, .lightbulb: 50, .lookingAround: 31, .lookingAroundEyesOnly: 42, .meditating: 60,
                .pointing: 43, .spark: 73, .swaying: 49, .thinking: 38, .turning: 29, .walking: 28, .waving: 17,
            ])
    }()
}
