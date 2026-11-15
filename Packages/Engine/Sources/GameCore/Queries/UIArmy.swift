// Queries behind the App's war tools (its War Room and group orders, docs/M2.md §10.4): where a
// group of own military units stands around a goal, and what one production order does to many
// cities' queues. They read only the player's knowledge and change nothing: the App issues the
// ordinary commands (`moveUnit`, `setQueue`) they plan.

/// Where a group of own units goes around a goal (`PlayerView.formation`): one tile each, the
/// goal first, then the tiles around it nearest first (on the side the group comes from), so
/// that a group sent at an enemy city closes around it and a group sent to a muster point packs
/// around the point.
public struct FormationPlan: Hashable, Sendable {
    public var target: HexCoord
    /// Each placed unit's tile. A unit already standing on its tile keeps it.
    public var slots: [UnitID: HexCoord]
    /// Phases until each placed unit arrives (0: already there; 1: this phase).
    public var turns: [UnitID: Int]
    /// Units with no route to any tile near the goal (another landmass, a blocked way).
    public var unreachable: [UnitID]

    public var placed: Int { slots.count }

    /// The first and last arrivals among the units that move (nil when none moves).
    public var arrivals: ClosedRange<Int>? {
        let moving = turns.values.filter { $0 > 0 }
        guard let first = moving.min(), let last = moving.max() else { return nil }
        return first...last
    }
}

/// Where `PlayerView.bulkQueues` puts an item in each city's queue.
public enum BulkPlacement: String, Hashable, Sendable, CaseIterable {
    /// Ahead of everything queued (a building already queued moves to the front).
    case first
    /// After everything queued.
    case last
    /// In place of the whole queue.
    case only
}

/// One city's part in a production order given to many cities: its new queue, or why it
/// cannot take the item.
public struct BulkQueueChange: Hashable, Sendable {
    public var city: CityID
    public var items: [ProductionItem]?
    public var problem: String?
}

extension PlayerView {
    /// How far from the goal a formation looks for tiles.
    static let formationReach = 5
    /// Routes tried per unit before it counts as unreachable.
    static let formationTries = 8

    /// Plans where own units `ids` go around `target` (military units only; others, and units
    /// that are not the player's, are left out): the goal tile first, then the rings around it,
    /// nearest first, ties to the tiles nearest the group's closest unit, then by tile index,
    /// out to the ring with room for all (at most `formationReach`). Tiles in `reserved` (another
    /// group's places) and tiles where other own military units stand are taken. A unit already standing on one
    /// of the tiles the group needs keeps it; the others, nearest the goal first, take the first
    /// free tile they have a route to (the player's knowledge: `path(for:to:)`), and a unit with
    /// none among its first `formationTries` is unreachable.
    ///
    /// At a known enemy city (a siege) places go by role: melee units close around the city
    /// first, then ranged and siege units take the tiles at their range (further in when those
    /// are full), so they shoot over the line instead of standing in it.
    public func formation(of ids: [UnitID], around target: HexCoord, reserved: Set<HexCoord> = []) -> FormationPlan {
        var plan = FormationPlan(target: target, slots: [:], turns: [:], unreachable: [])
        guard let goal = normalize(target) else {
            plan.unreachable = ids
            return plan
        }
        plan.target = goal
        let units = ids.compactMap { unit($0) }.filter { $0.owner == player && !$0.type.isCivilian }
            .sorted { (distance($0.position, goal), $0.id) < (distance($1.position, goal), $1.id) }
        guard let vanguard = units.first else { return plan }
        let siege = knownCity(at: goal).map { isAtWar(with: $0.owner) } ?? false
        /// The distance from the goal a unit wants (siege only): its range when it shoots from
        /// afar, else next to the city.
        func reach(_ unit: Unit) -> Int {
            let def = rules.unit(unit.type)
            return siege && def.isRanged && def.range > 1 ? min(def.range, Self.formationReach) : 1
        }
        // The tiles, by ring, then nearest the group's side: out to the ring that holds a place
        // for every unit and two spare (and, in a siege, the ranged units' range), leaving out
        // tiles held by other own military units.
        let group = Set(units.map(\.id))
        let held = Set(self.units.filter { !$0.type.isCivilian && !group.contains($0.id) }.map(\.position))
        let minRing = units.map(reach).max() ?? 1
        var candidates: [HexCoord] = []
        for ring in 1...Self.formationReach {
            candidates = coords(within: ring, of: goal).filter { !reserved.contains($0) && !held.contains($0) }
            if ring >= minRing, candidates.count >= units.count + 2 { break }
        }
        candidates.sort { a, b in
            let ka = (distance(a, goal), distance(a, vanguard.position), index(of: a) ?? 0)
            let kb = (distance(b, goal), distance(b, vanguard.position), index(of: b) ?? 0)
            return ka < kb
        }
        /// A unit's tiles, best first: by ring outside a siege; in one, its range first, then
        /// nearer rings (still in range), then further ones.
        func preferred(_ unit: Unit) -> [HexCoord] {
            let r = reach(unit)
            guard r > 1 else { return candidates }
            return candidates.enumerated().sorted { a, b in
                let da = distance(a.element, goal), db = distance(b.element, goal)
                return (da > r ? 1 : 0, abs(r - da), a.offset) < (db > r ? 1 : 0, abs(r - db), b.offset)
            }.map(\.element)
        }
        // Units already in place: on one of the tiles the group needs (in a siege: at the
        // distance their role wants).
        var taken = Set<HexCoord>()
        let needed = Set(candidates.prefix(units.count))
        let candidateSet = Set(candidates)
        var waiting: [Unit] = []
        for unit in units {
            let inPlace = siege ? candidateSet.contains(unit.position) && distance(unit.position, goal) == reach(unit)
                : needed.contains(unit.position)
            if inPlace, !taken.contains(unit.position) {
                plan.slots[unit.id] = unit.position
                plan.turns[unit.id] = 0
                taken.insert(unit.position)
            } else {
                waiting.append(unit)
            }
        }
        // In a siege the line takes its places before the archers behind it.
        if siege { waiting = waiting.filter { reach($0) == 1 } + waiting.filter { reach($0) > 1 } }
        for unit in waiting {
            var tries = 0
            var placed = false
            for tile in preferred(unit) where !taken.contains(tile) {
                if tile == unit.position {
                    plan.slots[unit.id] = tile
                    plan.turns[unit.id] = 0
                    taken.insert(tile)
                    placed = true
                    break
                }
                if let path = path(for: unit.id, to: tile), !path.steps.isEmpty {
                    plan.slots[unit.id] = tile
                    plan.turns[unit.id] = path.turns
                    taken.insert(tile)
                    placed = true
                    break
                }
                tries += 1
                if tries >= Self.formationTries { break }
            }
            if !placed { plan.unreachable.append(unit.id) }
        }
        return plan
    }

