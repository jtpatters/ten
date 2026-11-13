import Testing
@testable import GameCore

// The facts behind the App's tribal village notices (phase 3g H4; design §6.2): places, the news a
// batch of records brings (sightings, gifts and whether the player's own tap took them, rival
// takes, ones found gone) and the turn-1 sighting. Most tests build the records by hand
// (`EventRecord(_:audience:)`) and remove the site the way a take does, to set each case up
// exactly; some apply real moves, whose takes and records the engine makes.

@Suite struct UITribalVillagesTests {
    let p0 = PlayerID(0), p1 = PlayerID(1)
    /// Both players (a record's audience).
    let both: UInt16 = 0b11

    func taken(_ hex: HexCoord, by player: PlayerID, unit: UnitID? = nil, city: CityID? = nil, audience: UInt16) -> EventRecord {
        EventRecord(.tribalVillageTaken(at: hex, player: player, unit: unit, city: city), audience: audience)
    }

    func gift(_ gift: TribalVillageGift, at hex: HexCoord, to player: PlayerID) -> EventRecord {
        EventRecord(.tribalVillageGift(player: player, at: hex, gift: gift), audience: UInt16(1) << player.rawValue)
    }

    // MARK: Places

    /// A tribal village far from everything is still named after the nearest own city, at any
    /// distance (the other notices' "near Rome" stops at 4 tiles); on a tie the lower id wins.
    @Test func aPlaceIsNamedAfterTheNearestCityAtAnyDistance() throws {
        var state = makeTestState()
        let first = addCity(&state, p0, at: hex(1, 1))
        let second = addCity(&state, p0, at: hex(9, 1))
        let firstName = try #require(state.city(first)?.name), secondName = try #require(state.city(second)?.name)
        let view = state.view(for: p0)

        // 4 tiles from each city: the lower id.
        let middle = view.tribalVillagePlace(of: hex(5, 1))
        #expect(middle.anchor == .city(first, name: firstName) && middle.distance == 4 && middle.point == .east)
        #expect(middle.text == "4 tiles east of \(firstName)" && middle.direction == "east of \(firstName)")

        // 6 tiles out, beyond the 4 of NoticeMaker's "near Rome".
        let far = view.tribalVillagePlace(of: hex(7, 7))
        #expect(far.distance == view.distance(hex(9, 1), hex(7, 7)) && far.distance == 6)
        #expect(far.anchor == .city(second, name: secondName) && far.point == .north)
        #expect(far.text == "6 tiles north of \(secondName)")

        // One tile: singular.
        #expect(view.tribalVillagePlace(of: hex(2, 1)).text == "1 tile east of \(firstName)")
    }

    /// With no city yet (turn 1), the nearest own unit anchors the place; a player with nothing
    /// on the map has no anchor and no words.
    @Test func withNoCityTheNearestUnitAnchorsThePlace() throws {
        var state = makeTestState()
        let warrior = state.addUnit(.warrior, owner: p0, at: hex(2, 2))
        state.addUnit(.scout, owner: p0, at: hex(9, 2))
        let place = state.view(for: p0).tribalVillagePlace(of: hex(4, 2))
        #expect(place.anchor == .unit(warrior, .warrior) && place.distance == 2 && place.point == .east)
        #expect(place.text == "2 tiles east of your Warrior" && place.direction == "east of your Warrior")

        var empty = makeTestState(parkSettlers: false)
        empty.addUnit(.warrior, owner: p1, at: hex(2, 2))
        let none = empty.view(for: p0).tribalVillagePlace(of: hex(4, 2))
        #expect(none.anchor == nil && none.text == "" && none.direction == "")
    }

    // MARK: Sightings

