import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// Fairness (M1 §13): changing anything the AI's player cannot see leaves the AI's commands
// identical. The twin world changes every kind of hidden fact about every other player: gold,
// research (target, progress and known techs, keeping their count), cities out of sight (queue,
// progress, stored progress, food and culture stores, focus, HP, wall HP, buildings and
// population, keeping the score), units out of sight (position, HP, activity, experience,
// moves), what the others have explored, and the relations between two other players. Unit and
// city counts stay equal in both worlds: ids are global counters, so a new unit's id would count
// hidden units (the side channel noted in FogLeakTests). Several seeds, map sizes and turns,
// for every player whose phase comes up, at peace and at war.

@Suite struct AIFairnessTests {
    /// Tiles (indices) at least 7 tiles from every unit and city of `viewer` and not visible to
    /// it: nothing the viewer does in one phase can see them (its units see at most 3 tiles
    /// from where they end, after moving at most 3; a city it takes shows its territory, at
    /// most 3 tiles from the city, which is next to the attacker).
    static func farFromViewer(_ a: GameState, _ viewer: PlayerID) -> (Int) -> Bool {
        let visible = a.players[viewer.rawValue].visible
        let anchors = a.units.filter { $0.owner == viewer }.map(\.position) + a.cities.filter { $0.owner == viewer }.map(\.position)
        return { t in !visible[t] && anchors.allSatisfy { a.map.distance($0, a.map.coord(at: t)) >= 7 } }
    }

    /// World B: world A with everything `viewer` cannot see changed. Returns B and what was
    /// changed (units moved, hidden cities changed, third-party relations changed).
    static func hiddenTwin(of a: GameState, viewer: PlayerID) -> (GameState, moved: Int, cities: Int, relations: Int) {
        var b = a
        let rules = a.rules
        let far = farFromViewer(a, viewer)
        let others = a.players.map(\.id).filter { $0 != viewer }
        for rival in others where a.players[rival.rawValue].isAlive {
            let r = rival.rawValue
            b.players[r].gold += 537 + 11 * r
            // Research: another target, more progress, one known tech swapped for an unknown one
            // (same count: the score is public).
            let options = a.view(for: rival).researchOptions()
            if let other = options.last(where: { $0.available && !$0.researching }) {
                b.players[r].researching = other.tech
                b.players[r].researchTarget = other.tech
            }
            b.players[r].researchProgress += 9
            let known = a.players[r].knownTechs
            if let drop = known.last, let add = rules.techs.map(\.id).first(where: { !known.contains($0) }) {
                b.players[r].knownTechs = (known.filter { $0 != drop } + [add]).sorted()
                if b.players[r].researching == add {
                    b.players[r].researching = nil
                    b.players[r].researchTarget = nil
                }
            }
            // Everything explored: the viewer cannot tell.
            for t in 0..<a.map.tileCount { b.players[r].explored[t] = true }
            b.players[r].citiesNamed += 3
        }

        // Cities out of sight: inner state; population moves between two of the same owner.
        var hiddenCities: [City] = []
        for city in a.cities where city.owner != viewer && far(a.map.index(of: city.position)!) {
            hiddenCities.append(city)
            updateCity(&b, city.id) { c in
                c.queue = [QueueEntry(.unit(.warrior), progress: 3), QueueEntry(.building("monument"), progress: 1)]
                c.storedProgress += 2
                c.foodStore += 4
                c.cultureStore += 5
                c.focus = c.focus == .production ? .gold : .production
                c.hp = max(1, c.hp - 23)
                c.wallHP = max(0, c.wallHP - 7)
                // One building swapped for another (same count, walls untouched: the score and
                // the remembered walls stay the same).
                if let swap = c.buildings.first(where: { ["monument", "granary", "library", "market"].contains($0.rawValue) }),
                   let other = ["monument", "granary", "library", "market"].map({ BuildingID($0) }).first(where: { !c.has($0) }) {
                    c.buildings = (c.buildings.filter { $0 != swap } + [other]).sorted { $0.rawValue < $1.rawValue }
                }
            }
        }
        for owner in others {
            let mine = hiddenCities.filter { $0.owner == owner }
            guard mine.count >= 2, let from = mine.first(where: { $0.population >= 2 }), let to = mine.first(where: { $0.id != from.id }) else { continue }
            updateCity(&b, from.id) { $0.population -= 1 }
            updateCity(&b, to.id) { $0.population += 1 }
        }

        // Units out of sight: moved within 3 tiles (to another far tile), hurt, fortified.
        var moved = 0
        for unit in a.units where unit.owner != viewer && far(a.map.index(of: unit.position)!) {
            let spots = a.map.coords(within: 3, of: unit.position).filter { h in
                guard let t = b.map.index(of: h), h != unit.position, far(t), rules.isPassable(b.map.tiles[t]),
                      b.city(atTile: t) == nil else { return false }
                return b.canEnd(unit.type, owner: unit.owner, at: h, ignoring: unit.id)
            }
            b.updateUnit(unit.id) { u in
                u.hp = max(10, u.hp - 37)
                u.xp += 6
                u.movesLeft = max(0, u.movesLeft - 1)
                if !u.type.isCivilian { u.activity = u.activity == .fortified ? .none : .fortified }
                if let spot = spots.first { u.position = spot }
            }
            if !spots.isEmpty { moved += 1 }
        }

        // Relations between two other players: stance, since, cool-downs.
        var relations = 0
        for i in b.relations.indices where !b.relations[i].involves(viewer) {
            b.relations[i].stance = b.relations[i].stance == .war ? .peace : .war
            b.relations[i].since = (b.relations[i].since ?? 0) + 3
            b.relations[i].aCooldownEnds += 5
            relations += 1
        }
        DebugTools.refreshAllKnowledge(in: &b)
        return (b, moved, hiddenCities.count, relations)
    }

