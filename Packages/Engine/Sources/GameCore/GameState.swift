import Foundation

public struct PlayerID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (a: PlayerID, b: PlayerID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "p\(rawValue)" }
}

/// One player: civ, treasury, research and knowledge (M1 §12.3). `players[i].id == PlayerID(i)`.
/// M2 §12.5, §20: the Free Cities are a fixed non-player faction after the civs.
public enum PlayerKind: String, Codable, Hashable, Sendable {
    case major, free, raiders, minor
}

public struct Player: Codable, Hashable, Sendable {
    public let id: PlayerID
    public var name: String
    public var isHuman: Bool
    public var civ: CivID
    public internal(set) var isAlive: Bool
    public var gold: Int
    /// The tech science goes into (nil: science accumulates as overflow, M1 §6).
    public internal(set) var researching: TechID?
    /// The tech `setResearch` asked for; `researching` walks its missing prerequisites first.
    public internal(set) var researchTarget: TechID?
    /// Science toward `researching` (or banked overflow while nothing is being researched).
    public internal(set) var researchProgress: Int
    /// Sorted by id.
    public internal(set) var knownTechs: [TechID]
    /// The player's first city (domination counts these), nil until they found one.
    public internal(set) var originalCapital: CityID?
    /// The city with the player's Palace.
    public internal(set) var capital: CityID?
    /// Every tile ever visible.
    public var explored: TileBitSet
    /// Tiles visible now (M1 §11): within each own unit's sight, within the city sight of each
    /// own city centre, and every owned tile. Kept up to date after every command.
    public internal(set) var visible: TileBitSet
    /// What the player remembers of the world (M1 §11).
    public internal(set) var memory: PlayerMemory
    /// `GameState.phaseCount` when the player's latest phase started (0 before the first).
    public internal(set) var lastPhaseStart: Int
    /// Cities named so far (picks the next name from the civ's list).
    public internal(set) var citiesNamed: Int
    /// Credit toward each tech from Insights and the world era's catch-up (M2 §2, §6.2), in tree
    /// order; a tech needs `cost − credit` science. Nil until the first credit (left out of saves).
    public internal(set) var techCredit: [Int]?
    /// Techs whose Insight fired, sorted. Nil until the first (left out of saves).
    public internal(set) var insights: [TechID]?
    /// Strategic stockpiles in `Resource.allCases` order (M2 §3.1). Nil until the first
    /// (left out of saves).
    public internal(set) var stockpile: [Int]?
    /// What kind of player this is (M2 §12.5); nil is a major civ (left out of saves).
    public internal(set) var kind: PlayerKind?
    /// The civic Culture goes into (M2 §7.1); nil: Culture banks as progress.
    public internal(set) var studying: CivicID?
    /// The civic `setCivic` asked for; `studying` walks its missing prerequisites first.
    public internal(set) var civicTarget: CivicID?
    /// Culture toward `studying` (or banked). Nil until the first (left out of saves).
    public internal(set) var civicProgress: Int?
    /// Completed civics, sorted. Nil until the first (left out of saves).
    public internal(set) var knownCivics: [CivicID]?
    /// Civics whose Insight fired, sorted. Nil until the first (left out of saves).
    public internal(set) var civicInsights: [CivicID]?
    /// nil: the rules' default government (M2 §7.2).
    public internal(set) var government: String?
    /// Sorted; governments adopted at least once (the default is implied).
    public internal(set) var governmentsAdopted: [String]?
    /// Slotted policy ids.
    public internal(set) var policies: [String]?
    /// The turn a civic last completed: government and policy changes are free on it.
    public internal(set) var freeChangeTurn: Int?
    /// Influence toward the next envoy token (M2 §4.3).
    public internal(set) var influence: Int?
    public internal(set) var envoyTokens: Int?
    public internal(set) var envoysEarned: Int?

