import GameCore

/// One command the AI applied, with the events it produced (the App replays these on its own
/// state, with playback, M1 §16).
public struct AIStep: Sendable {
    public var command: Command
    public var events: [EventRecord]

    public init(command: Command, events: [EventRecord]) {
        self.command = command
        self.events = events
    }
}

/// Everything an AI did in one phase, in order; the last step is its `.endTurn`.
public struct AITurnResult: Sendable {
    public var steps: [AIStep]

    public init(steps: [AIStep] = []) {
        self.steps = steps
    }
}

/// How an AI plays a phase (M1 §13), derived afresh every phase.
public enum AIPosture: String, Sendable, CaseIterable {
    /// At war with someone.
    case war
    /// The war test holds for a rival except for the army: build one.
    case prepare
    /// A good site exists and there is room for more cities.
    case expand
    /// Otherwise.
    case develop
}

/// A command the engine refused during an AI phase. The AI skips it and goes on; the goal is
/// none (a refusal means the AI misjudged what its player may do, or fog hid something).
public struct AIRejection: Sendable, CustomStringConvertible {
    public var turn: Int
    public var player: PlayerID
    public var command: Command
    public var error: CommandError

    public var description: String { "turn \(turn) \(player): \(command) refused: \(error)" }
}

/// An AI phase with what the AI made of it (tests, HeadlessSim).
public struct AIPhaseReport: Sendable {
    /// What `AIPlayer.playTurn` returns.
    public var result: AITurnResult
    /// The posture at the end of the phase's planning (after any war declaration).
    public var posture: AIPosture
    /// The rival the AI prepares against or fights (nil: none).
    public var rival: PlayerID?
    /// Commands the engine refused (skipped).
    public var rejections: [AIRejection]
    /// The phase stopped issuing commands at `AIRules.maxCommandsPerPhase`.
    public var hitCommandCap: Bool
    /// A one-line account of the plan (army against estimate, rally city, target), for traces.
    public var planSummary: String
    /// The rival's city the army marches on, and the own city it gathers at (nil: none).
    public var target: CityID?
    public var rally: CityID?
    /// At war, the army marches on the target instead of gathering at the rally city.
    public var advancing: Bool
    /// With `narrate`: one line per notable decision of the phase, with its reason (war, peace,
    /// purchases, founding, razing, retiring Scouts), in order. Empty otherwise.
    public var notes: [String]
    /// With `profile`: the time each step of the phase took (planning, each tactic, settlers,
    /// builders, exploring, the military, cities), in order. Empty otherwise.
    public var stepTimes: [(step: String, time: Duration)]
    /// Civilians that found no safe way forward this phase and waited for an escort (M1 §13
    /// Safety), in the order they asked (HeadlessSim counts the Settlers' waiting phases).
    public var escortRequests: [UnitID] = []
}

/// The M1 AI (M1 §13). Decides only from its player's knowledge (`state.view(for:)` and its
/// queries) and changes the state only through `GameEngine.apply`; deterministic, and
/// stateless between phases: posture, rival, target, rally city and army are derived each
/// phase. Every threshold comes from the rules data (`Ruleset.ai`).
public enum AIPlayer {
    /// Plays `player`'s whole phase on `state`, ending with `.endTurn`. Deterministic.
    ///
    /// Returns no steps when it is not `player`'s phase or the game is over. If the game ends
    /// during the phase (a domination victory), the last step is the command that ended it.
    public static func playTurn(_ state: inout GameState, player: PlayerID) -> AITurnResult {
        playPhase(&state, player: player).result
    }

    /// `playTurn` with diagnostics: posture, rival, refused commands and whether the command
    /// cap was hit; with `narrate`, a note per notable decision (HeadlessSim `--narrate`); with
    /// `profile`, the time of each step (HeadlessSim `--profile`). Plays exactly the same
    /// commands either way.
    public static func playPhase(_ state: inout GameState, player: PlayerID, narrate: Bool = false,
                                 profile: Bool = false) -> AIPhaseReport {
        if state.isRaider(player) { return RaiderAI.playPhase(&state, player: player) }
        if state.isMinor(player) { return MinorAI.playPhase(&state, player: player) }
        var turn = AITurn(state: state, player: player, narrate: narrate, profile: profile)
        turn.play()
        state = turn.state
        return AIPhaseReport(result: AITurnResult(steps: turn.steps), posture: turn.plan.posture, rival: turn.plan.rival,
                             rejections: turn.rejections, hitCommandCap: turn.capped, planSummary: turn.plan.summary,
                             target: turn.plan.target?.id, rally: turn.plan.rally?.id, advancing: turn.plan.advancing,
                             notes: turn.notes, stepTimes: turn.stepTimes, escortRequests: turn.escortWanted)
    }
}

extension AIPlayer {
    /// Automated Builders (the App's Automate order for a human's Builders): the commands the
    /// AI's own Builder logic (M1 §13 Builders and Safety, M2 §3.3 roads) gives `builders` of
    /// `player` now, played on a copy of `state` and returned in order for the caller to apply
    /// one by one. It reads only `player`'s view. A Builder with nothing left to do goes to the
    /// nearest own city, where it is left awake (no `sleep`), so the order picks it up again
    /// when work appears. The player's military units are the player's to command: the Builders
    /// are planned as going alone (`AITurn.civiliansAlone`), so no move counts on an escort or
    /// guard that would not come, and only the Builders' own commands are returned. Empty when
    /// it is not `player`'s phase.
    public static func builderCommands(_ state: GameState, player: PlayerID, builders: [UnitID]) -> [Command] {
        guard state.outcome == nil, state.currentPlayer == player, !builders.isEmpty else { return [] }
        let ids = Set(builders)
        var turn = AITurn(state: state, player: player)
        turn.civiliansAlone = true
        turn.moveBuilders(only: ids)
        return turn.steps.map(\.command).filter { command in
            switch command {
            case let .moveUnit(unit, _), let .buildImprovement(unit, _), let .buildRoad(unit), let .wake(unit), let .cancelOrders(unit):
                ids.contains(unit)
            default:
                false
            }
        }
    }
}
