import Foundation
import GameAI
import GameCore

// `--early` (p3 early-game): what the first turns are like from player 0's seat, the seat a
// human plays. Observes only: it reads the state, the AI's reports and the events after each
// command and phase, and never feeds anything back into a game (games hash unchanged).
//
// Events are attributed to the turn of the latest `turnStarted` (a phase start's completions
// belong to the turn that phase starts). "Quiet" turns for player 0: none of its cities
// completes anything, it researches nothing and founds nothing, it meets nobody, it takes part
// in no combat, capture, war or peace event, and it gets no tribal village gift (p3g), in either
// phase of the turn. Tribal village sightings are recorded apart (`p0TribalVillageSightings`)
// and do not make a turn active.

/// One game's early-game record, from player 0's seat (JSON, one `EARLY` line per game).
struct EarlyRecord: Codable {
    var seed: UInt64
    var p0: String
    var turns: Int
    /// Turn player 0 met the AI (player 1); nil: not met.
    var contactTurn: Int?
    /// Turn player 0 first remembers a city of player 1.
    var firstAICitySeen: Int?
    /// Hex distance between the two original capitals (nil: one has no city).
    var capitalDistance: Int?
    /// Terrain path cost between the capitals by full knowledge (nil: no land path).
    var capitalPathCost: Int?
    /// Cities at the end of turns 10, 25, 50, 80: [p0, p1].
    var citiesAt: [String: [Int]] = [:]
    /// Military units (recon included) at the end of turns 25, 50, 80: [p0, p1].
    var militaryAt: [String: [Int]] = [:]
    /// Techs at the end of turns 25, 50, 80: [p0, p1].
    var techsAt: [String: [Int]] = [:]
    /// AI cities founded: turn and hex distance to the nearest p0 city then (nil: p0 had none).
    var aiFounded: [[Int]] = []
    /// p0 cities founded (turns).
    var p0Founded: [Int] = []
    /// Wars declared by the AI on p0, p0 on the AI, peace signed (turns).
    var warsOnP0: [Int] = []
    var warsByP0: [Int] = []
    var peaces: [Int] = []
    var peaceProposals: [Int] = []
    /// First turn the AI's posture was prepare (resp. war) against p0.
    var firstPrepareVsP0: Int?
    var firstWarPosture: Int?
    /// Attacks on p0 (by the AI): turns; p0's attacks on the AI.
    var attacksOnP0: [Int] = []
    var attacksByP0: [Int] = []
    /// p0 units killed, civilians captured from p0, p0 cities lost (turns).
    var p0UnitsLost: [Int] = []
    var p0CiviliansLost: [Int] = []
    var p0CitiesLost: [Int] = []
    var aiUnitsLost: [Int] = []
    var aiCitiesLost: [Int] = []
    /// p0's techs and production completions (turns).
    var p0Techs: [Int] = []
    var p0Completions: [Int] = []
    /// Turns with something for p0 (see the file comment); turns where p0 saw an AI unit at the
    /// end of the AI's phase; turns with a visible AI non-recon military unit within the threat
    /// radius of a p0 city (resp. a recon unit), with the most such units seen.
    var activeTurns: [Int] = []
    var aiSeenTurns: [Int] = []
    var aiNearTurns: [Int] = []
    var aiReconNearTurns: [Int] = []
    var maxAINear = 0
    /// Turns any AI unit stood in or next to p0's territory (live state, visible or not).
    var aiAtBorderTurns: [Int] = []
    /// Turns p0 saw an AI non-recon military unit anywhere (end of the AI's phase).
    var aiFighterSeenTurns: [Int] = []
    /// The AI's army (non-garrison, non-recon military units) at the end of turns 30, 40, …, 80.
    var aiArmyAt: [String: Int] = [:]
    /// p0's military (non-recon) units at the end of turns 30, 40, …, 80.
    var p0FightersAt: [String: Int] = [:]
    /// Feature occurrences (any player): name → turns.
    var features: [String: [Int]] = [:]
    /// Feature occurrences involving p0: name → turns.
    var p0Features: [String: [Int]] = [:]
    /// AI posture per turn (its phase's planning): "e" expand, "d" develop, "p" prepare, "w" war.
    var postures = ""
    /// p3b: production pace. p0's cities other than its first, founded by turn 80: [turn
    /// founded, Production in the founding phase, phases until the production collected since
    /// founding reaches a Warrior's cost (-1: not within the game)]. p3d: the count starts from
    /// the progress the city holds at the end of its founding phase (its founding production,
    /// M1 §5), and two entries follow: phases from founding to the city's first completion (built
    /// or bought), and to its first military non-recon unit (-1: none within the game).
    var p0NewCities: [[Int]] = []
    /// p3d: the same for the AI's (player 1's) cities other than its first.
    var aiNewCities: [[Int]] = []
    /// p3b: the turn each player's original capital completes its first Settler (built or
    /// bought; nil: none by the end), and p0's capital's Production in its founding phase.
    var p0CapitalFirstSettler: Int?
    var aiCapitalFirstSettler: Int?
    var p0CapitalProduction: Int?
    /// p3b: p0's Production collected over turns 1–25 and 1–50 (all its cities; the capital's
    /// alone), from its cities' Production at the end of each of its phases.
    var p0ProductionBy25 = 0
    var p0ProductionBy50 = 0
    var p0CapitalProductionBy50 = 0
    /// p3b (ai-settler-escort): per AI Settler made in the game, in order: [turn made, phases it
    /// spent waiting for an escort (M1 §13 Safety: the AI's own escort requests), turn it founded
    /// a city (-1: none)].
    var aiSettlers: [[Int]] = []
    /// p3f (ai-after-city-loss): each AI seat's first lost city and what followed (`AfterLoss.swift`).
    var aiLosses: [[Int]] = []
    /// p3g (tribal villages, M1 §7.7; `TribalVillageStats.swift`): how many the game placed; the
    /// turns p0's known tribal villages grew (once per turn; those known at game start count as
    /// turn 1); and every gift, [turn, player, kind (0 Gold, 1 Science, 2 Builder), its site's
    /// side for the taker (0 its own, 1 shared, 2 a rival's; −1 not placed at game start)]. All
    /// nil in a game without tribal villages, whose record then reads exactly as before.
    var tribalVillagesPlaced: Int?
    var p0TribalVillageSightings: [Int]?
    var tribalVillageGifts: [[Int]]?
}

