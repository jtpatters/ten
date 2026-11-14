/// An entry of a city's production queue with the production put into it (M1 §5). A waiting
/// item keeps its progress, up to its cost.
public struct QueueEntry: Codable, Hashable, Sendable {
    public var item: ProductionItem
    public var progress: Int
    /// A quarter's cost, fixed when queued (M2 §5.3); nil: the rules' cost.
    public var cost: Int?

    public init(_ item: ProductionItem, progress: Int = 0, cost: Int? = nil) {
        self.item = item
        self.progress = progress
        self.cost = cost
    }
}

/// A quarter of a city (M2 §5.3).
public struct CityQuarter: Codable, Hashable, Sendable {
    public var kind: QuarterKind
    public var tile: HexCoord
    public var pillaged: Bool?

    public init(kind: QuarterKind, tile: HexCoord) {
        self.kind = kind
        self.tile = tile
    }

    public var isPillaged: Bool { pillaged == true }
}

/// A city (M1 §5, §12.3).
public struct City: Codable, Hashable, Sendable, Identifiable {
    public let id: CityID
    public var name: String
    public var owner: PlayerID
    public let originalOwner: PlayerID
    public let position: HexCoord
    public var population: Int
    public var foodStore: Int
    /// Up to `maxQueue` items, each with its own progress.
    public var queue: [QueueEntry]
    /// Production not yet in any item: it goes to the next item that receives production.
    public var storedProgress: Int
    /// Sorted by id (the Palace included).
    public var buildings: [BuildingID]
    public var cultureStore: Int
    /// Tiles gained from culture (the next tile costs `borderThreshold(tilesGained:)`).
    public var tilesGained: Int
    public var focus: CityFocus
    public var hp: Int
    public var wallHP: Int
    public let foundedTurn: Int
    /// `GameState.phaseCount` when the city was last attacked (0 = never).
    public var lastAttackedPhase: Int
    /// The city has bombarded this phase.
    public var bombarded: Bool
    /// Tiles the citizens work, sorted by tile index (the centre is not listed).
    public var workedTiles: [HexCoord]
    /// The turn the city last changed hands (nil = never).
    public var capturedTurn: Int?
    /// Stability as of the owner's last phase start (M2 §5.2); nil without Stability rules or
    /// before the first.
    public var stability: Int?
    /// Built quarters in build order (M2 §5.3); nil when none.
    public var quarters: [CityQuarter]?
    /// Loyalty 0–100 (M2 §5.5); nil without Loyalty rules.
    public var loyalty: Int?
    /// A Free City's leading civ by pressure and for how many consecutive turns (M2 §5.5).
    public var freeCityLeader: PlayerID?
    public var freeCityTurns: Int?
    /// Tiles bought with Gold (M2 §7.4); nil = none.
    public var tilesBought: Int?

    init(id: CityID, name: String, owner: PlayerID, position: HexCoord, turn: Int, hp: Int) {
        self.id = id
        self.name = name
        self.owner = owner
        self.originalOwner = owner
        self.position = position
        self.population = 1
        self.foodStore = 0
        self.queue = []
        self.storedProgress = 0
        self.buildings = []
        self.cultureStore = 0
        self.tilesGained = 0
        self.focus = .balanced
        self.hp = hp
        self.wallHP = 0
        self.foundedTurn = turn
        self.lastAttackedPhase = 0
        self.bombarded = false
        self.workedTiles = []
        self.capturedTurn = nil
        self.stability = nil
    }

    public func has(_ building: BuildingID) -> Bool { buildings.contains(building) }

    /// Items in the queue, in order.
    public var queuedItems: [ProductionItem] { queue.map(\.item) }
}
