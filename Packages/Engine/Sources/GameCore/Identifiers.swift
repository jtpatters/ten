// Identifiers and small value types shared by commands, events, the state and the rules data
// (M1 §12). Everything here is Codable with a stable encoding: saves and `stateHash()` see it.

// MARK: Cities

public struct CityID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (a: CityID, b: CityID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "c\(rawValue)" }
}

// MARK: Rules data IDs

// Buildings, techs and civs are defined by the rules data, so their IDs are strings (the
// data's keys). Each encodes as a plain JSON string and orders by its raw value.

public struct TechID: Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (a: TechID, b: TechID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

public struct BuildingID: Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (a: BuildingID, b: BuildingID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

public struct CivID: Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (a: CivID, b: CivID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

/// A quarter kind (M2 §5.3), defined by the rules' `quarters` section.
public struct QuarterKind: Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (a: QuarterKind, b: QuarterKind) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

// MARK: Cities' production and focus

/// An entry of a city's production queue (M1 §5).
public enum ProductionItem: Hashable, Codable, Sendable {
    case unit(UnitType)
    case building(BuildingID)
    /// A quarter on a tile fixed when queued (M2 §5.3).
    case quarter(QuarterKind, at: HexCoord)
}

/// How a city's citizens pick the tiles they work (M1 §4).
public enum CityFocus: String, Codable, Hashable, Sendable, CaseIterable {
    case balanced, food, production, gold, science, culture
}

// MARK: Combat

/// Either side of a fight (M1 §8.4): a unit or a city.
public enum Combatant: Hashable, Codable, Sendable {
    case unit(UnitID)
    case city(CityID)
}

// MARK: Victory

public enum VictoryKind: String, Codable, Hashable, Sendable {
    case domination, lastStanding, score
}

/// How a game ended (M1 §10): a player's victory, or the defeat of every human player.
public enum GameOutcome: Hashable, Codable, Sendable {
    case victory(player: PlayerID, kind: VictoryKind)
    case defeat
}
