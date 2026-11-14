// Minor factions (M2 §12): single-city players after the civs. Civs send them envoys for
// bonuses; the leading civ with enough envoys is their Patron, sharing their resources and
// sight and able to levy their army. They offer quests, defend themselves and never expand.

public enum MinorType: String, Codable, Hashable, Sendable, CaseIterable {
    case scientific, cultural, trade, militaristic, industrial
}

/// The data-driven minor faction tuning (M2 §12); nil in rules without minors.
public struct MinorRules: Codable, Hashable, Sendable {
    public let counts: [MinorCount]
    public let defaultCount: Int
    /// A minor's city is at least this far from every start and from every other minor.
    public let minStartDistance: Int
    public let minMinorDistance: Int
    public let startPopulation: Int
    public let startBuildings: [BuildingID]
    public let startUnits: [UnitType]
    /// MinorAI builds era units up to this many; era defenders replace the oldest above it.
    public let maxMilitary: Int
    /// Per era index: the units a minor of that world era builds (melee first, then ranged).
    public let eraUnits: [[UnitType]]
    public let patronMinEnvoys: Int
    public let levyGoldPerUnit: Int
    public let levyTurns: Int
    /// A new quest every `questInterval` turns, or when one is completed.
    public let questInterval: Int
    public let questBuildings: [BuildingID]
    /// A "clear the camp" quest names a camp within this distance of the minor's city.
    public let questCampRange: Int
    /// MinorAI accepts peace once a war is this old.
    public let peaceAfterTurns: Int
    public let types: [MinorTypeDef]

    public func count(mapSize: String) -> Int {
        counts.first { $0.mapSize == mapSize }?.count ?? defaultCount
    }

    public func units(era: Int) -> [UnitType] {
        eraUnits.isEmpty ? [] : eraUnits[max(0, min(era, eraUnits.count - 1))]
    }

    public func type(_ type: MinorType) -> MinorTypeDef? { types.first { $0.type == type } }
}

public struct MinorCount: Codable, Hashable, Sendable {
    public let mapSize: String
    public let count: Int
}

/// What a minor type gives the civs with envoys there (M2 §12.2).
public struct MinorTypeDef: Codable, Hashable, Sendable {
    public let type: MinorType
    /// "food", "production", "gold", "science" or "culture".
    public let yield: String
    /// Production bonuses count only while the city builds this: "units" or "buildings"
    /// (buildings and quarters).
    public let whileBuilding: String?
    public let tiers: [MinorTier]
    public let names: [String]
}

/// From `envoys` envoys: +`amount` in the capital (no `buildings`) or in every city with one
/// of `buildings`.
public struct MinorTier: Codable, Hashable, Sendable {
    public let envoys: Int
    public let amount: Int
    public let buildings: [BuildingID]?
}

public enum MinorQuestKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Clear the raider camp at `tile`.
    case clearCamp
    /// Complete `building` in a city.
    case building
    /// Have met `count` civs.
    case meetCivs
    /// Have `count` envoys at minors in all.
    case envoys
    /// Start a trade route to the minor (M2 §13).
    case trader
}

public struct MinorQuest: Codable, Hashable, Sendable {
    public var kind: MinorQuestKind
    public var tile: Int32?
    public var building: BuildingID?
    public var count: Int?
    public var issued: Int
}

/// The minor's military units serving `player` until turn `until` (M2 §12.2).
public struct Levy: Codable, Hashable, Sendable {
    public var player: PlayerID
    public var until: Int
    public var units: [UnitID]
}

/// One minor faction's standing with the civs.
public struct MinorFaction: Codable, Hashable, Sendable {
    public let player: PlayerID
    public let type: MinorType
    /// Envoys per player index.
    public internal(set) var envoys: [Int]
    public internal(set) var patron: PlayerID?
    /// The civ that met it first (got the free envoy).
    public internal(set) var firstMet: PlayerID?
    public internal(set) var quest: MinorQuest?
    public internal(set) var levy: Levy?
    public internal(set) var questsCompleted: Int?

    public func envoys(of player: PlayerID) -> Int {
        envoys.indices.contains(player.rawValue) ? envoys[player.rawValue] : 0
    }
}

extension GameState {
    public func isMinor(_ player: PlayerID) -> Bool {
        players.indices.contains(player.rawValue) && players[player.rawValue].kind == .minor
    }

    func minorIndex(of player: PlayerID) -> Int? {
        minors?.firstIndex { $0.player == player }
    }

    public func minor(_ player: PlayerID) -> MinorFaction? {
        minorIndex(of: player).map { minors![$0] }
    }

