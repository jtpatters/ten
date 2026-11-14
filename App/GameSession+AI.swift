import GameAI
import GameCore
import os
import UIKit

/// Who plays the AI players' phases.
enum AIDriver: String, CaseIterable, Identifiable, Sendable {
    /// The M1 AI (`AIPlayer.playTurn`, M1 §13).
    case real
    /// Debug stand-in: `DebugTools.scriptedCommands` (founds cities, fills queues, wanders).
    case scripted
    /// Debug stand-in: `DebugTools.randomCommands` (random moves, attacks, diplomacy).
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .real: "M1 AI"
        case .scripted: "Scripted stand-in"
        case .random: "Random stand-in"
        }
    }

    /// The driver a launch starts with. Release builds always play the real AI. Debug builds
    /// take `-aiDriver real|scripted|random`, else the real AI.
    static var launchDefault: AIDriver {
        #if DEBUG
        UserDefaults.standard.string(forKey: "aiDriver").flatMap(AIDriver.init(rawValue:)) ?? .real
        #else
        .real
        #endif
    }

    /// Plays `player`'s whole phase on `state` (a background copy), ending with `.endTurn`.
    func playTurn(_ state: inout GameState, player: PlayerID) -> AITurnResult {
        #if DEBUG
        switch self {
        case .real: AIPlayer.playTurn(&state, player: player)
        case .scripted: StandInAI.playTurn(&state, player: player, random: false)
        case .random: StandInAI.playTurn(&state, player: player, random: true)
        }
        #else
        AIPlayer.playTurn(&state, player: player)
        #endif
    }
}

#if DEBUG
/// A debug stand-in for the M1 AI (for testing playback against simpler or noisier opponents): the player's `DebugTools` commands go through
/// `GameEngine.apply` one by one (refused ones are dropped), each recorded with its events, then
/// `.endTurn`. Deterministic: the stream is salted with the turn and the player.
enum StandInAI {
    static func playTurn(_ state: inout GameState, player: PlayerID, random: Bool) -> AITurnResult {
        var result = AITurnResult()
        guard state.outcome == nil, state.currentPlayer == player else { return result }
        var rng = SplitMix64(seed: state.seed, salts: UInt64(state.turn), UInt64(player.rawValue), 0xDEB0A1)
        let commands = random ? DebugTools.randomCommands(in: state, rng: &rng) : DebugTools.scriptedCommands(in: state, rng: &rng)
        for command in commands {
            guard state.outcome == nil, state.currentPlayer == player else { return result }
            guard let events = try? GameEngine.apply(command, by: player, to: &state) else { continue }
            result.steps.append(AIStep(command: command, events: events))
        }
        if state.outcome == nil, state.currentPlayer == player, let events = try? GameEngine.apply(.endTurn, by: player, to: &state) {
            result.steps.append(AIStep(command: .endTurn, events: events))
        }
        return result
    }
}
#endif

// Other players' phases (M1 §16 "AI turns"): each is computed by the driver on a background copy
// of the state, then its steps are replayed here on the main state one command at a time through
// `GameEngine.apply`, so the renderer animates each step's visible events in order. Playback
// waits for animations only after steps with events the viewer can see; consecutive move-only
// steps play together (the renderer chains several moves of one unit into one walk); after 3 s
// of playback in a phase the rest lands at once. Quick AI turns, Reduce Motion and a scene in
// the background land everything at once. Input stays off until the viewer's phase begins
// (then it is autosaved). In debug builds the replayed events and the final state hash must
// equal the AI's (the hash is checked off the main actor).
extension GameSession {
    /// Playback per AI phase before the rest of the phase lands at once.
    static let playbackBudget: Duration = .seconds(3)
    /// The camera follows events off screen only when the map has been left alone this long.
    static let cameraHandsOff: Duration = .seconds(2)

    /// Plays every phase up to the viewer's (or the end of the game), with playback.
    func playOtherPhases() {
        guard aiTask == nil else { return }
        guard state.outcome == nil, !isViewerPhase else {
            if isViewerPhase { humanPhaseBegan() }
            return
        }
        // A new round: the notices log's unread count starts again (M1 §16).
        notices.startUnreadCount()
        aiTask = Task { [weak self] in
            await self?.runOtherPhases()
        }
    }

    /// Whether other players' phases are being computed or played back.
    var isPlayingOtherPhases: Bool { aiTask != nil }

    /// Stops other players' phases where they are, because a load may replace the game: the
    /// game on screen must not play on, or autosave, behind it. `aiPhase` and the phase's start
    /// state stay, so a background save still writes that start and `resumeAI()` plays on from
    /// where it stopped. Returns whether anything was stopped.
    @discardableResult
    func suspendAI() -> Bool {
        guard let task = aiTask else { return false }
        task.cancel()
        aiTask = nil
        #if DEBUG
        DebugLog.write("AI phases suspended in \(aiPhase?.civName ?? "no AI")'s phase of turn \(state.turn)")
        #endif
        return true
    }

