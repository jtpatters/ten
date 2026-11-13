// Read-only helpers for the App's notices (M1 §16 "Notifications"): what a batch of event records
// the player may see means for it, beyond what each record says alone. Built only from those
// records and what the player knows now.

/// A unit whose completion cost its city population (a Settler, M1 §5), paired with the
/// `cityShrank` that paid for it: that shrink is not hunger.
public struct PopulationCost: Hashable, Sendable {
    public var city: CityID
    /// The index of the `cityShrank` record that paid it.
    public var shrink: Int
    /// The index of the unit's `productionCompleted` record.
    public var completion: Int
    /// The city's population after paying.
    public var population: Int
}

/// The blows one of the player's own units took in a batch of records and lived through.
public struct UnitDamage: Hashable, Sendable {
    public var unit: UnitID
    public var type: UnitType
    /// Who struck, one entry per blow, in order: a unit or a city.
    public var attackers: [Combatant]
    /// Per blow: a ranged attack or a city's bombard (no melee).
    public var ranged: [Bool]
    /// HP lost in all.
    public var damage: Int
    /// Its HP now.
    public var hp: Int
    /// Where it stands now.
    public var tile: HexCoord
}

/// One of the player's own units destroyed in a batch of records, paired with the blow that
/// destroyed it: the `.combat` record on it just before its `unitKilled` (the engine reports a
/// death right after the blow). A unit no blow destroyed (a garrison when its city is taken) has
/// no killer.
public struct UnitLoss: Hashable, Sendable {
    public var unit: UnitID
    public var type: UnitType
    /// Where it was destroyed.
    public var tile: HexCoord
    /// Who dealt the blow that destroyed it (a unit or a city); nil when no blow in the records did.
    public var killer: Combatant?
    /// That blow was a ranged attack or a city's bombard.
    public var ranged: Bool
    /// Blows it took earlier in the same records and lived through: who struck, per blow, in order.
    public var earlierAttackers: [Combatant]
    /// Per earlier blow: a ranged attack or a city's bombard.
    public var earlierRanged: [Bool]
    /// HP the earlier blows took in all.
    public var earlierDamage: Int
    /// The index of its `unitKilled` record.
    public var record: Int
}

/// One of the player's military units moved out of land closed to it (M1 §9: at peace, at its
/// owner's phase start).
public struct Eviction: Hashable, Sendable {
    public var unit: UnitID
    public var type: UnitType
    /// Whose land it left.
    public var owner: PlayerID
    public var to: HexCoord
}

extension PlayerView {
    /// A player's civilisation (nil for no such player): what names its people in a notice.
    public func civ(of other: PlayerID) -> CivID? {
        state.players.indices.contains(other.rawValue) ? state.players[other.rawValue].civ : nil
    }

    /// The `cityShrank` records in `records` (in order) that paid for a unit completed in the same
    /// records, each with that completion. A unit that costs population completes right after
    /// its city's shrink (production or purchase, M1 §5); a city that also starved in the same
    /// records keeps that other shrink, so it still counts as hunger.
    public func populationCosts(in records: [EventRecord]) -> [PopulationCost] {
        var costs: [PopulationCost] = []
        var paired = [Bool](repeating: false, count: records.count)
        for (j, record) in records.enumerated() {
            guard case let .productionCompleted(city, .unit(type), _) = record.event, rules.unit(type).populationCost > 0 else {
                continue
            }
            // The nearest earlier shrink of that city not paired yet, and no further back than
            // the city's previous completion.
            search: for i in stride(from: j - 1, through: 0, by: -1) {
                switch records[i].event {
                case let .cityShrank(c, population, _) where c == city && !paired[i]:
                    paired[i] = true
                    costs.append(PopulationCost(city: city, shrink: i, completion: j, population: population))
                    break search
                case let .productionCompleted(c, _, _) where c == city:
                    break search
                default:
                    continue
                }
            }
        }
        return costs
    }

