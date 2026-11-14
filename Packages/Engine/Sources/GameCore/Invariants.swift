// State invariants (M1 §17, §18): HeadlessSim and the tests check them.

extension GameState {
    /// Every broken invariant, described (empty when the state is sound).
    public func checkInvariants() -> [String] {
        var problems: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { problems.append(message()) }
        }
        let count = map.tileCount

        // Players and relations.
        check(players.indices.allSatisfy { players[$0].id == PlayerID($0) }, "players out of order")
        check(players.indices.contains(currentPlayer.rawValue), "current player \(currentPlayer) does not exist")
        if outcome == nil, players.indices.contains(currentPlayer.rawValue) {
            check(players[currentPlayer.rawValue].isAlive, "current player \(currentPlayer) is eliminated")
            check(players[currentPlayer.rawValue].takesPhases, "current player \(currentPlayer) takes no phases")
        }
        check(relations.count == players.count * (players.count - 1) / 2, "relation count")
        var k = 0
        for i in players.indices {
            for j in players.indices where j > i {
                if k < relations.count { check(relations[k].a == PlayerID(i) && relations[k].b == PlayerID(j), "relation \(k) out of order") }
                k += 1
            }
        }
        check(tileCity.count == count, "territory size")
        for r in relations {
            let free = [players[r.a.rawValue].kind, players[r.b.rawValue].kind].contains { $0 == .free || $0 == .raiders }
            if free { check(r.stance == .war && r.proposalFrom == nil, "\(r.a)-\(r.b): the Free Cities at peace") }
            if r.stance == .war, !free { check(r.met, "\(r.a) and \(r.b) at war without having met") }
            if let from = r.proposalFrom {
                check(r.stance == .war && r.involves(from), "\(r.a)-\(r.b): peace proposal at peace or from a third player")
            }
            check(r.since.map { $0 >= 1 && $0 <= turn } ?? true, "\(r.a)-\(r.b): stance changed in turn \(r.since ?? 0)")
        }

        // Units.
        check(zip(units, units.dropFirst()).allSatisfy { $0.id < $1.id }, "units not sorted by id")
        check(units.allSatisfy { $0.id.rawValue < nextUnitID }, "unit id beyond nextUnitID")
        var military = [Int32](repeating: 0, count: count), civilian = [Int32](repeating: 0, count: count)
        var occupant = [Int](repeating: -1, count: count)
        for unit in units {
            guard let t = map.index(of: unit.position), map.normalize(unit.position) == unit.position else {
                problems.append("\(unit.id) off the map or not normalized")
                continue
            }
            check(players.indices.contains(unit.owner.rawValue) && players[unit.owner.rawValue].isAlive, "\(unit.id) of a dead player")
            check(terrainAllows(t, unit.type, owner: unit.owner), "\(unit.id) on impassable \(unit.position)")
            check(unit.hp > 0 && unit.hp <= rules.constants.healing.maxHP, "\(unit.id) hp \(unit.hp)")
            check(unit.movesLeft >= 0 && unit.movesLeft <= maxMoves(of: unit), "\(unit.id) moves \(unit.movesLeft)")
            check(occupant[t] == -1 || occupant[t] == unit.owner.rawValue, "units of two players on \(unit.position)")
            occupant[t] = unit.owner.rawValue
            if unit.type.isCivilian { civilian[t] += 1 } else { military[t] += 1 }
            check(military[t] <= 1 && civilian[t] <= 1, "too many units on \(unit.position)")
            if let city = city(atTile: t) { check(city.owner == unit.owner, "\(unit.id) in foreign city \(city.id)") }
            check(unit.type != .builder || unit.charges > 0, "\(unit.id) builder without charges")
            check(unit.xp >= 0 && unit.charges >= 0, "\(unit.id) xp \(unit.xp) charges \(unit.charges)")
        }

