import Foundation
import GameCore

// p3g (M1 §7.7, §17; DESIGN §8.1): one game's tribal villages for HeadlessSim's lines — how many
// were placed and on whose side, who took them and when, and what the villagers gave — and the
// `--early` summary of them from player 0's seat. Observes only (games hash unchanged): it reads
// the events, the sites the game placed (`DebugTools.tribalVillages` at game start) and
// placement's tags (`DebugTools.tribalVillagePlacement`: the start whose own round placed each
// one, nil for a shared one). A game without tribal villages (rules without the
// `tribalVillages` section, or `--scripted`, which places none) counts and prints nothing, so
// such runs print what they printed before tribal villages.

/// What one game's tribal villages did.
struct TribalVillageStats {
    static let giftNames = ["gold", "science", "builder"]
    static let takerNames = ["Scout", "military", "civilian", "city"]
    static let sideNames = ["own", "shared", "rival's"]

    /// The sites placed at game start, in tile order, with their tags; nil: the game has none.
    let sites: [TribalVillageSite]?
    let rules: Ruleset
    /// Per player: the turn of each of its takes, and its gifts by kind (`giftNames`).
    var takes: [[Int]]
    var gifts: [[Int]]
    /// Per player: its takes by the site's side (`sideNames`): placed in its own round, shared,
    /// or placed in a rival's round.
    var sides: [[Int]]
    /// Takes by taker (`takerNames`): a recon unit, another military unit, a civilian, a city.
    var takers = [0, 0, 0, 0]
    /// The turn player 0 first knew one (those known at game start: turn 1).
    var p0FirstSeen: Int?
    /// Events count for the turn of the latest `turnStarted`, as in EarlyGame.swift.
    var eventTurn: Int
    /// Unit types by id, for the takers (lookups only).
    var unitTypes: [UnitID: UnitType] = [:]

    var enabled: Bool { sites != nil }

    /// `sites`: placement's tags for the game's sites (nil: a game without tribal villages);
    /// `state`: the game at its start.
    init(state: GameState, sites: [TribalVillageSite]?) {
        self.sites = sites
        rules = state.rules
        let players = state.players.count
        takes = Array(repeating: [], count: players)
        gifts = Array(repeating: [0, 0, 0], count: players)
        sides = Array(repeating: [0, 0, 0], count: players)
        eventTurn = state.turn
        guard sites != nil else { return }
        for unit in state.units { unitTypes[unit.id] = unit.type }
        phaseEnd(state)
    }

    /// The side of the site on `hex` for player `p` (`sideNames`); nil: not placed at game start.
    func side(of hex: HexCoord, for p: Int) -> Int? {
        guard let site = sites?.first(where: { $0.hex == hex }) else { return nil }
        guard let start = site.start else { return 1 }
        return start == p ? 0 : 2
    }

    /// Placed in start `p`'s own rounds (nil: shared ones).
    func placed(by start: Int?) -> Int { sites?.filter { $0.start == start }.count ?? 0 }

    /// One command's or phase's events, in order.
    mutating func add(_ records: [EventRecord]) {
        guard enabled else { return }
        for record in records {
            switch record.event {
            case let .turnStarted(turn):
                eventTurn = turn
            case let .unitCreated(unit, type, _, _):
                unitTypes[unit] = type
            case let .unitCaptured(_, new, type, _, _, _):
                unitTypes[new] = type
            case let .tribalVillageTaken(at, player, unit, city):
                let p = player.rawValue
                guard takes.indices.contains(p) else { continue }
                takes[p].append(eventTurn)
                if let s = side(of: at, for: p) { sides[p][s] += 1 }
                if city != nil {
                    takers[3] += 1
                } else if let type = unit.flatMap({ unitTypes[$0] }) {
                    takers[type.isCivilian ? 2 : rules.unit(type).unitClass == .recon ? 0 : 1] += 1
                }
            case let .tribalVillageGift(player, _, gift):
                guard gifts.indices.contains(player.rawValue) else { continue }
                gifts[player.rawValue][Self.kind(gift)] += 1
            default:
                break
            }
        }
    }

    /// A gift's kind (`giftNames`).
    static func kind(_ gift: TribalVillageGift) -> Int {
        switch gift {
        case .gold: 0
        case .science: 1
        case .builder: 2
        }
    }

    /// The end of a phase (and the game's start): player 0's first sighting.
    mutating func phaseEnd(_ state: GameState) {
        guard enabled, p0FirstSeen == nil, !state.view(for: PlayerID(0)).knownTribalVillages.isEmpty else { return }
        p0FirstSeen = state.turn
    }

    /// For a player's line: its takes by turn 25 and in all, and its gifts by kind.
    func playerSummary(_ p: Int) -> String {
        guard enabled, takes.indices.contains(p) else { return "" }
        return ", tribal villages \(takes[p].filter { $0 <= 25 }.count) by t25, \(takes[p].count) in all ("
            + zip(Self.giftNames, gifts[p]).map { "\($0) \($1)" }.joined(separator: ", ") + ")"
    }