struct EarlyObserver {
    let human = PlayerID(0)
    let ai = PlayerID(1)
    var eventTurn = 1
    var record: EarlyRecord
    /// p3b: p0's cities being timed (id, index into `record.p0NewCities`, production so far,
    /// phases sampled).
    var paced: [(city: CityID, entry: Int, sum: Int, phases: Int)] = []
    /// p3b: the AI's Settlers, by unit: index into `record.aiSettlers` (lookups only).
    var aiSettlerIndex: [UnitID: Int] = [:]
    /// p3d: the AI's cities being timed, as `paced`.
    var aiPaced: [(city: CityID, entry: Int, sum: Int, phases: Int)] = []
    /// p3g: the game's tribal villages at its start with placement's tags (nil: a game without
    /// them), and every one p0 has known (tile indices).
    var villageSites: [TribalVillageSite]?
    var p0KnewVillages: [Int32] = []

    init(seed: UInt64, p0: String, turns: Int) {
        record = EarlyRecord(seed: seed, p0: p0, turns: turns)
    }

    mutating func feature(_ name: String, _ turn: Int, p0: Bool) {
        record.features[name, default: []].append(turn)
        if p0 { record.p0Features[name, default: []].append(turn) }
    }

    mutating func active(_ turn: Int) {
        if record.activeTurns.last != turn { record.activeTurns.append(turn) }
    }

    /// Owner of a combatant: a killed unit's owner comes from the same command's events.
    func owner(_ c: Combatant, _ records: [EventRecord], _ state: GameState) -> PlayerID? {
        switch c {
        case let .unit(id):
            if let u = state.unit(id) { return u.owner }
            for r in records { if case let .unitKilled(u, _, owner, _) = r.event, u == id { return owner } }
            return nil
        case let .city(id):
            return state.city(id)?.owner
        }
    }

