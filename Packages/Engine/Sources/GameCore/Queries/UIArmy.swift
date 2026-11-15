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
        // The tiles, by ring, then nearest the group's side: out to the ring that holds a place
        // for every unit and two spare, leaving out tiles held by other own military units.
        let group = Set(units.map(\.id))
        let held = Set(self.units.filter { !$0.type.isCivilian && !group.contains($0.id) }.map(\.position))
        var candidates: [HexCoord] = []
        for ring in 1...Self.formationReach {
            candidates = coords(within: ring, of: goal).filter { !reserved.contains($0) && !held.contains($0) }
            if candidates.count >= units.count + 2 { break }
        }
        candidates.sort { a, b in
            let ka = (distance(a, goal), distance(a, vanguard.position), index(of: a) ?? 0)
            let kb = (distance(b, goal), distance(b, vanguard.position), index(of: b) ?? 0)
            return ka < kb
        }
        // Units already in place: on one of the tiles the group needs.
        var taken = Set<HexCoord>()
        let needed = Set(candidates.prefix(units.count))
        var waiting: [Unit] = []
        for unit in units {
            if needed.contains(unit.position) {
                plan.slots[unit.id] = unit.position
                plan.turns[unit.id] = 0
                taken.insert(unit.position)
            } else {
                waiting.append(unit)
            }
        }
        for unit in waiting {
            var tries = 0
            var placed = false
            for tile in candidates where !taken.contains(tile) {
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
