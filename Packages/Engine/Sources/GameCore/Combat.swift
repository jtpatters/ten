// Combat (M1 §8): effective strength, damage, rolls, attacks and bombards; city capture,
// razing and the Palace (M1 §5); civilian capture (M1 §7.3).
//
// Rules decided here where M1 is silent (simplest reading, listed in the Core-2 report):
// - Attacking also clears the attacker's standing orders (it already ends its moves and clears
//   its activity).
// - `combat` events report the HP actually lost (a city's wall HP and HP together), never more
//   than the side had.
// - Capturing a city is not combat: no `combat` event and no XP. The captured city counts as
//   attacked (`lastAttackedPhase`) and as having bombarded this phase.
// - A player who has cities but no Palace (they lost their capital while they had no other
//   city) gets it in their largest city (ties: lower id) whenever cities change hands or are
//   razed, so a player with cities always has a capital.
// - A city at 0 HP may still bombard.
// - A melee winner does not move in where it may not stand: a tile in the territory of a third
//   player it is at peace with (closed borders).

// MARK: - Strength

/// One named part of an effective strength (M1 §8.1), as the combat preview lists it.
public struct StrengthModifier: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Defender terrain (units): its tile's elevation…
        case elevation(Elevation)
        /// …and feature.
        case feature(Feature)
        /// A fortified defender.
        case fortified
        /// Defender: other own military units next to it (melee attacks only).
        case support
        /// Attacker: other own military units next to the target (melee attacks).
        case flanking
        /// A melee attack across a river edge.
        case river
        /// −1 per `hpPerWoundPenalty` HP missing (units).
        case wounded
        /// The unit's class bonus against the other side's class (rules data).
        case classBonus(UnitClass)
        /// The unit's promotions that apply (M2 §8.3).
        case promotion
        /// City Strength: per citizen.
        case population
        /// City Strength while wall HP is above 0.
        case walls
        /// City Strength of a city on hills.
        case hills
        /// City Strength with a military unit in the city.
        case garrison
    }

    public var kind: Kind
    public var value: Int

    public init(kind: Kind, value: Int) {
        self.kind = kind
        self.value = value
    }

    /// A short label for the preview ("Hills", "Fortified", "River crossing", …).
    public var name: String {
        switch kind {
        case let .elevation(e): caseName(e).capitalized
        case let .feature(f): caseName(f).capitalized
        case .fortified: "Fortified"
        case .support: "Support"
        case .flanking: "Flanking"
        case .river: "River crossing"
        case .wounded: "Wounded"
        case let .classBonus(c): "vs \(caseName(c).prefix(1).uppercased() + caseName(c).dropFirst())"
        case .promotion: "Promotions"
        case .population: "Population"
        case .walls: "Walls"
        case .hills: "Hills"
        case .garrison: "Garrison"
        }
    }
}

/// An effective strength (M1 §8.1): a base (Strength; Ranged Strength when attacking at range;
/// the City Strength base for cities) plus named modifiers.
public struct Strength: Hashable, Sendable {
    public var base: Int
    /// Non-zero modifiers, in a fixed order.
    public var modifiers: [StrengthModifier]

    public init(base: Int, modifiers: [StrengthModifier] = []) {
        self.base = base
        self.modifiers = modifiers
    }

    public var total: Int { modifiers.reduce(base) { $0 + $1.value } }

    mutating func add(_ kind: StrengthModifier.Kind, _ value: Int) {
        if value != 0 { modifiers.append(StrengthModifier(kind: kind, value: value)) }
    }
}

/// A side of a fight as the rules see it.
enum CombatSide {
    case unit(Unit)
    case city(City)

    var combatant: Combatant {
        switch self {
        case let .unit(u): .unit(u.id)
        case let .city(c): .city(c.id)
        }
    }

    var owner: PlayerID {
        switch self {
        case let .unit(u): u.owner
        case let .city(c): c.owner
        }
    }

