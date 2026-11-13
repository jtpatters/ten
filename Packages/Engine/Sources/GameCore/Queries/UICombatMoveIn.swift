// Where a melee attacker ends if it wins (M1 §8.3), for the combat card (M1 §16): a winner over
// a unit moves onto its tile, unless it is a garrison or the tile is land closed to it; a capture
// moves it into the city. That tile may lie within an enemy city's bombard range (M1 §5), which
// the card must say: a Warrior that killed and moved in two tiles from Rome was destroyed by its
// bombard the next phase.

/// The bombards that reach the tile a melee attacker moves onto if it wins, as its player knows
/// them, and how hard they are likely to strike there.
public struct MoveInWarning: Hashable, Sendable {
    /// Known enemy cities whose bombard reaches the tile, nearest first (ties: the lower id);
    /// for a capture, other than the city taken.
    public var cities: [CitySighting]
    /// A capture: the bombards strike the city taken (its garrison is never their target).
    public var capture: Bool
    /// What they would strike has this many HP left: the attacker's expected HP after a win (at
    /// least 1), or the city's HP once taken.
    public var hpLeft: Int
    /// The bombards' blows together with no roll (M1 §8.2), on what they would strike there.
    public var typicalBlow: Int

    /// The bombards are likely to destroy the winner there (or bring the city taken to 0 HP):
    /// what it has left is below their typical blow.
    public var severe: Bool { hpLeft < typicalBlow }

    /// "If it wins it moves in, within range of Rome's bombard (≈23 HP left).", "It moves in,
    /// within range of Antium's bombard (the city at 50 HP)."
    public var text: String {
        let names = cities.map { "\($0.name)'s" }
        let reach = switch names.count {
        case 1: "within range of \(names[0]) bombard"
        case 2: "within range of \(names[0]) and \(names[1]) bombards"
        default: "within range of \(names.count) cities' bombards"
        }
        return capture ? "It moves in, \(reach) (the city at \(hpLeft) HP)." : "If it wins it moves in, \(reach) (≈\(hpLeft) HP left)."
    }
}

extension PlayerView {
    /// The move-in warning for a previewed melee attack (`MoveInWarning`): an attack on a unit
    /// it may destroy, from outside an own city, onto a tile it may stop on; or a capture. Nil
    /// when no known enemy city's bombard reaches where it ends. `hpAfterWin`: the attacker's
    /// expected HP after a win (the card's).
    func moveInWarning(_ p: CombatPreview, hpAfterWin: Int) -> MoveInWarning? {
        guard !p.ranged, case let .unit(id) = p.attacker, let unit = unit(id), p.killPairs > 0 else { return nil }
        switch p.defender {
        case let .unit(target):
            // A garrison stays in its city; a winner stays out of land closed to it.
            guard !cities.contains(where: { $0.position == p.from }) else { return nil }
            if let owner = knownOwner(at: p.target), owner != player, !isAtWar(with: owner) { return nil }
            let reach = exposure(at: p.target, except: target).cities
            guard !reach.isEmpty else { return nil }
            let hp = max(1, hpAfterWin)
            let blow = reach.reduce(0) { $0 + bombardBlow(from: $1, onUnit: unit.type, hp: hp, at: p.target) }
            return MoveInWarning(cities: reach, capture: false, hpLeft: hp, typicalBlow: blow)
        case let .city(taken):
            guard p.capturesCity, let city = knownCities.first(where: { $0.id == taken }) else { return nil }
            let reach = exposure(at: p.target).cities.filter { $0.id != taken }
            guard !reach.isEmpty else { return nil }
            let hp = rules.constants.city.capturedHP
            let blow = reach.reduce(0) { $0 + bombardBlow(from: $1, onCaptured: city) }
            return MoveInWarning(cities: reach, capture: true, hpLeft: hp, typicalBlow: blow)
        }
    }

    /// A known city's bombard with no roll on an own unit of `type` with `hp` HP on `hex`: its
    /// City Strength as known against the unit's defence there (base, the tile, its wounds; a
    /// ranged blow meets no support, and the unit has not fortified).
    private func bombardBlow(from city: CitySighting, onUnit type: UnitType, hp: Int, at hex: HexCoord) -> Int {
        guard let strength = knownCityStrength(at: city.position) else { return 0 }
        let c = rules.constants
        let wounds = max(0, c.healing.maxHP - hp) / c.combat.hpPerWoundPenalty
        let defence = rules.unit(type).strength + (tileDefenseModifier(at: hex) ?? 0) - wounds
        return CombatMath.baseDamage(strength.total - defence)
    }

    /// A known city's bombard with no roll on a city just taken (M1 §5): a citizen fewer, no
    /// walls, the captor its garrison.
    private func bombardBlow(from city: CitySighting, onCaptured taken: CitySighting) -> Int {
        guard let strength = knownCityStrength(at: city.position), let t = index(of: taken.position) else { return 0 }
        let c = rules.constants.city
        let defence = c.strengthBase + c.strengthPerPopulation * max(1, taken.population - 1)
            + rules.elevation(state.map.tiles[t].elevation).cityStrength + c.garrisonStrength
        return CombatMath.baseDamage(strength.total - defence)
    }
}
