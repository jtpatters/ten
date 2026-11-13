// Read-only queries for the App's route messages (M1 §16): why an own unit has no route to a tile,
// so a refused route or a stopped march can say why. Built only from what the player knows, as
// the pathfinder plans (M1 §8.6): explored ground, remembered borders and cities, foreign units on
// tiles it sees now; unexplored tiles count as passable land.

/// Why an own unit cannot be routed to a tile, most telling first.
public enum RouteRefusal: Hashable, Sendable {
    /// Ground no land unit enters.
    public enum Ground: Hashable, Sendable {
        case water, mountains, ice
    }

    /// The goal is explored ground no land unit enters.
    case impassable(Ground)
    /// A foreign city stands there: units never enter one (at war it is attacked, M1 §8.6).
    case foreignCity(CityID)
    /// The goal is land of a player at peace with this one: closed to military units (M1 §9).
    case closedBorders(PlayerID)
    /// A foreign unit in sight stands there (and is no lone enemy civilian to capture).
    case foreignUnit(owner: PlayerID, type: UnitType)
    /// An own unit of the same kind holds the goal: one military and one civilian unit per tile
    /// (a city's garrison, say).
    case ownUnitThere(UnitType)
    /// No land route leads there through the ground the player knows (water or mountains in
    /// between).
    case noLandRoute
    /// Every way there crosses land closed to military units at peace: these owners', by id.
    case closedBordersOnTheWay([PlayerID])
    /// Units or cities block every way there, or it has nowhere to stop on the way.
    case blocked
}

extension PlayerView {
    /// Whether `owner`'s land is closed to this player's military units: at peace (M1 §9).
    public func landClosed(by owner: PlayerID) -> Bool {
        state.bordersClosed(to: player, by: owner)
    }

    /// Why an own unit has no route to `hex` (nil when it has one, or already stands there), by
    /// this player's knowledge, as `path(for:to:)` plans.
    public func routeRefusal(for id: UnitID, to hex: HexCoord) -> RouteRefusal? {
        guard let unit = state.unit(id), unit.owner == player, let goal = normalize(hex), goal != unit.position,
              let g = index(of: goal), let start = index(of: unit.position), path(for: id, to: goal) == nil else { return nil }
        let military = !unit.type.isCivilian
        // The goal itself.
        if me.explored[g] {
            let tile = state.map.tiles[g]
            if tile.terrain.isWater { return .impassable(.water) }
            if !rules.elevation(tile.elevation).passable { return .impassable(.mountains) }
            if !rules.feature(tile.feature).passable { return .impassable(.ice) }
        }
        if let city = knownCity(at: goal), city.owner != player { return .foreignCity(city.id) }
        if military, let owner = knownOwner(at: goal), owner != player, state.bordersClosed(to: player, by: owner) {
            return .closedBorders(owner)
        }
        let here = units(at: goal)
        // Foreign units in sight block it, except enemy civilians a military unit captures.
        let blockers = here.filter { $0.owner != player && (!$0.type.isCivilian || !(military && isAtWar(with: $0.owner))) }
        if let blocker = blockers.first(where: { !$0.type.isCivilian }) ?? blockers.first {
            return .foreignUnit(owner: blocker.owner, type: blocker.type)
        }
        if let own = here.first(where: { $0.owner == player && $0.id != id && $0.type.isCivilian == unit.type.isCivilian }) {
            return .ownUnitThere(own.type)
        }
        // The way there: over the land the player knows, then through the borders open to it.
        if !knownLandReaches(from: start, to: g, closedLand: false, military: military) { return .noLandRoute }
        if military {
            var touched: [PlayerID] = []
            if !knownLandReaches(from: start, to: g, closedLand: true, military: true, closedOwners: &touched) {
                return .closedBordersOnTheWay(touched)
            }
        }
        return .blocked
    }

    /// Whether `goal` can be reached from `start` over passable land as this player knows it
    /// (unexplored tiles count as land), units and cities aside; with `closedLand`, not through
    /// land closed to its military units either.
    private func knownLandReaches(from start: Int, to goal: Int, closedLand: Bool, military: Bool) -> Bool {
        var owners: [PlayerID] = []
        return knownLandReaches(from: start, to: goal, closedLand: closedLand, military: military, closedOwners: &owners)
    }

    /// As above; `closedOwners` gets the owners (by id) of the closed land met at the edge of the
    /// land reached.
    private func knownLandReaches(from start: Int, to goal: Int, closedLand: Bool, military: Bool,
                                  closedOwners: inout [PlayerID]) -> Bool {
        let map = state.map
        var seen = [Bool](repeating: false, count: map.tileCount)
        var queue = [start]
        seen[start] = true
        var head = 0
        var owners: [PlayerID] = []
        func closed(_ t: Int) -> PlayerID? {
            guard closedLand, military, let owner = knownOwner(at: map.coord(at: t)), owner != player,
                  state.bordersClosed(to: player, by: owner) else { return nil }
            return owner
        }
        while head < queue.count {
            let t = queue[head]
            head += 1
            var found = false
            map.forEachNeighbor(of: t) { n, _ in
                guard !seen[n], !me.explored[n] || rules.isPassable(map.tiles[n]) else { return }
                if let owner = closed(n) {
                    if !owners.contains(owner) { owners.append(owner) }
                    return
                }
                if n == goal { found = true }
                seen[n] = true
                queue.append(n)
            }
            if found { return true }
        }
        closedOwners = owners.sorted()
        return false
    }
}

/// How far a planned route rests on unexplored ground, which the pathfinder counts as passable
/// land at one move each (M1 §8.6): its turn count is then a guess, and an unexplored goal may
/// turn out to be water, mountains or a foreign city.
public enum RouteFog: Hashable, Sendable {
    /// The goal itself is unexplored.
    case goal
    /// The goal is explored, but the way there crosses unexplored tiles.
    case way
}

extension PlayerView {
    /// Whether `path` (planned by this player) crosses or ends on unexplored tiles; nil when it
    /// runs over explored ground only.
    public func routeFog(_ path: Path) -> RouteFog? {
        guard let goal = path.destination else { return nil }
        if !isExplored(goal) { return .goal }
        return path.steps.contains { !isExplored($0.hex) } ? .way : nil
    }
}