    /// A civ that takes phases, researches and can win; not the Free Cities.
    public var isMajor: Bool { kind == nil || kind == .major }
    /// Takes phases: the civs and the raiders (M2 §11); not the Free Cities.
    public var takesPhases: Bool { isMajor || kind == .raiders || kind == .minor }

    /// A new, living player with nothing yet. An empty `civ` is filled in by `GameState.init`.
    public init(id: PlayerID, name: String, isHuman: Bool, tileCount: Int, civ: CivID = "", gold: Int = 0,
                kind: PlayerKind? = nil) {
        self.id = id
        self.name = name
        self.isHuman = isHuman
        self.civ = civ
        self.isAlive = true
        self.gold = gold
        self.researching = nil
        self.researchTarget = nil
        self.researchProgress = 0
        self.knownTechs = []
        self.originalCapital = nil
        self.capital = nil
        self.explored = TileBitSet(count: tileCount)
        self.visible = TileBitSet(count: tileCount)
        self.memory = PlayerMemory(tileCount: tileCount)
        self.lastPhaseStart = 0
        self.citiesNamed = 0
        self.techCredit = nil
        self.insights = nil
        self.stockpile = nil
        self.kind = kind
    }

    public func knows(_ tech: TechID) -> Bool { knownTechs.contains(tech) }

    /// Units of a strategic resource in stock (M2 §3.1).
    public func stock(_ resource: Resource) -> Int { stockpile?[Int(resource.rawValue) - 1] ?? 0 }

    /// Credit toward the tech at tree index `index` (M2 §6.2).
    public func credit(techIndex index: Int) -> Int {
        guard let credit = techCredit, credit.indices.contains(index) else { return 0 }
        return credit[index]
    }

    /// Whether the tech's Insight has fired for this player.
    public func hasInsight(_ tech: TechID) -> Bool { insights?.contains(tech) ?? false }
}

/// The complete simulation state. A value type: copying is cheap until mutated.
///
/// Invariants (checked by `checkInvariants()`): `units` and `cities` are sorted by id; every
/// collection is an array (no `Set` or `Dictionary` anywhere), so encoding and hashing are
/// deterministic; `players[i].id == PlayerID(i)`; `relations` holds one entry per pair i < j in
/// pair order.
public struct GameState: Codable, Hashable, Sendable {
    public let seed: UInt64
    /// The rules this game plays by, stored by identity (`RulesRef`).
    public let rulesRef: RulesRef
    /// The map size the game was made with ("duel", "small", …), for saves and the AI.
    public let mapSizeName: String
    /// Numbered from 1; one phase per living player (M1 §3).
    public internal(set) var turn: Int
    /// Whose phase it is. Only this player may issue commands.
    public internal(set) var currentPlayer: PlayerID
    /// Phases started so far (the first phase of the game is 1).
    public internal(set) var phaseCount: Int
    public var map: HexMap
    public var players: [Player]
    public internal(set) var units: [Unit]
    public internal(set) var nextUnitID: Int
    /// Sorted by id.
    public internal(set) var cities: [City]
    public internal(set) var nextCityID: Int
    /// Territory: per tile, the owning city's id + 1 (0 = unowned).
    public internal(set) var tileCity: [Int32]
    /// One per player pair i < j, in pair order (0-1, 0-2, …, 1-2, …).
    public internal(set) var relations: [Relation]
    /// Set when the game is over; every command is then rejected.
    public internal(set) var outcome: GameOutcome?
    /// The tribal villages still standing and the gifts given (M1 §7.7); nil in a game without
    /// them, so the key is absent from saves and the state hash. Internal: players learn of
    /// them only through their memory (`PlayerView.knownTribalVillages`).
    var tribalVillages: TribalVillageState?
    /// Raider camps and rebels (M2 §11); nil in a game without raiders.
    public internal(set) var raiders: RaiderState?
    /// Minor factions (M2 §12), in player order; nil in a game without them.
    public internal(set) var minors: [MinorFaction]?
    /// Trade routes by id (M2 §13); nil while there are none.
    public internal(set) var tradeRoutes: [TradeRoute]?
    public internal(set) var nextRouteID: Int?
    /// The world era's index (M2 §2); nil in a game whose rules have no eras (left out of saves).
    public internal(set) var worldEra: Int?