    /// The damage the player's own units took from attacks in `records` (records it may see, in
    /// order): one entry per unit that is alive now, in the order of its first blow. A unit that
    /// died is left out: its `unitKilled` says so.
    public func unitDamage(in records: [EventRecord]) -> [UnitDamage] {
        var out: [UnitDamage] = []
        var slot: [UnitID: Int] = [:]
        for record in records {
            guard case let .combat(attacker, .unit(id), _, _, ranged, dealt, _) = record.event,
                  let unit = state.unit(id), unit.owner == player else { continue }
            if let i = slot[id] {
                out[i].attackers.append(attacker)
                out[i].ranged.append(ranged)
                out[i].damage += dealt
            } else {
                slot[id] = out.count
                out.append(UnitDamage(unit: id, type: unit.type, attackers: [attacker], ranged: [ranged], damage: dealt,
                                      hp: unit.hp, tile: unit.position))
            }
        }
        return out
    }

    /// The player's own units destroyed in `records` (records it may see, in order), one entry per
    /// `unitKilled`, in order: each with the blow that destroyed it (the `.combat` record on it
    /// right before its death, other deaths aside) and the blows it took before that in the same
    /// records. A unit that died attacking was destroyed by its defender's retaliation.
    public func unitLosses(in records: [EventRecord]) -> [UnitLoss] {
        var out: [UnitLoss] = []
        for (j, record) in records.enumerated() {
            guard case let .unitKilled(id, type, owner, at) = record.event, owner == player else { continue }
            var loss = UnitLoss(unit: id, type: type, tile: at, killer: nil, ranged: false, earlierAttackers: [],
                                earlierRanged: [], earlierDamage: 0, record: j)
            // The blow: the record before the death, skipping the other side's death.
            var i = j - 1
            while i >= 0, case .unitKilled = records[i].event { i -= 1 }
            if i >= 0, case let .combat(attacker, defender, _, _, ranged, _, _) = records[i].event {
                if defender == .unit(id) {
                    loss.killer = attacker
                    loss.ranged = ranged
                } else if attacker == .unit(id) {
                    loss.killer = defender
                }
            }
            // The blows before it.
            let end = loss.killer == nil ? j : i
            for earlier in records[..<end] {
                guard case let .combat(attacker, .unit(victim), _, _, ranged, dealt, _) = earlier.event, victim == id else { continue }
                loss.earlierAttackers.append(attacker)
                loss.earlierRanged.append(ranged)
                loss.earlierDamage += dealt
            }
            out.append(loss)
        }
        return out
    }

    /// The known city (own or remembered) on `hex`, else the nearest within `radius` tiles (ties:
    /// the lower id): what a notice names a place by ("near Rome").
    public func nearestKnownCity(to hex: HexCoord, within radius: Int) -> CitySighting? {
        var best: (distance: Int, city: CitySighting)?
        for city in knownCities {
            let d = distance(city.position, hex)
            guard d <= radius else { continue }
            if let b = best, (b.distance, b.city.id.rawValue) <= (d, city.id.rawValue) { continue }
            best = (d, city)
        }
        return best?.city
    }

    /// The player's military units that `records` move out of land closed to them: a move that
    /// starts on a tile owned (as the player knows it) by a player it is at peace with (M1 §9).
    /// Their own orders never lead into such land, so only an eviction starts there.
    public func evictions(in records: [EventRecord]) -> [Eviction] {
        var out: [Eviction] = []
        for record in records {
            guard case let .unitMoved(id, from, path) = record.event, let to = path.last,
                  let unit = state.unit(id), unit.owner == player, !unit.type.isCivilian,
                  let owner = knownOwner(at: from), owner != player, state.bordersClosed(to: player, by: owner) else { continue }
            out.append(Eviction(unit: id, type: unit.type, owner: owner, to: to))
        }
        return out
    }
}