    /// The key that salts its combat rolls (M1 §8.2): a unit's id, a city's `1 << 32 | id`.
    var rollKey: UInt64 {
        switch self {
        case let .unit(u): UInt64(u.id.rawValue)
        case let .city(c): 1 << 32 | UInt64(c.id.rawValue)
        }
    }
}

// MARK: - Damage

/// The damage formula (M1 §8.2).
public enum CombatMath {
    /// `base(Δ) = round(30 · e^(Δ/25))` for Δ = −50…50, hard-coded (integers only in the rules;
    /// a test checks it against the formula). Index Δ + 50.
    public static let damageTable: [Int] = [
        4, 4, 4, 5, 5, 5, 5, 5, 6, 6,
        6, 6, 7, 7, 7, 7, 8, 8, 8, 9,
        9, 9, 10, 10, 11, 11, 11, 12, 12, 13,
        13, 14, 15, 15, 16, 16, 17, 18, 19, 19,
        20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
        30, 31, 32, 34, 35, 37, 38, 40, 41, 43,
        45, 47, 48, 50, 53, 55, 57, 59, 62, 64,
        67, 69, 72, 75, 78, 82, 85, 88, 92, 96,
        100, 104, 108, 112, 117, 122, 127, 132, 137, 143,
        149, 155, 161, 168, 174, 181, 189, 197, 205, 213,
        222,
    ]

    /// The largest |Δ| the table covers; Δ is clamped to it.
    public static let maxDifference = 50

    /// `base(Δ)` with Δ = attacker − defender clamped to ±50.
    public static func baseDamage(_ delta: Int) -> Int {
        damageTable[min(maxDifference, max(-maxDifference, delta)) + maxDifference]
    }

    /// Damage for one roll `r` in −15…15: `(base · (100 + r) + 50) / 100`.
    public static func damage(base: Int, roll: Int) -> Int {
        (base * (100 + roll) + 50) / 100
    }
}

// MARK: - A fight about to happen

/// Strengths and base damages of one attack, before the rolls.
struct Clash {
    var attacker: CombatSide
    var defender: CombatSide
    var from: Int
    var target: Int
    var ranged: Bool
    var attack: Strength
    var defence: Strength

    var delta: Int { attack.total - defence.total }
    /// Base damage to the defender (rolls scale it).
    var baseDealt: Int { CombatMath.baseDamage(delta) }
    /// Base damage to a melee attacker.
    var baseTaken: Int { CombatMath.baseDamage(-delta) }
}

extension GameState {
    // MARK: Strength

    /// City Strength (M1 §5): base + per citizen, walls while wall HP > 0, hills, and a
    /// garrison (a military unit of the owner on the tile) on a tile `sees` admits.
    func cityStrength(_ city: City, sees: (Int) -> Bool) -> Strength {
        let c = rules.constants.city
        let centre = map.index(of: city.position)!
        var s = Strength(base: c.strengthBase)
        s.add(.population, c.strengthPerPopulation * city.population)
        if city.wallHP > 0 {
            let walls = city.buildings.compactMap { rules.building($0) }.map(\.cityStrength).max() ?? 0
            s.add(.walls, walls)
        }
        let elevation = map.tiles[centre].elevation
        s.add(.hills, rules.elevation(elevation).cityStrength)
        if sees(centre), units.contains(where: { $0.position == city.position && $0.owner == city.owner && !$0.type.isCivilian }) {
            s.add(.garrison, c.garrisonStrength)
        }
        return s
    }

    /// Other military units of `owner` next to tile `t` on tiles `sees` admits (`excluding` one).
    func adjacentMilitary(of owner: PlayerID, around t: Int, excluding: UnitID?, sees: (Int) -> Bool) -> Int {
        var count = 0
        map.forEachNeighbor(of: t) { n, _ in
            guard sees(n) else { return }
            let hex = map.coord(at: n)
            for u in units where u.position == hex && u.owner == owner && !u.type.isCivilian && u.id != excluding {
                count += 1
            }
        }
        return count
    }