    /// Plays on after `suspendAI()` (the load did not happen): the phase it stopped in goes on
    /// (keeping the state it began with), or, stopped after the last one ended, the viewer's
    /// phase begins.
    func resumeAI() {
        guard aiTask == nil else { return }
        #if DEBUG
        DebugLog.write("AI phases resumed in turn \(state.turn)")
        #endif
        if state.outcome == nil, !isViewerPhase {
            playOtherPhases()
            return
        }
        aiPhase = nil
        phaseStartState = nil
        refreshSelection()
        if isViewerPhase { humanPhaseBegan() }
    }

    /// Release builds log a replay that diverged from the AI's run (debug builds assert).
    static let playbackLog = Logger(subsystem: "com.tenthousandyears.app", category: "AI playback")

    private func runOtherPhases() async {
        while state.outcome == nil, state.currentPlayer != viewer {
            if Task.isCancelled { return }
            let player = state.currentPlayer
            #if DEBUG
            playDebugPrelude(of: player)
            if state.outcome != nil || state.currentPlayer != player { continue }
            #endif
            let start = state
            // A phase resumed after `suspendAI` keeps the state it began with.
            if phaseStartState?.phaseCount != start.phaseCount {
                phaseStartState = start
                phaseStartCommandCount = commandCount
                notices.markPhaseStart()
            }
            aiPhase = AIPhase(player: player, civName: civName(of: player))
            clearPreviews()
            refreshSelection()

            let driver = aiDriver
            let (result, final, finalHash) = await Task.detached(priority: .userInitiated) {
                var copy = start
                let result = driver.playTurn(&copy, player: player)
                #if DEBUG
                let hash = copy.stateHash()
                #else
                let hash: UInt64 = 0
                #endif
                return (result, copy, hash)
            }.value
            if Task.isCancelled { return }

            let refused = await replay(result.steps, by: player)
            if Task.isCancelled { return }
            if let refused {
                // A step was refused on replay (it cannot be, the rules being deterministic):
                // adopt the AI's own result so the game goes on, with the events of the steps
                // not replayed, so their notices, attention items and commands still count.
                let name = civName(of: player), turn = start.turn, count = result.steps.count
                Self.playbackLog.error("""
                    Replaying \(name, privacy: .public)'s phase of turn \(turn): step \(refused) of \(count) was refused; \
                    the AI's own result is adopted
                    """)
                adopt(final)
                commandCount += result.steps.count - refused
                stateChanged(events: result.steps[refused...].flatMap(\.events), animate: false)
            }
            #if DEBUG
            // Hashing a Standard map takes tens of milliseconds in a debug build: off the main
            // actor, on a copy, so pans and camera glides do not stall after every phase.
            let replayed = state, turn = start.turn, civ = civName(of: player)
            Task.detached(priority: .utility) {
                assert(replayed.stateHash() == finalHash, "the replayed state differs from the AI's (\(player), turn \(turn))")
                let problems = replayed.checkInvariants()
                if !problems.isEmpty {
                    DebugLog.write("Invariants failed after \(civ)'s phase of turn \(turn): \(problems.joined(separator: "; "))")
                }
            }
            #endif
            _ = finalHash
            if state.outcome == nil, state.currentPlayer == player, state.phaseCount == start.phaseCount {
                // The driver did not end its phase: end it here so play goes on.
                guard let events = try? applyOthers(.endTurn, by: player) else { break }
                stateChanged(events: events, animate: false)
            }
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        aiTask = nil
        aiPhase = nil
        phaseStartState = nil
        refreshSelection()
        if isViewerPhase { humanPhaseBegan() }
    }

    #if DEBUG
    /// Automation's `aicommand`: commands the player issues before its driver plays its phase,
    /// applied (and shown) on the main state first, so the driver's copy and the replay both
    /// start after them.
    private func playDebugPrelude(of player: PlayerID) {
        guard let commands = debugPrelude.removeValue(forKey: player) else { return }
        for command in commands {
            do {
                let events = try applyOthers(command, by: player)
                stateChanged(events: events)
            } catch {
                DebugLog.write("aicommand \(command) for \(player) refused: \(error)")
            }
        }
    }
    #endif

    /// Replays one AI phase's steps on the main state. Returns the index of a step that was
    /// refused (the steps before it applied and shown; it and the rest not applied), else nil:
    /// every step applied, or playback was cancelled (the caller checks `Task.isCancelled`).
    private func replay(_ steps: [AIStep], by player: PlayerID) async -> Int? {
        var deadline: ContinuousClock.Instant?
        var stats = PlaybackStats(steps: steps.count)
        defer { stats.log(civName(of: player)) }
        var i = 0
        while i < steps.count {
            if Task.isCancelled { return nil }
            let budgetSpent = deadline.map { ContinuousClock.now >= $0 } ?? false
            let instant = quickAITurns || reduceMotion || !isSceneActive || budgetSpent
            // One step, a run of moves, or (landing at once) everything left.
            var end = i + 1
            if instant {
                end = steps.count
                stats.instantFrom = i
            } else if Self.isMove(steps[i].command) {
                while end < steps.count, Self.isMove(steps[end].command) { end += 1 }
            }
            var events: [EventRecord] = []
            for k in i..<end {
                let step = steps[k]
                do {
                    let produced = try applyOthers(step.command, by: player)
                    assert(produced == step.events, "replaying \(step.command) for \(player) gave other events than the AI's")
                    events += produced
                } catch {
                    assertionFailure("replaying \(step.command) for \(player) was refused: \(error)")
                    if !events.isEmpty { stateChanged(events: events, animate: false) }
                    return k
                }
            }
            let visible = visibleRecords(events)
            if !instant, !visible.isEmpty, deadline == nil { deadline = .now + Self.playbackBudget }
            if !instant, !visible.isEmpty { followIfOffScreen(visible) }
            stateChanged(events: events, animate: !instant)
            if !instant, !visible.isEmpty, let deadline {
                let began = ContinuousClock.now
                await waitForAnimations(until: deadline)
                stats.shown += 1
                stats.waited += ContinuousClock.now - began
            }
            i = end
        }
        return nil
    }

    /// What one AI phase's playback did (logged in debug builds).
    private struct PlaybackStats {
        var steps: Int
        var shown = 0
        var waited = Duration.zero
        var instantFrom: Int?

        func log(_ civ: String) {
            #if DEBUG
            let ms = Int(waited / .milliseconds(1))
            DebugLog.write("AI playback, \(civ): \(steps) step\(steps == 1 ? "" : "s"), \(shown) shown, waited \(ms) ms" + (instantFrom.map { ", instant from step \($0)" } ?? ""))
            #endif
        }
    }

    private static func isMove(_ command: Command) -> Bool {
        if case .moveUnit = command { true } else { false }
    }

    /// Waits for the renderer's animations to end; at the deadline, in the background or when
    /// playback turns instant, they land at once.
    func waitForAnimations(until deadline: ContinuousClock.Instant) async {
        while renderer.isAnimating {
            if Task.isCancelled { return }
            if ContinuousClock.now >= deadline || !isSceneActive || quickAITurns || reduceMotion {
                renderer.skipAnimations()
                return
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Recentres the camera on the first of these events with a place, when none of its places
    /// is in the open part of the view and the map has not been touched for 2 s (M1 §16).
    private func followIfOffScreen(_ records: [EventRecord]) {
        if let touched = lastMapTouch, ContinuousClock.now - touched < Self.cameraHandsOff { return }
        guard let places = records.lazy.map({ Self.places(of: $0.event) }).first(where: { !$0.isEmpty }) else { return }
        guard !places.contains(where: { isOnScreen($0) }) else { return }
        lookAt(places[places.count - 1])
    }

    /// Whether a hex shows in the part of the view the panels leave open, at least `margin`
    /// points inside it.
    func isOnScreen(_ hex: HexCoord, margin: CGFloat = 16) -> Bool {
        let size = renderer.camera.viewSize
        guard size.x > 1, size.y > 1, let p = renderer.screenPoint(of: hex) else { return false }
        let open = CGRect(x: mapInsets.left, y: mapInsets.top, width: CGFloat(size.x) - mapInsets.left - mapInsets.right,
                          height: CGFloat(size.y) - mapInsets.top - mapInsets.bottom)
        return open.insetBy(dx: margin, dy: margin).contains(p)
    }

    /// The tiles an event happens on, most telling last (a move's destination).
    static func places(of event: GameEvent) -> [HexCoord] {
        switch event {
        case let .unitMoved(_, from, path): [from] + (path.last.map { [$0] } ?? [])
        case let .moveInterrupted(_, at): [at]
        case let .unitCreated(_, _, _, at), let .unitKilled(_, _, _, at): [at]
        case let .unitCaptured(_, _, _, _, _, at): [at]
        case let .unitDisbanded(_, _, _, at, _): [at]
        case let .combat(_, _, from, to, _, _, _): [from, to]
        case let .cityFounded(_, _, _, at), let .cityCaptured(_, _, _, _, at), let .cityRazed(_, _, _, at),
             let .cityRevolted(_, _, _, _, at), let .cityJoined(_, _, _, _, at): [at]
        case let .improvementBuilt(_, at, _): [at]
        case let .roadBuilt(at, _), let .tilePillaged(at, _, _, _, _, _, _): [at]
        case let .unitUpgraded(_, _, _, _, at), let .unitPromoted(_, _, _, at): [at]
        // Growth, borders and production happen quietly; the rest has no place.
        default: []
        }
    }

    /// The viewer's phase began (after any playback): autosave (M1 §14).
    func humanPhaseBegan() {
        guard state.outcome == nil, isViewerPhase else { return }
        continueExploring()
        guard state.outcome == nil, isViewerPhase else { return }
        autosave()
        // Playback may have taken the camera away from the selection: bring it back, unless
        // the player has been moving the map.
        if lastMapTouch.map({ ContinuousClock.now - $0 >= Self.cameraHandsOff }) ?? true {
            revealSelectionSoon()
        }
    }
}
