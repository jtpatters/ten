// Read-only helpers for the App's combat card (M1 §8.3, §8.4, §16): what each side of a previewed
// fight has and is likely to keep, with a city's walls taking damage first; the odds as the card
// prints them; the verdict line; what may strike a unit's shot back later where it then stands
// (an enemy city's bombard, enemies next to it); and whether a preview made before a move still
// holds after it. Built from the preview and what the attacking player knows (the target is in
// sight); and, for an enemy city out of sight, how near a ranged unit must come to shoot it.

/// One side of a previewed fight as the combat card shows it.
public struct CombatCardSide: Hashable, Sendable {
    public var hp: Int
    public var maxHP: Int
    /// A city's wall HP (0 for a unit), and the most walls can have.
    public var wallHP: Int
    public var maxWallHP: Int
    /// A city with Walls (shown even at 0 wall HP: they recover).
    public var hasWalls: Bool
    /// Damage it takes for the lowest and the highest roll, capped at what it has (walls and
    /// HP); nil when it takes none (the attacker of a ranged attack or a bombard).
    public var damage: ClosedRange<Int>?
    /// The expected damage, capped likewise, and its split: the walls take it first, then the
    /// HP (M1 §8.3).
    public var expected: Int
    public var expectedWalls: Int
    public var expectedHP: Int
    /// HP expected after the fight.
    public var hpAfter: Int
    /// `hpAfter` is what a melee attacker keeps if it wins (at least 1 HP, M1 §8.3): the
    /// expected blow alone would bring it to 0.
    public var keepsOneIfItWins: Bool

    /// Whether every roll leaves the walls at `wallHP − expectedWalls`: one possible blow, or
    /// the smallest one breaks them. The card drops its "≈" on such a figure.
    public var wallsAfterIsExact: Bool {
        guard let damage else { return true }
        return damage.lowerBound == damage.upperBound || damage.lowerBound >= wallHP
    }

    /// Whether every roll leaves the HP at `hpAfter`: one possible blow, walls that take even
    /// the largest one (the HP untouched), or a smallest blow that leaves nothing.
    public var hpAfterIsExact: Bool {
        guard let damage else { return true }
        return damage.lowerBound == damage.upperBound || damage.upperBound <= wallHP || damage.lowerBound >= wallHP + hp
    }
}

/// The combat card's verdict tone.
public enum CombatVerdictTone: Hashable, Sendable {
    case good, bad, neutral
}

/// What may strike an own unit where it stands, in the other players' phases, as its owner
/// knows: known enemy cities whose bombard reaches the tile (M1 §5) and visible enemy military
/// units next to it.
public struct CombatExposure: Hashable, Sendable {
    /// Known cities of players at war within bombard range of the tile, nearest first (ties:
    /// the lower id).
    public var cities: [CitySighting]
    /// Visible military units of players at war next to the tile, by id.
    public var units: [Unit]
    public var isEmpty: Bool { cities.isEmpty && units.isEmpty }
}

/// Everything the combat card says about a previewed attack, besides the strengths.
public struct CombatCard: Hashable, Sendable {
    public var attacker: CombatCardSide
    public var defender: CombatCardSide
    /// The defender's odds line: "62%", "<1%", ">99%" with its label ("chance to destroy",
    /// "chance to bring it to 0 HP", "chance to take it"); nil when it would say nothing (a city
    /// already at 0 HP and 0 wall HP).
    public var killOdds: String?
    public var killLabel: String
    /// Whether the kill chance is at least 50% (the line shows in the good tone).
    public var killLikely: Bool
    /// The attacker's odds of falling; nil for a ranged attack or a bombard (no retaliation).
    public var deathOdds: String?
    public var deathLikely: Bool
    public var verdict: String
    public var tone: CombatVerdictTone
    /// Further one-line hints: "Walls take damage first.", "Ranged attacks never take cities."
    public var notes: [String]
    /// What may strike a unit's ranged attack back later, where it stands after the shot (the
    /// marked tile it moves to first, or its own); nil for melee attacks and bombards.
    public var exposure: CombatExposure?
    /// Warnings of that exposure the verdict does not give: "It ends in range of Rome's
    /// bombard.", "Enemies next to it there: a Spearman, a Warrior."
    public var warnings: [String] = []
    /// A melee attack whose winner moves in (or a capture) within reach of known enemy
    /// bombards (`MoveInWarning`); nil otherwise.
    public var moveIn: MoveInWarning? = nil
}

