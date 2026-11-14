import GameCore

/// A minor faction's phase (M2 §12.1), stateless: accept peace once the war is old enough,
/// keep the city building era units up to `maxMilitary`, bombard, make favourable attacks on
/// enemy units near the city, and otherwise hold the city and its ring. Never settles, never
/// declares war, never takes cities.
enum MinorAI {
    static func playPhase(_ state: inout GameState, player: PlayerID) -> AIPhaseReport {
        var bot = MinorTurn(state: state, player: player)
        bot.play()
        state = bot.state
        return AIPhaseReport(result: AITurnResult(steps: bot.steps), posture: .develop, rival: nil, rejections: [],
                             hitCommandCap: false, planSummary: "minor", target: nil, rally: nil, advancing: false,
                             notes: [], stepTimes: [], escortRequests: [])
    }
}

struct MinorTurn {
    var state: GameState
    let player: PlayerID
    var steps: [AIStep] = []
    /// Units engage enemies within this distance of the city.
    static let guardRange = 3

    var live: Bool { state.outcome == nil && state.currentPlayer == player }

    @discardableResult
    mutating func issue(_ command: Command) -> Bool {
        guard live, let events = try? GameEngine.apply(command, by: player, to: &state) else { return false }
        steps.append(AIStep(command: command, events: events))
        return true
    }

    mutating func play() {
        acceptPeace()
        manageCity()
        bombard()
        let ids = state.units.filter { $0.owner == player }.map(\.id)
        for id in ids where live { act(id) }
        if live { issue(.endTurn) }
    }

    var city: City? { state.cities.first { $0.owner == player } }

    mutating func acceptPeace() {
        let after = state.rules.minors?.peaceAfterTurns ?? 5
        for proposer in state.view(for: player).peaceProposals {
            let since = state.relation(player, proposer).since ?? 0
            if state.turn - since >= after { issue(.respondToPeace(from: proposer, accept: true)) }
        }
    }

    mutating func manageCity() {
        guard let city, city.queue.isEmpty, let m = state.rules.minors else { return }
        let military = state.units.filter { $0.owner == player && !$0.type.isCivilian }
        if military.count < m.maxMilitary {
            let types = m.units(era: state.worldEra ?? 0)
            let ranged = military.count { state.rules.unit($0.type).isRanged }
            let wanted = types.sorted { a, b in
                let (ra, rb) = (state.rules.unit(a).isRanged, state.rules.unit(b).isRanged)
                return ra != rb ? (ranged * 2 < military.count ? ra : !ra) : a.rawValue < b.rawValue
            }
            for type in wanted where issue(.setQueue(city: city.id, items: [.unit(type)])) { return }
        }
        for b in ["monument", "granary", "walls"] as [BuildingID] where !city.has(b) {
            if issue(.setQueue(city: city.id, items: [.building(b)])) { return }
        }
    }

    mutating func bombard() {
        guard let city else { return }
        let view = state.view(for: player)
        let best = view.cityAttackOptions(for: city.id).compactMap { option -> (Int, AttackOption)? in
            guard case .unit = option.defender,
                  let p = view.combatPreview(attacker: .city(city.id), target: option.target, from: city.position) else { return nil }
            return (p.meanDealt, option)
        }.max { ($0.0, $1.1.target.q, $1.1.target.r) < ($1.0, $0.1.target.q, $0.1.target.r) }
        if let option = best?.1 { issue(.cityAttack(city: city.id, target: option.target)) }
    }

    mutating func act(_ id: UnitID) {
        guard let unit = state.unit(id), unit.movesLeft > 0, let home = city?.position else { return }
        let map = state.map
        let view = state.view(for: player)

        var best: (score: Int, option: AttackOption)?
        for option in view.attackOptions(for: id) where map.distance(option.target, home) <= Self.guardRange {
            guard case .unit = option.defender,
                  let p = view.combatPreview(attacker: .unit(id), target: option.target, from: option.from),
                  p.meanDealt >= p.meanTaken, p.deathPairs * 5 < p.rollPairs else { continue }
            let score = p.killPairs * 100 + p.meanDealt - p.meanTaken - (option.from == unit.position ? 0 : 5)
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

        // Hold: the city centre if no own military stands there, else the ring.
        let garrisoned = state.units.contains { $0.owner == player && $0.id != id && !$0.type.isCivilian && $0.position == home }
        let goal = garrisoned ? 1 : 0
        if map.distance(unit.position, home) > goal {
            let reach = view.reachableTiles(for: id)
            if let target = reach.filter({ $0 != unit.position })
                .min(by: { (map.distance($0, home), $0.q, $0.r) < (map.distance($1, home), $1.q, $1.r) }),
               map.distance(target, home) < map.distance(unit.position, home) {
                issue(.moveUnit(unit: id, to: target))
                return
            }
        }
        if unit.activity != .fortified && unit.activity != .fortifying, issue(.fortify(unit: id)) { return }
        issue(.skip(unit: id))
    }
}
