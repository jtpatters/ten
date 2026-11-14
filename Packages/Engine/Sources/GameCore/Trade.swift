// Trade routes (M2 §13): a Trader in its owner's territory starts a route to a city within
// range along tiles its owner has explored. The Trader leaves the map; the route lays roads on
// its land tiles, starts paying when the Trader would arrive, lasts `routeTurns`, then the Trader
// comes home to the origin city. An enemy (or raider) military unit on a route tile plunders it.

/// The data-driven trade tuning (M2 §13); nil in rules without trade.
public struct TradeRules: Codable, Hashable, Sendable {
    public let routeRange: Int
    /// Sea routes: +`seaRangeBonus` range over water once the owner knows `seaTech`, between two
    /// cities with a `seaQuarter`.
    public let seaRangeBonus: Int
    public let seaTech: TechID
    public let seaQuarter: QuarterKind
    public let routeTurns: Int
    /// Capacity: base + one per city with each building + one per civic and tech known +
    /// the `tradeRoutes` bonus.
    public let capacityBase: Int
    public let capacityBuildings: [BuildingID]
    public let capacityCivics: [CivicID]
    public let capacityTechs: [TechID]
    public let domesticFood: Int
    public let domesticProduction: Int
    public let domesticFoodBuildings: [BuildingID]
    public let domesticProductionBuildings: [BuildingID]
    public let internationalGold: Int
    public let internationalGoldBuildings: [BuildingID]
    /// +`internationalScience` when the destination's owner knows this many techs the origin's does not.
    public let scienceTechGap: Int
    public let internationalScience: Int
    public let destinationGold: Int
    public let minorGold: Int
    /// A route to a minor gives an envoy there every this many turns.
    public let minorEnvoyTurns: Int
    public let plunderGold: Int
    public let traderCaptureGold: Int
}

public enum TradeRouteKind: String, Codable, Hashable, Sendable {
    case domestic, international, minor
}

public struct TradeRoute: Codable, Hashable, Sendable {
    public let id: Int
    public let owner: PlayerID
    public let origin: CityID
    public let destination: CityID
    public let kind: TradeRouteKind
    /// Tiles from the origin (excluded) to the destination centre.
    public let path: [Int32]
    /// Pays from this turn (the Trader's arrival) until `ends`.
    public let arrives: Int
    public let ends: Int
}

extension GameState {
    /// Routes running or under way, by id.
    public var allTradeRoutes: [TradeRoute] { tradeRoutes ?? [] }

    public func tradeRoutes(of player: PlayerID) -> [TradeRoute] {
        allTradeRoutes.filter { $0.owner == player }
    }

    public func tradeCapacity(of player: PlayerID) -> Int {
        guard let t = rules.trade else { return 0 }
        let p = players[player.rawValue]
        let buildings = cities.reduce(0) { n, city in
            city.owner == player ? n + t.capacityBuildings.count(where: city.has) : n
        }
        return t.capacityBase + buildings + t.capacityCivics.count(where: p.knowsCivic) + t.capacityTechs.count(where: p.knows)
            + bonus(\.tradeRoutes, for: player)
    }

    /// The own city a Trader at `hex` starts from: the city whose territory it stands in.
    func tradeOrigin(at hex: HexCoord, for player: PlayerID) -> City? {
        guard let t = map.index(of: hex), let city = owningCity(ofTile: t), city.owner == player else { return nil }
        return city
    }

    func routeKind(to city: City, from player: PlayerID) -> TradeRouteKind {
        city.owner == player ? .domestic : (isMinor(city.owner) ? .minor : .international)
    }

    /// The shortest path along tiles `player` has explored, at most the route range long.
    func tradePath(from origin: City, to destination: City, for player: PlayerID) -> [Int]? {
        guard let t = rules.trade else { return nil }
        let start = map.index(of: origin.position)!, goal = map.index(of: destination.position)!
        let sea = players[player.rawValue].knows(t.seaTech) && quarter(t.seaQuarter, of: origin) != nil
            && quarter(t.seaQuarter, of: destination) != nil
        let range = t.routeRange + (sea ? t.seaRangeBonus : 0)
        let explored = players[player.rawValue].explored
        var parent = [Int32](repeating: -1, count: map.tileCount)
        var depth = [Int16](repeating: -1, count: map.tileCount)
        depth[start] = 0
        var frontier = [start]
        while !frontier.isEmpty, depth[goal] < 0 {
            var next: [Int] = []
            for c in frontier where Int(depth[c]) < range {
                for n in map.neighbors(of: map.coord(at: c)) {
                    guard let i = map.index(of: n), depth[i] < 0, explored[i] else { continue }
                    let tile = map.tiles[i]
                    guard tile.isLand ? rules.isPassable(tile) : sea else { continue }
                    depth[i] = depth[c] + 1
                    parent[i] = Int32(c)
                    next.append(i)
                }
            }
            frontier = next
        }
        guard depth[goal] > 0 else { return nil }
        var path = [goal]
        while Int(parent[path.last!]) != start { path.append(Int(parent[path.last!])) }
        return path.reversed()
    }

