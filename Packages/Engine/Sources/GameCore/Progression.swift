// Insights and the world era (M2 §2, §6.2).

extension GameState {
    // MARK: World era

    /// At a turn's start (before its first phase): the world advances one era when the living
    /// players' mean progress through the world era's own techs, weighted by cost, reaches
    /// `worldEraAdvancePct`, or when a player knows `forceAheadCount` techs of the era after the
    /// next. Every living player then gets catch-up credit toward the unknown techs of the era
    /// the world left.
    mutating func advanceWorldEraIfDue(_ fx: inout Effects) {
        guard let era = worldEra, let progression = rules.progression, era + 1 < rules.eras.count else { return }
        let living = players.indices.filter { players[$0].isAlive && players[$0].isMajor }
        guard !living.isEmpty else { return }
        let current = rules.techs.indices.filter { rules.techEras[$0] == era }
        let total = current.reduce(0) { $0 + rules.techs[$1].cost }
        var sum = 0
        var forced = false
        for p in living {
            let known = current.reduce(0) { $0 + (players[p].knows(rules.techs[$1].id) ? rules.techs[$1].cost : 0) }
            sum += total == 0 ? 100 : 100 * known / total
            let ahead = rules.techs.indices.count { rules.techEras[$0] >= era + 2 && players[p].knows(rules.techs[$0].id) }
            if ahead >= progression.forceAheadCount { forced = true }
        }
        guard forced || sum >= progression.worldEraAdvancePct * living.count else { return }
        worldEra = era + 1
        for p in living {
            for i in rules.techs.indices where rules.techEras[i] == era {
                addTechCredit(rules.techs[i].cost * progression.catchUpInsightPct / 100, techIndex: i, player: PlayerID(p))
            }
        }
        giveMinorsEraDefenders(&fx)
        fx.emit(.worldEraAdvanced(era: era + 1), .everyone)
    }

    // MARK: Insights

    /// After a command: fires the Insights the command's events may have completed (M2 §6.2).
    /// Each event marks the kinds it can affect for the players it concerns; only those are
    /// evaluated, from the state after the command.
    mutating func checkInsights(_ fx: inout Effects) {
        guard let progression = rules.progression,
              rules.techs.contains(where: { $0.insight != nil }) || rules.civics.contains(where: { $0.insight != nil }) else { return }
        var dirty = [Set<InsightKind>](repeating: [], count: players.count)
        var kills = [[(by: UnitClass, of: UnitClass)]](repeating: [], count: players.count)
        var defended = [Bool](repeating: false, count: players.count)
        func mark(_ player: PlayerID, _ kinds: InsightKind...) {
            guard dirty.indices.contains(player.rawValue) else { return }
            dirty[player.rawValue].formUnion(kinds)
        }
        let events = fx.pending.map(\.event)
        var killed: [UnitID: UnitType] = [:]
        for event in events { if case let .unitKilled(unit, type, _, _) = event { killed[unit] = type } }
        for event in events {
            switch event {
            case let .playersMet(a, b):
                mark(a, .meetPlayers, .meetMinors)
                mark(b, .meetPlayers, .meetMinors)
            case let .patronChanged(_, patron):
                if let patron { mark(patron, .bePatron) }
            case let .cityFounded(_, _, owner, _):
                mark(owner, .ownCities, .ownCoastalCities, .foundOverseasCity)
            case let .warDeclared(_, on):
                mark(on, .warDeclaredOn)
            case let .cityGrew(city, _, _):
                if let owner = self.city(city)?.owner { mark(owner, .cityPopulation) }
            case let .phaseStarted(_, player):
                mark(player, .cityInUnrest)
            case let .cityCaptured(_, _, _, to, _):
                mark(to, .ownCities, .ownCoastalCities, .ownBuildings, .foundOverseasCity)
            case let .improvementBuilt(_, _, owner):
                mark(owner, .buildImprovements, .quarterAdjacency)
            case let .productionCompleted(city, _, _):
                if let owner = self.city(city)?.owner { mark(owner, .ownBuildings, .ownUnits, .ownQuarters, .ownMilitaryUnits, .quarterAdjacency) }
            case let .unitCreated(_, _, owner, _):
                mark(owner, .ownUnits, .ownMilitaryUnits)
            case let .unitCaptured(_, _, _, _, to, _):
                mark(to, .ownUnits)
            case let .combat(.unit(attacker), .unit(defender), _, _, _, _, _):
                if let victim = killed[defender], let unit = unit(attacker), players.indices.contains(unit.owner.rawValue) {
                    kills[unit.owner.rawValue].append((rules.unit(unit.type).unitClass, rules.unit(victim).unitClass))
                    mark(unit.owner, .killWith)
                }
            case let .combat(_, .city(id), _, _, _, _, _):
                if let city = city(id), city.wallHP > 0, players.indices.contains(city.owner.rawValue) {
                    defended[city.owner.rawValue] = true
                    mark(city.owner, .cityDefended)
                }
            case let .raiderCampCleared(player, _, _):
                mark(player, .clearRaiderCamp)
            case let .tradeRouteStarted(_, owner, _, _):
                mark(owner, .tradeRoutes)
            default:
                break
            }
        }
        for p in players.indices where players[p].isAlive && players[p].isMajor && !dirty[p].isEmpty {
            for (i, tech) in rules.techs.enumerated() {
                guard let insight = tech.insight, dirty[p].contains(insight.kind), !players[p].knows(tech.id),
                      !players[p].hasInsight(tech.id) else { continue }
                let fired: Bool = switch insight.kind {
                case .killWith:
                    kills[p].contains { kill in
                        (insight.classes ?? []).contains(kill.by) && (insight.against.map { $0.contains(kill.of) } ?? true)
                    }
                case .cityDefended:
                    defended[p]
                default:
                    insightCount(insight, for: PlayerID(p)) >= (insight.count ?? 1)
                }
                guard fired else { continue }
                let credit = tech.cost * progression.insightPct / 100
                addTechCredit(credit, techIndex: i, player: PlayerID(p))
                players[p].insights = ((players[p].insights ?? []) + [tech.id]).sorted()
                fx.emit(.insightGained(player: PlayerID(p), tech: tech.id, credit: credit), .owner(PlayerID(p)))
            }
            for civic in rules.civics {
                guard let insight = civic.insight, dirty[p].contains(insight.kind), !players[p].knowsCivic(civic.id),
                      players[p].civicInsights?.contains(civic.id) != true else { continue }
                let fired = insight.kind == .warDeclaredOn || insight.kind == .clearRaiderCamp || insightCount(insight, for: PlayerID(p)) >= (insight.count ?? 1)
                guard fired else { continue }
                players[p].civicInsights = ((players[p].civicInsights ?? []) + [civic.id]).sorted()
                let credit = civic.cost * progression.insightPct / 100
                fx.emit(.civicInsightGained(player: PlayerID(p), civic: civic.id, credit: credit), .owner(PlayerID(p)))
            }
        }
    }