    /// The AI's plan for a phase.
    mutating func plan(_ report: AIPhaseReport, player: PlayerID, turn: Int) {
        guard player == ai else { return }
        let code: String
        switch report.posture {
        case .expand: code = "e"
        case .develop: code = "d"
        case .prepare: code = "p"
        case .war: code = "w"
        }
        if record.postures.count < turn { record.postures += String(repeating: ".", count: turn - 1 - record.postures.count) + code }
        if report.posture == .prepare, report.rival == human, record.firstPrepareVsP0 == nil { record.firstPrepareVsP0 = turn }
        if report.posture == .war, record.firstWarPosture == nil { record.firstWarPosture = turn }
        for id in report.escortRequests { if let k = aiSettlerIndex[id] { record.aiSettlers[k][1] += 1 } }
    }

    /// One command and its events (any player's), with the state after it.
    mutating func step(_ command: Command, _ records: [EventRecord], by player: PlayerID, turn: Int, state: GameState) {
        switch command {
        case let .purchase(city, item):
            let t = eventTurn
            feature("purchase", t, p0: player == human)
            if case let .unit(type) = item, !type.isCivilian { feature("purchase military", t, p0: player == human) }
            _ = city
        case .razeCity: feature("raze", eventTurn, p0: player == human)
        case .proposePeace:
            feature("peace proposal", eventTurn, p0: true)
            record.peaceProposals.append(eventTurn)
        case .fortify: break
        default: break
        }
        for r in records {
            let t = eventTurn
            afterLoss(r.event, turn: t, state: state)
            switch r.event {
            case let .turnStarted(turn):
                eventTurn = turn
            case let .playersMet(a, b):
                if a == human || b == human {
                    if record.contactTurn == nil { record.contactTurn = t }
                    active(t)
                }
            case let .cityFounded(founded, _, owner, at):
                if owner == ai {
                    let mine = state.cities.filter { $0.owner == human }
                    let d = mine.map { state.map.distance($0.position, at) }.min()
                    record.aiFounded.append([t, d ?? -1])
                } else if owner == human {
                    record.p0Founded.append(t)
                    active(t)
                }
                if owner == ai, case let .foundCity(id) = command, let k = aiSettlerIndex[id] { record.aiSettlers[k][2] = t }
                newCity(founded, owner: owner, turn: t, state: state)
                feature("city founded", t, p0: owner == human)
            case let .unitCreated(unit, type, owner, _):
                if owner == ai, type == .settler {
                    aiSettlerIndex[unit] = record.aiSettlers.count
                    record.aiSettlers.append([t, 0, -1])
                }
            case let .warDeclared(by, on):
                if on == human { record.warsOnP0.append(t) }
                if by == human { record.warsByP0.append(t) }
                feature("war", t, p0: on == human || by == human)
                if on == human || by == human { active(t) }
            case let .peaceSigned(a, b):
                record.peaces.append(t)
                feature("peace", t, p0: a == human || b == human)
                if a == human || b == human { active(t) }
            case let .peaceProposed(from, to):
                if from == human || to == human { active(t) }
            case let .combat(attacker, defender, _, _, ranged, _, _):
                let a = owner(attacker, records, state), d = owner(defender, records, state)
                let involves = a == human || d == human
                if case .city = attacker {
                    feature("bombard", t, p0: involves)
                } else if case .city = defender {
                    feature(ranged ? "ranged on city" : "melee on city", t, p0: involves)
                } else {
                    feature(ranged ? "ranged on unit" : "melee on unit", t, p0: involves)
                }
                feature("combat", t, p0: involves)
                if d == human { record.attacksOnP0.append(t) }
                if a == human { record.attacksByP0.append(t) }
                if involves { active(t) }
            case let .unitKilled(_, _, owner, _):
                if owner == human { record.p0UnitsLost.append(t) }
                if owner == ai { record.aiUnitsLost.append(t) }
                feature("unit killed", t, p0: owner == human)
            case let .unitCaptured(_, _, _, from, to, _):
                if from == human { record.p0CiviliansLost.append(t) }
                feature("civilian captured", t, p0: from == human || to == human)
                if from == human || to == human { active(t) }
            case let .cityCaptured(_, _, from, to, _):
                if from == human { record.p0CitiesLost.append(t) }
                if from == ai { record.aiCitiesLost.append(t) }
                feature("city captured", t, p0: from == human || to == human)
                if from == human || to == human { active(t) }
            case let .cityRazed(_, _, owner, _):
                feature("city razed", t, p0: owner == human)
            case let .productionCompleted(city, item, _):
                let owner = state.city(city)?.owner
                if owner == human {
                    record.p0Completions.append(t)
                    active(t)
                }
                firstCompletion(city, item, turn: t, state: state)
                if item == .unit(.settler), let owner, city == state.players[owner.rawValue].originalCapital {
                    if owner == human, record.p0CapitalFirstSettler == nil { record.p0CapitalFirstSettler = t }
                    if owner == ai, record.aiCapitalFirstSettler == nil { record.aiCapitalFirstSettler = t }
                }
                if case let .building(b) = item, b == "walls" { feature("walls built", t, p0: owner == human) }
            case let .techResearched(p, _):
                if p == human {
                    record.p0Techs.append(t)
                    active(t)
                }
            case let .improvementBuilt(_, _, owner):
                feature("improvement", t, p0: owner == human)
            case let .unitDisbanded(_, _, owner, _, upkeep):
                if upkeep { feature("upkeep disband", t, p0: owner == human) }
            case let .borderGrew(city, _):
                feature("border growth", t, p0: state.city(city)?.owner == human)
            case let .cityGrew(city, _, _):
                feature("city growth", t, p0: state.city(city)?.owner == human)
            case let .tribalVillageGift(player, at, gift):
                tribalVillageGift(player: player, at: at, gift: gift, turn: t)
            default:
                break
            }
        }
    }

