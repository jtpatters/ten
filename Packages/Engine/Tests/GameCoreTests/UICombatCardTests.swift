import Foundation
import Testing
@testable import GameCore

// The combat card (GameCore/Queries/UICombatCard.swift, M1 §8.3, §8.4, §16): an attack brings a
// city to 0 HP (a later melee attack takes it), walls take damage first, a ranged shot at a city
// at 0 HP does no damage yet keeps it from healing, a melee winner keeps at least 1 HP, a
// certain kill reads "Sure", and small chances are not rounded away; the trade bands, the
// figures every roll leaves the same, and an out-of-sight city's hint to a ranged unit.

@Suite struct UICombatCardTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// A Warrior beside a 10-HP city is sure to bring it to 0 HP, not to take it; a second melee
    /// unit then takes it, and its card says so.
    @Test func meleeBringsACityToZeroThenASecondUnitTakesIt() throws {
        var state = makeWarState()
        let city = addCity(&state, them, at: hex(5, 3))
        updateCity(&state, city) { $0.hp = 10 }
        let a = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        let b = state.addUnit(.warrior, owner: me, at: hex(6, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(a), target: hex(5, 3), from: hex(4, 3)))
        #expect(!p.capturesCity)
        let card = view.combatCard(for: p)
        #expect(card.killLabel == "chance to bring it to 0 HP")
        #expect(card.killOdds == "100%")
        #expect(card.verdict == "Sure to bring it to 0 HP: then a Warrior or Spearman can take it.")
        #expect(card.defender.hp == 10 && card.defender.hpAfter == 0 && card.defender.damage == 10...10)
        #expect(!card.attacker.keepsOneIfItWins, "bringing a city to 0 HP saves no one")

        try apply(.attack(unit: a, target: hex(5, 3)), &state)
        #expect(state.city(city)?.hp == 0 && state.city(city)?.owner == them)
        let view2 = state.view(for: me)
        let p2 = try #require(view2.combatPreview(attacker: .unit(b), target: hex(5, 3), from: hex(6, 3)))
        #expect(p2.capturesCity)
        let card2 = view2.combatCard(for: p2)
        #expect(card2.killLabel == "chance to take it")
        #expect(card2.verdict == "The city falls to this attack.")
        try apply(.attack(unit: b, target: hex(5, 3)), &state)
        #expect(state.city(city)?.owner == me)
    }

    /// An Archer at a city at 0 HP (and no walls) deals no damage, and its card says so; the shot
    /// still keeps the city from healing at its owner's next phase start.
    @Test func aRangedShotAtACityAtZeroBlocksItsHealing() throws {
        func run(fire: Bool) throws -> (hp: Int, card: CombatCard?) {
            var state = makeWarState()
            let city = addCity(&state, them, at: hex(5, 3))
            let archer = state.addUnit(.archer, owner: me, at: hex(3, 3))
            refreshKnowledge(&state)
            // Knocked to 0 last turn; its owner has had a phase since.
            updateCity(&state, city) { $0.hp = 0 }
            try endPhases(until: them, &state)
            try endPhases(until: me, &state)
            var card: CombatCard?
            if fire {
                let view = state.view(for: me)
                let p = try #require(view.combatPreview(attacker: .unit(archer), target: hex(5, 3), from: hex(3, 3)))
                card = view.combatCard(for: p)
                let records = try apply(.attack(unit: archer, target: hex(5, 3)), &state)
                #expect(combatEvent(records)?.dealt == 0)
            }
            try endPhases(until: them, &state)
            return (state.city(city)!.hp, card)
        }
        let fired = try run(fire: true)
        let left = try run(fire: false)
        #expect(fired.hp < left.hp, "the shot kept the city from healing")
        let card = try #require(fired.card)
        #expect(card.killOdds == nil)
        #expect(card.deathOdds == nil, "no retaliation")
        #expect(card.verdict == "No damage: the city is at 0 HP. Firing keeps it from healing next turn; only a Warrior or Spearman can take it.")
        #expect(!card.notes.contains("Ranged attacks never take cities."))
    }

    /// Walls take a city's damage first: the card shows the wall HP falling and the HP kept, as
    /// the attack then does.
    @Test func wallsTakeTheDamageFirst() throws {
        var state = makeWarState()
        let city = addCity(&state, them, at: hex(5, 3))
        updateCity(&state, city) { c in
            c.buildings = ["palace", "walls"]
            c.wallHP = 100
        }
        let a = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(a), target: hex(5, 3), from: hex(4, 3)))
        let card = view.combatCard(for: p)
        #expect(card.defender.hasWalls && card.defender.wallHP == 100 && card.defender.maxWallHP == 100)
        #expect(card.defender.expected == p.meanDealt && p.meanDealt <= 100)
        #expect(card.defender.expectedWalls == p.meanDealt && card.defender.expectedHP == 0)
        #expect(card.defender.hpAfter == card.defender.hp)
        #expect(card.notes.contains("Walls take damage first."))
        let records = try apply(.attack(unit: a, target: hex(5, 3)), &state)
        let dealt = try #require(combatEvent(records)?.dealt)
        #expect(state.city(city)?.hp == card.defender.hp)
        #expect(state.city(city)?.wallHP == 100 - dealt)
    }

    /// A ranged attack on a city is told that it never takes it.
    @Test func rangedAttacksNeverTakeCities() throws {
        var state = makeWarState()
        addCity(&state, them, at: hex(5, 3))
        let archer = state.addUnit(.archer, owner: me, at: hex(3, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(archer), target: hex(5, 3), from: hex(3, 3)))
        let card = view.combatCard(for: p)
        #expect(card.notes.contains("Ranged attacks never take cities."))
        #expect(card.killLabel == "chance to bring it to 0 HP")
        #expect(card.attacker.damage == nil && card.attacker.hpAfter == card.attacker.hp)
    }

    /// A certain kill reads "Sure", one short of certain "Almost sure": an Archer's shot at a
    /// 1-HP Spearman always destroys it (one possible blow, capped at its 1 HP); at a Spearman
    /// with more HP, most shots but not all do.
    @Test func aCertainKillIsSure() throws {
        var state = makeWarState()
        let archer = state.addUnit(.archer, owner: me, at: hex(4, 3))
        let spearman = state.addUnit(.spearman, owner: them, at: hex(6, 3))
        state.updateUnit(spearman) { $0.hp = 1 }
        refreshKnowledge(&state)
        var view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(archer), target: hex(6, 3), from: hex(4, 3)))
        try #require(p.ranged && p.killPairs == p.rollPairs)
        let card = view.combatCard(for: p)
        #expect(card.verdict == "Sure to destroy it.")
        #expect(card.killOdds == "100%")
        #expect(card.defender.damage == 1...1 && card.defender.expected == 1 && card.defender.hpAfter == 0)

        // Most rolls but not all: "Almost sure".
        let pairs = p.rollPairs
        for hp in 2...100 {
            state.updateUnit(spearman) { $0.hp = hp }
            view = state.view(for: me)
            let q = try #require(view.combatPreview(attacker: .unit(archer), target: hex(6, 3), from: hex(4, 3)))
            guard q.killPairs < q.rollPairs else { continue }
            if q.killChance(atLeast: 90) {
                #expect(view.combatCard(for: q).verdict == "Almost sure to destroy it.", "at \(hp) HP")
                #expect(q.rollPairs == pairs)
                return
            }
        }
        Issue.record("no Spearman HP gives a kill chance of 90% or more short of certain")
    }

    /// A melee attacker whose expected wounds would leave it at 0 keeps 1 HP if it wins (M1
    /// §8.3): the card says "≈1 if it wins", not a likely death.
    @Test func aMeleeWinnerKeepsOneHP() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        let d = state.addUnit(.warrior, owner: them, at: hex(5, 3))
        for (id, hp) in [(a, 24), (d, 20)] {
            let index = try #require(state.units.firstIndex { $0.id == id })
            state.units[index].hp = hp
        }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(a), target: hex(5, 3), from: hex(4, 3)))
        try #require(p.meanTaken >= 24 && p.killPairs > 0, "the set-up: an expected blow that would leave it at 0")
        let card = view.combatCard(for: p)
        #expect(card.attacker.hp == 24 && card.attacker.hpAfter == 1 && card.attacker.keepsOneIfItWins)
        #expect(card.attacker.damage?.upperBound ?? 0 <= 24, "damage is capped at what it has")
        #expect(card.deathOdds != nil)
    }

    /// A shot that leaves the Archer within bombard range (2) of a known enemy city is no safe
    /// blow: the card warns in the bad tone. Three tiles away (the city known all the same), it
    /// is one.
    @Test func aShotFromBombardRangeWarns() throws {
        func card(cityAt site: HexCoord) throws -> (card: CombatCard, name: String) {
            var state = makeWarState()
            let city = addCity(&state, them, at: site)
            let archer = state.addUnit(.archer, owner: me, at: hex(4, 3))
            state.addUnit(.warrior, owner: them, at: hex(6, 3))
            state.addUnit(.warrior, owner: me, at: hex(2, 0)) // sees the farther site
            refreshKnowledge(&state)
            let view = state.view(for: me)
            try #require(view.knownCities.contains { $0.id == city })
            let option = try #require(view.attackOptions(for: archer).first { $0.target == hex(6, 3) })
            #expect(option.from == hex(4, 3), "it fires from where it stands")
            let p = try #require(view.combatPreview(attacker: .unit(archer), target: option.target, from: option.from))
            return (view.combatCard(for: p), try #require(state.city(city)?.name))
        }
        let near = try card(cityAt: hex(4, 1))
        #expect(makeTestState().map.distance(hex(4, 3), hex(4, 1)) == 2)
        #expect(near.card.verdict == "No retaliation now, but it ends in range of \(near.name)'s bombard.")
        #expect(near.card.tone == .bad)
        #expect(near.card.exposure?.cities.map(\.name) == [near.name])

        let far = try card(cityAt: hex(4, 0))
        #expect(makeTestState().map.distance(hex(4, 3), hex(4, 0)) == 3)
        #expect(far.card.verdict == "No retaliation: a safe blow.")
        #expect(far.card.tone == .neutral)
        #expect(far.card.exposure?.isEmpty == true)
    }

    /// A melee winner over a unit moves onto its tile (M1 §8.3): two tiles from a known enemy
    /// city, the card warns that it ends within the bombard's range, with the HP it is likely to
    /// keep; three tiles away (the city known all the same), it does not.
    @Test func aMeleeKillThatMovesIntoBombardRangeWarns() throws {
        func card(cityAt site: HexCoord, attackerHP: Int = 100) throws -> (card: CombatCard, name: String, state: GameState) {
            var state = makeWarState()
            let city = addCity(&state, them, at: site)
            let warrior = state.addUnit(.warrior, owner: me, at: hex(4, 4))
            let target = state.addUnit(.warrior, owner: them, at: hex(4, 3))
            state.updateUnit(target) { $0.hp = 20 }
            state.updateUnit(warrior) { $0.hp = attackerHP }
            state.addUnit(.scout, owner: me, at: hex(2, 0)) // sees both sites
            refreshKnowledge(&state)
            let view = state.view(for: me)
            try #require(view.knownCities.contains { $0.id == city })
            let p = try #require(view.combatPreview(attacker: .unit(warrior), target: hex(4, 3), from: hex(4, 4)))
            try #require(!p.ranged && p.killPairs > 0)
            return (view.combatCard(for: p), try #require(state.city(city)?.name), state)
        }
        let map = makeTestState().map
        #expect(map.distance(hex(4, 4), hex(4, 3)) == 1 && map.distance(hex(4, 3), hex(4, 1)) == 2 && map.distance(hex(4, 3), hex(4, 0)) == 3)

        let near = try card(cityAt: hex(4, 1))
        let warning = try #require(near.card.moveIn)
        #expect(warning.cities.map(\.name) == [near.name] && !warning.capture)
        #expect(warning.hpLeft == near.card.attacker.hpAfter && warning.hpLeft > 1)
        #expect(warning.text == "If it wins it moves in, within range of \(near.name)'s bombard (≈\(warning.hpLeft) HP left).")
        #expect(!warning.severe, "a healthy winner outlasts one blow")
        #expect(near.card.verdict == "Sure to destroy it.", "the verdict is the fight's; the row is about afterwards")

        // The blow it weighs is the bombard's with no roll, as the engine would strike the
        // winner there.
        var after = near.state
        let winner = try #require(after.units.first { $0.owner == me && $0.position == hex(4, 4) }).id
        let loser = try #require(after.units.first { $0.owner == them && $0.position == hex(4, 3) }).id
        after.removeUnit(loser)
        after.updateUnit(winner) { $0.position = hex(4, 3); $0.hp = warning.hpLeft }
        refreshKnowledge(&after)
        let city = try #require(after.cities.first { $0.owner == them })
        let shot = try #require(after.view(for: them).combatPreview(attacker: .city(city.id), target: hex(4, 3), from: city.position))
        #expect(CombatMath.damage(base: CombatMath.baseDamage(shot.attackerStrength.total - shot.defenderStrength.total), roll: 0)
            == warning.typicalBlow)

        // A winner likely to keep less than that blow is warned in the bad tone.
        let weak = try card(cityAt: hex(4, 1), attackerHP: 30)
        let weakWarning = try #require(weak.card.moveIn)
        #expect(weakWarning.hpLeft < weakWarning.typicalBlow && weakWarning.severe)

        let far = try card(cityAt: hex(4, 0))
        #expect(far.card.moveIn == nil)
    }

    /// No warning where the winner would not move in: a garrison stays in its city, and a
    /// ranged attacker stays put (its own exposure has its own warning).
    @Test func aGarrisonThatWinsStaysOutOfRange() throws {
        var state = makeWarState()
        addCity(&state, them, at: hex(4, 1))
        addCity(&state, me, at: hex(4, 4))
        let garrison = state.addUnit(.warrior, owner: me, at: hex(4, 4))
        let target = state.addUnit(.warrior, owner: them, at: hex(4, 3))
        state.updateUnit(target) { $0.hp = 20 }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(garrison), target: hex(4, 3), from: hex(4, 4)))
        try #require(p.killPairs > 0)
        #expect(view.combatCard(for: p).moveIn == nil)
    }

    /// A capture moves the unit into the city: another enemy city whose bombard reaches it is
    /// named, with the HP the city keeps once taken. (M1's minimum city distance, 4, keeps
    /// cities out of each other's bombard range, 2, so only a hand-built map shows it.)
    @Test func aCaptureWithinAnotherCitysRangeWarns() throws {
        var state = makeWarState()
        let taken = addCity(&state, them, at: hex(4, 3))
        let other = addCity(&state, them, at: hex(4, 1))
        updateCity(&state, taken) { $0.hp = 0 }
        let warrior = state.addUnit(.warrior, owner: me, at: hex(4, 4))
        state.addUnit(.scout, owner: me, at: hex(2, 0)) // sees the other city
        refreshKnowledge(&state)
        let view = state.view(for: me)
        try #require(view.knownCities.contains { $0.id == other })
        let p = try #require(view.combatPreview(attacker: .unit(warrior), target: hex(4, 3), from: hex(4, 4)))
        try #require(p.capturesCity)
        let warning = try #require(view.combatCard(for: p).moveIn)
        let name = try #require(state.city(other)?.name)
        #expect(warning.capture && warning.cities.map(\.id) == [other])
        #expect(warning.hpLeft == state.rules.constants.city.capturedHP)
        #expect(warning.text == "It moves in, within range of \(name)'s bombard (the city at \(warning.hpLeft) HP).")
    }

    /// A unit that moves before it fires is judged where it ends: the marked tile, not its own.
    @Test func aMoveThenFireIsJudgedWhereItEnds() throws {
        var state = makeWarState()
        let city = addCity(&state, them, at: hex(6, 2))
        let archer = state.addUnit(.archer, owner: me, at: hex(3, 3))
        state.addUnit(.warrior, owner: them, at: hex(6, 3))
        state.addUnit(.warrior, owner: me, at: hex(8, 2)) // sees the city
        refreshKnowledge(&state)
        let view = state.view(for: me)
        try #require(view.knownCities.contains { $0.id == city })
        let option = try #require(view.attackOptions(for: archer).first { $0.target == hex(6, 3) })
        #expect(option.from == hex(4, 3), "it steps forward to fire")
        #expect(view.exposure(at: hex(3, 3)).isEmpty, "its own tile is out of the bombard's reach")
        #expect(view.exposure(at: hex(4, 3)).cities.map(\.id) == [city])
        let p = try #require(view.combatPreview(attacker: .unit(archer), target: option.target, from: option.from))
        let card = view.combatCard(for: p)
        let name = try #require(state.city(city)?.name)
        #expect(card.verdict == "No retaliation now, but it ends in range of \(name)'s bombard.")
    }

    /// Enemy military units next to where the shot leaves the attacker may strike it in their
    /// phase: the verdict names a single one; with more, a note names them all. A target likely
    /// to fall is left out.
    @Test func enemiesNextToTheTileAreNamed() throws {
        var state = makeWarState()
        let archer = state.addUnit(.archer, owner: me, at: hex(4, 3))
        state.addUnit(.warrior, owner: them, at: hex(6, 3))
        let spearman = state.addUnit(.spearman, owner: them, at: hex(5, 3)) // next to the Archer
        refreshKnowledge(&state)
        var view = state.view(for: me)
        var p = try #require(view.combatPreview(attacker: .unit(archer), target: hex(6, 3), from: hex(4, 3)))
        var card = view.combatCard(for: p)
        #expect(card.exposure?.units.map(\.id) == [spearman])
        #expect(card.verdict == "No retaliation now, but it ends next to an enemy Spearman.")
        #expect(card.tone == .bad)
        #expect(card.warnings.isEmpty, "the verdict names it already")

        state.addUnit(.warrior, owner: them, at: hex(3, 3)) // a second neighbour
        refreshKnowledge(&state)
        view = state.view(for: me)
        p = try #require(view.combatPreview(attacker: .unit(archer), target: hex(6, 3), from: hex(4, 3)))
        card = view.combatCard(for: p)
        #expect(card.verdict == "No retaliation now, but it ends next to 2 enemy units.")
        #expect(card.warnings == ["Enemies next to it there: a Spearman, a Warrior."])

        // A wounded neighbour that the shot is likely to destroy is no threat afterwards.
        var weak = makeWarState()
        let shooter = weak.addUnit(.archer, owner: me, at: hex(4, 3))
        let victim = weak.addUnit(.warrior, owner: them, at: hex(5, 3))
        weak.updateUnit(victim) { $0.hp = 5 }
        refreshKnowledge(&weak)
        let wv = weak.view(for: me)
        let shot = try #require(wv.combatPreview(attacker: .unit(shooter), target: hex(5, 3), from: hex(4, 3)))
        try #require(shot.killChance(atLeast: 50))
        #expect(wv.combatCard(for: shot).exposure?.isEmpty == true)
        // Near an enemy city the likely kill keeps its verdict, and the bombard is a warning.
        let fort = addCity(&weak, them, at: hex(4, 1))
        refreshKnowledge(&weak)
        let fv = weak.view(for: me)
        let nearShot = try #require(fv.combatPreview(attacker: .unit(shooter), target: hex(5, 3), from: hex(4, 3)))
        let nearCard = fv.combatCard(for: nearShot)
        let fortName = try #require(weak.city(fort)?.name)
        #expect(nearCard.tone == .good && !nearCard.verdict.contains("bombard"))
        #expect(nearCard.warnings == ["It ends in range of \(fortName)'s bombard."])

        // At peace, nothing threatens.
        var peace = makeTestState(map: openMap())
        let calm = peace.addUnit(.archer, owner: me, at: hex(4, 3))
        addCity(&peace, them, at: hex(4, 1))
        peace.addUnit(.warrior, owner: them, at: hex(5, 3))
        refreshKnowledge(&peace)
        #expect(peace.view(for: me).exposure(at: hex(4, 3)).isEmpty)
        _ = calm
    }

    /// A melee trade's verdict by what each side is likely to take: good from twice what the
    /// attacker takes, favourable from 1.3 × (the good tone too), even below that, costly when
    /// the attacker takes more (play-iphone g096: 38 for 24 read "An even fight.").
    @Test func aTradeBetweenEvenAndGoodIsFavourable() {
        let view = makeTestState().view(for: me)
        func card(dealt: Int, taken: Int) -> CombatCard {
            let p = CombatPreview(attacker: .unit(UnitID(1)), defender: .unit(UnitID(2)), from: hex(0, 0), target: hex(1, 0), ranged: false,
                                  attackerStrength: Strength(base: 20), defenderStrength: Strength(base: 20),
                                  damageDealt: (dealt - 5)...(dealt + 5), damageTaken: (taken - 5)...(taken + 5),
                                  meanDealt: dealt, meanTaken: taken, killPairs: 0, deathPairs: 0, rollPairs: 961,
                                  capturesCity: false, capturesCivilians: false)
            return view.combatCard(for: p)
        }
        // Both sides at full HP (unknown ids): no target is left weak.
        let cases: [(dealt: Int, taken: Int, verdict: String, tone: CombatVerdictTone)] = [
            (24, 24, "An even fight.", .neutral),
            (31, 24, "An even fight.", .neutral),
            (32, 24, "A favourable trade.", .good),
            (38, 24, "A favourable trade.", .good),
            (47, 24, "A favourable trade.", .good),
            (48, 24, "A good trade.", .good),
            (24, 25, "A costly trade.", .bad),
        ]
        for c in cases {
            let made = card(dealt: c.dealt, taken: c.taken)
            #expect(made.defender.hpAfter > 20)
            #expect(made.verdict == c.verdict && made.tone == c.tone, "\(c.dealt) dealt for \(c.taken) taken")
        }
    }

    /// A melee blow likely to leave the target at 20 HP or less (and below the attacker) is a
    /// good trade, whatever the ratio: a full Warrior on a Warrior at 46 HP (play-iphone g096).
    @Test func aTargetLikelyLeftWeakMakesAGoodTrade() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        let d = state.addUnit(.warrior, owner: them, at: hex(5, 3))
        state.updateUnit(d) { $0.hp = 46 }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let p = try #require(view.combatPreview(attacker: .unit(a), target: hex(5, 3), from: hex(4, 3)))
        try #require(!p.killChance(atLeast: 50) && !p.deathChance(atLeast: 15) && p.meanDealt < p.meanTaken * 2,
                     "the set-up: neither side likely to fall, and short of twice the damage")
        let card = view.combatCard(for: p)
        #expect(card.defender.hpAfter <= 20 && card.attacker.hpAfter > card.defender.hpAfter)
        #expect(card.verdict == "A good trade." && card.tone == .good)

        // At full HP the same two Warriors fight an even fight.
        state.updateUnit(d) { $0.hp = 100 }
        let even = state.view(for: me)
        let q = try #require(even.combatPreview(attacker: .unit(a), target: hex(5, 3), from: hex(4, 3)))
        #expect(even.combatCard(for: q).verdict == "An even fight.")
    }

    /// The card's "≈" marks a figure the roll decides: walls that take even the largest blow
    /// leave the HP exact ("HP 200 → 200", play-iphone s02); a smallest blow that breaks the
    /// walls leaves them exactly at 0; a sure kill leaves exactly 0 HP.
    @Test func aFigureEveryRollLeavesTheSameIsExact() throws {
        func card(wallHP: Int) throws -> CombatCard {
            var state = makeWarState()
            let city = addCity(&state, them, at: hex(5, 3))
            updateCity(&state, city) { c in
                c.buildings = ["palace", "walls"]
                c.wallHP = wallHP
            }
            let a = state.addUnit(.warrior, owner: me, at: hex(4, 3))
            refreshKnowledge(&state)
            let view = state.view(for: me)
            let p = try #require(view.combatPreview(attacker: .unit(a), target: hex(5, 3), from: hex(4, 3)))
            return view.combatCard(for: p)
        }
        let full = try card(wallHP: 100)
        let blow = try #require(full.defender.damage)
        try #require(blow.upperBound <= 100 && blow.lowerBound < blow.upperBound)
        #expect(full.defender.hpAfterIsExact && full.defender.hpAfter == full.defender.hp)
        #expect(!full.defender.wallsAfterIsExact, "the walls' figure is the expected one")

        let thin = try card(wallHP: blow.lowerBound)
        #expect(thin.defender.wallsAfterIsExact && thin.defender.wallHP - thin.defender.expectedWalls == 0)
        #expect(!thin.defender.hpAfterIsExact, "the HP takes what the walls do not")

        // No blow at all (a shot's attacker) and a sure kill: exact.
        var state = makeWarState()
        let archer = state.addUnit(.archer, owner: me, at: hex(4, 3))
        let spearman = state.addUnit(.spearman, owner: them, at: hex(6, 3))
        state.updateUnit(spearman) { $0.hp = 1 }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let shot = view.combatCard(for: try #require(view.combatPreview(attacker: .unit(archer), target: hex(6, 3), from: hex(4, 3))))
        #expect(shot.attacker.damage == nil && shot.attacker.hpAfterIsExact && shot.attacker.wallsAfterIsExact)
        #expect(shot.defender.hpAfterIsExact && shot.defender.hpAfter == 0)
    }

    /// A ranged unit cannot shoot what it does not see (M1 §8.3, §11): an enemy city remembered
    /// out of sight tells it how near to come (its range, within its sight); nothing for a melee
    /// unit, for a city in sight, or for one at peace.
    @Test func anOutOfSightCityTellsARangedUnitHowNearToCome() throws {
        var state = makeWarState(width: 16)
        addCity(&state, them, at: hex(12, 3))
        let archer = state.addUnit(.archer, owner: me, at: hex(10, 3))
        let warrior = state.addUnit(.warrior, owner: me, at: hex(10, 4))
        refreshKnowledge(&state)
        let near = state.view(for: me)
        let seen = try #require(near.knownCity(at: hex(12, 3)))
        try #require(near.isVisible(seen.position))
        #expect(near.outOfSightShotHint(unit: archer, city: seen) == nil, "in sight: the attack itself")

        state.updateUnit(archer) { $0.position = hex(3, 3) }
        state.updateUnit(warrior) { $0.position = hex(3, 4) }
        refreshKnowledge(&state)
        let far = state.view(for: me)
        let remembered = try #require(far.knownCity(at: hex(12, 3)))
        try #require(!far.isVisible(remembered.position))
        let def = state.rules.unit(.archer)
        try #require(min(def.range, def.sight) == 2)
        #expect(far.outOfSightShotHint(unit: archer, city: remembered) == "Out of sight: move within 2 tiles to see it, then shoot.")
        #expect(far.outOfSightShotHint(unit: warrior, city: remembered) == nil, "a melee unit")

        state.updateRelation(me, them) { $0.stance = .peace }
        #expect(state.view(for: me).outOfSightShotHint(unit: archer, city: remembered) == nil, "at peace")
    }

    /// Chances as the card prints them: whole percents, but "<1%" and ">99%" for chances that
    /// would round to 0 or 100 without being impossible or certain.
    @Test func smallChancesAreNotRoundedAway() {
        #expect(CombatPreview.percentText(957, of: 961) == ">99%")
        #expect(CombatPreview.percentText(4, of: 961) == "<1%")
        #expect(CombatPreview.percentText(0, of: 961) == "0%")
        #expect(CombatPreview.percentText(961, of: 961) == "100%")
        #expect(CombatPreview.percentText(481, of: 961) == "50%")
        #expect(CombatPreview.percentText(10, of: 961) == "1%")
        let p = CombatPreview(attacker: .unit(UnitID(1)), defender: .unit(UnitID(2)), from: hex(0, 0), target: hex(1, 0), ranged: false,
                              attackerStrength: Strength(base: 20), defenderStrength: Strength(base: 20),
                              damageDealt: 0...0, damageTaken: 0...0, meanDealt: 0, meanTaken: 0,
                              killPairs: 957, deathPairs: 4, rollPairs: 961, capturesCity: false, capturesCivilians: false)
        // The rounded percents the engine keeps would say 100 and 0.
        #expect(p.killChancePercent == 100 && p.deathChancePercent == 0)
        let card = makeTestState().view(for: me).combatCard(for: p)
        #expect(card.killOdds == ">99%" && card.deathOdds == "<1%")
        #expect(card.killLikely && !card.deathLikely)
    }
}
