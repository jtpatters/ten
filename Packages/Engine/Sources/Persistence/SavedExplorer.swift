import GameCore

/// An own unit on one of the App's standing orders when its game was saved: the Explore order
/// (M1 §16), or the Automate order of a Builder (`automated`). The orders are the App's, not
/// rules, so they live in the save's header (`SaveSummary.explorers`) beside the game.
/// `knownEnemies`: enemy military units in an explorer's sight that do not end its order (they
/// were there when it was given).
public struct SavedExplorer: Codable, Hashable, Sendable {
    public var unit: UnitID
    public var knownEnemies: [UnitID]
    /// The unit is a Builder on the Automate order, not an explorer. Stored only when true, so
    /// headers without automated Builders are unchanged (an older reader would take the entry
    /// for an explorer and drop it, as it drops any civilian there).
    public var automated: Bool

    public init(unit: UnitID, knownEnemies: [UnitID] = [], automated: Bool = false) {
        self.unit = unit
        self.knownEnemies = knownEnemies
        self.automated = automated
    }

    private enum CodingKeys: String, CodingKey {
        case unit, knownEnemies, automated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(UnitID.self, forKey: .unit)
        knownEnemies = try c.decodeIfPresent([UnitID].self, forKey: .knownEnemies) ?? []
        automated = try c.decodeIfPresent(Bool.self, forKey: .automated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unit, forKey: .unit)
        try c.encode(knownEnemies, forKey: .knownEnemies)
        if automated { try c.encode(true, forKey: .automated) }
    }
}