        // Cities and territory.
        check(zip(cities, cities.dropFirst()).allSatisfy { $0.id < $1.id }, "cities not sorted by id")
        let maxQueue = rules.constants.production.maxQueue
        for city in cities {
            check(city.id.rawValue < nextCityID, "\(city.id) beyond nextCityID")
            guard let centre = map.index(of: city.position) else {
                problems.append("\(city.id) off the map")
                continue
            }
            check(tileCity[centre] == Int32(city.id.rawValue + 1), "\(city.id) does not own its centre")
            check(players.indices.contains(city.owner.rawValue) && players[city.owner.rawValue].isAlive, "\(city.id) of a dead player")
            check(city.population >= 1, "\(city.id) population \(city.population)")
            check(city.foodStore >= 0, "\(city.id) food store \(city.foodStore)")
            check(city.queue.count <= maxQueue, "\(city.id) queue too long")
            check(city.storedProgress >= 0, "\(city.id) stored progress \(city.storedProgress)")
            check(city.buildings == city.buildings.sorted() && Set(city.buildings).count == city.buildings.count,
                  "\(city.id) buildings not sorted and unique")
            let queuedBuildings = city.queue.compactMap { entry -> BuildingID? in
                if case let .building(id) = entry.item { return id } else { return nil }
            }
            check(Set(queuedBuildings).count == queuedBuildings.count, "\(city.id) building queued twice")
            check(queuedBuildings.allSatisfy { !city.has($0) }, "\(city.id) queues a building it has")
            check(city.workedTiles.count + (city.specialists?.count ?? 0) <= city.population,
                  "\(city.id) works more tiles and slots than citizens")
            check(Set(city.workedTiles).count == city.workedTiles.count, "\(city.id) works a tile twice")
            for hex in city.workedTiles {
                guard let t = map.index(of: hex) else { continue }
                check(tileCity[t] == Int32(city.id.rawValue + 1) && t != centre && rules.isWorkable(map.tiles[t]) && !isQuarterTile(t)
                      && map.distance(hex, city.position) <= rules.constants.city.workRadius,
                      "\(city.id) works \(hex) it may not")
            }
            check(city.hp >= 0 && city.hp <= rules.constants.city.maxHP, "\(city.id) hp \(city.hp)")
            let maxWall = city.buildings.compactMap { rules.building($0)?.wallHP }.max() ?? 0
            check(city.wallHP >= 0 && city.wallHP <= maxWall, "\(city.id) wall HP \(city.wallHP) of \(maxWall)")
            if let captured = city.capturedTurn { check(captured >= city.foundedTurn && captured <= turn, "\(city.id) captured in turn \(captured)") }
            check(map.tiles[centre].improvement == nil, "\(city.id) centre improved")
            let quarters = city.quarters ?? []
            check(city.quarters?.isEmpty != true, "\(city.id) empty quarter list")
            if let loyalty = city.loyalty { check((0...100).contains(loyalty), "\(city.id) loyalty \(loyalty)") }
            if city.freeCityLeader != nil || city.freeCityTurns != nil {
                check(city.owner == freeCities && city.freeCityLeader != nil && (city.freeCityTurns ?? 0) > 0,
                      "\(city.id) Free City state on a civ's city")
            }
            check(Set(quarters.map(\.kind)).count == quarters.count && Set(quarters.map(\.tile)).count == quarters.count,
                  "\(city.id) quarters not unique")
            for q in quarters {
                let t = map.index(of: q.tile)
                check(rules.quarter(q.kind) != nil && t != nil && t != centre && tileCity[t ?? centre] == Int32(city.id.rawValue + 1)
                      && map.tiles[t ?? centre].improvement == nil, "\(city.id) quarter \(q.kind) at \(q.tile)")
            }
        }
        let liveCities = Set(cities.map { $0.id.rawValue + 1 })
        for t in 0..<count where tileCity[t] != 0 {
            check(liveCities.contains(Int(tileCity[t])), "tile \(t) owned by a missing city")
        }
        for i in cities.indices {
            for j in cities.indices where j > i {
                check(map.distance(cities[i].position, cities[j].position) >= 1, "two cities on one tile")
            }
        }

        // Tribal villages (M1 §7.7): on passable, unowned land with no unit; indices are
        // range-checked before use, so a damaged save fails here rather than trapping.
        if let villages = tribalVillages {
            check(zip(villages.sites, villages.sites.dropFirst()).allSatisfy { $0 < $1 }, "tribal villages not sorted and unique")
            for site in villages.sites {
                let t = Int(site)
                guard t >= 0, t < count else {
                    problems.append("tribal village on tile \(t), off the map")
                    continue
                }
                let hex = map.coord(at: t)
                check(rules.isPassable(map.tiles[t]), "tribal village on impassable \(hex)")
                check(tileCity[t] == 0, "tribal village on owned \(hex)")
                check(military[t] == 0 && civilian[t] == 0, "a unit on the tribal village at \(hex)")
            }
            check(villages.gifts.count == players.count, "tribal village gifts for \(villages.gifts.count) players")
            check(villages.gifts.allSatisfy { $0 >= 0 }, "tribal village gifts \(villages.gifts)")
        }