    /// Per player index: the civ whose Patron-ship covers it, or −1.
    func patronTable() -> [Int] {
        var table = [Int](repeating: -1, count: players.count)
        for m in minors ?? [] where players[m.player.rawValue].isAlive {
            if let p = m.patron { table[m.player.rawValue] = p.rawValue }
        }
        return table
    }

    /// Envoys `player` has at minors in all.
    public func envoysSent(by player: PlayerID) -> Int {
        (minors ?? []).reduce(0) { $0 + $1.envoys(of: player) }
    }

    /// The living minors whose Patron is `player`.
    public func patronages(of player: PlayerID) -> [PlayerID] {
        (minors ?? []).filter { $0.patron == player && players[$0.player.rawValue].isAlive }.map(\.player)
    }

    // MARK: Setup

    /// Sites for the minors' cities (M2 §12.1): passable land with room around it, at least
    /// `minStartDistance` from every start and `minMinorDistance` from each other.
    static func minorSites(map: HexMap, starts: [HexCoord], rules: Ruleset, seed: UInt64, count: Int) -> [Int] {
        guard let m = rules.minors, count > 0 else { return [] }
        let startTiles = starts.compactMap { map.index(of: $0) }
        var candidates: [Int] = []
        for t in 0..<map.tileCount {
            let tile = map.tiles[t]
            guard tile.isLand, rules.isPassable(tile), rules.isWorkable(tile),
                  startTiles.allSatisfy({ map.distance(index: t, $0) >= m.minStartDistance }) else { continue }
            let land = map.neighbors(of: map.coord(at: t)).count { n in
                map.index(of: n).map { map.tiles[$0].isLand && rules.isPassable(map.tiles[$0]) } ?? false
            }
            if land >= 4 { candidates.append(t) }
        }
        var rng = SplitMix64(seed: seed, salts: 0x3171)
        var sites: [Int] = []
        while sites.count < count {
            let open = candidates.filter { t in sites.allSatisfy { map.distance(index: t, $0) >= m.minMinorDistance } }
            guard let pick = rng.pick(open) else { break }
            sites.append(pick)
        }
        return sites
    }