    /// Whether the edge between neighbouring tiles `a` and `b` carries a river.
    func crossesRiver(_ a: Int, _ b: Int) -> Bool {
        guard let d = map.direction(from: a, to: b) else { return false }
        return map.tiles[a].riverEdges & (1 << UInt8(d.rawValue)) != 0
            || map.tiles[b].riverEdges & (1 << UInt8(d.opposite.rawValue)) != 0
    }

    private func woundPenalty(_ unit: Unit) -> Int {
        let missing = max(0, rules.constants.healing.maxHP - unit.hp)
        return -(missing / rules.constants.combat.hpPerWoundPenalty)
    }

    /// Strength from `unit`'s promotions in a fight against `other` (M2 §8.3).
    private func promotionBonus(of unit: Unit, attacking: Bool, ranged: Bool, against other: CombatSide) -> Int {
        guard let taken = unit.promotions, !taken.isEmpty else { return 0 }
        let otherClass: UnitClass? = if case let .unit(o) = other { rules.unit(o.type).unitClass } else { nil }
        let inOwnCity = city(atTile: map.index(of: unit.position)!)?.owner == unit.owner
        return rules.promotions.filter { taken.contains($0.id) }.reduce(0) { sum, p in
            guard let s = p.strength,
                  p.when.map({ $0 == (attacking ? "attack" : "defend") }) ?? true,
                  p.ranged.map({ $0 == ranged }) ?? true,
                  p.against.map({ list in otherClass.map(list.contains) ?? false }) ?? true,
                  p.vsCity.map({ $0 == (otherClass == nil) }) ?? true,
                  p.inCity.map({ $0 == inOwnCity }) ?? true else { return sum }
            return sum + s
        }
    }

    private func classBonus(of unit: Unit, against other: CombatSide) -> (UnitClass, Int)? {
        guard case let .unit(o) = other else { return nil }
        let otherClass = rules.unit(o.type).unitClass
        let bonus = rules.unit(unit.type).classBonuses.filter { $0.against == otherClass }.reduce(0) { $0 + $1.strength }
        return bonus == 0 ? nil : (otherClass, bonus)
    }

    /// The strengths of an attack from tile `from` on tile `target` (M1 §8.1). `sees` limits
    /// the units that count for support, flanking and a garrison to what a player sees (the
    /// engine sees everything; a melee attacker next to its target sees all of its
    /// neighbours, so the two agree whenever the attacker stands on `from`).
    func clash(attacker: CombatSide, defender: CombatSide, from: Int, target: Int, ranged: Bool,
               sees: (Int) -> Bool) -> Clash {
        let c = rules.constants.combat
        let attack: Strength
        switch attacker {
        case let .city(city):
            attack = cityStrength(city, sees: sees)
        case let .unit(unit):
            let def = rules.unit(unit.type)
            var s = Strength(base: ranged ? def.rangedStrength : def.strength)
            if !ranged {
                let flankers = adjacentMilitary(of: unit.owner, around: target, excluding: unit.id, sees: sees)
                s.add(.flanking, min(c.flankingMax, c.flankingPerUnit * flankers))
                if crossesRiver(from, target) { s.add(.river, rules.river.meleeAttackModifier) }
            }
            s.add(.wounded, woundPenalty(unit))
            if let (cls, bonus) = classBonus(of: unit, against: defender) { s.add(.classBonus(cls), bonus) }
            s.add(.promotion, promotionBonus(of: unit, attacking: true, ranged: ranged, against: defender))
            attack = s
        }

        let defence: Strength
        switch defender {
        case let .city(city):
            defence = cityStrength(city, sees: sees)
        case let .unit(unit):
            var s = Strength(base: rules.unit(unit.type).strength)
            let tile = map.tiles[target]
            s.add(.elevation(tile.elevation), rules.elevation(tile.elevation).defense)
            let feature = rules.feature(tile.feature)
            if !(feature.removedByCity && city(atTile: target) != nil) { s.add(.feature(tile.feature), feature.defense) }
            if unit.activity == .fortified { s.add(.fortified, c.fortified) }
            if !ranged {
                let supporters = adjacentMilitary(of: unit.owner, around: target, excluding: unit.id, sees: sees)
                s.add(.support, min(c.supportMax, c.supportPerUnit * supporters))
            }
            s.add(.wounded, woundPenalty(unit))
            if let (cls, bonus) = classBonus(of: unit, against: attacker) { s.add(.classBonus(cls), bonus) }
            s.add(.promotion, promotionBonus(of: unit, attacking: false, ranged: ranged, against: attacker))
            defence = s
        }
        return Clash(attacker: attacker, defender: defender, from: from, target: target, ranged: ranged,
                     attack: attack, defence: defence)
    }