extension CombatPreview {
    /// A chance as the card prints it: whole percents, but "<1%" for a chance that is not 0
    /// yet rounds to 0, and ">99%" for one that is not certain yet rounds to 100.
    public static func percentText(_ pairs: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        if pairs <= 0 { return "0%" }
        if pairs >= total { return "100%" }
        let percent = (pairs * 200 + total) / (2 * total)
        if percent == 0 { return "<1%" }
        if percent == 100 { return ">99%" }
        return "\(percent)%"
    }

    /// Whether `other`, the same attack previewed again, rests on the same inputs: both sides'
    /// strengths with every modifier. A preview made before a move to the tile to strike from
    /// still holds after the move exactly when this is true (newly seen supporters change the
    /// defence, M1 §8.1). False when there is no other preview.
    public func sameInputs(as other: CombatPreview?) -> Bool {
        guard let other else { return false }
        return attacker == other.attacker && defender == other.defender && target == other.target && ranged == other.ranged
            && capturesCity == other.capturesCity
            && attackerStrength == other.attackerStrength && defenderStrength == other.defenderStrength
    }
}

extension PlayerView {
    /// The combat card for a preview this player made: each side's health now and as the fight
    /// is likely to leave it (a city's walls first), the odds lines, the verdict and its hints.
    public func combatCard(for p: CombatPreview) -> CombatCard {
        let defenderIsCity = if case .city = p.defender { true } else { false }
        let attackerIsCity = if case .city = p.attacker { true } else { false }

        // The defender: capped at what it has, walls first.
        var defender = side(p.defender)
        let cap = defender.hp + defender.wallHP
        let dealt = min(p.damageDealt.lowerBound, cap)...min(p.damageDealt.upperBound, cap)
        defender.damage = dealt
        defender.expected = min(p.meanDealt, cap)
        defender.expectedWalls = min(defender.wallHP, defender.expected)
        defender.expectedHP = min(defender.hp, defender.expected - defender.expectedWalls)
        defender.hpAfter = defender.hp - defender.expectedHP

        // The attacker: retaliation only for melee.
        var attacker = side(p.attacker)
        if !p.ranged {
            let taken = min(p.damageTaken.lowerBound, attacker.hp)...min(p.damageTaken.upperBound, attacker.hp)
            attacker.damage = taken
            attacker.expected = min(p.meanTaken, attacker.hp)
            attacker.expectedHP = attacker.expected
            attacker.hpAfter = attacker.hp - attacker.expected
            // A melee winner over a unit keeps at least 1 HP (a city brought to 0 saves no one).
            if attacker.hpAfter <= 0, !defenderIsCity, p.killPairs > 0 {
                attacker.hpAfter = 1
                attacker.keepsOneIfItWins = true
            }
        }

        let atZero = defenderIsCity && !p.capturesCity && cap == 0
        let killLabel = if p.capturesCity { "chance to take it" } else if defenderIsCity { "chance to bring it to 0 HP" } else { "chance to destroy" }
        var notes: [String] = []
        if defenderIsCity, defender.wallHP > 0, !p.capturesCity { notes.append("Walls take damage first.") }
        if defenderIsCity, p.ranged, !atZero { notes.append("Ranged attacks never take cities.") }

        // A unit's shot: what may strike it back later where it stands then (a target likely
        // to fall left out).
        var exposure: CombatExposure?
        if p.ranged, !attackerIsCity {
            let target: UnitID? = if case let .unit(id) = p.defender, p.killChance(atLeast: 50) { id } else { nil }
            exposure = self.exposure(at: p.from, except: target)
        }
        let (verdict, tone) = verdict(p, defenderIsCity: defenderIsCity, atZero: atZero, attackerIsCity: attackerIsCity,
                                      exposure: exposure, hpAfter: (attacker: attacker.hpAfter, defender: defender.hpAfter))
        return CombatCard(attacker: attacker, defender: defender,
                          killOdds: atZero ? nil : CombatPreview.percentText(p.killPairs, of: p.rollPairs), killLabel: killLabel,
                          killLikely: p.killChance(atLeast: 50),
                          deathOdds: p.ranged ? nil : CombatPreview.percentText(p.deathPairs, of: p.rollPairs),
                          deathLikely: p.deathChance(atLeast: 50),
                          verdict: verdict, tone: tone, notes: notes, exposure: exposure,
                          warnings: exposure.map { exposureWarnings($0, verdict: verdict) } ?? [],
                          moveIn: moveInWarning(p, hpAfterWin: attacker.hpAfter))
    }