    /// The minors' players for `sites`: types in a seeded order, names from each type's list.
    static func minorPlayers(sites: [Int], firstID: Int, rules: Ruleset, seed: UInt64, tileCount: Int) -> [(Player, MinorType)] {
        guard let m = rules.minors, !m.types.isEmpty else { return [] }
        var rng = SplitMix64(seed: seed, salts: 0x3171, 1)
        var order = m.types
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, rng.nextInt(below: i + 1)) }
        return sites.indices.map { i in
            let def = order[i % order.count]
            let name = def.names.isEmpty ? "Minor \(i + 1)" : def.names[(i / order.count) % def.names.count]
            return (Player(id: PlayerID(firstID + i), name: name, isHuman: false, tileCount: tileCount, kind: .minor), def.type)
        }
    }

    /// Founds each minor's city with its population, buildings and units (M2 §12.1).
    mutating func foundMinorCities(at sites: [Int], _ fx: inout Effects) {
        guard let m = rules.minors, let list = minors else { return }
        for (faction, t) in zip(list, sites) {
            let p = faction.player
            let id = foundCity(at: t, by: p, &fx)
            guard let i = cityIndex(id) else { continue }
            cities[i].name = players[p.rawValue].name
            cities[i].population = max(1, m.startPopulation)
            cities[i].loyalty = nil
            for b in m.startBuildings where !cities[i].has(b) {
                guard let def = rules.building(b) else { continue }
                cities[i].buildings.append(b)
                cities[i].buildings.sort()
                if def.wallHP > 0 { cities[i].wallHP = max(cities[i].wallHP, def.wallHP) }
            }
            assignCitizens(i)
            let centre = map.coord(at: t)
            for type in m.startUnits {
                if let spot = ([centre] + map.neighbors(of: centre)).first(where: { canEnd(type, owner: p, at: $0) && !holdsTribalVillage(map.index(of: $0)!) }) {
                    insertUnit(type, owner: p, at: spot)
                }
            }
        }
    }

    // MARK: Envoys and Patrons

    /// Why `player` may not send an envoy to `minor` now (nil: it may).
    public func envoyProblem(_ player: PlayerID, to minor: PlayerID) -> String? {
        guard players[player.rawValue].isMajor else { return "only civs send envoys" }
        guard isMinor(minor), players[minor.rawValue].isAlive else { return "not a minor faction" }
        guard hasMet(player, minor) else { return "you have not met \(players[minor.rawValue].name)" }
        guard !isAtWar(player, minor) else { return "at war with \(players[minor.rawValue].name)" }
        guard (players[player.rawValue].envoyTokens ?? 0) > 0 else { return "no envoy tokens" }
        return nil
    }

    /// `sendEnvoy` (validated by the caller).
    mutating func sendEnvoy(_ player: PlayerID, to minor: PlayerID, _ fx: inout Effects) {
        guard let i = minorIndex(of: minor) else { return }
        players[player.rawValue].envoyTokens = max(0, (players[player.rawValue].envoyTokens ?? 0) - 1)
        addEnvoys(i, player, 1, &fx)
    }

    mutating func addEnvoys(_ i: Int, _ player: PlayerID, _ n: Int, _ fx: inout Effects) {
        let p = player.rawValue
        guard minors![i].envoys.indices.contains(p) else { return }
        minors![i].envoys[p] += n
        fx.emit(.envoySent(player: player, minor: minors![i].player, envoys: minors![i].envoys[p]), .owner(player))
        fx.touchPlayer(player)
        updatePatron(i, raised: player, &fx)
    }

    /// The Patron (M2 §12.2): the most envoys, at least `patronMinEnvoys`; a tie keeps the
    /// one who reached the count first. `raised` just gained envoys.
    mutating func updatePatron(_ i: Int, raised: PlayerID?, _ fx: inout Effects) {
        guard let m = rules.minors else { return }
        let faction = minors![i]
        let old = faction.patron
        var new = old
        if let r = raised, faction.envoys(of: r) >= m.patronMinEnvoys,
           old.map({ faction.envoys(of: r) > faction.envoys(of: $0) }) ?? true {
            new = r
        }
        if let current = new, faction.envoys(of: current) < m.patronMinEnvoys || !players[current.rawValue].isAlive
            || faction.envoys.indices.contains(where: { faction.envoys[$0] > faction.envoys(of: current) }) {
            new = nil
        }
        if new == nil {
            var best = m.patronMinEnvoys - 1
            for p in faction.envoys.indices where players[p].isAlive && faction.envoys[p] > best {
                best = faction.envoys[p]
                new = PlayerID(p)
            }
        }
        guard new != old else { return }
        minors![i].patron = new
        if let levy = faction.levy, levy.player != new { endLevy(i, &fx) }
        for p in [old, new].compactMap({ $0 }) { fx.touchPlayer(p) }
        fx.touchPlayer(faction.player)
        fx.emit(.patronChanged(minor: faction.player, patron: new), .everyone)
    }

    /// The first civ to meet a minor gets an envoy there (M2 §12.2).
    mutating func minorMet(_ a: PlayerID, _ b: PlayerID, _ fx: inout Effects) {
        let (civ, minor) = isMinor(a) ? (b, a) : (a, b)
        guard players[civ.rawValue].isMajor, let i = minorIndex(of: minor), minors![i].firstMet == nil else { return }
        minors![i].firstMet = civ
        addEnvoys(i, civ, 1, &fx)
    }

    /// Declaring war on a minor costs every envoy there and ends a levy to the declarer.
    mutating func minorWarDeclared(by player: PlayerID, on minor: PlayerID, _ fx: inout Effects) {
        guard let i = minorIndex(of: minor) else { return }
        if minors![i].levy?.player == player { endLevy(i, &fx) }
        if minors![i].envoys(of: player) > 0 {
            minors![i].envoys[player.rawValue] = 0
            updatePatron(i, raised: nil, &fx)
        }
    }

    // MARK: Levy

    /// The minor's military units a levy takes: all but the city's garrison.
    func levyable(_ minor: PlayerID) -> [Int] {
        let centre = cities.first { $0.owner == minor }?.position
        return units.indices.filter { units[$0].owner == minor && !units[$0].type.isCivilian && units[$0].position != centre }
    }

    func levyCost(of minor: PlayerID) -> Int {
        guard let m = rules.minors else { return 0 }
        return m.levyGoldPerUnit * levyable(minor).count
    }

    public func levyProblem(_ player: PlayerID, on minor: PlayerID) -> String? {
        guard let m = self.minor(minor), players[minor.rawValue].isAlive else { return "not a minor faction" }
        guard m.patron == player else { return "only the Patron may levy" }
        guard m.levy == nil else { return "already levied" }
        let cost = levyCost(of: minor)
        guard cost > 0 else { return "no units to levy" }
        guard players[player.rawValue].gold >= cost else { return "needs \(cost) gold" }
        return nil
    }

    /// `levy` (validated by the caller): the minor's military units serve `player`.
    mutating func levy(_ player: PlayerID, on minor: PlayerID, _ fx: inout Effects) {
        guard let i = minorIndex(of: minor), let m = rules.minors else { return }
        players[player.rawValue].gold -= levyCost(of: minor)
        var ids: [UnitID] = []
        for u in levyable(minor) {
            units[u].owner = player
            units[u].destination = nil
            units[u].activity = .none
            ids.append(units[u].id)
            fx.touchTile(map.index(of: units[u].position)!)
        }
        minors![i].levy = Levy(player: player, until: turn + m.levyTurns, units: ids)
        fx.touchPlayer(player)
        fx.touchPlayer(minor)
        fx.emit(.levied(minor: minor, player: player, units: ids.count), .pair(player, minor))
    }

    /// Living levied units go home to the minor's city (or are disbanded when it has no room).
    mutating func endLevy(_ i: Int, _ fx: inout Effects) {
        guard let levy = minors![i].levy else { return }
        let minor = minors![i].player
        minors![i].levy = nil
        guard players[minor.rawValue].isAlive, let city = cities.first(where: { $0.owner == minor }) else { return }
        for id in levy.units {
            guard let u = unit(id), u.owner == levy.player else { continue }
            fx.touchTile(map.index(of: u.position)!)
            guard let t = spawnTile(for: u.type, in: city) else {
                removeUnit(id)
                continue
            }
            fx.touchTile(t)
            let hex = map.coord(at: t)
            updateUnit(id) { u in
                u.owner = minor
                u.position = hex
                u.destination = nil
                u.activity = .none
            }
        }
        fx.touchPlayer(levy.player)
        fx.touchPlayer(minor)
        fx.emit(.levyEnded(minor: minor, player: levy.player), .pair(levy.player, minor))
    }

    // MARK: Phases

    /// The minor's phase start: a due levy returns; quests are checked and issued.
    mutating func runMinor(_ player: PlayerID, _ fx: inout Effects) {
        guard let i = minorIndex(of: player) else { return }
        if let levy = minors![i].levy, turn >= levy.until || isAtWar(levy.player, player) { endLevy(i, &fx) }
        checkQuests(i, &fx)
    }

    /// When the world era advances: each minor gets one melee and one ranged unit of the era,
    /// removing its oldest military units above `maxMilitary` (M2 §12.1).
    mutating func giveMinorsEraDefenders(_ fx: inout Effects) {
        guard let m = rules.minors, let list = minors else { return }
        let types = Array(m.units(era: worldEra ?? 0).prefix(2))
        for faction in list where players[faction.player.rawValue].isAlive && faction.levy == nil {
            let p = faction.player
            guard let city = cities.first(where: { $0.owner == p }) else { continue }
            for type in types {
                guard let t = spawnTile(for: type, in: city) else { continue }
                let id = insertUnit(type, owner: p, at: map.coord(at: t))
                fx.emit(.unitCreated(unit: id, type: type, owner: p, at: map.coord(at: t)), .tiles([t]))
            }
            let military = units.filter { $0.owner == p && !$0.type.isCivilian }
            for u in military.prefix(max(0, military.count - m.maxMilitary)) {
                fx.touchTile(map.index(of: u.position)!)
                removeUnit(u.id)
            }
            fx.touchPlayer(p)
        }
    }

    // MARK: Quests

    /// Civs who have met minor `i`, in player order.
    private func questTakers(_ i: Int) -> [PlayerID] {
        let minor = minors![i].player
        return players.filter { $0.isAlive && $0.isMajor && hasMet($0.id, minor) && !isAtWar($0.id, minor) }.map(\.id)
    }

    func civsMet(by player: PlayerID) -> Int {
        players.count { $0.id != player && $0.isMajor && hasMet(player, $0.id) }
    }

    mutating func checkQuests(_ i: Int, _ fx: inout Effects) {
        guard let m = rules.minors else { return }
        if let quest = minors![i].quest {
            switch quest.kind {
            case .clearCamp:
                if let t = quest.tile, !holdsRaiderCamp(Int(t)) { minors![i].quest = nil }
            case .meetCivs:
                if let p = questTakers(i).first(where: { civsMet(by: $0) >= quest.count ?? 0 }) { completeQuest(i, by: p, &fx) }
            case .envoys:
                if let p = questTakers(i).first(where: { envoysSent(by: $0) >= quest.count ?? 0 }) { completeQuest(i, by: p, &fx) }
            case .building, .trader:
                break
            }
            if let q = minors![i].quest, turn - q.issued >= m.questInterval { minors![i].quest = nil }
        }
        if minors![i].quest == nil { issueQuest(i) }
    }

    mutating func issueQuest(_ i: Int) {
        guard let m = rules.minors, let city = cities.first(where: { $0.owner == minors![i].player }) else { return }
        let takers = questTakers(i)
        guard !takers.isEmpty else { return }
        let centre = map.index(of: city.position)!
        var options: [MinorQuest] = []
        if let camp = raiderCamps.map({ Int($0.tile) }).filter({ map.distance(index: $0, centre) <= m.questCampRange })
            .min(by: { (map.distance(index: $0, centre), $0) < (map.distance(index: $1, centre), $1) }) {
            options.append(MinorQuest(kind: .clearCamp, tile: Int32(camp), issued: turn))
        }
        for b in m.questBuildings where rules.building(b) != nil {
            options.append(MinorQuest(kind: .building, building: b, issued: turn))
        }
        let majors = players.count(where: \.isMajor)
        let met = 1 + takers.map(civsMet(by:)).max()!
        if met <= majors - 1 { options.append(MinorQuest(kind: .meetCivs, count: met, issued: turn)) }
        if rules.trade != nil { options.append(MinorQuest(kind: .trader, issued: turn)) }
        options.append(MinorQuest(kind: .envoys, count: 1 + takers.map(envoysSent(by:)).max()!, issued: turn))
        var rng = SplitMix64(seed: seed, salts: UInt64(turn), UInt64(i), UInt64(minors![i].questsCompleted ?? 0), 0x3172)
        minors![i].quest = rng.pick(options)
    }

    mutating func completeQuest(_ i: Int, by player: PlayerID, _ fx: inout Effects) {
        let minor = minors![i].player
        minors![i].quest = nil
        minors![i].questsCompleted = (minors![i].questsCompleted ?? 0) + 1
        fx.emit(.questCompleted(minor: minor, player: player), .pair(player, minor))
        addEnvoys(i, player, 1, &fx)
        issueQuest(i)
    }

    /// A city of `player` completed `building`: it may finish "build" quests.
    mutating func buildingCompletedForQuests(_ building: BuildingID, by player: PlayerID, _ fx: inout Effects) {
        guard let list = minors else { return }
        for i in list.indices where list[i].quest?.kind == .building && list[i].quest?.building == building
            && players[list[i].player.rawValue].isAlive && questTakers(i).contains(player) {
            completeQuest(i, by: player, &fx)
        }
    }

    /// `player` started a route to `minor`: it may finish its "send a Trader" quest.
    mutating func tradeRouteStartedForQuests(to minor: PlayerID, by player: PlayerID, _ fx: inout Effects) {
        guard let i = minorIndex(of: minor), minors![i].quest?.kind == .trader, questTakers(i).contains(player) else { return }
        completeQuest(i, by: player, &fx)
    }

    /// `player` cleared the camp at `t`: it may finish "clear the camp" quests.
    mutating func campClearedForQuests(_ t: Int, by player: PlayerID, _ fx: inout Effects) {
        guard let list = minors else { return }
        for i in list.indices where list[i].quest?.kind == .clearCamp && list[i].quest?.tile == Int32(t) {
            if players[list[i].player.rawValue].isAlive, questTakers(i).contains(player) {
                completeQuest(i, by: player, &fx)
            } else {
                minors![i].quest = nil
            }
        }
    }

    // MARK: Bonuses

    /// The envoy bonuses a civ's city gets (M2 §12.2).
    public func envoyYields(_ city: City) -> Yields {
        guard let list = minors, let m = rules.minors, players[city.owner.rawValue].isMajor else { return .zero }
        var total = Yields.zero
        let isCapital = players[city.owner.rawValue].capital == city.id
        let head = city.queue.first?.item
        for faction in list where players[faction.player.rawValue].isAlive {
            let n = faction.envoys(of: city.owner)
            guard n > 0, let def = m.type(faction.type) else { continue }
            switch def.whileBuilding {
            case "units": guard case .unit? = head else { continue }
            case "buildings":
                switch head {
                case .building?, .quarter?: break
                default: continue
                }
            default: break
            }
            var amount = 0
            for tier in def.tiers where n >= tier.envoys {
                if let buildings = tier.buildings {
                    if buildings.contains(where: city.has) { amount += tier.amount }
                } else if isCapital {
                    amount += tier.amount
                }
            }
            guard amount > 0 else { continue }
            switch def.yield {
            case "food": total.food += amount
            case "production": total.production += amount
            case "gold": total.gold += amount
            case "science": total.science += amount
            default: total.culture += amount
            }
        }
        return total
    }
}