    /// p3b: the end of player 0's own phase (before its endTurn): each of its cities' Production
    /// now is what it collects at its next phase start. Times every city but the first from its
    /// founding phase until the production collected reaches a Warrior's cost.
    mutating func p0PhaseEnd(turn: Int, state: GameState) {
        let warrior = state.rules.unit(.warrior).cost
        for city in state.cities where city.owner == human {
            let production = state.cityYields(city).total.production
            if turn < 25 { record.p0ProductionBy25 += production }
            if turn < 50 { record.p0ProductionBy50 += production }
            if turn < 50, city.id == state.players[human.rawValue].originalCapital { record.p0CapitalProductionBy50 += production }
            if city.id == state.players[human.rawValue].originalCapital {
                if record.p0CapitalProduction == nil { record.p0CapitalProduction = production }
                continue
            }
            Self.pace(&record.p0NewCities, &paced, city: city, production: production, warrior: warrior)
        }
    }

    /// p3d: the end of the AI's phase: times the AI's cities but its first like p0's.
    mutating func aiPhaseEnd(state: GameState) {
        let warrior = state.rules.unit(.warrior).cost
        for city in state.cities where city.owner == ai {
            Self.pace(&record.aiNewCities, &aiPaced, city: city, production: state.cityYields(city).total.production, warrior: warrior)
        }
    }

    /// p3d: a city of p0 or the AI founded by turn 80, not its owner's first, is timed from its
    /// founding (its entry's Production is set at the end of the founding phase).
    mutating func newCity(_ id: CityID, owner: PlayerID, turn: Int, state: GameState) {
        guard turn <= 80, owner == human || owner == ai, id != state.players[owner.rawValue].originalCapital else { return }
        if owner == human {
            record.p0NewCities.append([turn, -1, -1, -1, -1])
            paced.append((id, record.p0NewCities.count - 1, 0, 0))
        } else {
            record.aiNewCities.append([turn, -1, -1, -1, -1])
            aiPaced.append((id, record.aiNewCities.count - 1, 0, 0))
        }
    }

    /// p3d: one phase end of a timed city: the founding phase sets its Production and starts the
    /// count from the progress the city holds (stored and in its queue: its founding production).
    static func pace(_ entries: inout [[Int]], _ timed: inout [(city: CityID, entry: Int, sum: Int, phases: Int)],
                     city: City, production: Int, warrior: Int) {
        guard let k = timed.firstIndex(where: { $0.city == city.id }) else { return }
        let e = timed[k].entry
        if entries[e][1] < 0 {
            entries[e][1] = production
            timed[k].sum = city.storedProgress + city.queue.reduce(0) { $0 + $1.progress }
        }
        guard entries[e][2] < 0 else { return }
        timed[k].sum += production
        timed[k].phases += 1
        if timed[k].sum >= warrior { entries[e][2] = timed[k].phases }
    }