    /// What may strike an own unit standing on `hex` in the other players' phases, as this
    /// player knows: known cities of players at war whose bombard reaches the tile
    /// (`city.bombardRange`, M1 §5), and visible military units of players at war next to it
    /// (`except`: one left out, such as a target likely to fall).
    public func exposure(at hex: HexCoord, except: UnitID? = nil) -> CombatExposure {
        let range = rules.constants.city.bombardRange
        let cities = knownCities
            .filter { $0.owner != player && isAtWar(with: $0.owner) && distance($0.position, hex) <= range }
            .sorted { (distance($0.position, hex), $0.id.rawValue) < (distance($1.position, hex), $1.id.rawValue) }
        let units = visibleForeignUnits.filter {
            !$0.type.isCivilian && $0.id != except && isAtWar(with: $0.owner) && distance($0.position, hex) == 1
        }
        return CombatExposure(cities: cities, units: units)
    }

    /// "it ends in range of Rome's bombard", "… of Rome's and Antium's bombards", "it ends next
    /// to an enemy Spearman", "… next to 2 enemy units" (nil when nothing threatens the tile).
    private func exposurePhrase(_ exposure: CombatExposure) -> String? {
        let names = exposure.cities.map { "\($0.name)'s" }
        switch names.count {
        case 0: break
        case 1: return "it ends in range of \(names[0]) bombard"
        case 2: return "it ends in range of \(names[0]) and \(names[1]) bombards"
        default: return "it ends in range of \(names.count) cities' bombards"
        }
        switch exposure.units.count {
        case 0: return nil
        case 1: return "it ends next to an enemy \(exposure.units[0].type.displayName)"
        default: return "it ends next to \(exposure.units.count) enemy units"
        }
    }

    /// The warnings of what may strike the attacker later that the verdict does not give: the
    /// bombard in range, and the enemy units next to the tile by name.
    private func exposureWarnings(_ exposure: CombatExposure, verdict: String) -> [String] {
        guard let phrase = exposurePhrase(exposure) else { return [] }
        var notes: [String] = []
        if !exposure.cities.isEmpty, !verdict.contains(phrase) { notes.append(phrase.prefix(1).uppercased() + phrase.dropFirst() + ".") }
        let single = exposure.cities.isEmpty && exposure.units.count == 1
        if !exposure.units.isEmpty, !(single && verdict.contains(phrase)) {
            let names = exposure.units.map { unit -> String in
                let name = unit.type.displayName
                return ("AEIOU".contains(name.prefix(1).uppercased()) ? "an " : "a ") + name
            }
            notes.append("Enemies next to it there: \(names.joined(separator: ", ")).")
        }
        return notes
    }

    /// One line on what the fight is likely to do. A melee trade: good when the target is
    /// likely left at `weakHP` or less (and below the attacker), or it takes twice what the
    /// attacker does; favourable from 1.3 ×; costly when the attacker takes more.
    private func verdict(_ p: CombatPreview, defenderIsCity: Bool, atZero: Bool,
                         attackerIsCity: Bool, exposure: CombatExposure? = nil,
                         hpAfter: (attacker: Int, defender: Int)? = nil) -> (String, CombatVerdictTone) {
        if p.capturesCity { return ("The city falls to this attack.", .good) }
        if atZero {
            let verb = attackerIsCity ? "Bombarding" : "Firing"
            return ("No damage: the city is at 0 HP. \(verb) keeps it from healing next turn; only \(cityTakers) can take it.", .neutral)
        }
        if p.deathChance(atLeast: 50) { return ("Dangerous: the attacker will likely fall.", .bad) }
        if p.killChance(atLeast: 90) {
            // Every roll pair does it: sure, not "almost".
            let sure = p.killPairs == p.rollPairs ? "Sure" : "Almost sure"
            return (defenderIsCity ? "\(sure) to bring it to 0 HP: then \(cityTakers) can take it." : "\(sure) to destroy it.", .good)
        }
        if p.killChance(atLeast: 50) { return (defenderIsCity ? "Likely to bring it to 0 HP." : "Likely to destroy it.", .good) }
        if p.deathChance(atLeast: 15) { return ("Risky: the attacker may fall.", .bad) }
        if p.ranged {
            // No blow back now; but a bombard or enemies next to it may strike it later.
            if let exposure, let phrase = exposurePhrase(exposure) { return ("No retaliation now, but \(phrase).", .bad) }
            return ("No retaliation: a safe blow.", .neutral)
        }
        if let hpAfter, hpAfter.defender <= Self.weakHP, hpAfter.attacker > hpAfter.defender { return ("A good trade.", .good) }
        if p.meanDealt >= p.meanTaken * 2 { return ("A good trade.", .good) }
        if p.meanTaken > p.meanDealt { return ("A costly trade.", .bad) }
        if p.meanDealt * 10 >= p.meanTaken * 13 { return ("A favourable trade.", .good) }
        return ("An even fight.", .neutral)
    }