    /// Turn 1: every tribal village the player knows, as one sighting with the nearest one's
    /// place (anchored on a unit: no city yet); none known, no sighting.
    @Test func theTurnOneSighting() throws {
        var state = makeTestState()
        state.addUnit(.scout, owner: p0, at: hex(2, 2))
        #expect(state.view(for: p0).tribalVillageSighting(state.view(for: p0).knownTribalVillages) == nil)
        let north = hex(2, 5), east = hex(4, 2), hidden = hex(10, 3)
        for site in [north, east, hidden] { #expect(DebugTools.placeTribalVillage(at: site, in: &state)) }
        let view = state.view(for: p0)
        #expect(view.knownTribalVillages.count == 2)
        let sighting = try #require(view.tribalVillageSighting(view.knownTribalVillages))
        guard case let .spotted(tiles, nearest) = sighting else {
            Issue.record("not a sighting: \(sighting)")
            return
        }
        // In tile order; the nearest is 2 tiles east of the Scout (the other is 3 north).
        #expect(tiles == [east, north])
        #expect(nearest.hex == east && nearest.text == "2 tiles east of your Scout")
        #expect(view.tribalVillagePlace(of: north).text == "3 tiles north of your Scout")
        // Tiles off the map are left out.
        #expect(view.tribalVillageSighting([-1, Int32(view.tileCount)]) == nil)
    }

    /// A batch that brings several tribal villages into sight gives one sighting of them all,
    /// with the nearest one's place (ties: the lower tile); one known before is not repeated.
    @Test func aBatchSightingMergesTheNewOnes() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: p0, at: hex(0, 2))
        let old = hex(1, 1), east = hex(4, 2), north = hex(3, 4)
        for site in [old, east, north] { #expect(DebugTools.placeTribalVillage(at: site, in: &state)) }
        let before = state.view(for: p0).knownTribalVillages
        #expect(before == [Int32(tile(state, old))])
        let records = try apply(.moveUnit(unit: scout, to: hex(2, 2)), &state)
        let view = state.view(for: p0)
        let news = view.tribalVillageNews(in: records, knownBefore: before, viewerActed: true)
        // Both 2 tiles from the Scout: the lower tile is the nearest.
        #expect(news == [.spotted(tiles: [east, north], nearest: view.tribalVillagePlace(of: east))])
        #expect(view.tribalVillagePlace(of: east).text == "2 tiles east of your Scout")
        // Nothing new: nothing to say.
        #expect(view.tribalVillageNews(in: records, knownBefore: view.knownTribalVillages, viewerActed: true).isEmpty)
    }

    // MARK: Gifts