    // MARK: Rolls

    /// The two rolls of a fight (M1 §8.2), each uniform in −rollRange…rollRange, from
    /// `SplitMix64(seed: seed, salts: turn, attackerKey, defenderKey, 0xC0B)`: the attacker's
    /// roll first, then the retaliation's.
    func combatRolls(attacker: UInt64, defender: UInt64) -> (attack: Int, retaliation: Int) {
        let range = rules.constants.combat.rollRange
        var rng = SplitMix64(seed: seed, salts: UInt64(turn), attacker, defender, 0xC0B)
        let attack = rng.nextInt(in: -range...range)
        let retaliation = rng.nextInt(in: -range...range)
        return (attack, retaliation)
    }

    // MARK: Targets

    enum TargetLookup {
        case target(CombatSide)
        case problem(String)
    }

    /// What `player` would hit by attacking tile `t` (M1 §8.3): an enemy city, else the enemy
    /// military unit on it. Judged on what the player sees: a tile it cannot see holds no
    /// target, with the same reason as an empty tile, so a refusal never reveals a hidden unit
    /// or city.
    func attackTarget(at t: Int, by player: PlayerID) -> TargetLookup {
        let none = TargetLookup.problem("no enemy there")
        guard players[player.rawValue].visible[t] else { return none }
        if let city = city(atTile: t) {
            guard city.owner != player else { return none }
            guard isAtWar(player, city.owner) else { return .problem("not at war with \(players[city.owner.rawValue].name)") }
            return .target(.city(city))
        }
        let hex = map.coord(at: t)
        let foreign = units.filter { $0.position == hex && $0.owner != player }
        if let military = foreign.first(where: { !$0.type.isCivilian }) {
            guard isAtWar(player, military.owner) else { return .problem("not at war with \(players[military.owner.rawValue].name)") }
            return .target(.unit(military))
        }
        if !foreign.isEmpty { return .problem("civilians cannot be attacked") }
        return none
    }