    /// The game's line (`standing`: those left at the end).
    func gameLine(standing: Int) -> String {
        guard let sites else { return "" }
        let own = takes.indices.map { "\(placed(by: $0))" }.joined(separator: "/")
        let first = takes.first?.first
        return "tribal villages: \(sites.count) placed (own \(own), shared \(placed(by: nil))), \(standing) standing at the end; "
            + "taken by " + zip(Self.takerNames, takers).map { "\($0) \($1)" }.joined(separator: ", ")
            + "; p0 first seen " + (p0FirstSeen.map { "t\($0)" } ?? "never") + ", first taken " + (first.map { "t\($0)" } ?? "never")
            + ", takes by side " + zip(Self.sideNames, sides.first ?? []).map { "\($0) \($1)" }.joined(separator: ", ")
    }
}

/// Sums of `TribalVillageStats` over a run's games (the summary after `--games N`).
struct TribalVillageTotals {
    var games = 0
    var placed = 0, standing = 0, shared = 0
    /// Per seat: sites placed in its own rounds, takes by turn 25 and in all, gifts by kind,
    /// takes by side.
    var own: [Int] = [], byT25: [Int] = [], inAll: [Int] = []
    var gifts: [[Int]] = [], sides: [[Int]] = []
    var takers = [0, 0, 0, 0]
    /// Player 0: first sighting and first take per game (nil: never).
    var p0FirstSeen: [Int?] = [], p0FirstTake: [Int?] = []
    /// Per game (two players): player 0's takes by turn 25 minus player 1's.
    var p0MinusP1: [Int] = []

    mutating func add(_ s: TribalVillageStats, standing: Int) {
        guard let sites = s.sites else { return }
        let seats = s.takes.count
        if own.count < seats {
            let more = seats - own.count
            own += Array(repeating: 0, count: more)
            byT25 += Array(repeating: 0, count: more)
            inAll += Array(repeating: 0, count: more)
            gifts += Array(repeating: [0, 0, 0], count: more)
            sides += Array(repeating: [0, 0, 0], count: more)
        }
        games += 1
        placed += sites.count
        shared += s.placed(by: nil)
        self.standing += standing
        for p in 0..<seats {
            own[p] += s.placed(by: p)
            byT25[p] += s.takes[p].filter { $0 <= 25 }.count
            inAll[p] += s.takes[p].count
            for k in 0..<3 {
                gifts[p][k] += s.gifts[p][k]
                sides[p][k] += s.sides[p][k]
            }
        }
        for k in 0..<4 { takers[k] += s.takers[k] }
        p0FirstSeen.append(s.p0FirstSeen)
        p0FirstTake.append(s.takes.first?.first)
        if seats == 2 { p0MinusP1.append(s.takes[0].filter { $0 <= 25 }.count - s.takes[1].filter { $0 <= 25 }.count) }
    }

    func print() {
        guard games > 0 else { return }
        func mean(_ x: Int) -> String { String(format: "%.2f", Double(x) / Double(games)) }
        func seats(_ xs: [Int]) -> String { xs.indices.map { "p\($0) \(mean(xs[$0]))" }.joined(separator: ", ") }
        Swift.print("tribal villages (\(games) games): placed mean \(mean(placed)) (own per seat \(seats(own)); shared \(mean(shared))), "
            + "standing at the end mean \(mean(standing)); taken by t25 mean \(seats(byT25)), in all \(seats(inAll))"
            + (p0MinusP1.isEmpty ? "" : "; p0 − p1 by t25 mean " + String(format: "%+.2f", Double(p0MinusP1.reduce(0, +)) / Double(p0MinusP1.count))
                + " (range \(p0MinusP1.min()!)…\(p0MinusP1.max()!))"))
        Swift.print("  gifts (" + TribalVillageStats.giftNames.joined(separator: "/") + "): "
            + gifts.indices.map { "p\($0) " + gifts[$0].map(String.init).joined(separator: "/") }.joined(separator: ", ")
            + "; takers: " + zip(TribalVillageStats.takerNames, takers).map { "\($0) \($1)" }.joined(separator: ", ")
            + "; takes by side (" + TribalVillageStats.sideNames.joined(separator: "/") + "): "
            + sides.indices.map { "p\($0) " + sides[$0].map(String.init).joined(separator: "/") }.joined(separator: ", "))
        let seen = p0FirstSeen.compactMap { $0 }, took = p0FirstTake.compactMap { $0 }
        Swift.print("  p0: first seen median t\(EarlySummary.median(seen)) (never \(games - seen.count)); first take median "
            + "t\(EarlySummary.median(took)), by t5 \(took.filter { $0 <= 5 }.count)/\(games), by t8 \(took.filter { $0 <= 8 }.count)/\(games), "
            + "never \(games - took.count)")
    }
}

// MARK: The `--early` summary