    /// `byOwnTap`: the player's own command took it (a tap's move, a city founded), not an
    /// Explore leg, a standing order or border growth at its phase start. The take explains
    /// the tribal village leaving memory: no "gone".
    @Test func byOwnTapForEachWayOfTaking() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: p0, at: hex(2, 2))
        let city = addCity(&state, p0, at: hex(1, 5))
        let name = try #require(state.city(city)?.name)
        let site = hex(3, 2)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        let before = state.view(for: p0).knownTribalVillages
        #expect(before == [Int32(tile(state, site))])
        removeTribalVillage(at: site, in: &state)
        let view = state.view(for: p0)
        #expect(view.knownTribalVillages.isEmpty)

        let byUnit = [taken(site, by: p0, unit: scout, audience: 1), gift(.gold(50), at: site, to: p0)]
        let byCity = [taken(site, by: p0, city: city, audience: 1), gift(.science(20, toward: nil), at: site, to: p0)]
        func ownTap(_ records: [EventRecord], viewerActed: Bool, exploring: [UnitID] = []) -> Bool? {
            let news = view.tribalVillageNews(in: records, knownBefore: before, viewerActed: viewerActed, exploring: exploring)
            guard news.count == 1, case let .gift(_, _, _, _, _, _, byOwnTap) = news[0] else {
                Issue.record("expected one gift: \(news)")
                return nil
            }
            return byOwnTap
        }
        #expect(ownTap(byUnit, viewerActed: true) == true)                       // a tap
        #expect(ownTap(byUnit, viewerActed: true, exploring: [scout]) == false)  // an Explore leg
        #expect(ownTap(byUnit, viewerActed: false) == false)                     // a standing order at the phase start
        #expect(ownTap(byCity, viewerActed: false) == false)                     // border growth at the phase start
        #expect(ownTap(byCity, viewerActed: true) == true)                       // a city founded
        // Another explorer does not make a tap an Explore leg.
        #expect(ownTap(byUnit, viewerActed: true, exploring: [UnitID(99)]) == true)

        #expect(view.tribalVillageNews(in: byUnit, knownBefore: before, viewerActed: true)
            == [.gift(.gold(50), at: site, taker: .scout, unit: scout, city: nil, cityName: nil, byOwnTap: true)])
        #expect(view.tribalVillageNews(in: byCity, knownBefore: before, viewerActed: false)
            == [.gift(.science(20, toward: nil), at: site, taker: nil, unit: nil, city: city, cityName: name, byOwnTap: false)])
        // A Builder gift names the new unit.
        let builder = UnitID(42)
        #expect(view.tribalVillageNews(in: [byUnit[0], gift(.builder(builder), at: site, to: p0)], knownBefore: before, viewerActed: true)
            == [.gift(.builder(builder), at: site, taker: .scout, unit: scout, city: nil, cityName: nil, byOwnTap: true)])
        // Another player's gift is never the viewer's (diagnostic mode shows every record).
        #expect(view.tribalVillageNews(in: [gift(.gold(50), at: site, to: p1)], knownBefore: [], viewerActed: false).isEmpty)
    }

    // MARK: Rival takes and ones found gone

    /// A rival's take of one the player sees is "reached first", never also "gone"; a take far
    /// from anything the player knows or sees (diagnostic mode passes every record) says nothing.
    @Test func theRivalTake() throws {
        var state = makeTestState()
        state.addUnit(.scout, owner: p0, at: hex(2, 2))
        let site = hex(4, 2), unseen = hex(10, 3)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        #expect(DebugTools.placeTribalVillage(at: unseen, in: &state))
        let before = state.view(for: p0).knownTribalVillages
        #expect(before == [Int32(tile(state, site))])
        // Player 1's Scout takes the one in sight, another of its units the unseen one.
        removeTribalVillage(at: site, in: &state)
        removeTribalVillage(at: unseen, in: &state)
        let rival = state.addUnit(.scout, owner: p1, at: site)
        #expect(state.view(for: p0).unit(rival) != nil)
        let records = [taken(site, by: p1, unit: rival, audience: both), gift(.gold(50), at: site, to: p1),
                       taken(unseen, by: p1, unit: UnitID(77), audience: EventRecord.everyone)]
        let view = state.view(for: p0)
        #expect(view.tribalVillageNews(in: records, knownBefore: before, viewerActed: false)
            == [.reachedFirst(p1, at: site, place: view.tribalVillagePlace(of: site))])
        #expect(view.tribalVillagePlace(of: site).direction == "east of your Scout")
    }

    /// One remembered, taken out of sight, is found gone when its tile comes back into sight
    /// with no event saying who took it.
    @Test func foundGone() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: p0, at: hex(2, 2))
        let site = hex(4, 2)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        try apply(.moveUnit(unit: scout, to: hex(0, 2)), &state)
        #expect(!state.view(for: p0).isVisible(site))
        removeTribalVillage(at: site, in: &state)
        try nextTurn(&state)
        let before = state.view(for: p0).knownTribalVillages
        #expect(before == [Int32(tile(state, site))])
        let records = try apply(.moveUnit(unit: scout, to: hex(2, 2)), &state)
        let view = state.view(for: p0)
        #expect(view.knownTribalVillages.isEmpty)
        #expect(view.tribalVillageNews(in: records, knownBefore: before, viewerActed: true)
            == [.gone(site, place: view.tribalVillagePlace(of: site))])
        #expect(view.tribalVillagePlace(of: site).direction == "east of your Scout")
    }
}
