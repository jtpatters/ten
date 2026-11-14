import Testing
@testable import GameCore

// M2 §5.4 building and quarter upkeep, §5.7 the Science and Culture focuses, §7.4 buying tiles.

@Suite struct UpkeepTileTests {
    let p0 = PlayerID(0)

    @Test func buildingsAndQuartersCostUpkeepAndAShortfallCutsScience() {
        var state = makeTestState(map: openMap(), gold: 0)
        let id = addCity(&state, p0, at: hex(3, 4))
        let base = state.buildingUpkeep(of: p0)
        #expect(base == 0, "the Palace costs nothing")
        updateCity(&state, id) {
            $0.buildings += ["granary", "monument"]
            $0.quarters = [CityQuarter(kind: "campus", tile: hex(4, 4))]
        }
        #expect(state.buildingUpkeep(of: p0) == 2, "Granary 1, Monument 0, a quarter 1")
        #expect(state.view(for: p0).income().buildings == 2)
        var fx = Effects()
        #expect(state.runGold(for: p0, income: 1, &fx) == 1 && state.players[0].gold == 0)
        #expect(state.runGold(for: p0, income: 5, &fx) == 0 && state.players[0].gold == 3)
    }

    @Test func theScienceAndCultureFocusesWeighTheirYield() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        let id = addCity(&state, p0, at: hex(3, 4))
        #expect(state.rules.focus(.science).science == 4 && state.rules.focus(.culture).culture == 4)
        try apply(.setFocus(city: id, focus: .science), &state)
        #expect(state.city(id)?.focus == .science)
        try apply(.setFocus(city: id, focus: .culture), &state)
        #expect(state.city(id)?.focus == .culture)
        expectSound(state)
    }

    @Test func aCityBuysATileNextToItsTerritory() throws {
        var state = makeTestState(map: openMap(), gold: 60)
        let id = addCity(&state, p0, at: hex(3, 4))
        let city = try #require(state.city(id))
        let centre = state.map.index(of: city.position)!
        let tiles = state.purchasableTiles(for: city)
        #expect(!tiles.isEmpty)
        for tile in tiles {
            let t = state.map.index(of: tile)!
            #expect(state.tileCity[t] == 0 && state.map.distance(index: t, centre) <= 3)
        }
        #expect(state.tilePrice(for: city) == 25)
        let tile = tiles[0]
        try apply(.purchaseTile(city: id, tile: tile), &state)
        #expect(state.tileCity[state.map.index(of: tile)!] == Int32(id.rawValue + 1))
        #expect(state.players[0].gold == 35 && state.city(id)?.tilesBought == 1)
        #expect(state.tilePrice(for: state.city(id)!) == 35)
        expectSound(state)

        #expect(throws: (any Error).self) { try apply(.purchaseTile(city: id, tile: tile), &state) }
        #expect(state.tilePurchaseProblem(hex(9, 4), for: state.city(id)!) != nil, "too far")
        state.players[0].gold = 34
        let next = try #require(state.purchasableTiles(for: state.city(id)!).first)
        #expect(throws: (any Error).self) { try apply(.purchaseTile(city: id, tile: next), &state) }
    }
}