    /// The HP at or below which a target the attack is likely to leave there makes the trade
    /// good: one more blow finishes it.
    static let weakHP = 20

    /// Why an own ranged unit cannot shoot a known enemy city that is out of sight (a target
    /// must be in sight, M1 §8.3, §11), and what to do: "Out of sight: move within 2 tiles to
    /// see it, then shoot." (its range, or its sight when that is shorter). Nil for any other
    /// unit, for a city in sight, and for one of a player not at war.
    public func outOfSightShotHint(unit id: UnitID, city: CitySighting) -> String? {
        guard let unit = unit(id), unit.owner == player, city.owner != player, isAtWar(with: city.owner),
              !isVisible(city.position) else { return nil }
        let def = rules.unit(unit.type)
        guard def.isRanged else { return nil }
        let near = max(1, min(state.range(of: unit), state.sight(of: unit)))
        return "Out of sight: move within \(near) tile\(near == 1 ? "" : "s") to see it, then shoot."
    }

    /// The units that take a city at 0 HP (M1 §8.3: melee and antiCavalry), by name from the
    /// rules: "a Warrior or Spearman".
    /// Who can capture a city (M1 §8.3): named while few unit types can, by class once M2's
    /// roster makes the list long.
    private var cityTakers: String {
        let names = rules.units.filter { $0.unitClass == .melee || $0.unitClass == .antiCavalry }.map(\.type.displayName)
        guard let first = names.first else { return "no unit" }
        guard names.count <= 3 else { return "a melee or anti-cavalry unit" }
        let article = "AEIOU".contains(first.prefix(1).uppercased()) ? "an" : "a"
        let list = names.count == 1 ? first : names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        return "\(article) \(list)"
    }

    /// A side's health and walls as this player knows them: an own unit or city live, a foreign
    /// one in sight (the target of a preview always is) live for units, from its sighting for a
    /// city (current while it is in sight).
    private func side(_ combatant: Combatant) -> CombatCardSide {
        let maxWall = rules.buildings.map(\.wallHP).max() ?? 0
        func make(hp: Int, maxHP: Int, wallHP: Int, hasWalls: Bool) -> CombatCardSide {
            CombatCardSide(hp: max(0, hp), maxHP: maxHP, wallHP: max(0, wallHP), maxWallHP: maxWall, hasWalls: hasWalls, damage: nil,
                           expected: 0, expectedWalls: 0, expectedHP: 0, hpAfter: max(0, hp), keepsOneIfItWins: false)
        }
        switch combatant {
        case let .unit(id):
            let maxHP = rules.constants.healing.maxHP
            return make(hp: unit(id)?.hp ?? maxHP, maxHP: maxHP, wallHP: 0, hasWalls: false)
        case let .city(id):
            let maxHP = rules.constants.city.maxHP
            if let own = city(id) {
                let walls = own.buildings.contains { (rules.building($0)?.wallHP ?? 0) > 0 }
                return make(hp: own.hp, maxHP: maxHP, wallHP: own.wallHP, hasWalls: walls || own.wallHP > 0)
            }
            let known = knownCities.first { $0.id == id }
            return make(hp: known?.hp ?? maxHP, maxHP: maxHP, wallHP: known?.wallHP ?? 0,
                        hasWalls: (known?.walls ?? false) || (known?.wallHP ?? 0) > 0)
        }
    }
}
