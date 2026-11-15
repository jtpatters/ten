import GameCore

/// The App's war orders when its game was saved (docs/M2.md §4.3): the cities' rally points,
/// where the military units they produce march, and the marches under way, each unit with the
/// goal its group was sent to and its own place there, and the sieges under way. Like the Explore order they are the
/// App's, not rules, so they live in the save's header (`SaveSummary.war`) beside the game.
public struct SavedWarOrders: Codable, Hashable, Sendable {
    public var rallies: [SavedRally]
    public var marches: [SavedMarch]
    /// Sieges under way (absent from saves made before sieges: none).
    public var sieges: [SavedSiege]

    public init(rallies: [SavedRally] = [], marches: [SavedMarch] = [], sieges: [SavedSiege] = []) {
        self.rallies = rallies
        self.marches = marches
        self.sieges = sieges
    }

    public var isEmpty: Bool { rallies.isEmpty && marches.isEmpty && sieges.isEmpty }

    private enum CodingKeys: String, CodingKey { case rallies, marches, sieges }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rallies = try c.decodeIfPresent([SavedRally].self, forKey: .rallies) ?? []
        marches = try c.decodeIfPresent([SavedMarch].self, forKey: .marches) ?? []
        sieges = try c.decodeIfPresent([SavedSiege].self, forKey: .sieges) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !rallies.isEmpty { try c.encode(rallies, forKey: .rallies) }
        if !marches.isEmpty { try c.encode(marches, forKey: .marches) }
        if !sieges.isEmpty { try c.encode(sieges, forKey: .sieges) }
    }
}

/// A siege: the enemy city (by id and tile) and the own units holding it.
public struct SavedSiege: Codable, Hashable, Sendable {
    public var city: CityID
    public var tile: HexCoord
    public var units: [UnitID]

    public init(city: CityID, tile: HexCoord, units: [UnitID]) {
        self.city = city
        self.tile = tile
        self.units = units
    }
}

/// A city's rally point: the tile its new military units march to.
public struct SavedRally: Codable, Hashable, Sendable {
    public var city: CityID
    public var tile: HexCoord

    public init(city: CityID, tile: HexCoord) {
        self.city = city
        self.tile = tile
    }
}

/// A unit on the march: the goal its group was sent to, and its place there (`slot`).
public struct SavedMarch: Codable, Hashable, Sendable {
    public var unit: UnitID
    public var target: HexCoord
    public var slot: HexCoord

    public init(unit: UnitID, target: HexCoord, slot: HexCoord) {
        self.unit = unit
        self.target = target
        self.slot = slot
    }
}
