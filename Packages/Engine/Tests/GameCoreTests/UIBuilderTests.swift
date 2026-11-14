import Foundation
import Testing
@testable import GameCore

// The App's Builder guidance (GameCore/Queries/UITileInfo.swift, M1 §7.2, §16): the tech panel
// counts where an improvement could go in the player's land, and a selected Builder's job tiles
// are marked on the map. Both must say what the engine allows, from what the player knows.

@Suite struct UIBuilderTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Rome at (5,3) with hills beside it: (4,3) and (6,3) in its first ring, (7,3) one further,
    /// (9,3) beyond its work radius.
    private func hillsState() -> (GameState, CityID) {
        var map = openMap()
        for h in [hex(4, 3), hex(6, 3), hex(7, 3), hex(9, 3)] { map[h] = Tile(terrain: .grassland, elevation: .hills) }
        var state = makeTestState(map: map)
        let rome = addCity(&state, me, at: hex(5, 3))
        return (state, rome)
    }

    /// Builds `improvement` on `hex` directly, updating what the players in sight remember.
    private func improve(_ state: inout GameState, _ hex: HexCoord, _ improvement: Improvement) {
        let t = state.map.index(of: hex)!
        state.map[hex].improvement = improvement
        var fx = Effects()
        fx.touchTile(t)
        state.updateKnowledge(&fx)
    }

    /// Sites on own land are where the player's Builders may work (no city centre, no
    /// improvement), by the city whose land it is; explored tiles that are nobody's within an own
    /// city's work radius count apart, as sites once borders grow; another player's land never
    /// counts. Mines go on hills only.
    @Test func improvementSitesCountOwnLandAndUnclaimed() throws {
        let (start, rome) = hillsState()
        var state = start
        var mines = state.view(for: me).improvementSites(.mine)
        // (4,3) and (6,3) are Rome's, (7,3) is nobody's within its work radius, (9,3) beyond it.
        #expect(mines.cities.map(\.city) == [rome] && mines.ownLand == 2 && mines.unclaimed == 1 && mines.onHillsOnly)
        #expect(mines.cities.first?.name == state.city(rome)?.name)
        // Pasture: the flat tiles of Rome's first ring are its land; the second ring's (Rome sees
        // 2 tiles: 12 more, 1 of them a hill) are nobody's.
        let pastures = state.view(for: me).improvementSites(.pasture)
        #expect(pastures.ownLand == 4 && pastures.unclaimed == 11 && !pastures.onHillsOnly)

        // A mine already built no longer counts, nor another player's land; a tile explored later does.
        improve(&state, hex(4, 3), .mine)
        let theirs = addCity(&state, them, at: hex(10, 0))
        claimTile(&state, hex(7, 3), for: theirs)
        state.map[hex(5, 0)] = Tile(terrain: .grassland, elevation: .hills)
        #expect(!state.players[0].explored[tile(state, hex(5, 0))])
        mines = state.view(for: me).improvementSites(.mine)
        #expect(mines.ownLand == 1 && mines.unclaimed == 0)
        state.addUnit(.scout, owner: me, at: hex(5, 1))
        mines = state.view(for: me).improvementSites(.mine)
        #expect(mines.ownLand == 1 && mines.unclaimed == 1)
        // The hill their city was given is their land, to mine; Rome's are not.
        let theirMines = state.view(for: them).improvementSites(.mine)
        #expect(theirMines.cities.map(\.city) == [theirs] && theirMines.ownLand == 1)

        // A second city: its own hills, and open ones near both counted once.
        for h in [hex(8, 6), hex(10, 6), hex(9, 5), hex(7, 5)] { state.map[h] = Tile(terrain: .plains, elevation: .hills) }
        let antium = addCity(&state, me, at: hex(9, 6))
        mines = state.view(for: me).improvementSites(.mine)
        let antiumOwn = [hex(8, 6), hex(10, 6), hex(9, 5), hex(7, 5)].filter { state.owningCity(ofTile: tile(state, $0))?.id == antium }.count
        #expect(antiumOwn > 1 && mines.cities.map(\.city) == [antium, rome] && mines.cities.map(\.count) == [antiumOwn, 1])
        #expect(mines.unclaimed == 1 + 4 - antiumOwn, "(5,0), and Antium's hills it does not own yet")

        // By the tech that unlocks them.
        #expect(state.view(for: me).improvementSites(unlockedBy: "mining").map(\.improvement) == [.mine])
        #expect(state.view(for: me).improvementSites(unlockedBy: "animalHusbandry").map(\.improvement) == [.pasture, .camp])
        #expect(state.view(for: me).improvementSites(unlockedBy: "pottery").isEmpty)
    }

    /// An unclaimed hill within the work radius is a site "as borders grow", never a job now: the
    /// tech panel must not promise Builders work the engine refuses. Own-land sites are the
    /// tiles `builderJobs` accepts, reach aside.
    @Test func anUnclaimedHillCountsAsBordersGrow() throws {
        let (start, rome) = hillsState()
        var state = start
        state.players[0].knownTechs.append("mining")
        let builder = state.addUnit(.builder, owner: me, at: hex(5, 2))
        func mineJobs() -> [HexCoord] {
            state.view(for: me).builderJobs(for: builder).filter { $0.improvements.contains(.mine) }.map(\.hex)
        }
        #expect(state.tileOwner(tile(state, hex(7, 3))) == nil)
        var mines = state.view(for: me).improvementSites(.mine)
        #expect(mines.ownLand == 2 && mines.unclaimed == 1)
        #expect(mineJobs().count == mines.ownLand && !mineJobs().contains(hex(7, 3)))
        #expect(state.tileOwner(tile(state, hex(7, 3))) == nil, "unchanged by the query")

        // Once Rome's borders take it, it is a site on Rome's land and a job.
        claimTile(&state, hex(7, 3), for: rome)
        mines = state.view(for: me).improvementSites(.mine)
        #expect(mines.ownLand == 3 && mines.unclaimed == 0)
        #expect(mineJobs().count == 3 && mineJobs().contains(hex(7, 3)))
    }

    /// The city panel's note on a Builder: the jobs on its city's own land, else the techs whose
    /// improvements would fit there; nothing at all once its land is improved.
    @Test func builderWorkOnACitysOwnLand() throws {
        // Rome on a hill with hills all round: before Mining, its land has no job.
        var map = openMap()
        var ring: [Int] = []
        map.forEachIndex(within: 1, of: hex(5, 3)) { ring.append($0) }
        for t in ring { map[index: t] = Tile(terrain: .grassland, elevation: .hills) }
        var state = makeTestState(map: map)
        let rome = addCity(&state, me, at: hex(5, 3))
        var work = try #require(state.view(for: me).builderWork(in: rome))
        #expect(work.jobs == 0 && work.techs == ["mining"])

        state.players[0].knownTechs.append("mining")
        work = try #require(state.view(for: me).builderWork(in: rome))
        #expect(work.jobs == ring.count - 1 && work.techs.isEmpty, "every hill but the centre")

        for t in ring where state.city(atTile: t) == nil { improve(&state, state.map.coord(at: t), .mine) }
        work = try #require(state.view(for: me).builderWork(in: rome))
        #expect(work.jobs == 0 && work.techs.isEmpty, "all mined: no job on Rome's land")

        // Flat land: farms need no tech. Another player's city has no answer.
        let (flat, flatRome) = hillsState()
        let flatWork = try #require(flat.view(for: me).builderWork(in: flatRome))
        #expect(flatWork.jobs == 4 && flatWork.techs.isEmpty, "4 flat tiles to farm; before Mining, no mine")
        #expect(flat.view(for: them).builderWork(in: flatRome) == nil)
    }

    /// A Builder's jobs: own land it reaches and may stop on, unimproved, with an improvement
    /// whose tech is known (a farm needs none; a mine needs Mining). The engine accepts every job
    /// it could start now.
    @Test func builderJobsNeedTheTechAndAPath() throws {
        let (start, rome) = hillsState()
        var state = start
        let builder = state.addUnit(.builder, owner: me, at: hex(5, 2))
        var jobs = state.view(for: me).builderJobs(for: builder)
        #expect(!jobs.isEmpty && jobs.allSatisfy { $0.improvements == [.farm] }, "without Mining the hills have no job")
        #expect(!jobs.contains { $0.hex == hex(5, 3) }, "not the city centre")
        #expect(jobs.allSatisfy { state.tileOwner($0.tile) == me })
        let here = try #require(jobs.first { $0.hex == hex(5, 2) })
        #expect(here.cost == 0 && here.thisPhase)
        #expect(jobs.first { $0.hex == hex(6, 2) }?.thisPhase == true)

        state.players[0].knownTechs.append("mining")
        claimTile(&state, hex(7, 3), for: rome)
        improve(&state, hex(6, 4), .farm)
        let miner = state.addUnit(.builder, owner: me, at: hex(6, 3))
        jobs = state.view(for: me).builderJobs(for: builder)
        #expect(jobs.first { $0.hex == hex(4, 3) }?.improvements == [.mine])
        #expect(!jobs.contains { $0.hex == hex(6, 4) }, "already improved")
        #expect(!jobs.contains { $0.hex == hex(6, 3) }, "another Builder stands there")
        #expect(!jobs.contains { $0.hex == hex(9, 3) }, "not our land")
        let far = try #require(jobs.first { $0.hex == hex(7, 3) })
        #expect(!far.thisPhase && far.cost >= 2)
        let minerJobs = state.view(for: me).builderJobs(for: miner)
        #expect(minerJobs.first { $0.hex == hex(6, 3) }.map { $0.improvements == [.mine] && $0.thisPhase } == true)

        // Every job a Builder could start now, the engine allows: move there, then build.
        for (unit, list) in [(builder, jobs), (miner, minerJobs)] {
            for job in list where job.thisPhase {
                for improvement in job.improvements {
                    var copy = state
                    if copy.unit(unit)?.position != job.hex { try apply(.moveUnit(unit: unit, to: job.hex), &copy) }
                    #expect(copy.unit(unit)?.position == job.hex)
                    try apply(.buildImprovement(unit: unit, improvement: improvement), &copy)
                }
            }
        }
        #expect(state.view(for: me).builderJobs(for: parkedSettler(of: me)).isEmpty, "a Settler has no jobs")
        #expect(state.view(for: them).builderJobs(for: builder).isEmpty, "not their unit")
    }
}