    public var rules: Ruleset { rulesRef.rules }

    /// A state at turn 1, phase 1 (`players[0]`'s), with no units or cities. Players with an
    /// empty civ get the rules' civs in order (skipping civs already taken). Prefer `newGame`.
    public init(seed: UInt64, map: HexMap, players: [Player], rules: Ruleset = .standard, mapSizeName: String = "") {
        precondition(players.indices.allSatisfy { players[$0].id == PlayerID($0) }, "players[i].id must be PlayerID(i)")
        precondition(players.count <= 16, "event audiences hold 16 players")
        self.seed = seed
        self.rulesRef = RulesRef(rules: rules)
        self.mapSizeName = mapSizeName.isEmpty ? "\(map.width)x\(map.height)" : mapSizeName
        self.turn = 1
        self.currentPlayer = PlayerID(0)
        self.phaseCount = 1
        self.map = map
        var players = players
        var free = rules.civs.map(\.id).filter { civ in !players.contains { $0.civ == civ } }
        for i in players.indices where players[i].civ.rawValue.isEmpty && players[i].isMajor {
            players[i].civ = free.isEmpty ? rules.civs[i % rules.civs.count].id : free.removeFirst()
        }
        if !players.isEmpty { players[0].lastPhaseStart = 1 }
        self.players = players
        self.units = []
        self.nextUnitID = 1
        self.cities = []
        self.nextCityID = 1
        self.tileCity = Array(repeating: 0, count: map.tileCount)
        var relations: [Relation] = []
        for i in players.indices {
            for j in players.indices where j > i {
                var relation = Relation(PlayerID(i), PlayerID(j))
                if [players[i].kind, players[j].kind].contains(where: { $0 == .free || $0 == .raiders }) { relation.stance = .war }
                relations.append(relation)
            }
        }
        self.relations = relations
        self.outcome = nil
        self.tribalVillages = nil
        self.worldEra = rules.eras.isEmpty ? nil : 0
    }