    /// Whether an own unit on the march to `target` standing at `hex` has met the enemy: a
    /// visible military unit of a player at war with the player, or a known city of one, within
    /// `marchContactRange`. The goal itself (a city under siege and its garrison) is expected and
    /// does not count.
    public func marchContact(at hex: HexCoord, target: HexCoord) -> Bool {
        let goal = normalize(target) ?? target
        let range = Self.marchContactRange
        let cities = knownCities.contains {
            $0.position != goal && isAtWar(with: $0.owner) && distance($0.position, hex) <= range
        }
        return cities || visibleForeignUnits.contains {
            !$0.type.isCivilian && $0.position != goal && isAtWar(with: $0.owner) && distance($0.position, hex) <= range
        }
    }

    /// What each unit of the marches to one goal does this phase (`marchSteps`): the group keeps
    /// together, so a unit more than one phase ahead of the slowest waits for it. Without
    /// `stopOnContact` (an order just given, near the enemy on purpose) contact does not stop it.
    public func marchSteps(_ marches: [MarchLeg], stopOnContact: Bool = true) -> [UnitID: MarchStep] {
        var steps: [UnitID: MarchStep] = [:]
        var turns: [UnitID: Int] = [:]
        for leg in marches {
            guard let unit = unit(leg.unit), unit.owner == player, !unit.type.isCivilian else {
                steps[leg.unit] = .gone
                continue
            }
            if unit.position == normalize(leg.slot) {
                steps[leg.unit] = .arrived
            } else if stopOnContact, marchContact(at: unit.position, target: leg.target) {
                steps[leg.unit] = .contact
            } else if let path = path(for: leg.unit, to: leg.slot), !path.steps.isEmpty {
                turns[leg.unit] = path.turns
            } else {
                steps[leg.unit] = .noRoute
            }
        }
        let slowest = turns.values.max() ?? 0
        for (id, t) in turns { steps[id] = t < slowest - 1 ? .wait : .move }
        return steps
    }
}

extension PlayerView {
    /// How close (tiles) an enemy may come before a marching unit stops for orders.
    public static let marchContactRange = 2
}

/// One unit's march (`PlayerView.marchSteps`): its group's goal and its own place there.
public struct MarchLeg: Hashable, Sendable {
    public var unit: UnitID
    public var target: HexCoord
    public var slot: HexCoord

    public init(unit: UnitID, target: HexCoord, slot: HexCoord) {
        self.unit = unit
        self.target = target
        self.slot = slot
    }
}

/// What a marching unit does at the start of a phase.
public enum MarchStep: Hashable, Sendable {
    /// In its place.
    case arrived
    /// An enemy within `PlayerView.marchContactRange`: it stops and waits for orders.
    case contact
    /// No route to its place (another unit there, a way closed): it needs a new place.
    case noRoute
    /// More than a phase ahead of the slowest unit of its group: it waits for them.
    case wait
    /// It marches on.
    case move
    /// No longer the player's military unit.
    case gone
}