extension EarlyObserver {
    /// p3g: the game's tribal villages at its start (`sites`: placement's tags), and those p0
    /// knows then, which count as seen on turn 1.
    mutating func startTribalVillages(_ sites: [TribalVillageSite], state: GameState) {
        villageSites = sites
        record.tribalVillagesPlaced = sites.count
        record.p0TribalVillageSightings = []
        record.tribalVillageGifts = []
        tribalVillageSightings(turn: 1, state: state)
    }

    /// p3g: records `turn` when p0 knows a tribal village it never knew before (once per turn).
    mutating func tribalVillageSightings(turn: Int, state: GameState) {
        guard villageSites != nil else { return }
        var grew = false
        for t in state.view(for: human).knownTribalVillages where !p0KnewVillages.contains(t) {
            p0KnewVillages.append(t)
            grew = true
        }
        if grew, record.p0TribalVillageSightings?.last != turn { record.p0TribalVillageSightings?.append(turn) }
    }

    /// p3g: a gift (attributed to turn `t`): a p0 gift makes the turn active (M1 §17), and every
    /// gift is a feature and an entry [turn, player, kind, side].
    mutating func tribalVillageGift(player: PlayerID, at hex: HexCoord, gift: TribalVillageGift, turn t: Int) {
        feature("tribal village gift", t, p0: player == human)
        if player == human { active(t) }
        let p = player.rawValue
        var side = -1
        if let site = villageSites?.first(where: { $0.hex == hex }) { side = site.start == nil ? 1 : site.start == p ? 0 : 2 }
        record.tribalVillageGifts?.append([t, p, TribalVillageStats.kind(gift), side])
    }
}

extension EarlySummary {
    /// p3g: tribal villages from p0's seat (records of games with them only), and quiet turns over
    /// the gates' windows, also with sightings counted (outside the gates, DESIGN §8.1).
    static func printTribalVillages(_ all: [EarlyRecord]) {
        let records = all.filter { $0.tribalVillagesPlaced != nil }
        let n = records.count
        guard n > 0 else { return }
        func gifts(_ r: EarlyRecord, _ p: Int, by turn: Int) -> Int {
            (r.tribalVillageGifts ?? []).filter { $0[1] == p && $0[0] <= turn }.count
        }
        let seen = records.compactMap { $0.p0TribalVillageSightings?.first }
        let first = records.compactMap { r in (r.tribalVillageGifts ?? []).first { $0[1] == 0 }?[0] }
        let mine = records.flatMap { ($0.tribalVillageGifts ?? []).filter { $0[1] == 0 } }
        let diff = records.map { gifts($0, 0, by: 25) - gifts($0, 1, by: 25) }
        func per(_ p: Int, _ turn: Int) -> String { mean(records.map { gifts($0, p, by: turn) }, over: n) }
        Swift.print("  tribal villages (\(n) games): placed mean \(mean(records.compactMap(\.tribalVillagesPlaced), over: n)); "
            + "p0's first sighting median t\(median(seen)) (none: \(n - seen.count)); p0's first gift median t\(median(first)), "
            + "by t5 \(first.filter { $0 <= 5 }.count)/\(n), by t8 \(first.filter { $0 <= 8 }.count)/\(n) (none: \(n - first.count)); "
            + "gifts by t10/t25/t50: p0 mean \(per(0, 10))/\(per(0, 25))/\(per(0, 50)), AI mean \(per(1, 10))/\(per(1, 25))/\(per(1, 50)); "
            + "p0 − AI by t25 mean " + String(format: "%+.2f", Double(diff.reduce(0, +)) / Double(n)) + " (\(dist_(diff))); "
            + "p0's gifts gold \(mine.filter { $0[2] == 0 }.count), science \(mine.filter { $0[2] == 1 }.count), "
            + "builder \(mine.filter { $0[2] == 2 }.count); by side own \(mine.filter { $0[3] == 0 }.count), "
            + "shared \(mine.filter { $0[3] == 1 }.count), rival's \(mine.filter { $0[3] == 2 }.count)")
        func quiet(_ from: Int, _ to: Int, sightings: Bool) -> String {
            mean(records.map { r in
                let extra = sightings ? (r.p0TribalVillageSightings ?? []) : []
                let active = (from...to).filter { r.activeTurns.contains($0) || extra.contains($0) }
                return (to - from + 1) - active.count
            }, over: n)
        }
        Swift.print("  quiet turns t1–t10 mean \(quiet(1, 10, sightings: false)), t11–t25 \(quiet(11, 25, sightings: false)), "
            + "t1–t25 \(quiet(1, 25, sightings: false)), t1–t50 \(quiet(1, 50, sightings: false)); with tribal village sightings "
            + "counted active: t1–t10 \(quiet(1, 10, sightings: true)), t1–t25 \(quiet(1, 25, sightings: true)), "
            + "t1–t50 \(quiet(1, 50, sightings: true))")
    }
}
