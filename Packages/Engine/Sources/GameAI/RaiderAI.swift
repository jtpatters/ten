import GameCore

/// The raiders' phase (M2 §11), stateless: each unit in id order captures a reachable civilian,
/// else makes a favourable attack (a city only to sack it at 0 HP), else pillages, else roams
/// toward the nearest remembered city within reach of its home (its camp, or the city that
/// raised it) or wanders near home. A camp's first unit guards the camp.
enum RaiderAI {
    static func playPhase(_ state: inout GameState, player: PlayerID) -> AIPhaseReport {
        var bot = RaiderTurn(state: state, player: player)
        bot.play()
        state = bot.state
        return AIPhaseReport(result: AITurnResult(steps: bot.steps), posture: .war, rival: nil, rejections: [],
                             hitCommandCap: false, planSummary: "raiders", target: nil, rally: nil, advancing: false,
                             notes: [], stepTimes: [], escortRequests: [])
    }
}

struct RaiderTurn {
    var state: GameState
    let player: PlayerID
    var steps: [AIStep] = []

    init(state: GameState, player: PlayerID) {
        self.state = state
        self.player = player
    }

    var live: Bool { state.outcome == nil && state.currentPlayer == player }

    @discardableResult
    mutating func issue(_ command: Command) -> Bool {
        guard live, let events = try? GameEngine.apply(command, by: player, to: &state) else { return false }
        steps.append(AIStep(command: command, events: events))
        return true
    }

    mutating func play() {
        let ids = state.units.filter { $0.owner == player }.map(\.id)
        for id in ids where live { act(id) }
        if live { issue(.endTurn) }
    }

    func owner(ofTile t: Int) -> PlayerID? {
        let code = Int(state.tileCity[t])
        guard code > 0 else { return nil }
        return state.cities.first { $0.id.rawValue == code - 1 }?.owner
    }

    func home(of id: UnitID, at position: HexCoord) -> HexCoord {
        if let camp = state.raiderCamp(of: id) { return state.map.coord(at: Int(camp.tile)) }
        if let city = state.rebelCity(of: id), let c = state.city(city) { return c.position }
        return position
    }

    func pillageable(_ t: Int) -> Bool {
        guard let owner = owner(ofTile: t), owner != player, !state.cities.contains(where: { state.map.index(of: $0.position) == t }) else { return false }
        let tile = state.map.tiles[t]
        return (tile.improvement != nil && !tile.isPillaged) || tile.hasRoad
    }

    mutating func act(_ id: UnitID) {
        guard let unit = state.unit(id), unit.movesLeft > 0 else { return }
        let map = state.map
        let me = state.players[player.rawValue]
        let home = home(of: id, at: unit.position)

        // The camp's guard stays on (or goes back to) the camp.
        if let camp = state.raiderCamp(of: id), camp.units.first == id {
            let tile = map.coord(at: Int(camp.tile))
            if unit.position != tile { issue(.moveUnit(unit: id, to: tile)) }
            if let u = state.unit(id), u.position == tile, u.movesLeft > 0 { issue(.fortify(unit: id)) }
            return
        }

        let view = state.view(for: player)
        let reach = view.reachableTiles(for: id)

        // 1. A visible enemy civilian standing alone.
        let civilianTiles = Set(state.units.compactMap { other -> HexCoord? in
            guard other.owner != player, other.type.isCivilian, let t = map.index(of: other.position), me.visible[t],
                  !state.units.contains(where: { $0.position == other.position && !$0.type.isCivilian }) else { return nil }
            return other.position
        })
        if let target = reach.filter({ civilianTiles.contains($0) }).min(by: { (map.distance(unit.position, $0), $0.q, $0.r) < (map.distance(unit.position, $1), $1.q, $1.r) }) {
            issue(.moveUnit(unit: id, to: target))
            return
        }

        // 2. A favourable attack.
        var best: (score: Int, option: AttackOption)?
        for option in view.attackOptions(for: id) {
            guard let p = view.combatPreview(attacker: .unit(id), target: option.target, from: option.from) else { continue }
            let score: Int
            if case .city = option.defender {
                // Cities only with another raider next to them (M2 §11).
                let besiegers = state.units.filter { u in
                    u.owner == player && !u.type.isCivilian && map.distance(u.position, option.target) <= 1
                }.count + (map.distance(option.from, option.target) <= 1 && map.distance(unit.position, option.target) > 1 ? 1 : 0)
                guard besiegers >= 2 else { continue }
                if p.capturesCity {
                    score = 1_000_000
                } else {
                    guard p.ranged, p.meanDealt > 0 else { continue }
                    score = p.meanDealt
                }
            } else {
                guard p.meanDealt >= p.meanTaken, p.deathPairs * 5 < p.rollPairs else { continue }
                score = p.killPairs * 100 + p.meanDealt - p.meanTaken
            }
            if best == nil || score > best!.score { best = (score, option) }
        }
        if let option = best?.option {
            if option.from != unit.position {
                guard issue(.moveUnit(unit: id, to: option.from)), state.unit(id)?.position == option.from,
                      (state.unit(id)?.movesLeft ?? 0) > 0 else { return }
            }
            issue(.attack(unit: id, target: option.target))
            return
        }

        // 3. Pillage here, or move to something to pillage.
        if let t = map.index(of: unit.position), pillageable(t) {
            issue(.pillage(unit: id))
            return
        }
        let r = state.rules.raiders
        let roam = r?.roamRange ?? 8
        let homeRange = r?.homeRange ?? 3
        if let target = reach.filter({ hex in
            map.distance(hex, home) <= roam && map.index(of: hex).map(pillageable) == true
        }).min(by: { (map.distance(unit.position, $0), $0.q, $0.r) < (map.distance(unit.position, $1), $1.q, $1.r) }) {
            if issue(.moveUnit(unit: id, to: target)), state.unit(id)?.position == target, (state.unit(id)?.movesLeft ?? 0) > 0 {
                issue(.pillage(unit: id))
            }
            return
        }

        // 4. Toward the nearest remembered foreign city within reach of home, else near home.
        let goal = me.memory.cities.filter { $0.owner != player && map.distance($0.position, home) <= roam }
            .min { (map.distance(unit.position, $0.position), $0.id.rawValue) < (map.distance(unit.position, $1.position), $1.id.rawValue) }?
            .position
        let options = reach.filter { $0 != unit.position }
        let target: HexCoord?
        if let goal {
            target = options.filter { map.distance($0, goal) >= 1 }
                .min { (map.distance($0, goal), $0.q, $0.r) < (map.distance($1, goal), $1.q, $1.r) }
        } else if map.distance(unit.position, home) > homeRange {
            target = options.min { (map.distance($0, home), $0.q, $0.r) < (map.distance($1, home), $1.q, $1.r) }
        } else {
            var rng = SplitMix64(seed: state.seed, salts: UInt64(state.turn), UInt64(id.rawValue), 0x2A1F)
            target = rng.pick(options.filter { map.distance($0, home) <= homeRange }.sorted { ($0.q, $0.r) < ($1.q, $1.r) })
        }
        if let target, map.distance(target, unit.position) > 0 {
            issue(.moveUnit(unit: id, to: target))
        } else {
            issue(.skip(unit: id))
        }
    }
}
