import Foundation
import Testing
@testable import GameCore

// The App's read-only queries (GameCore/Queries/UI*.swift, M1 §16): the tile sheet's facts, and
// the info cards' City Strength and tile defence. Each must say what the engine does, from what
// the player knows only.

@Suite struct UIQueryTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Move cost, defence, river and city numbers come from the rules, as the engine uses them.
    @Test func tileFactsFollowTheRules() throws {
        var map = openMap()
        map[hex(4, 3)] = Tile(terrain: .plains, elevation: .hills, feature: .forest, riverEdges: 1)
        map[hex(6, 3)] = Tile(terrain: .grassland, elevation: .mountains)
        var state = makeTestState(map: map)
        #expect(state.view(for: me).tileFacts(at: hex(4, 3)) == nil, "unexplored tiles have no facts")

        state.addUnit(.warrior, owner: me, at: hex(5, 3))
        let view = state.view(for: me)
        let rules = state.rules
        let facts = try #require(view.tileFacts(at: hex(4, 3)))
        let hills = rules.elevation(.hills), forest = rules.feature(.forest)
        #expect(facts.moveCost == 1 + hills.moveCost + forest.moveCost)
        #expect(facts.defense == [StrengthModifier(kind: .elevation(.hills), value: hills.defense),
                                  StrengthModifier(kind: .feature(.forest), value: forest.defense)])
        #expect(facts.defense.map(\.name) == ["Hills", "Forest"])
        #expect(facts.totalDefense == view.tileDefenseModifier(at: hex(4, 3)))
        #expect(facts.riverCrossingCost == rules.river.crossingMoveCost)
        #expect(facts.riverAttackModifier == rules.river.meleeAttackModifier && facts.riverAttackModifier < 0)
        #expect(facts.cityStrength == hills.cityStrength)
        #expect(facts.yields == view.tileYields(at: hex(4, 3)))
        #expect(facts.owner == nil && facts.city == nil && facts.isVisible)

        let mountain = try #require(view.tileFacts(at: hex(6, 3)))
        #expect(mountain.moveCost == nil, "land units cannot enter mountains")
        let plain = try #require(view.tileFacts(at: hex(5, 2)))
        #expect(plain.moveCost == 1 && plain.defense.isEmpty && plain.riverCrossingCost == 0 && plain.riverAttackModifier == 0)
        #expect(view.tileFacts(at: HexCoord(q: 500, r: 500)) == nil)
    }

    /// A city centre counts as having no forest (M1 §4): no move cost or defence from it.
    @Test func aCityCentreDropsItsForest() throws {
        var map = openMap()
        map[hex(5, 3)] = Tile(terrain: .grassland, feature: .forest)
        var state = makeTestState(map: map)
        let city = addCity(&state, me, at: hex(5, 3))
        let facts = try #require(state.view(for: me).tileFacts(at: hex(5, 3)))
        #expect(facts.moveCost == 1)
        #expect(facts.defense.isEmpty)
        #expect(facts.owner == me)
        #expect(facts.city?.id == city)
    }

    /// The tile sheet's defence is what the combat preview lists for a defender standing there.
    @Test func tileDefenceMatchesTheCombatPreview() throws {
        var map = openMap()
        map[hex(5, 3)] = Tile(terrain: .grassland, elevation: .hills, feature: .forest)
        var state = makeTestState(map: map)
        setWar(&state, me, them)
        let archer = state.addUnit(.archer, owner: me, at: hex(3, 3))
        state.addUnit(.warrior, owner: them, at: hex(5, 3))
        let view = state.view(for: me)
        let preview = try #require(view.combatPreview(attacker: .unit(archer), target: hex(5, 3), from: hex(3, 3)))
        let terrain = preview.defenderStrength.modifiers.filter { modifier in
            switch modifier.kind {
            case .elevation, .feature: true
            default: false
            }
        }
        let facts = try #require(view.tileFacts(at: hex(5, 3)))
        #expect(terrain == facts.defense)
    }

    /// A foreign city's info card shows the City Strength the attacker would meet.
    @Test func knownCityStrengthMatchesTheCombatPreview() throws {
        var state = makeTestState(map: openMap())
        setWar(&state, me, them)
        let city = addCity(&state, them, at: hex(6, 3))
        updateCity(&state, city) { $0.population = 3 }
        let archer = state.addUnit(.archer, owner: me, at: hex(4, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let preview = try #require(view.combatPreview(attacker: .unit(archer), target: hex(6, 3), from: hex(4, 3)))
        let strength = try #require(view.knownCityStrength(at: hex(6, 3)))
        #expect(strength.total == preview.defenderStrength.total)
        #expect(view.knownOwner(at: hex(6, 3)) == them)
    }

    /// Why a city cannot be founded on a tile mirrors `canFoundCity`, the first failing rule:
    /// unexplored, water, mountains, a feature that forbids it, another player's land, too
    /// close to a known city.
    @Test func foundingProblemMirrorsCanFoundCity() throws {
        var map = openMap()
        map[hex(2, 5)] = Tile(terrain: .coast)
        map[hex(3, 5)] = Tile(terrain: .grassland, elevation: .mountains)
        map[hex(1, 4)] = Tile(terrain: .desert, feature: .oasis)
        var state = makeTestState(map: map)
        let rome = addCity(&state, me, at: hex(2, 1))
        addCity(&state, them, at: hex(8, 3))
        state.addUnit(.scout, owner: me, at: hex(2, 4))
        state.addUnit(.scout, owner: me, at: hex(6, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let name = try #require(view.city(rome)?.name)
        let minimum = state.rules.constants.city.minDistance
        #expect(view.foundingProblem(at: hex(2, 5)) == .water)
        #expect(view.foundingProblem(at: hex(3, 5)) == .mountains)
        #expect(view.foundingProblem(at: hex(1, 4)) == .feature("oasis"))
        #expect(view.knownOwner(at: hex(7, 3)) == them)
        #expect(view.foundingProblem(at: hex(7, 3)) == .owned(by: them))
        #expect(view.foundingProblem(at: hex(2, 3)) == .tooClose(to: rome, name: name, minimum: minimum))
        #expect(view.foundingProblem(at: hex(11, 0)) == .unexplored)
        // Every explored tile: a problem exactly where no city may be founded.
        for t in 0..<state.map.tileCount where state.players[0].explored[t] {
            let hex = state.map.coord(at: t)
            #expect((view.foundingProblem(at: hex) == nil) == view.canFoundCity(at: hex), "\(hex)")
        }
    }

    /// Sites rank against each other: the top quarter good, the bottom quarter poor, fair
    /// between; equal scores share a rank, so a field of equal sites is all fair. The overlay
    /// shades follow the qualities (poor 1–3, fair 4–5, good 6–7).
    @Test func sitesRankAgainstEachOther() throws {
        let ranking = SiteRanking(sites: (0..<8).map { SiteScore(tile: $0, score: 10 * ($0 + 1)) })
        #expect(stride(from: 10, through: 80, by: 10).map { ranking.quality(of: $0) }
            == [.poor, .poor, .fair, .fair, .fair, .fair, .good, .good])
        let shades = stride(from: 10, through: 80, by: 10).map { ranking.shade(of: $0) }
        #expect(shades == shades.sorted(), "shades never fall as scores rise")
        for score in stride(from: 10, through: 80, by: 10) {
            let shade = ranking.shade(of: score)
            switch ranking.quality(of: score) {
            case .poor: #expect((1...3).contains(shade))
            case .fair: #expect((4...5).contains(shade))
            case .good: #expect((6...7).contains(shade))
            }
        }
        let flat = SiteRanking(sites: (0..<30).map { SiteScore(tile: $0, score: 90) })
        #expect(flat.quality(of: 90) == .fair, "nothing stands out where every site is alike")
        #expect(SiteRanking(sites: [SiteScore(tile: 0, score: 40)]).quality(of: 40) == .fair)
        #expect(SiteRanking(sites: []).quality(of: 40) == .fair)
        // A score among others: below all of them poor, above all good.
        #expect(ranking.quality(of: 5) == .poor && ranking.quality(of: 99) == .good)
    }

    /// The ranking takes every site the player could found a city on within the radius, by its
    /// settle score, in tile order; the site facts count what the score counts.
    @Test func siteRankingAndFactsFollowTheSettleScore() throws {
        var map = makeTestMap()
        map[hex(2, 5)] = Tile(terrain: .coast)
        map[hex(2, 4)] = Tile(terrain: .plains, elevation: .hills)
        map[hex(2, 2)] = Tile(terrain: .grassland, riverEdges: 1)
        var state = makeTestState(map: map)
        state.addUnit(.settler, owner: me, at: hex(3, 3))
        state.addUnit(.scout, owner: me, at: hex(7, 4))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let ranking = view.siteRanking(around: hex(3, 3), radius: 4)
        let expected = view.coords(within: 4, of: hex(3, 3)).compactMap { hex -> SiteScore? in
            let score = view.settleScore(at: hex)
            return score > 0 ? SiteScore(tile: view.index(of: hex)!, score: score) : nil
        }.sorted { $0.tile < $1.tile }
        #expect(ranking.sites == expected)
        #expect(!ranking.sites.isEmpty)
        let s = state.rules.constants.settle
        var bonuses = (water: false, coast: false, hills: false)
        for t in 0..<state.map.tileCount {
            let hex = state.map.coord(at: t)
            guard let facts = view.siteFacts(at: hex) else {
                #expect(!view.canFoundCity(at: hex), "\(hex)")
                continue
            }
            let y = facts.yields
            let score = s.foodWeight * y.food + s.productionWeight * y.production + s.goldWeight * y.gold
                + (facts.freshWater ? s.freshWaterBonus : 0) + (facts.coast ? s.coastBonus : 0) + (facts.hills ? s.hillsBonus : 0)
            #expect(score == view.settleScore(at: hex), "\(hex)")
            #expect(facts.radius == s.radius)
            bonuses.water = bonuses.water || facts.freshWater
            bonuses.coast = bonuses.coast || facts.coast
            bonuses.hills = bonuses.hills || facts.hills
        }
        #expect(bonuses.water && bonuses.coast && bonuses.hills, "the map exercises each bonus")
        // At the edge of what is explored, the unexplored tiles are counted.
        let edge = try #require(ranking.sites.map { view.coord(at: $0.tile) }.first { hex in
            view.coords(within: s.radius, of: hex).contains { !view.isExplored($0) }
        })
        #expect(try #require(view.siteFacts(at: edge)).unexplored > 0)
    }
}
