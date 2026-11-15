import GameCore

/// The App's war orders when its game was saved (docs/M2.md §4.3): the cities' rally points,
/// where the military units they produce march, and the marches under way, each unit with the
/// goal its group was sent to and its own place there. Like the Explore order they are the
/// App's, not rules, so they live in the save's header (`SaveSummary.war`) beside the game.
public struct SavedWarOrders: Codable, Hashable, Sendable {
    public var rallies: [SavedRally]
    public var marches: [SavedMarch]

    public init(rallies: [SavedRally] = [], marches: [SavedMarch] = []) {
        self.rallies = rallies
        self.marches = marches
    }

    public var isEmpty: Bool { rallies.isEmpty && marches.isEmpty }

    private enum CodingKeys: String, CodingKey { case rallies, marches }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rallies = try c.decodeIfPresent([SavedRally].self, forKey: .rallies) ?? []
        marches = try c.decodeIfPresent([SavedMarch].self, forKey: .marches) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !rallies.isEmpty { try c.encode(rallies, forKey: .rallies) }
        if !marches.isEmpty { try c.encode(marches, forKey: .marches) }
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
