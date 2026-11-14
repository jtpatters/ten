@testable import GameCore
import Testing

/// Promotions (M2 §8.3).
@Suite struct PromotionTests {
    @Test func aWarriorWithEnoughXPTakesATierOnePromotion() throws {
        var state = makeTestState()
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        #expect(state.promotionsOffered(to: state.unit(warrior)!).isEmpty)
        state.updateUnit(warrior) { u in
            u.xp = 15
            u.hp = 40
        }
        #expect(state.promotionsOffered(to: state.unit(warrior)!).map(\.id) == ["battlecry", "tortoise"])
        #expect(throws: CommandError.self) { try apply(.promote(unit: warrior, promotion: "volley"), &state) }
        let records = try apply(.promote(unit: warrior, promotion: "battlecry"), &state)
        let unit = try #require(state.unit(warrior))
        #expect(unit.promotions == ["battlecry"] && unit.hp == 90 && unit.movesLeft == 0)
        #expect(events(records).contains(.unitPromoted(unit: warrior, promotion: "battlecry", owner: PlayerID(0), at: hex(3, 3))))
        #expect(state.promotionsOffered(to: unit).isEmpty)
        state.updateUnit(warrior) { $0.xp = 45 }
        #expect(state.promotionsOffered(to: state.unit(warrior)!).map(\.id) == ["commando", "amphibious"])
    }

    @Test func pursuitAddsAMove() {
        var state = makeTestState()
        let horse = state.addUnit(.horseman, owner: PlayerID(0), at: hex(3, 3))
        state.updateUnit(horse) { $0.promotions = ["caparison", "pursuit"] }
        state.startPhase(ofUnit: horse)
        #expect(state.unit(horse)!.movesLeft == state.rules.points(5))
    }

    @Test func rangeSightAndCrewPromotions() {
        var state = makeTestState()
        let catapult = state.addUnit(.catapult, owner: PlayerID(0), at: hex(3, 3))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(4, 4))
        #expect(state.range(of: state.unit(catapult)!) == 2 && !state.firesAfterMoving(state.unit(catapult)!))
        state.updateUnit(catapult) { $0.promotions = ["crew", "siegeEngineers"] }
        #expect(state.range(of: state.unit(catapult)!) == 3 && state.firesAfterMoving(state.unit(catapult)!))
        let sight = state.sight(of: state.unit(scout)!)
        state.updateUnit(scout) { $0.promotions = ["ranger", "sentry"] }
        #expect(state.sight(of: state.unit(scout)!) == sight + 1 && state.range(of: state.unit(scout)!) == 0)
    }

    @Test func sentryRefreshesVisibilityAndEnemiesInSight() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 3))
        state.updateUnit(scout) { u in
            u.promotions = ["ranger"]
            u.xp = 45
        }
        let sight = state.sight(of: state.unit(scout)!)
        setWar(&state, PlayerID(0), PlayerID(1))
        let enemy = state.addUnit(.warrior, owner: PlayerID(1), at: hex(3 + sight + 1, 3))
        refreshKnowledge(&state)
        #expect(state.checkInvariants().isEmpty)
        try apply(.promote(unit: scout, promotion: "sentry"), &state)
        #expect(state.checkInvariants().isEmpty)
        #expect(PlayerView(state: state, player: PlayerID(0)).enemiesInSight(of: scout) == [enemy])
    }

    @Test func alpineCrossesHillsFreely() {
        var map = openMap(width: 8, height: 6)
        let a = map.index(of: hex(1, 1))!, b = map.index(of: hex(2, 1))!
        map[index: b].elevation = .hills
        var state = makeTestState(map: map)
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        let plain = state.moveCost(from: a, to: b, .east, free: state.freeMove(state.unit(scout)!))
        state.updateUnit(scout) { $0.promotions = ["alpine"] }
        let alpine = state.moveCost(from: a, to: b, .east, free: state.freeMove(state.unit(scout)!))
        #expect(plain == state.rules.points(2) && alpine == state.rules.points(1))
    }

    @Test func pursuitIgnoresZonesOfControlExceptSquare() {
        var state = makeWarState(width: 16, height: 10)
        let horse = state.addUnit(.horseman, owner: PlayerID(0), at: hex(3, 3))
        let enemy = state.addUnit(.spearman, owner: PlayerID(1), at: hex(6, 3))
        let near = tile(state, hex(5, 3))
        #expect(state.zoneOfControl(for: state.unit(horse)!)?[near] == true)
        state.updateUnit(horse) { $0.promotions = ["caparison", "pursuit"] }
        #expect(state.zoneOfControl(for: state.unit(horse)!)?[near] != true)
        state.updateUnit(enemy) { $0.promotions = ["echelon", "square"] }
        #expect(state.zoneOfControl(for: state.unit(horse)!)?[near] == true)
    }

    @Test func guerrillaMovesAfterAttackingOnce() throws {
        var state = makeWarState(width: 16, height: 10)
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(4, 3))
        _ = state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 3))
        state.updateUnit(scout) { $0.promotions = ["ranger", "guerrilla"] }
        let moves = state.unit(scout)!.movesLeft
        try apply(.attack(unit: scout, target: hex(5, 3)), &state)
        let after = try #require(state.unit(scout))
        #expect(after.movesLeft == moves - state.rules.movePoints && after.attacked == true)
        #expect(throws: CommandError.self) { try apply(.attack(unit: scout, target: hex(5, 3)), &state) }
        state.startPhase(ofUnit: scout)
        #expect(state.unit(scout)!.attacked == nil)
    }

    @Test func chargeHitsOnlyWoundedUnits() throws {
        var state = makeWarState(width: 16, height: 10)
        let horse = state.addUnit(.horseman, owner: PlayerID(0), at: hex(4, 3))
        let enemy = state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 3))
        func strength(_ state: GameState) throws -> Int {
            try #require(state.view(for: PlayerID(0)).combatPreview(attacker: .unit(horse), target: hex(5, 3), from: hex(4, 3)))
                .attackerStrength.total
        }
        let base = try strength(state)
        state.updateUnit(horse) { $0.promotions = ["charge"] }
        #expect(try strength(state) == base)
        state.updateUnit(enemy) { $0.hp = 60 }
        #expect(try strength(state) == base + 7)
    }
}