    /// Why `unit` may not attack at all now (nil: it may).
    func attackerProblem(_ unit: Unit) -> String? {
        let def = rules.unit(unit.type)
        guard def.isMilitary else { return "civilians cannot attack" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        // Siege units fire only before moving in the phase (M2 §8.1).
        if def.rangedAfterMove == false, unit.movesLeft < def.moves { return "\(unit.type.displayName)s cannot fire after moving" }
        return nil
    }

    /// Why a unit of `type` standing on tile `from` may not attack `target` on tile `t`
    /// (nil: it may): range, and recon units never attack cities.
    func attackReachProblem(_ type: UnitType, from: Int, at t: Int, against target: CombatSide) -> String? {
        let def = rules.unit(type)
        if case .city = target, def.unitClass == .recon { return "\(type.displayName)s cannot attack cities" }
        let distance = map.distance(index: from, t)
        if def.isRanged {
            if distance < 1 || distance > def.range { return "target out of range" }
        } else if distance != 1 {
            return "target not adjacent"
        }
        return nil
    }

    /// Whether a unit of `type` takes a city at 0 HP by attacking it (M1 §5: melee and
    /// antiCavalry units).
    func capturesCities(_ type: UnitType) -> Bool {
        let cls = rules.unit(type).unitClass
        return cls == .melee || cls == .antiCavalry
    }

    // MARK: Attacks

    /// `unit` attacks `target` on tile `t` (validated by the caller), M1 §8.3. A melee or
    /// antiCavalry unit attacking a city at 0 HP captures it instead.
    mutating func attack(with id: UnitID, at t: Int, against target: CombatSide, _ fx: inout Effects) {
        guard let attacker = unit(id), let from = map.index(of: attacker.position) else { return }
        let def = rules.unit(attacker.type)
        let ranged = def.isRanged
        if case let .city(city) = target, !ranged, city.hp == 0, capturesCities(attacker.type), let index = cityIndex(city.id) {
            captureCity(index, by: id, &fx)
            return
        }
        let clash = clash(attacker: .unit(attacker), defender: target, from: from, target: t, ranged: ranged, sees: { _ in true })
        let rolls = combatRolls(attacker: CombatSide.unit(attacker).rollKey, defender: target.rollKey)
        let c = rules.constants.combat
        let turn = self.turn

        // Attacking ends the attacker's moves and clears its activity and orders.
        updateUnit(id) { u in
            u.movesLeft = 0
            u.activity = .none
            u.destination = nil
            u.lastActedTurn = turn
            u.xp += ranged ? c.xpRangedAttack : c.xpMeleeAttack
        }

        let damage = CombatMath.damage(base: clash.baseDealt, roll: rolls.attack)
        let (dealt, defenderDied) = hurt(target, by: damage, at: t, &fx)

        var taken = 0
        var attackerDied = false
        if !ranged {
            let retaliation = CombatMath.damage(base: clash.baseTaken, roll: rolls.retaliation)
            var hp = attacker.hp - retaliation
            if defenderDied { hp = max(1, hp) } // the winner of a melee survives
            taken = attacker.hp - max(0, hp)
            if hp <= 0 {
                attackerDied = true
            } else {
                updateUnit(id) { $0.hp = hp }
            }
        }

        fx.emit(.combat(attacker: .unit(id), defender: target.combatant, from: attacker.position, to: map.coord(at: t),
                        ranged: ranged, dealt: dealt, taken: taken), .tiles([from, t]))
        if defenderDied, case let .unit(victim) = target { killUnit(victim.id, &fx) }
        if attackerDied { killUnit(id, &fx) }
        fx.touchPlayer(attacker.owner)
        fx.touchPlayer(target.owner)

        // A melee winner moves in, capturing civilians there, unless it is a garrison (or the
        // tile is in territory closed to it: a third player's, at peace).
        if defenderDied, !ranged, !attackerDied, city(atTile: from) == nil, let winner = unit(id), mayStop(t, winner) {
            let hex = map.coord(at: t)
            updateUnit(id) { $0.position = hex }
            fx.emit(.unitMoved(unit: id, from: attacker.position, path: [hex]), .tiles([from, t]))
            captureCivilians(at: t, by: attacker.owner, &fx)
        }
    }

    /// City `index` bombards `target` on tile `t` (validated by the caller): a ranged attack
    /// with its City Strength, once per phase (M1 §5).
    mutating func bombard(fromCity index: Int, at t: Int, against target: CombatSide, _ fx: inout Effects) {
        let city = cities[index]
        let from = map.index(of: city.position)!
        let clash = clash(attacker: .city(city), defender: target, from: from, target: t, ranged: true, sees: { _ in true })
        let rolls = combatRolls(attacker: CombatSide.city(city).rollKey, defender: target.rollKey)
        cities[index].bombarded = true
        let damage = CombatMath.damage(base: clash.baseDealt, roll: rolls.attack)
        let (dealt, died) = hurt(target, by: damage, at: t, &fx)
        fx.emit(.combat(attacker: .city(city.id), defender: target.combatant, from: city.position, to: map.coord(at: t),
                        ranged: true, dealt: dealt, taken: 0), .tiles([from, t]))
        if died, case let .unit(victim) = target { killUnit(victim.id, &fx) }
        fx.touchPlayer(target.owner)
    }

    /// Applies `damage` to a defender: a unit loses HP (a survivor gains defence XP); a city
    /// loses wall HP first, then HP, never below 0, and counts as attacked this phase. Returns
    /// the HP actually lost and whether a unit died (the caller removes it).
    /// `wallPct` scales the damage wall HP takes (M2 §9.2: siege 150, other units 50, bombard
    /// 100); damage beyond the walls reaches HP at full value.
    private mutating func hurt(_ target: CombatSide, by damage: Int, at t: Int, wallPct: Int = 100,
                               _ fx: inout Effects) -> (lost: Int, died: Bool) {
        switch target {
        case let .unit(victim):
            if damage >= victim.hp { return (victim.hp, true) }
            let xp = rules.constants.combat.xpDefend
            updateUnit(victim.id) { u in
                u.hp -= damage
                u.xp += xp
            }
            return (damage, false)
        case let .city(city):
            guard let i = cityIndex(city.id) else { return (0, false) }
            let pct = max(1, wallPct)
            let scaled = cities[i].wallHP > 0 ? damage * pct / 100 : 0
            let walls = min(cities[i].wallHP, scaled)
            let spent = cities[i].wallHP == 0 ? 0 : walls == scaled ? damage : walls * 100 / pct
            let hp = min(cities[i].hp, max(0, damage - spent))
            cities[i].wallHP -= walls
            cities[i].hp -= hp
            cities[i].lastAttackedPhase = phaseCount
            fx.touchTile(t)
            return (walls + hp, false)
        }
    }

    /// Removes a unit that died, with `unitKilled` (seen by those who see its tile). Players
    /// who see it die forget their sighting of it.
    mutating func killUnit(_ id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id), let t = map.index(of: unit.position) else { return }
        forgetSightings(of: unit)
        removeUnit(id)
        fx.touchPlayer(unit.owner)
        fx.emit(.unitKilled(unit: id, type: unit.type, owner: unit.owner, at: unit.position), .tiles([t]))
    }