    /// Why `unit` may not start a route to city `destination` (nil: it may).
    public func tradeRouteProblem(_ unit: Unit, to destination: CityID) -> String? {
        guard rules.trade != nil, unit.type == .trader else { return "only Traders start trade routes" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        let player = unit.owner
        guard let origin = tradeOrigin(at: unit.position, for: player) else { return "a Trader starts in its own territory" }
        guard let city = city(destination), city.id != origin.id,
              city.owner == player || players[player.rawValue].memory.cities.contains(where: { $0.id == destination })
        else { return "no such city" }
        if city.owner != player {
            let other = players[city.owner.rawValue]
            guard other.isMajor || other.kind == .minor else { return "no trade with \(other.name)" }
            guard hasMet(player, city.owner), !isAtWar(player, city.owner) else { return "not at peace with \(other.name)" }
        }
        guard tradeRoutes(of: player).count < tradeCapacity(of: player) else { return "no trade route capacity left" }
        guard tradePath(from: origin, to: city, for: player) != nil else { return "out of reach" }
        return nil
    }

    /// `startTradeRoute` (validated by the caller).
    mutating func startTradeRoute(_ id: UnitID, to destination: CityID, _ fx: inout Effects) {
        guard let t = rules.trade, let unit = unit(id), let origin = tradeOrigin(at: unit.position, for: unit.owner),
              let city = city(destination), let path = tradePath(from: origin, to: city, for: unit.owner) else { return }
        let moves = max(1, rules.unit(unit.type).moves)
        let arrives = turn + max(1, (path.count + moves - 1) / moves)
        let routeID = nextRouteID ?? 1
        nextRouteID = routeID + 1
        let route = TradeRoute(id: routeID, owner: unit.owner, origin: origin.id, destination: destination,
                               kind: routeKind(to: city, from: unit.owner), path: path.map(Int32.init),
                               arrives: arrives, ends: arrives + t.routeTurns)
        tradeRoutes = allTradeRoutes + [route]
        fx.touchTile(map.index(of: unit.position)!)
        removeUnit(id)
        if rules.roads != nil {
            for tile in path where map.tiles[tile].isLand && !map.tiles[tile].hasRoad {
                layRoad(tile)
                fx.touchTile(tile)
            }
        }
        fx.touchPlayer(unit.owner)
        fx.emit(.tradeRouteStarted(route: routeID, owner: unit.owner, from: origin.id, to: destination),
                .ownerAndTiles(unit.owner, [map.index(of: city.position)!]))
        if route.kind == .minor { tradeRouteStartedForQuests(to: city.owner, by: unit.owner, &fx) }
    }

    /// Ends route `index`: the Trader comes home to the origin city unless plundered or the
    /// origin is lost (or full).
    mutating func endTradeRoute(_ index: Int, plunderedBy: PlayerID?, _ fx: inout Effects) {
        let route = tradeRoutes![index]
        tradeRoutes!.remove(at: index)
        if tradeRoutes!.isEmpty { tradeRoutes = nil }
        if plunderedBy == nil, let origin = city(route.origin), origin.owner == route.owner,
           let t = spawnTile(for: .trader, in: origin) {
            let id = insertUnit(.trader, owner: route.owner, at: map.coord(at: t), movesLeft: 0)
            fx.emit(.unitCreated(unit: id, type: .trader, owner: route.owner, at: map.coord(at: t)), .tiles([t]))
        }
        fx.touchPlayer(route.owner)
        fx.emit(.tradeRouteEnded(route: route.id, owner: route.owner, plunderedBy: plunderedBy), .owner(route.owner))
    }

    /// The owner's phase start: routes that ran out, lost their cities or now cross a war end;
    /// routes to minors give their envoys.
    mutating func runTrade(for player: PlayerID, _ fx: inout Effects) {
        guard let t = rules.trade, tradeRoutes != nil else { return }
        var i = 0
        while let routes = tradeRoutes, i < routes.count {
            let route = routes[i]
            guard route.owner == player else { i += 1; continue }
            let origin = city(route.origin), destination = city(route.destination)
            let broken = origin?.owner != player || destination == nil
                || destination.map { $0.owner != player && (isAtWar(player, $0.owner) || routeKind(to: $0, from: player) != route.kind) } == true
            if turn >= route.ends || broken {
                endTradeRoute(i, plunderedBy: nil, &fx)
                continue
            }
            if route.kind == .minor, turn > route.arrives, (turn - route.arrives) % max(1, t.minorEnvoyTurns) == 0,
               let d = destination, let m = minorIndex(of: d.owner) {
                addEnvoys(m, player, 1, &fx)
            }
            i += 1
        }
    }

    /// Why `unit` may not plunder a route where it stands (nil: it may).
    public func plunderProblem(_ unit: Unit) -> String? {
        guard rules.trade != nil, rules.unit(unit.type).isMilitary else { return "only military units plunder" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        let t = Int32(map.index(of: unit.position)!)
        guard allTradeRoutes.contains(where: { $0.path.contains(t) && isAtWar(unit.owner, $0.owner) }) else {
            return "no enemy trade route here"
        }
        return nil
    }

    /// `plunder` (validated by the caller): the lowest-id enemy route here ends; Gold; all moves.
    mutating func plunder(by id: UnitID, _ fx: inout Effects) {
        guard let t = rules.trade, let unit = unit(id) else { return }
        let tile = Int32(map.index(of: unit.position)!)
        guard let i = allTradeRoutes.firstIndex(where: { $0.path.contains(tile) && isAtWar(unit.owner, $0.owner) }) else { return }
        players[unit.owner.rawValue].gold += t.plunderGold
        updateUnit(id) { $0.movesLeft = 0 }
        fx.touchTile(Int(tile))
        fx.touchPlayer(unit.owner)
        endTradeRoute(i, plunderedBy: unit.owner, &fx)
    }

    /// What `city` gets from the routes it starts and, for international routes, ends.
    public func tradeYields(_ city: City) -> Yields {
        guard let t = rules.trade, let routes = tradeRoutes else { return .zero }
        var y = Yields.zero
        let owner = city.owner
        for r in routes where turn >= r.arrives {
            if r.origin == city.id, r.owner == owner, let d = self.city(r.destination) {
                switch r.kind {
                case .domestic:
                    y.food += t.domesticFood + t.domesticFoodBuildings.count(where: d.has)
                    y.production += t.domesticProduction + t.domesticProductionBuildings.count(where: d.has)
                case .international:
                    y.gold += t.internationalGold + t.internationalGoldBuildings.count(where: d.has)
                    let theirs = players[d.owner.rawValue].knownTechs
                    if theirs.count(where: { !players[owner.rawValue].knows($0) }) >= t.scienceTechGap { y.science += t.internationalScience }
                    y.science += bonus(\.intlTradeScience, for: owner)
                    y.culture += bonus(\.intlTradeCulture, for: owner)
                case .minor:
                    y.gold += t.minorGold
                }
                y.gold += bonus(\.tradeRouteGold, for: owner)
            } else if r.destination == city.id, r.kind == .international, r.owner != owner {
                y.gold += t.destinationGold
            }
        }
        return y
    }

    /// A Trader's estimated value per turn for a route to `destination` (AI and UI).
    public func tradeRouteValue(_ unit: Unit, to destination: CityID) -> Int {
        guard let t = rules.trade, let origin = tradeOrigin(at: unit.position, for: unit.owner),
              let d = city(destination) else { return 0 }
        switch routeKind(to: d, from: unit.owner) {
        case .domestic:
            return 2 * (t.domesticFood + t.domesticFoodBuildings.count(where: d.has))
                + 2 * (t.domesticProduction + t.domesticProductionBuildings.count(where: d.has))
                - (origin.id == d.id ? 100 : 0)
        case .international:
            return t.internationalGold + t.internationalGoldBuildings.count(where: d.has) + 2
        case .minor:
            return t.minorGold + 2
        }
    }
}