    /// The viewer's knowledge is the same in both worlds (a check on the setup).
    static func sameKnowledge(_ a: GameState, _ b: GameState, _ viewer: PlayerID) -> Bool {
        let va = a.view(for: viewer), vb = b.view(for: viewer)
        let others = a.players.map(\.id).filter { $0 != viewer }
        return va.visibleForeignUnits == vb.visibleForeignUnits && va.knownCities == vb.knownCities
            && va.sightings == vb.sightings && va.knownTerritory == vb.knownTerritory && va.knownImprovements == vb.knownImprovements
            && va.me == vb.me && va.peaceProposals == vb.peaceProposals && va.players == vb.players
            && va.units == vb.units && va.cities == vb.cities && va.visible == vb.visible
            && others.allSatisfy { va.relation(with: $0) == vb.relation(with: $0) }
    }

    /// What one game's comparisons covered.
    struct Coverage: Sendable {
        var compared = 0, warPhases = 0, moved = 0, hiddenCities = 0, relations = 0
        var failures: [String] = []
    }

    /// Plays an AI game and, at each stop, compares one round of phases (each player's) in
    /// world A and its hidden twin.
    static func compare(_ size: MapSize, seed: UInt64, stops: [Int]) -> Coverage {
        var state = aiGame(size, seed: seed)
        var cover = Coverage()
        for stop in stops {
            playAI(&state, until: stop)
            guard state.outcome == nil else { break }
            for _ in 0..<state.players.count {
                let viewer = state.currentPlayer
                var a = state
                DebugTools.refreshAllKnowledge(in: &a)
                var (b, moved, cities, relations) = hiddenTwin(of: a, viewer: viewer)
                guard sameKnowledge(a, b, viewer) else {
                    cover.failures.append("\(size) seed \(seed) turn \(state.turn): the twin leaks to \(viewer)")
                    return cover
                }
                guard a.stateHash() != b.stateHash() else { continue }
                cover.moved += moved
                cover.hiddenCities += cities
                cover.relations += relations
                if a.players.contains(where: { $0.id != viewer && $0.isAlive && a.isAtWar(viewer, $0.id) }) { cover.warPhases += 1 }
                let commandsA = playPhase(&a).commands
                let commandsB = playPhase(&b).commands
                if commandsA != commandsB {
                    let first = zip(commandsA, commandsB).first { $0 != $1 }.map { "\($0.0) vs \($0.1)" } ?? "lengths differ"
                    cover.failures.append("\(size) seed \(seed) turn \(state.turn) \(viewer): hidden facts changed the commands; first difference: \(first)")
                }
                cover.compared += 1
                state = a
                if state.outcome != nil { break }
            }
        }
        return cover
    }

    /// Duel seeds 1–3 and a Small game (four players: relations between two others), at peace
    /// and at war, for every player whose phase comes up: the AI plays the same commands in
    /// both worlds.
    @Test func hiddenFactsDoNotChangeCommands() async throws {
        async let duel1 = Self.compare(.duel, seed: 1, stops: [12, 40, 70, 85, 100, 115])
        async let duel2 = Self.compare(.duel, seed: 2, stops: [25, 60, 80, 95, 110])
        async let duel3 = Self.compare(.duel, seed: 3, stops: [35, 75, 90, 105])
        async let small = Self.compare(.small, seed: 4, stops: [20, 50, 80, 95])
        let all = [await duel1, await duel2, await duel3, await small]
        for failure in all.flatMap(\.failures) { Issue.record(Comment(rawValue: failure)) }
        let compared = all.reduce(0) { $0 + $1.compared }
        #expect(compared >= 40, "only \(compared) phases compared")
        #expect(all.reduce(0) { $0 + $1.moved } > 0, "no hidden unit was moved: the test proves little")
        #expect(all.reduce(0) { $0 + $1.hiddenCities } > 0, "no hidden city was changed")
        #expect(all.reduce(0) { $0 + $1.relations } > 0, "no third-party relation was changed")
        #expect(all.reduce(0) { $0 + $1.warPhases } >= 4, "too few comparisons at war")
    }
}
