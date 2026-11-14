public enum Terrain: UInt8, Codable, Sendable, CaseIterable {
    case grassland, plains, desert, tundra, snow, coast, ocean, lake

    public var isWater: Bool {
        switch self {
        case .coast, .ocean, .lake: true
        default: false
        }
    }
}

public enum Elevation: UInt8, Codable, Sendable, CaseIterable {
    case flat, hills, mountains
}

public enum Feature: UInt8, Codable, Sendable, CaseIterable {
    case none, forest, jungle, marsh, floodplain, oasis, reef, ice

    /// Features that slow land movement.
    public var isRough: Bool {
        switch self {
        case .forest, .jungle, .marsh: true
        default: false
        }
    }
}

/// A tile improvement built by a Builder (M1 §4). Raw values are append-only: memory and
/// renderer inputs store them per tile (0 = none).
public enum Improvement: UInt8, Codable, Hashable, Sendable, CaseIterable {
    case farm = 1, mine = 2, pasture = 3
    // M2 §4.1.
    case quarry = 4, plantation = 5, camp = 6, fishingBoats = 7, lumberMill = 8
}

/// A map resource (M2 §3.1). Raw values are append-only (saves and renderer inputs store them).
public enum Resource: UInt8, Codable, Hashable, Sendable, CaseIterable {
    case wheat = 1, rice, cattle, sheep, deer, stone, fish, bananas
    case wine, silk, spices, incense, ivory, furs, salt, pearls
    case horses, iron
}

public struct Tile: Codable, Hashable, Sendable {
    public var terrain: Terrain
    public var elevation: Elevation
    public var feature: Feature
    /// Bitmask of `HexDirection` edges that carry a river (bit n = rawValue n).
    public var riverEdges: UInt8
    public var improvement: Improvement?
    /// Placed by MapGen; never changes (M2 §3.1). Nil = none (left out of saves).
    public var resource: Resource?

    public init(terrain: Terrain, elevation: Elevation = .flat, feature: Feature = .none, riverEdges: UInt8 = 0,
                improvement: Improvement? = nil, resource: Resource? = nil) {
        self.terrain = terrain
        self.elevation = elevation
        self.feature = feature
        self.riverEdges = riverEdges
        self.improvement = improvement
        self.resource = resource
    }

    public var isLand: Bool { !terrain.isWater }

    /// Movement points needed for a land unit to enter, or nil if impassable.
    public var landMovementCost: Int? {
        if terrain.isWater || elevation == .mountains { return nil }
        var cost = 1
        if elevation == .hills { cost += 1 }
        if feature.isRough { cost += 1 }
        return cost
    }
}
