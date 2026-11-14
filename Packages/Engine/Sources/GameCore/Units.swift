public struct UnitID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (a: UnitID, b: UnitID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "u\(rawValue)" }
}

/// A unit type. Stays an enum (each type has its own procedural art); its numbers live in the
/// rules data, keyed by case name (M1 §7, §12.2): `state.rules.unit(type)`. The order is fixed:
/// art and data follow it.
public enum UnitType: String, Codable, Sendable, CaseIterable {
    case settler, builder, scout, warrior, archer, spearman
    // M2 §8.1 (appended; naval units, the Trader and unique units come later).
    case horseman, heavyChariot, swordsman, catapult, manAtArms, crossbowman, pikeman, knight, trebuchet
    // M2 §8.4 (appended).
    case galley, quadrireme, cog, dromon

    /// Hard-coded; rules validation checks it matches the data's unit class.
    public var isCivilian: Bool {
        switch self {
        case .settler, .builder: true
        case .scout, .warrior, .archer, .spearman: false
        case .horseman, .heavyChariot, .swordsman, .catapult, .manAtArms, .crossbowman, .pikeman, .knight, .trebuchet: false
        case .galley, .quadrireme, .cog, .dromon: false
        }
    }

    /// Hard-coded; rules validation checks it matches the data's unit class.
    public var isNaval: Bool {
        switch self {
        case .galley, .quadrireme, .cog, .dromon: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .heavyChariot: "Heavy Chariot"
        case .manAtArms: "Man-at-Arms"
        default: rawValue.capitalized
        }
    }
}

/// What a unit is doing besides moving (M1 §7.4). Moving or attacking clears it.
public enum UnitActivity: String, Codable, Hashable, Sendable {
    case none, fortifying, fortified, sleeping, skipped
}

public struct Unit: Codable, Hashable, Sendable {
    public let id: UnitID
    public let owner: PlayerID
    public var type: UnitType
    public var position: HexCoord
    public var movesLeft: Int
    /// Remaining multi-turn move order, continued automatically at the owner's phase start.
    public var destination: HexCoord?
    public var hp: Int
    public var activity: UnitActivity
    /// Movement ended by an enemy's zone of control this phase (it may still attack).
    public var zocStopped: Bool
    /// Experience; tracked, no effect in M1.
    public var xp: Int
    /// Builder charges left.
    public var charges: Int
    /// The turn the unit last moved or attacked (healing, M1 §7.5); 0 = never.
    public var lastActedTurn: Int
    /// Promotions taken, in order (M2 §8.3); nil = none.
    public var promotions: [String]?
    /// Attacked this phase, for units that may move after attacking (M2 §8.3); nil = no.
    public var attacked: Bool?

    /// A fresh unit: full HP, no orders or activity. Moves and charges come from the rules
    /// (`GameState.addUnit` fills them in).
    public init(id: UnitID, owner: PlayerID, type: UnitType, position: HexCoord, movesLeft: Int, charges: Int = 0, hp: Int = 100) {
        self.id = id
        self.owner = owner
        self.type = type
        self.position = position
        self.movesLeft = movesLeft
        self.destination = nil
        self.hp = hp
        self.activity = .none
        self.zocStopped = false
        self.xp = 0
        self.charges = charges
        self.lastActedTurn = 0
        self.promotions = nil
        self.attacked = nil
    }
}
