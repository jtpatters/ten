@testable import GameCore
import Testing

/// Resources and strategic stockpiles (M2 §3.1).
@Suite struct ResourceTests {
    @Test func ironYieldsAndShowsOnlyOnceRevealed() {
        var map = makeTestMap()
        map[hex(4, 3)] = Tile(terrain: .grassland, elevation: .hills, resource: .iron)
        var state = makeTestState(map: map)
        addCity(&state, PlayerID(0), at: hex(3, 3))
        let t = tile(state, hex(4, 3))
        let before = state.tileYields(t, for: PlayerID(0))
        #expect(PlayerView(state: state, player: PlayerID(0)).resource(at: hex(4, 3)) == nil)
        #expect(state.knownResource(at: t, for: PlayerID(1)) == nil)
        state.learn("bronzeWorking", player: PlayerID(0))
        let view = PlayerView(state: state, player: PlayerID(0))
        #expect(view.resource(at: hex(4, 3)) == .iron)
        #expect(state.tileYields(t, for: PlayerID(0)).production == before.production + 1)
        #expect(view.tileYields(at: hex(4, 3)) == state.tileYields(t, for: PlayerID(0)))
        #expect(state.knownResource(at: t, for: PlayerID(1)) == nil)
    }

    @Test func improvementsFollowTheirResource() {
        let rules = Ruleset.standard
        let grass = Tile(terrain: .grassland)
        #expect(!rules.allowsImprovement(.plantation, on: grass))
        #expect(rules.allowsImprovement(.plantation, on: grass, resource: .wine))
        #expect(!rules.allowsImprovement(.camp, on: grass, resource: .wine))
        #expect(rules.allowsImprovement(.quarry, on: grass, resource: .stone))
        #expect(rules.allowsImprovement(.fishingBoats, on: Tile(terrain: .coast), resource: .fish))
        #expect(!rules.allowsImprovement(.fishingBoats, on: Tile(terrain: .coast)))
        #expect(rules.allowsImprovement(.lumberMill, on: Tile(terrain: .grassland, feature: .forest)))
        #expect(!rules.allowsImprovement(.lumberMill, on: grass))
        #expect(rules.allowsImprovement(.farm, on: grass))
    }

    @Test func improvedSourcesFillTheStockpileUpToTheCap() {
        var map = makeTestMap()
        map[hex(4, 3)] = Tile(terrain: .grassland, improvement: .pasture, resource: .horses)
        var state = makeTestState(map: map)
        addCity(&state, PlayerID(0), at: hex(3, 3))
        var fx = Effects()
        state.startPhase(of: PlayerID(0), &fx)
        #expect(state.players[0].stock(.horses) == 0) // not revealed yet
        state.learn("animalHusbandry", player: PlayerID(0))
        #expect(state.improvedSources(of: PlayerID(0))[Int(Resource.horses.rawValue) - 1] == 1)
        state.startPhase(of: PlayerID(0), &fx)
        #expect(state.players[0].stock(.horses) == 2)
        for _ in 0..<20 { state.startPhase(of: PlayerID(0), &fx) }
        #expect(state.players[0].stock(.horses) == state.stockpileCap && state.stockpileCap == 20)
        #expect(state.players[0].stock(.iron) == 0)
        expectSound(state)
    }

    @Test func unitsNeedTheirResource() {
        var state = makeTestState()
        #expect(state.resourceProblem(.horseman, owner: PlayerID(0)) == "needs 10 Horses (have 0)")
        #expect(state.resourceProblem(.warrior, owner: PlayerID(0)) == nil)
        state.setStock(.horses, of: PlayerID(0), to: 10)
        #expect(state.resourceProblem(.horseman, owner: PlayerID(0)) == nil)
        state.spendResource(for: .horseman, owner: PlayerID(0))
        #expect(state.players[0].stock(.horses) == 0)
    }

    @Test func warDrainsTheStockpileThenUnitsFightShort() {
        var state = makeWarState()
        addCity(&state, PlayerID(0), at: hex(3, 3))
        let horse = state.addUnit(.horseman, owner: PlayerID(0), at: hex(4, 4))
        state.setStock(.horses, of: PlayerID(0), to: 1)
        #expect(state.shortage(of: state.unit(horse)!) == nil)
        var fx = Effects()
        state.startPhase(of: PlayerID(0), &fx)
        #expect(state.players[0].stock(.horses) == 0)
        #expect(state.shortage(of: state.unit(horse)!) == .horses)
        #expect(state.shortagePenalty(state.unit(horse)!) == -5)
        #expect(StrengthModifier(kind: .shortage(.horses), value: -5).name == "Out of Horses")
    }

    @Test func atPeaceThereIsNoShortage() {
        var state = makeTestState()
        let horse = state.addUnit(.horseman, owner: PlayerID(0), at: hex(4, 4))
        #expect(state.shortage(of: state.unit(horse)!) == nil)
    }
}