        // Players' state and knowledge.
        let palace = rules.palace.id
        let fresh = computeVisibility(for: players.indices.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) })
        let territory = territoryCodes()
        for p in players {
            let i = p.id.rawValue
            check(p.gold >= 0, "\(p.id) gold \(p.gold)")
            check(p.knownTechs == p.knownTechs.sorted() && Set(p.knownTechs).count == p.knownTechs.count, "\(p.id) techs not sorted")
            check(p.knownTechs.allSatisfy { rules.tech($0) != nil }, "\(p.id) knows an unknown tech")
            let civics = p.knownCivics ?? []
            check(civics == civics.sorted() && Set(civics).count == civics.count, "\(p.id) civics not sorted")
            check(civics.allSatisfy { rules.civic($0) != nil }, "\(p.id) knows an unknown civic")
            if let id = p.government { check(rules.government(id) != nil, "\(p.id) has an unknown government") }
            let adopted = p.governmentsAdopted ?? []
            check(adopted == adopted.sorted() && Set(adopted).count == adopted.count, "\(p.id) governments not sorted")
            if let slotted = p.policies {
                let defs = slotted.compactMap(rules.policy)
                check(defs.count == slotted.count && Set(slotted).count == slotted.count, "\(p.id) has bad policies")
                if let gov = government(of: p.id) { check(gov.fits(defs), "\(p.id) policies overflow their slots") }
            }
            if let current = p.researching { check(!p.knows(current), "\(p.id) researches a known tech") }
            let palaces = cities.filter { $0.owner == p.id && $0.has(palace) }
            check(palaces.count <= 1, "\(p.id) has \(palaces.count) palaces")
            if let capital = p.capital { check(palaces.first?.id == capital, "\(p.id) capital is not the palace city") }
            // A player with cities has a capital (the Palace moves when it is lost, M1 §5).
            let hasCities = cities.contains { $0.owner == p.id }
            if p.isMajor {
                check(hasCities == (p.capital != nil), "\(p.id) has \(hasCities ? "cities but no capital" : "a capital but no city")")
            } else if p.kind == .minor {
                check(cities.count { $0.owner == p.id } <= 1 && hasCities == (p.capital != nil), "\(p.id) minor with \(cities.count { $0.owner == p.id }) cities")
                check(minor(p.id)?.envoys.count == players.count, "\(p.id) minor without its envoy table")
            } else if p.kind == .raiders {
                check(p.capital == nil && !hasCities && p.id == raiderPlayer, "\(p.id) raiders with a city")
            } else {
                check(p.capital == nil && palaces.isEmpty && p.id == freeCities, "\(p.id) Free Cities with a capital")
            }
            check(p.visible.count == count && p.explored.count == count, "\(p.id) bitset size")
            check(p.visible == fresh[i], "\(p.id) visibility is stale")
            check(p.explored.isSuperset(of: p.visible), "\(p.id) sees unexplored tiles")
            check(p.memory.tileOwner.count == count && p.memory.tileImprovement.count == count, "\(p.id) memory size")
            var staleTiles = 0
            p.visible.forEachIndex { t in
                if p.memory.tileOwner[t] != territory[t] || p.memory.tileImprovement[t] != (map.tiles[t].improvement?.rawValue ?? 0)
                    || p.memory.remembersRoad(t) != map.tiles[t].hasRoad {
                    staleTiles += 1
                }
            }
            check(staleTiles == 0, "\(p.id) remembers \(staleTiles) visible tiles wrongly")
            // Tribal villages remembered: sorted, unique, on the map, nil rather than empty; and
            // on every tile the player sees now, remembered exactly when one stands there.
            var rememberedVillages: [Int32] = []
            if let memory = p.memory.tribalVillages {
                check(!memory.isEmpty, "\(p.id) remembers an empty list of tribal villages")
                check(zip(memory, memory.dropFirst()).allSatisfy { $0 < $1 }, "\(p.id) tribal village memory not sorted and unique")
                check(memory.allSatisfy { $0 >= 0 && Int($0) < count }, "\(p.id) remembers a tribal village off the map")
                rememberedVillages = memory.filter { $0 >= 0 && Int($0) < count }
            }
            if p.visible.count == count {
                let liveVillages = (tribalVillages?.sites ?? []).filter { $0 >= 0 && Int($0) < count }
                let unremembered = liveVillages.filter { p.visible[Int($0)] && !SortedTiles.contains(rememberedVillages, Int($0)) }
                let gone = rememberedVillages.filter { p.visible[Int($0)] && !holdsTribalVillage(Int($0)) }
                check(unremembered.isEmpty && gone.isEmpty,
                      "\(p.id) remembers visible tribal villages wrongly: \(unremembered.count) seen and not remembered, \(gone.count) remembered and gone")
            }
            check(zip(p.memory.cities, p.memory.cities.dropFirst()).allSatisfy { $0.id < $1.id }, "\(p.id) city memory not sorted")
            check(zip(p.memory.units, p.memory.units.dropFirst()).allSatisfy { $0.id < $1.id }, "\(p.id) unit memory not sorted")
            check(p.memory.units.allSatisfy { $0.owner != p.id }, "\(p.id) remembers its own units")
        }
        return problems
    }
}