extension PlayerView {

    /// What putting `item` in the queues of own cities `ids` does, city by city (in the order
    /// given): the new queue, or why the city cannot take it (the item is not available there,
    /// a building already built or queued, a full queue). `placement` says where it goes.
    public func bulkQueues(_ item: ProductionItem, in ids: [CityID], placement: BulkPlacement) -> [BulkQueueChange] {
        ids.compactMap { id -> BulkQueueChange? in
            guard let city = city(id) else { return nil }
            if let problem = state.itemProblem(item, in: city) {
                return BulkQueueChange(city: id, items: nil, problem: problem)
            }
            var items = city.queuedItems
            let isBuilding = if case .building = item { true } else { false }
            switch placement {
            case .first:
                if isBuilding, let i = items.firstIndex(of: item) {
                    guard i > 0 else { return BulkQueueChange(city: id, items: nil, problem: "already first") }
                    items.remove(at: i)
                }
                items.insert(item, at: 0)
            case .last:
                if isBuilding, items.contains(item) { return BulkQueueChange(city: id, items: nil, problem: "already queued") }
                items.append(item)
            case .only:
                if items == [item] { return BulkQueueChange(city: id, items: nil, problem: "already its only item") }
                items = [item]
            }
            if items.count > rules.constants.production.maxQueue {
                return BulkQueueChange(city: id, items: nil, problem: "queue full")
            }
            if let problem = GameEngine.queueProblem(items, in: city, state) {
                return BulkQueueChange(city: id, items: nil, problem: problem)
            }
            return BulkQueueChange(city: id, items: items, problem: nil)
        }
    }
}

// MARK: - Sieges

/// What a siege of a known enemy city can do this phase (`PlayerView.siegeOutlook`): the city
/// as the player knows it, the ranged units that can shoot it from where they stand, and the
/// best assault by a melee unit next to it.
public struct SiegeOutlook: Hashable, Sendable {
    /// The city as last seen (current while it is in sight).
    public var city: CitySighting
    /// Its full HP, and the wall HP of its wall tier (0 without walls).
    public var maxHP: Int
    public var maxWallHP: Int
    /// Ranged members that can shoot the city now without moving, strongest first.
    public var shots: [UnitID]
    /// The best attack on the city by a melee member next to it (nil when none can): a capture
    /// first, then the likeliest to take it, the least likely to die, the healthiest.
    public var assault: SiegeAssault?
    /// Visible enemy military units within 2 tiles of the city, outside it.
    public var enemiesNear: Int
}

/// A melee member's attack on a besieged city, with its preview.
public struct SiegeAssault: Hashable, Sendable {
    public var unit: UnitID
    public var preview: CombatPreview
}

extension PlayerView {
    /// The siege of the known enemy city at `city` by own units `members` (others are left
    /// out): who can shoot it now, who could storm it, what stands near. Nil when no city of a
    /// player at war with the player is known there.
    public func siegeOutlook(of members: [UnitID], at city: HexCoord) -> SiegeOutlook? {
        guard let goal = normalize(city), let sighting = knownCity(at: goal), isAtWar(with: sighting.owner) else { return nil }
        let units = members.compactMap { unit($0) }.filter { !$0.type.isCivilian }
        var shots: [(id: UnitID, strength: Int)] = []
        var assault: SiegeAssault?
        for unit in units {
            guard let option = attackOptions(for: unit.id).first(where: { $0.target == goal }), option.from == unit.position else { continue }
            let def = rules.unit(unit.type)
            if def.isRanged {
                if sighting.hp > 0 { shots.append((unit.id, def.rangedStrength)) }
                continue
            }
            guard let preview = combatPreview(attacker: .unit(unit.id), target: goal, from: unit.position) else { continue }
            func rank(_ a: SiegeAssault) -> (Int, Int, Int, Int, Int) {
                (a.preview.capturesCity ? 0 : 1, -a.preview.killPairs, a.preview.deathPairs, -(self.unit(a.unit)?.hp ?? 0), a.unit.rawValue)
            }
            let candidate = SiegeAssault(unit: unit.id, preview: preview)
            if assault.map({ rank(candidate) < rank($0) }) ?? true { assault = candidate }
        }
        let wallTiers = rules.buildings.map(\.wallHP).filter { $0 > 0 }
        let maxWall = sighting.walls || sighting.wallHP > 0 ? (wallTiers.filter { $0 >= sighting.wallHP }.min() ?? sighting.wallHP) : 0
        let near = visibleForeignUnits.filter {
            !$0.type.isCivilian && isAtWar(with: $0.owner) && $0.position != goal && distance($0.position, goal) <= 2
        }.count
        return SiegeOutlook(city: sighting, maxHP: rules.constants.city.maxHP, maxWallHP: maxWall,
                            shots: shots.sorted { ($0.strength, $1.id) > ($1.strength, $0.id) }.map(\.id),
                            assault: assault, enemiesNear: near)
    }
}