    /// Creates a game (M1 §2): one player per start position, civs in order (or `civs`), each
    /// with the rules' starting units and gold, all at peace and unmet. Player 0's first phase
    /// has started. With `placeTribalVillages`, and rules that have them, tribal villages are
    /// placed after the start units and before the first knowledge update (M1 §7.7), so those
    /// in a start's sight are known on turn 1.
    public static func newGame(seed: UInt64, map: HexMap, startPositions: [HexCoord], humanPlayers: Set<Int> = [0],
                               rules: Ruleset = .standard, civs: [CivID]? = nil, mapSizeName: String = "",
                               placeTribalVillages: Bool = false, placeMinors: Bool = false) -> GameState {
        var players = startPositions.indices.map { i -> Player in
            let civ = civs.flatMap { i < $0.count ? $0[i] : nil } ?? rules.civs[i % rules.civs.count].id
            let name = rules.civ(civ)?.name ?? "Player \(i + 1)"
            return Player(id: PlayerID(i), name: name, isHuman: humanPlayers.contains(i), tileCount: map.tileCount,
                          civ: civ, gold: rules.constants.start.gold)
        }
        let minorSites = placeMinors ? minorSites(map: map, starts: startPositions, rules: rules, seed: seed,
                                                  count: rules.minors?.count(mapSize: mapSizeName) ?? 0) : []
        let minorPlayers = minorPlayers(sites: minorSites, firstID: players.count, rules: rules, seed: seed, tileCount: map.tileCount)
        players += minorPlayers.map(\.0)
        if rules.raiders != nil {
            players.append(Player(id: PlayerID(players.count), name: "Raiders", isHuman: false,
                                  tileCount: map.tileCount, kind: .raiders))
        }
        if rules.loyalty != nil {
            players.append(Player(id: PlayerID(players.count), name: "Free Cities", isHuman: false,
                                  tileCount: map.tileCount, kind: .free))
        }
        var state = GameState(seed: seed, map: map, players: players, rules: rules, mapSizeName: mapSizeName)
        if rules.raiders != nil { state.raiders = RaiderState() }
        var setupFx = Effects()
        if !minorPlayers.isEmpty {
            state.minors = minorPlayers.map { MinorFaction(player: $0.0.id, type: $0.1, envoys: [Int](repeating: 0, count: players.count)) }
            state.foundMinorCities(at: minorSites, &setupFx)
        }
        for (i, start) in startPositions.enumerated() {
            let owner = PlayerID(i)
            for type in rules.constants.start.units {
                // The start tile first (one military and one civilian unit), then its neighbors.
                let spot = ([start] + map.neighbors(of: start)).first { state.canEnd(type, owner: owner, at: $0) }
                if let spot { state.insertUnit(type, owner: owner, at: spot) }
            }
        }
        // Tribal villages (M1 §7.7): placed after the start units and before the first knowledge
        // update, so those in a start's sight are known on turn 1. Rules without the section
        // place none, and the state stays exactly as without the flag.
        if placeTribalVillages, let villageRules = rules.tribalVillages {
            var placer = TribalVillagePlacer(state: state, startPositions: startPositions, rules: villageRules)
            var villages = TribalVillageState(players: state.players.count)
            for pick in placer.place() { villages.insert(pick.tile) }
            state.tribalVillages = villages
        }
        var fx = Effects()
        fx.touchAllPlayers(state.players.count)
        state.updateKnowledge(&fx)
        return state
    }

    /// Civs for a new game: the human's pick first, then the AIs take the others in rules order.
    public static func civOrder(human: CivID, players: Int, rules: Ruleset = .standard) -> [CivID] {
        let others = rules.civs.map(\.id).filter { $0 != human }
        return Array(([human] + others).prefix(players))
    }

    // MARK: Units

    /// Adds a fresh unit (moves and charges from the rules) and updates everyone's knowledge.
    /// A debug and test entry point: the engine creates units through production. A tribal
    /// village on the tile is removed, with no gift (M1 §7.7: no unit stands on one), and every
    /// player who sees the tile forgets it.
    @discardableResult
    public mutating func addUnit(_ type: UnitType, owner: PlayerID, at position: HexCoord) -> UnitID {
        let id = insertUnit(type, owner: owner, at: position)
        var fx = Effects()
        if let t = map.index(of: position), tribalVillages?.remove(t) == true { fx.touchTile(t) }
        fx.touchPlayer(owner)
        updateKnowledge(&fx)
        return id
    }

    /// Appends a unit without touching knowledge (the caller updates it).
    @discardableResult
    mutating func insertUnit(_ type: UnitType, owner: PlayerID, at position: HexCoord, movesLeft: Int? = nil,
                             charges: Int? = nil) -> UnitID {
        let def = rules.unit(type)
        let extraCharges = def.charges > 0 ? bonus(\.builderCharges, for: owner) + bonus(\.newBuilderCharges, for: owner) : 0
        let id = UnitID(nextUnitID)
        nextUnitID += 1
        units.append(Unit(id: id, owner: owner, type: type, position: map.normalize(position)!,
                          movesLeft: movesLeft ?? def.moves * rules.movePoints, charges: charges ?? def.charges + extraCharges, hp: rules.constants.healing.maxHP))
        return id
    }

    mutating func removeUnit(_ id: UnitID) {
        if let i = unitIndex(id) { units.remove(at: i) }
    }