    /// The counted quantity of a count-based Insight for `player`.
    func insightCount(_ insight: InsightDef, for player: PlayerID) -> Int {
        switch insight.kind {
        case .meetPlayers:
            return players.indices.count { $0 != player.rawValue && players[$0].isMajor && hasMet(player, PlayerID($0)) }
        case .meetMinors:
            return players.count { $0.kind == .minor && hasMet(player, $0.id) }
        case .bePatron:
            return patronages(of: player).count
        case .ownCities:
            return cities.count { $0.owner == player }
        case .ownCoastalCities:
            return cities.count { city in
                city.owner == player && map.neighbors(of: city.position).contains { hex in
                    map.tile(at: hex).map { $0.terrain == .coast || $0.terrain == .lake } ?? false
                }
            }
        case .buildImprovements:
            let kind = Improvement.allCases.first { caseName($0) == insight.target }
            guard kind != nil || insight.target == nil else { return 0 }
            return map.tiles.indices.count { t in
                map.tiles[t].improvement != nil && (kind == nil || map.tiles[t].improvement == kind) && tileCity[t] > 0 && city(CityID(Int(tileCity[t]) - 1))?.owner == player
            }
        case .ownBuildings:
            let id = BuildingID(stringLiteral: insight.target ?? "")
            return cities.count { $0.owner == player && $0.has(id) }
        case .ownUnits:
            guard let type = UnitType(rawValue: insight.target ?? "") else { return 0 }
            return units.count { $0.owner == player && $0.type == type }
        case .ownQuarters:
            return cities.reduce(0) { n, city in
                guard city.owner == player else { return n }
                return n + (city.quarters ?? []).count { insight.target == nil || $0.kind.rawValue == insight.target }
            }
        case .cityPopulation:
            return cities.filter { $0.owner == player }.map(\.population).max() ?? 0
        case .cityInUnrest:
            return cities.count { city in
                guard city.owner == player, let value = city.stability else { return false }
                let state = rules.stabilityState(value)
                return state == .unrest || state == .revolt
            }
        case .ownMilitaryUnits:
            return units.count { $0.owner == player && rules.unit($0.type).isMilitary }
        case .foundOverseasCity:
            return overseasCityCount(of: player)
        case .quarterAdjacency:
            return cities.reduce(0) { best, city in
                guard city.owner == player, let centre = map.index(of: city.position) else { return best }
                return (city.quarters ?? []).reduce(best) { b, q in
                    guard q.kind.rawValue == insight.target, let t = map.index(of: q.tile) else { return b }
                    return max(b, quarterAdjacency(q.kind, at: t, owner: player, centre: centre))
                }
            }
        case .tradeRoutes:
            return (tradeRoutes ?? []).count { $0.owner == player }
        case .killWith, .cityDefended, .warDeclaredOn, .clearRaiderCamp:
            return 0
        }
    }

    /// `player`'s cities on another landmass than its capital's (land tiles joined by land).
    func overseasCityCount(of player: PlayerID) -> Int {
        let own = cities.filter { $0.owner == player }
        guard own.count > 1, let capital = own.first(where: { $0.has(rules.palace.id) }),
              let start = map.index(of: capital.position) else { return 0 }
        var seen = [Bool](repeating: false, count: map.tiles.count)
        var stack = [start]
        seen[start] = true
        while let t = stack.popLast() {
            map.forEachNeighbor(of: t) { n, _ in
                guard !seen[n], !map.tiles[n].terrain.isWater else { return }
                seen[n] = true
                stack.append(n)
            }
        }
        return own.count { city in map.index(of: city.position).map { !seen[$0] } ?? false }
    }
}