    // MARK: Civilian capture

    /// Captures every civilian on tile `t` that a player at war with `captor` owns (M1 §7.3):
    /// each is removed and the captor gets a new unit (new id, 0 moves): a Settler becomes a
    /// Builder with 2 charges, a Builder keeps its charges (`capturedAs`, `capturedCharges`).
    mutating func captureCivilians(at t: Int, by captor: PlayerID, _ fx: inout Effects) {
        let hex = map.coord(at: t)
        let victims = units.filter { $0.position == hex && $0.owner != captor && $0.type.isCivilian && isAtWar(captor, $0.owner) }
        for victim in victims {
            let def = rules.unit(victim.type)
            let type = def.capturedAs ?? victim.type
            let charges = def.capturedCharges ?? victim.charges
            removeUnit(victim.id)
            let new = insertUnit(type, owner: captor, at: hex, movesLeft: 0, charges: charges)
            fx.emit(.unitCaptured(old: victim.id, new: new, type: type, from: victim.owner, to: captor, at: hex), .tiles([t]))
            fx.touchPlayer(victim.owner)
            fx.touchPlayer(captor)
        }
    }

    // MARK: Cities

    /// Unit `id` takes city `index`, which has 0 HP, without combat (M1 §5): the garrison is
    /// destroyed, civilians on the tile are captured, the unit moves in; the city loses one
    /// citizen (never below 1), its Walls and the Palace, its queue and stored progress, and
    /// changes hands with its territory and other buildings at `capturedHP`. Palaces move: the
    /// loser's to its largest remaining city, the captor's back to its original capital.
    mutating func captureCity(_ index: Int, by id: UnitID, _ fx: inout Effects) {
        guard let captor = unit(id) else { return }
        let city = cities[index]
        let old = city.owner
        let new = captor.owner
        let centre = map.index(of: city.position)!
        let from = map.index(of: captor.position)!
        let turn = self.turn

        for garrison in units where garrison.position == city.position && garrison.owner == old && !garrison.type.isCivilian {
            killUnit(garrison.id, &fx)
        }
        updateUnit(id) { u in
            u.position = city.position
            u.movesLeft = 0
            u.activity = .none
            u.destination = nil
            u.lastActedTurn = turn
        }
        fx.emit(.unitMoved(unit: id, from: captor.position, path: [city.position]), .tiles([from, centre]))
        captureCivilians(at: centre, by: new, &fx)

        let palace = rules.palace.id
        let walls = rules.buildings.filter { $0.wallHP > 0 }.map(\.id)
        cities[index].owner = new
        cities[index].population = max(1, city.population - 1)
        cities[index].buildings.removeAll { $0 == palace || walls.contains($0) }
        cities[index].wallHP = 0
        cities[index].queue = []
        cities[index].storedProgress = rules.constants.city.capturedProduction // 0 by default (p3f experiment)
        cities[index].hp = rules.constants.city.capturedHP
        cities[index].capturedTurn = turn
        cities[index].bombarded = true
        cities[index].lastAttackedPhase = phaseCount

        // The territory goes with the city; the loser knows it lost it.
        let code = Int32(city.id.rawValue + 1)
        let newCode = UInt8(new.rawValue + 1)
        for t in tileCity.indices where tileCity[t] == code {
            fx.touchTile(t)
            if players[old.rawValue].memory.tileOwner[t] != newCode { players[old.rawValue].memory.tileOwner[t] = newCode }
        }
        fx.touchPlayer(old)
        fx.touchPlayer(new)
        assignCitizens(index)

        if players[old.rawValue].capital == city.id { players[old.rawValue].capital = nil }
        if players[new.rawValue].originalCapital == city.id {
            movePalace(of: new, to: city.id, &fx)
        }
        ensureCapital(of: old, &fx)
        ensureCapital(of: new, &fx)
        remember(cities[index], by: old)
        fx.emit(.cityCaptured(city: city.id, name: city.name, from: old, to: new, at: city.position), .tiles([centre]))
    }