    /// p3d: a timed new city's first completion and first military non-recon unit.
    mutating func firstCompletion(_ id: CityID, _ item: ProductionItem, turn: Int, state: GameState) {
        let fighter: Bool
        if case let .unit(type) = item { fighter = !type.isCivilian && state.rules.unit(type).unitClass != .recon } else { fighter = false }
        func mark(_ entry: inout [Int]) {
            if entry[3] < 0 { entry[3] = turn - entry[0] }
            if fighter, entry[4] < 0 { entry[4] = turn - entry[0] }
        }
        if let k = paced.first(where: { $0.city == id })?.entry { mark(&record.p0NewCities[k]) }
        if let k = aiPaced.first(where: { $0.city == id })?.entry { mark(&record.aiNewCities[k]) }
    }

    /// The end of a player's phase (the AI's: what player 0 will see at its phase start).
    mutating func endOfPhase(_ player: PlayerID, turn: Int, state: GameState) {
        // p3g: p0's sightings in the phase (and in the phase start it led to: the state's turn).
        tribalVillageSightings(turn: state.turn, state: state)
        afterLossPhaseEnd(player, turn: turn, state: state)
        if player == ai { aiPhaseEnd(state: state) }
        guard player == ai || state.players.count == 1 else { return }
        let view = state.view(for: human)
        if record.firstAICitySeen == nil, view.knownCities.contains(where: { $0.owner == ai }) { record.firstAICitySeen = turn }
        let mine = view.cities
        let threat = state.rules.ai.threatRadius
        let seen = view.visibleForeignUnits.filter { $0.owner == ai }
        if !seen.isEmpty { record.aiSeenTurns.append(turn) }
        let near = seen.filter { u in !u.type.isCivilian && mine.contains { view.distance($0.position, u.position) <= threat } }
        let fighters = near.filter { state.rules.unit($0.type).unitClass != .recon }
        if seen.contains(where: { !$0.type.isCivilian && state.rules.unit($0.type).unitClass != .recon }) { record.aiFighterSeenTurns.append(turn) }
        if turn % 10 == 0, turn >= 30 {
            let isFighter: (GameCore.Unit) -> Bool = { !$0.type.isCivilian && state.rules.unit($0.type).unitClass != .recon }
            let aiCities = state.cities.filter { $0.owner == ai }
            let garrisons = aiCities.compactMap { c in state.units.first { $0.owner == ai && !$0.type.isCivilian && $0.position == c.position }?.id }
            record.aiArmyAt["\(turn)"] = state.units.filter { $0.owner == ai && isFighter($0) && !garrisons.contains($0.id) }.count
            record.p0FightersAt["\(turn)"] = state.units.filter { $0.owner == human && isFighter($0) }.count
        }
        if !fighters.isEmpty { record.aiNearTurns.append(turn) }
        if near.count > fighters.count { record.aiReconNearTurns.append(turn) }
        record.maxAINear = max(record.maxAINear, fighters.count)
        // Any AI unit (live state) in or next to p0's territory.
        let mineIDs = state.cities.filter { $0.owner == human }.map(\.id.rawValue)
        if !mineIDs.isEmpty {
            func p0Tile(_ hex: HexCoord) -> Bool {
                guard let t = state.map.index(of: hex) else { return false }
                return mineIDs.contains(Int(state.tileCity[t]) - 1)
            }
            let atBorder = state.units.contains { u in
                guard u.owner == ai else { return false }
                return p0Tile(u.position) || state.map.neighbors(of: u.position).contains(where: p0Tile)
            }
            if atBorder { record.aiAtBorderTurns.append(turn) }
        }
        if [10, 25, 50, 80].contains(turn) {
            let key = "\(turn)"
            record.citiesAt[key] = [human, ai].map { p in state.cities.filter { $0.owner == p }.count }
            record.militaryAt[key] = [human, ai].map { state.militaryUnitCount(of: $0) }
            record.techsAt[key] = [human, ai].map { state.players[$0.rawValue].knownTechs.count }
        }
        if record.capitalDistance == nil, let a = state.players[0].originalCapital.flatMap({ state.city($0) }),
           let b = state.players[1].originalCapital.flatMap({ state.city($0) }) {
            record.capitalDistance = state.map.distance(a.position, b.position)
            // Terrain cost by full knowledge: a fog-free view is not available, so use the
            // AI query on the AI's own view once it has explored (approximation: the AI's
            // knowledge at the time). Recomputed below when both are known.
            let v = state.view(for: ai)
            let field = v.aiTerrainCostField(from: [b.position])
            if let t = state.map.index(of: a.position), field[t] >= 0, v.explored[t] { record.capitalPathCost = Int(field[t]) }
        }
    }
}

