import GameCore

/// An own unit on the App's Explore order when its game was saved (M1 §16). The order is the
/// App's, not a rule, so it lives in the save's header (`SaveSummary.explorers`) beside the game.
/// `knownEnemies`: enemy military units in its sight that do not end the order (they were there
/// when it was given).
public struct SavedExplorer: Codable, Hashable, Sendable {
    public var unit: UnitID
    public var knownEnemies: [UnitID]

    public init(unit: UnitID, knownEnemies: [UnitID] = []) {
        self.unit = unit
        self.knownEnemies = knownEnemies
    }

    private enum CodingKeys: String, CodingKey {
        case unit, knownEnemies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(UnitID.self, forKey: .unit)
        knownEnemies = try c.decodeIfPresent([UnitID].self, forKey: .knownEnemies) ?? []
    }
}