    public func unitIndex(_ id: UnitID) -> Int? {
        // Sorted by ID, so binary search.
        var lo = 0, hi = units.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if units[mid].id == id { return mid }
            if units[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public func unit(_ id: UnitID) -> Unit? {
        unitIndex(id).map { units[$0] }
    }

    mutating func updateUnit(_ id: UnitID, _ change: (inout Unit) -> Void) {
        guard let i = unitIndex(id) else { return }
        change(&units[i])
    }

    public func units(at hex: HexCoord) -> [Unit] {
        units.filter { $0.position == hex }
    }

    public func units(of player: PlayerID) -> [Unit] {
        units.filter { $0.owner == player }
    }

    /// One military and one civilian unit per tile; tiles with foreign units or a foreign city
    /// are blocked, and land units stand only on passable land (M1 §5, §8.6).
    public func canEnd(_ type: UnitType, owner: PlayerID, at hex: HexCoord, ignoring: UnitID? = nil) -> Bool {
        guard let index = map.index(of: hex), rules.isPassable(map.tiles[index]) else { return false }
        let hex = map.coord(at: index)
        for other in units where other.position == hex && other.id != ignoring {
            if other.owner != owner { return false }
            if other.type.isCivilian == type.isCivilian { return false }
        }
        if let city = city(atTile: index), city.owner != owner { return false }
        return true
    }

    // MARK: Cities and territory

    func cityIndex(_ id: CityID) -> Int? {
        var lo = 0, hi = cities.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cities[mid].id == id { return mid }
            if cities[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public func city(_ id: CityID) -> City? {
        cityIndex(id).map { cities[$0] }
    }

    public func cities(of player: PlayerID) -> [City] {
        cities.filter { $0.owner == player }
    }

    /// The city whose centre is `hex`.
    public func city(at hex: HexCoord) -> City? {
        map.index(of: hex).flatMap(city(atTile:))
    }

    /// The city whose centre is tile `index`.
    func city(atTile index: Int) -> City? {
        let code = tileCity[index]
        guard code != 0, let city = city(CityID(Int(code) - 1)), map.index(of: city.position) == index else { return nil }
        return city
    }

    /// The city owning tile `index`.
    func owningCity(ofTile index: Int) -> City? {
        let code = tileCity[index]
        return code == 0 ? nil : city(CityID(Int(code) - 1))
    }

    /// The player owning tile `index`.
    public func tileOwner(_ index: Int) -> PlayerID? {
        owningCity(ofTile: index)?.owner
    }

    /// Per city id (index = id), its owner's raw value or −1: a quick territory lookup.
    func cityOwnerTable() -> [Int] {
        var table = [Int](repeating: -1, count: nextCityID)
        for city in cities { table[city.id.rawValue] = city.owner.rawValue }
        return table
    }

    /// Per tile: owner code (0 = none, else player + 1), as memory stores it.
    func territoryCodes() -> [UInt8] {
        let owners = cityOwnerTable()
        return tileCity.map { $0 == 0 ? 0 : UInt8(owners[Int($0) - 1] + 1) }
    }

    // MARK: Players

    /// Living major players, in player order (not the Free Cities).
    public var livingPlayers: [PlayerID] { players.filter { $0.isAlive && $0.isMajor }.map(\.id) }

    /// The Free Cities faction (M2 §12.5), when the rules have Loyalty.
    public var freeCities: PlayerID? { players.last.flatMap { $0.kind == .free ? $0.id : nil } }

    // MARK: Visibility

    /// Tile indices currently visible to a player (stored, M1 §11).
    public func visibleTiles(for player: PlayerID) -> TileBitSet {
        guard players.indices.contains(player.rawValue) else { return TileBitSet(count: map.tileCount) }
        return players[player.rawValue].visible
    }

    // MARK: Hashing

    /// Stable 64-bit hash of the full state (M1 §12.7): FNV-1a over the synthesized encoding
    /// (keys, integers and strings in encoding order, `StableHash`), no JSON. Same seed + same
    /// commands must always produce the same hash, in any process, on any OS version.
    public func stateHash() -> UInt64 {
        StableHash.of(self)
    }
}