/// Aggregates of early records (printed with `--early`).
enum EarlySummary {
    static func median(_ xs: [Int]) -> String {
        guard !xs.isEmpty else { return "-" }
        let s = xs.sorted()
        return s.count % 2 == 1 ? "\(s[s.count / 2])" : String(format: "%.1f", Double(s[s.count / 2 - 1] + s[s.count / 2]) / 2)
    }

    static func mean(_ xs: [Int], over n: Int) -> String {
        n == 0 ? "-" : String(format: "%.2f", Double(xs.reduce(0, +)) / Double(n))
    }

    static func print(_ records: [EarlyRecord]) {
        let n = records.count
        guard n > 0 else { return }
        func games(_ f: (EarlyRecord) -> Bool) -> String {
            let k = records.filter(f).count
            return "\(k)/\(n)"
        }
        func count(_ f: (EarlyRecord) -> [Int], by turn: Int) -> [Int] { records.map { f($0).filter { $0 <= turn }.count } }
        Swift.print("early game from p0's seat (\(records[0].p0) in seat 0, \(n) games, seeds \(records.first!.seed)–\(records.last!.seed)):")
        let contacts = records.compactMap(\.contactTurn)
        Swift.print("  first contact: median t\(median(contacts)), range t\(contacts.min() ?? -1)–t\(contacts.max() ?? -1); "
            + "by t10 \(games { ($0.contactTurn ?? .max) <= 10 }), by t20 \(games { ($0.contactTurn ?? .max) <= 20 }), "
            + "by t50 \(games { ($0.contactTurn ?? .max) <= 50 }), never \(games { $0.contactTurn == nil })")
        let seen = records.compactMap(\.firstAICitySeen)
        Swift.print("  first AI city seen: median t\(median(seen)); by t50 \(games { ($0.firstAICitySeen ?? .max) <= 50 })")
        let dist = records.compactMap(\.capitalDistance)
        Swift.print("  capital distance (hexes): median \(median(dist)), range \(dist.min() ?? -1)–\(dist.max() ?? -1); "
            + "path cost median \(median(records.compactMap(\.capitalPathCost)))")
        for t in ["10", "25", "50", "80"] {
            let c = records.compactMap { $0.citiesAt[t] }
            guard !c.isEmpty else { continue }
            let m = records.compactMap { $0.militaryAt[t] }
            let k = records.compactMap { $0.techsAt[t] }
            Swift.print("  t\(t): cities p0 mean \(mean(c.map { $0[0] }, over: c.count)) / AI mean \(mean(c.map { $0[1] }, over: c.count)) "
                + "(AI dist \(dist_(c.map { $0[1] }))); military p0 \(mean(m.map { $0[0] }, over: m.count)) / AI \(mean(m.map { $0[1] }, over: m.count)); "
                + "techs p0 \(mean(k.map { $0[0] }, over: k.count)) / AI \(mean(k.map { $0[1] }, over: k.count))")
        }
        for limit in [50, 80] {
            let fwd = records.map { $0.aiFounded.filter { $0[0] <= limit && $0[1] >= 0 && $0[1] <= 6 }.count }
            let fwd5 = records.map { $0.aiFounded.filter { $0[0] <= limit && $0[1] >= 0 && $0[1] <= 5 }.count }
            let all = records.map { $0.aiFounded.filter { $0[0] <= limit }.count }
            Swift.print("  AI cities founded by t\(limit): \(all.reduce(0, +)); within 6 of a p0 city: \(fwd.reduce(0, +)) "
                + "(in \(fwd.filter { $0 > 0 }.count) games), within 5: \(fwd5.reduce(0, +))")
        }
        for limit in [50, 80] {
            let near = count(\.aiNearTurns, by: limit), recon = count(\.aiReconNearTurns, by: limit)
            let seenT = count(\.aiSeenTurns, by: limit), border = count(\.aiAtBorderTurns, by: limit)
            Swift.print("  by t\(limit): turns p0 sees an AI unit: mean \(mean(seenT, over: n)); turns with visible AI military "
                + "within \(4) of a p0 city: mean \(mean(near, over: n)) (games \(near.filter { $0 > 0 }.count)/\(n)); recon only: mean "
                + "\(mean(recon, over: n)); turns with an AI unit in/next to p0 territory: mean \(mean(border, over: n))")
        }
        let first = records.map { $0.warsOnP0.first }
        Swift.print("  AI war on p0: by t30 \(first.filter { ($0 ?? .max) <= 30 }.count)/\(n), by t50 \(first.filter { ($0 ?? .max) <= 50 }.count)/\(n), "
            + "by t60 \(first.filter { ($0 ?? .max) <= 60 }.count)/\(n), "
            + "by t80 \(first.filter { ($0 ?? .max) <= 80 }.count)/\(n), never (in \(records[0].turns) turns) \(first.filter { $0 == nil }.count)/\(n); "
            + "turns: " + first.map { $0.map { "\($0)" } ?? "-" }.joined(separator: " "))
        let prep = records.map { $0.firstPrepareVsP0 }
        Swift.print("  AI first prepares vs p0: median t\(median(prep.compactMap { $0 })); never \(prep.filter { $0 == nil }.count)/\(n)")
        for limit in [50, 80] {
            let att = count(\.attacksOnP0, by: limit), by = count(\.attacksByP0, by: limit)
            let lost = count(\.p0UnitsLost, by: limit), civ = count(\.p0CiviliansLost, by: limit), cities = count(\.p0CitiesLost, by: limit)
            let aiLost = count(\.aiUnitsLost, by: limit), aiCities = count(\.aiCitiesLost, by: limit)
            Swift.print("  by t\(limit): attacks on p0 \(att.reduce(0, +)) (games \(att.filter { $0 > 0 }.count)/\(n)); p0 attacks \(by.reduce(0, +)); "
                + "p0 units lost \(lost.reduce(0, +)), civilians lost \(civ.reduce(0, +)), cities lost \(cities.reduce(0, +)) "
                + "(games \(cities.filter { $0 > 0 }.count)); AI units lost \(aiLost.reduce(0, +)), AI cities lost \(aiCities.reduce(0, +))")
        }
        printAfterLoss(records)
        for (from, to) in [(1, 50), (20, 50), (51, 80)] {
            let span = to - from + 1
            let quiet = records.map { r in span - r.activeTurns.filter { $0 >= from && $0 <= to }.count }
            let streak = records.map { r -> Int in
                var best = 0, run = 0
                for t in from...to { if r.activeTurns.contains(t) { run = 0 } else { run += 1; best = max(best, run) } }
                return best
            }
            Swift.print("  quiet turns t\(from)–t\(to) (\(span) turns): mean \(mean(quiet, over: n)), min \(quiet.min()!), max \(quiet.max()!); "
                + "longest quiet run mean \(mean(streak, over: n)), max \(streak.max()!)")
        }
        // p3b: production pace.
        let fresh = records.flatMap { $0.p0NewCities.filter { $0[0] <= 50 } }
        let reached = fresh.map { $0[2] }.filter { $0 >= 0 }
        Swift.print("  p0 new cities founded by t50: \(fresh.count); Production in the founding phase mean \(mean(fresh.map { $0[1] }, over: fresh.count)) "
            + "(\(dist_(fresh.map { $0[1] }))); phases to collect a Warrior's cost: median \(median(reached)), mean \(mean(reached, over: reached.count)) "
            + "(not within the game: \(fresh.count - reached.count))")
        // p3d: new cities' first completions, and the AI's new cities.
        func firsts(_ xs: [[Int]], _ i: Int) -> String {
            let done = xs.map { $0[i] }.filter { $0 >= 0 }
            return "median \(median(done)), mean \(mean(done, over: done.count)) (none: \(xs.count - done.count))"
        }
        Swift.print("  p0 new cities: first completion after \(firsts(fresh, 3)) phases; first military unit after \(firsts(fresh, 4))")
        let aiFresh = records.flatMap { $0.aiNewCities.filter { $0[0] <= 50 } }
        let aiReached = aiFresh.map { $0[2] }.filter { $0 >= 0 }
        Swift.print("  AI new cities founded by t50: \(aiFresh.count); Production in the founding phase mean \(mean(aiFresh.map { $0[1] }, over: aiFresh.count)); "
            + "phases to collect a Warrior's cost: median \(median(aiReached)), mean \(mean(aiReached, over: aiReached.count)) "
            + "(not within the game: \(aiFresh.count - aiReached.count)); first completion after \(firsts(aiFresh, 3)); first military unit after \(firsts(aiFresh, 4))")
        let capital = records.compactMap(\.p0CapitalFirstSettler), aiCapital = records.compactMap(\.aiCapitalFirstSettler)
        Swift.print("  capital's first Settler: p0 median t\(median(capital)), mean t\(mean(capital, over: capital.count)) (none: \(n - capital.count)); "
            + "AI median t\(median(aiCapital)) (none: \(n - aiCapital.count)); p0 capital Production at founding mean "
            + "\(mean(records.compactMap(\.p0CapitalProduction), over: records.compactMap(\.p0CapitalProduction).count))")
        printOpening(records) // p3f (EarlyOpening.swift)
        printTribalVillages(records) // p3g (TribalVillageStats.swift): games with tribal villages only
        // p3b (ai-settler-escort): how long the AI's Settlers wait for an escort.
        let settlers = records.flatMap(\.aiSettlers)
        let waits = records.map { $0.aiSettlers.reduce(0) { $0 + $1[1] } }
        let longest = records.map { $0.aiSettlers.map { $0[1] }.max() ?? 0 }
        let ages = settlers.filter { $0[2] >= 0 }.map { $0[2] - $0[0] }
        Swift.print("  AI Settlers: \(settlers.count) made, \(ages.count) founded a city (age at founding median \(median(ages)), max \(ages.max() ?? 0)); "
            + "phases waiting for an escort: \(waits.reduce(0, +)) (mean \(mean(waits, over: n)) per game); one Settler's longest wait per game: "
            + "median \(median(longest)), max \(longest.max() ?? 0), games over 10 \(games { ($0.aiSettlers.map { $0[1] }.max() ?? 0) > 10 }) "
            + "(\(dist_(longest)))")
        let techs = count(\.p0Techs, by: 50), done = count(\.p0Completions, by: 50)
        Swift.print("  p0 t1–t50: techs \(mean(techs, over: n)) per game (\(String(format: "%.3f", Double(techs.reduce(0, +)) / Double(50 * n))) per turn); "
            + "production completions \(mean(done, over: n)) per game (\(String(format: "%.3f", Double(done.reduce(0, +)) / Double(50 * n))) per turn)")
        var names: [String] = []
        for r in records { for k in r.features.keys.sorted() where !names.contains(k) { names.append(k) } }
        names.sort()
        Swift.print("  features by t50 (games with any / total count; involving p0: games / count):")
        for name in names {
            let any = records.map { ($0.features[name] ?? []).filter { $0 <= 50 }.count }
            let mine = records.map { ($0.p0Features[name] ?? []).filter { $0 <= 50 }.count }
            Swift.print("    \(name): \(any.filter { $0 > 0 }.count)/\(n) games, \(any.reduce(0, +)); p0: \(mine.filter { $0 > 0 }.count)/\(n), \(mine.reduce(0, +))")
        }
    }

    static func dist_(_ xs: [Int]) -> String {
        var counts: [Int: Int] = [:]
        for x in xs { counts[x, default: 0] += 1 }
        return counts.keys.sorted().map { "\($0):\(counts[$0]!)" }.joined(separator: " ")
    }
}