    /// Why `player` may not raze city `index` (nil: it may): only in the phase it was captured,
    /// and never an original capital (M1 §5).
    func razeProblem(_ index: Int) -> String? {
        let city = cities[index]
        guard city.capturedTurn == turn, city.owner == currentPlayer else { return "only a city captured this phase can be razed" }
        if players.contains(where: { $0.originalCapital == city.id }) { return "original capitals cannot be razed" }
        return nil
    }

    /// Razes city `index` (validated by the caller): it is removed and its tiles become
    /// unowned; improvements and units stay.
    mutating func raze(_ index: Int, _ fx: inout Effects) {
        let city = cities[index]
        let code = Int32(city.id.rawValue + 1)
        let centre = map.index(of: city.position)!
        for t in tileCity.indices where tileCity[t] == code {
            tileCity[t] = 0
            fx.touchTile(t)
        }
        cities.remove(at: index)
        fx.touchPlayer(city.owner)
        if players[city.owner.rawValue].capital == city.id {
            players[city.owner.rawValue].capital = nil
            ensureCapital(of: city.owner, &fx)
        }
        fx.emit(.cityRazed(city: city.id, name: city.name, owner: city.owner, at: city.position), .tiles([centre]))
    }

    /// Moves `player`'s Palace to city `id` (one of theirs).
    mutating func movePalace(of player: PlayerID, to id: CityID, _ fx: inout Effects) {
        let palace = rules.palace.id
        for i in cities.indices where cities[i].owner == player && cities[i].has(palace) && cities[i].id != id {
            cities[i].buildings.removeAll { $0 == palace }
            fx.touchTile(map.index(of: cities[i].position)!)
        }
        guard let i = cityIndex(id) else { return }
        if !cities[i].has(palace) {
            cities[i].buildings.append(palace)
            cities[i].buildings.sort()
        }
        players[player.rawValue].capital = id
        fx.touchTile(map.index(of: cities[i].position)!)
    }

    /// A player with cities but no capital gets the Palace in their largest city (ties: lower
    /// id), M1 §5.
    mutating func ensureCapital(of player: PlayerID, _ fx: inout Effects) {
        guard players[player.rawValue].capital == nil else { return }
        var best: City?
        for city in cities where city.owner == player {
            if let b = best, b.population >= city.population { continue }
            best = city
        }
        if let best { movePalace(of: player, to: best.id, &fx) }
    }
}
