import Foundation

/// The rules a game plays by (M1 §12.2): immutable data loaded once and shared by every state
/// that uses it. Identity is `id` (a hand-bumped string such as "m1.1") plus `contentHash`:
/// FNV-1a 64 over the canonical re-encoding of the decoded data (`StableHash`: the synthesized
/// encoding in declaration order, no JSON), so the file's formatting and key order never
/// change it, and neither do OS updates.
///
/// Every number of the game lives here (`Sources/GameCore/Rules/ruleset.json`). The JSON uses
/// arrays (never keyed maps) and integers only (ratios are percentages). Enum-keyed tables
/// (`Terrain`, `Elevation`, `Feature`, `Improvement`, `UnitType`, `CityFocus`) name each case
/// and are indexed here by the case's position; validation on load checks that every case has
/// exactly one definition, that every reference resolves, that the tech graph is acyclic and in
/// tree order, that numbers are in range and that `UnitType.isCivilian` matches the data.
public final class Ruleset: Sendable, Hashable, CustomStringConvertible {
    public let id: String
    public let contentHash: UInt64
    /// The decoded data.
    let data: RulesetData

    /// Indexed by `Terrain.rawValue`.
    public let terrains: [TerrainDef]
    /// Indexed by `Elevation.rawValue`.
    public let elevations: [ElevationDef]
    /// Indexed by `Feature.rawValue`.
    public let features: [FeatureDef]
    public let river: RiverDef
    /// In `Improvement.allCases` order.
    public let improvements: [ImprovementDef]
    /// In `UnitType.allCases` order.
    public let units: [UnitDef]
    /// In data order (the Palace included).
    public let buildings: [BuildingDef]
    /// In tree order: every tech comes after its prerequisites.
    public let techs: [TechDef]
    /// In data order (the order AIs take them in).
    public let civs: [CivDef]
    /// In `CityFocus.allCases` order.
    public let focuses: [FocusDef]
    public let constants: RuleConstants
    /// AI tuning (M1 §13).
    public let ai: AIRules
    /// Tribal villages (M1 §7.7); nil when the rules have no such section, and then a game has
    /// none.
    public let tribalVillages: TribalVillageRules?
    /// The building a player's capital has (free in the first city).
    public let palace: BuildingDef
    /// In order (M2 §2); empty in rules without eras.
    public let eras: [EraDef]
    /// Per tech index: its era's index (0 without eras).
    public let techEras: [Int]
    /// Insights and the world era (M2 §2, §6.2); nil in rules without them.
    public let progression: ProgressionRules?
    /// Promotions and the XP each tier needs (M2 §8.3); empty without the sections.
    public let promotions: [PromotionDef]
    public let promotionXP: [Int]
    /// In `Resource.allCases` order (M2 §3.1); empty without the section.
    public let resources: [ResourceDef]
    /// Strategic stockpiles (M2 §3.1); nil without the section.
    public let stockpile: StockpileRules?
    /// Roads and pillage (M2 §3.3); nil without the section.
    public let roads: RoadRules?
    /// Internal move points per move: every move and move cost is multiplied by it (M2 §3.3).
    public var movePoints: Int { roads?.movePoints ?? 1 }
    /// Embarking and naval units (M2 §8.4); nil without the section.
    public let embark: EmbarkRules?

    /// Per tech index: indices of its direct prerequisites.
    let techRequires: [[Int]]
    /// Per improvement ordinal, per (terrain, elevation, feature) combination: may it be built?
    private let improvementSites: [[Bool]]

    /// The bundled rules (`Sources/GameCore/Rules/ruleset.json`), loaded on first use.
    public static let standard: Ruleset = {
        guard let url = Bundle.module.url(forResource: "ruleset", withExtension: "json", subdirectory: "Rules") else {
            preconditionFailure("GameCore resource Rules/ruleset.json is missing from the bundle")
        }
        do {
            return try Ruleset(jsonData: Data(contentsOf: url))
        } catch {
            preconditionFailure("Rules/ruleset.json failed to load: \(error)")
        }
    }()

    /// Decodes rules data (JSON), validates it and fingerprints it.
    public convenience init(jsonData: Data) throws {
        try self.init(data: JSONDecoder().decode(RulesetData.self, from: jsonData))
    }

    /// Validates decoded rules data and builds the lookup tables.
    init(data: RulesetData) throws {
        let problems = data.validationProblems()
        guard problems.isEmpty else { throw RulesValidationError(problems: problems) }

        self.id = data.id
        self.contentHash = StableHash.of(data)
        self.data = data

        // Validation guarantees every lookup below succeeds.
        terrains = Terrain.allCases.map { c in data.terrains.first { $0.name == caseName(c) }! }
        elevations = Elevation.allCases.map { c in data.elevations.first { $0.name == caseName(c) }! }
        features = Feature.allCases.map { c in data.features.first { $0.name == caseName(c) }! }
        river = data.river
        improvements = Improvement.allCases.map { c in data.improvements.first { $0.name == caseName(c) }! }
        units = UnitType.allCases.map { t in data.units.first { $0.type == t }! }
        buildings = data.buildings
        techs = data.techs
        civs = data.civs
        focuses = CityFocus.allCases.map { f in data.focuses.first { $0.focus == f }! }
        constants = data.constants
        ai = data.ai
        tribalVillages = data.tribalVillages
        palace = data.buildings.first { $0.palace }!
        let eras = data.eras ?? []
        self.eras = eras
        techEras = data.techs.map { tech in tech.era.flatMap { e in eras.firstIndex { $0.id == e } } ?? 0 }
        progression = data.progression
        promotions = data.promotions ?? []
        promotionXP = data.promotionXP ?? []
        resources = data.resources.map { list in Resource.allCases.map { c in list.first { $0.name == caseName(c) }! } } ?? []
        stockpile = data.stockpile
        roads = data.roads
        embark = data.embark
        techRequires = data.techs.map { tech in tech.requires.map { r in data.techs.firstIndex { $0.id == r }! } }

        improvementSites = Improvement.allCases.map { improvement in
            let def = data.improvements.first { $0.name == caseName(improvement) }!
            var allowed = [Bool](repeating: false, count: Ruleset.siteCombinations)
            for site in def.sites {
                for t in Terrain.allCases where site.terrains.contains(caseName(t)) {
                    for e in Elevation.allCases where site.elevations.contains(caseName(e)) {
                        for f in Feature.allCases where site.features.contains(caseName(f)) {
                            allowed[Ruleset.siteIndex(t, e, f)] = true
                        }
                    }
                }
            }
            return allowed
        }
    }

    public static func == (a: Ruleset, b: Ruleset) -> Bool { a.id == b.id && a.contentHash == b.contentHash }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(contentHash)
    }

    public var description: String { "\(id) (\(String(contentHash, radix: 16)))" }

    // MARK: Lookups

    public func terrain(_ terrain: Terrain) -> TerrainDef { terrains[Int(terrain.rawValue)] }
    public func elevation(_ elevation: Elevation) -> ElevationDef { elevations[Int(elevation.rawValue)] }
    public func feature(_ feature: Feature) -> FeatureDef { features[Int(feature.rawValue)] }
    public func improvement(_ improvement: Improvement) -> ImprovementDef { improvements[improvement.ordinal] }
    /// Nil in rules without resources.
    public func resource(_ resource: Resource) -> ResourceDef? {
        resources.isEmpty ? nil : resources[Int(resource.rawValue) - 1]
    }
    public func unit(_ type: UnitType) -> UnitDef { units[type.ordinal] }
    public func focus(_ focus: CityFocus) -> FocusDef { focuses[focus.ordinal] }

    public func building(_ id: BuildingID) -> BuildingDef? { buildings.first { $0.id == id } }
    public func tech(_ id: TechID) -> TechDef? { techs.first { $0.id == id } }
    /// Position in tree order.
    public func techIndex(_ id: TechID) -> Int? { techs.firstIndex { $0.id == id } }
    public func civ(_ id: CivID) -> CivDef? { civs.first { $0.id == id } }

    /// Production cost of a queue item (0 for an unknown building).
    public func cost(of item: ProductionItem) -> Int {
        switch item {
        case let .unit(type): unit(type).cost
        case let .building(id): building(id)?.cost ?? 0
        }
    }

    /// The tech an item needs, if any.
    public func requiredTech(for item: ProductionItem) -> TechID? {
        switch item {
        case let .unit(type): unit(type).tech
        case let .building(id): building(id)?.tech
        }
    }

    /// Whether `improvement` may stand on a tile with this terrain, elevation and feature (the
    /// improvement's site list and the feature's `allowsImprovements`; ownership, city centres
    /// and techs are checked by the engine).
    /// `resource`: the tile's resource as the builder's player knows it (M2 §4.1): an improvement
    /// listing it may stand there whatever the site list and feature say.
    public func allowsImprovement(_ improvement: Improvement, on tile: Tile, resource: Resource? = nil) -> Bool {
        let def = self.improvement(improvement)
        if let r = resource, def.resources?.contains(caseName(r)) == true { return true }
        if def.noResource == true, resource != nil { return false }
        guard feature(tile.feature).allowsImprovements || def.anyFeature == true else { return false }
        return improvementSites[improvement.ordinal][Self.siteIndex(tile.terrain, tile.elevation, tile.feature)]
    }

    /// Whether a land unit may stand on the tile (terrain, elevation and feature).
    public func isPassable(_ tile: Tile) -> Bool {
        !tile.terrain.isWater && elevation(tile.elevation).passable && feature(tile.feature).passable
    }

    /// Whether a citizen may work the tile.
    public func isWorkable(_ tile: Tile) -> Bool {
        elevation(tile.elevation).workable && feature(tile.feature).workable
    }

    /// Food needed to grow from population `p` (M1 §5): base + perPop·(p−1) + curve·isqrt((p−1)³).
    public func growthThreshold(population p: Int) -> Int {
        let g = constants.growth
        let n = max(0, p - 1)
        return g.base + g.perPopulation * n + g.curvePct * isqrt(n * n * n) / 100
    }

    /// Culture needed for a city's next tile after it has gained `tilesGained` (M1 §5).
    public func borderThreshold(tilesGained n: Int) -> Int {
        constants.borders.baseCost + constants.borders.costPerTile * n
    }

    /// Maximum cities for the AI on a map size (M1 §13).
    public func aiMaxCities(mapSize: String) -> Int {
        ai.maxCities.first { $0.mapSize == mapSize }?.cities ?? ai.defaultMaxCities
    }

    private static let siteCombinations = Terrain.allCases.count * Elevation.allCases.count * Feature.allCases.count

    private static func siteIndex(_ t: Terrain, _ e: Elevation, _ f: Feature) -> Int {
        (Int(t.rawValue) * Elevation.allCases.count + Int(e.rawValue)) * Feature.allCases.count + Int(f.rawValue)
    }
}

/// Rules data that failed validation, with every problem found.
public struct RulesValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    public let problems: [String]
    public var description: String { "invalid rules: " + problems.joined(separator: "; ") }
}

/// Integer square root (floor), by Newton's method in integers (M1 §12.7: no floating point
/// in the rules).
func isqrt(_ n: Int) -> Int {
    guard n > 0 else { return 0 }
    var x = n
    var y = (x + 1) / 2
    while y < x {
        x = y
        y = (x + n / x) / 2
    }
    return x
}

/// The case name of an enum value, as the rules data spells it.
func caseName<T>(_ value: T) -> String { String(describing: value) }

// MARK: - Ordinals

extension UnitType {
    /// Position in `allCases`.
    var ordinal: Int {
        switch self {
        case .settler: 0
        case .builder: 1
        case .scout: 2
        case .warrior: 3
        case .archer: 4
        case .spearman: 5
        case .horseman: 6
        case .heavyChariot: 7
        case .swordsman: 8
        case .catapult: 9
        case .manAtArms: 10
        case .crossbowman: 11
        case .pikeman: 12
        case .knight: 13
        case .trebuchet: 14
        case .galley: 15
        case .quadrireme: 16
        case .cog: 17
        case .dromon: 18
        }
    }
}

extension Improvement {
    /// Position in `allCases`.
    var ordinal: Int { Int(rawValue) - 1 }
}

extension CityFocus {
    /// Position in `allCases`.
    var ordinal: Int {
        switch self {
        case .balanced: 0
        case .food: 1
        case .production: 2
        case .gold: 3
        }
    }
}

// MARK: - Data

/// The rules file's contents. JSON uses arrays and integers only (M1 §12.2).
struct RulesetData: Codable, Hashable, Sendable {
    var id: String
    var version: Int
    var terrains: [TerrainDef]
    var elevations: [ElevationDef]
    var features: [FeatureDef]
    var river: RiverDef
    var improvements: [ImprovementDef]
    var units: [UnitDef]
    var buildings: [BuildingDef]
    var techs: [TechDef]
    var civs: [CivDef]
    var focuses: [FocusDef]
    var constants: RuleConstants
    var ai: AIRules
    /// Optional: absent (nil), the key is left out of the canonical encoding, so the content
    /// hash is the one the rules had before the section existed (the C0 kill switch).
    var tribalVillages: TribalVillageRules?
    /// Optional (M2 §2): absent, techs have no eras and there is no world era.
    var eras: [EraDef]?
    /// Optional (M2 §2, §6.2): absent, no Insights fire and the world era never advances.
    var progression: ProgressionRules?
    var promotions: [PromotionDef]?
    var promotionXP: [Int]?
    /// Optional (M2 §3.1): absent, maps have no resources and nothing needs one.
    var resources: [ResourceDef]?
    var stockpile: StockpileRules?
    var roads: RoadRules?
    var embark: EmbarkRules?
}

/// What a resource is for (M2 §3.1).
public enum ResourceKind: String, Codable, Hashable, Sendable {
    case bonus, luxury, strategic
}

public struct ResourceDef: Codable, Hashable, Sendable {
    /// The `Resource` case name.
    public let name: String
    public let displayName: String
    public let kind: ResourceKind
    public let food: Int
    public let production: Int
    public let gold: Int
    public let culture: Int
    /// The `Improvement` case name that improves it.
    public let improvement: String
    /// The tech that shows it to a player; nil = always known.
    public let revealedBy: TechID?
    /// Where MapGen may place it.
    public let sites: [ImprovementSite]
}

/// Strategic stockpiles (M2 §3.1, M2-D5).
public struct StockpileRules: Codable, Hashable, Sendable {
    /// Added per improved source at phase start.
    public let perSource: Int
    public let cap: Int
    /// Added to the cap from this era index on.
    public let capBonus: Int
    public let capBonusEra: Int
    /// Taken when a unit that needs the resource completes, is bought or upgrades.
    public let unitCost: Int
    /// Taken per such unit per turn while at war.
    public let warUsePerUnit: Int
    /// Strength of such units while at war with an empty stockpile.
    public let shortageStrength: Int
    /// Map placement per 1000 land tiles, and luxury cluster sizes.
    public let bonusPer1000Land: Int
    public let luxuryPer1000Land: Int
    public let strategicPer1000Land: Int
    public let clusterMin: Int
    public let clusterMax: Int
}

/// Roads and pillage (M2 §3.3).
public struct RoadRules: Codable, Hashable, Sendable {
    /// Move points per M1 move.
    public let movePoints: Int
    /// Move points for a step from a road tile to a road tile.
    public let roadCost: Int
    /// A Builder may build roads with it.
    public let tech: TechID
    /// Road steps ignore river crossings with it.
    public let riverTech: TechID
    /// Pillaging an improvement gives this much Gold, or heals this much when wounded.
    public let pillageGold: Int
    public let pillageHeal: Int
}

/// Embarked land units and naval units (M2 §8.4).
public struct EmbarkRules: Codable, Hashable, Sendable {
    /// Land units may enter Coast and Lake with it.
    public let coastTech: TechID
    /// Any unit may enter Ocean with it.
    public let oceanTech: TechID
    /// An embarked unit's (fixed) defending strength, moves on water and sight.
    public let strength: Int
    public let moves: Int
    public let sight: Int
    /// A naval unit heals this much in an own city; at sea it does not heal.
    public let navalHealInCity: Int
}

/// Yields of one source (M1 §4). Integer only.
public struct Yields: Codable, Hashable, Sendable, CustomStringConvertible {
    public var food: Int
    public var production: Int
    public var gold: Int
    public var science: Int
    public var culture: Int

    public init(food: Int = 0, production: Int = 0, gold: Int = 0, science: Int = 0, culture: Int = 0) {
        self.food = food
        self.production = production
        self.gold = gold
        self.science = science
        self.culture = culture
    }

    public static let zero = Yields()

    public static func + (a: Yields, b: Yields) -> Yields {
        Yields(food: a.food + b.food, production: a.production + b.production, gold: a.gold + b.gold,
               science: a.science + b.science, culture: a.culture + b.culture)
    }

    public static func += (a: inout Yields, b: Yields) { a = a + b }

    public var isZero: Bool { self == .zero }

    public var description: String { "F\(food) P\(production) G\(gold) S\(science) C\(culture)" }
}

public struct TechYieldBonus: Codable, Hashable, Sendable {
    public let tech: TechID
    public let food: Int
    public let production: Int
    public let gold: Int
}

public struct TerrainDef: Codable, Hashable, Sendable {
    /// The `Terrain` case name.
    public let name: String
    public let food: Int
    public let production: Int
    public let gold: Int
    /// Extra yields once a tech is known (Sailing: +1 Food on Coast and Lake).
    public let techBonuses: [TechYieldBonus]
}

public struct ElevationDef: Codable, Hashable, Sendable {
    /// The `Elevation` case name.
    public let name: String
    public let food: Int
    public let production: Int
    public let gold: Int
    /// Added to the base move cost of 1.
    public let moveCost: Int
    /// Defence modifier of a unit standing here.
    public let defense: Int
    /// City Strength of a city standing here.
    public let cityStrength: Int
    public let passable: Bool
    public let workable: Bool
}

public struct FeatureDef: Codable, Hashable, Sendable {
    /// The `Feature` case name.
    public let name: String
    public let food: Int
    public let production: Int
    public let gold: Int
    /// Added to the base move cost of 1.
    public let moveCost: Int
    /// Defence modifier of a unit standing here.
    public let defense: Int
    public let passable: Bool
    public let workable: Bool
    /// A city centre counts as not having this feature (yields, movement, defence).
    public let removedByCity: Bool
    /// A city may be founded on it.
    public let allowsCity: Bool
    /// Improvements may be built on it.
    public let allowsImprovements: Bool
}

public struct RiverDef: Codable, Hashable, Sendable {
    /// Gold of a tile with any river edge.
    public let gold: Int
    /// Added to the move cost when crossing a river edge.
    public let crossingMoveCost: Int
    /// Added to a melee attacker's strength across a river edge (negative).
    public let meleeAttackModifier: Int
    /// Added to a tile's border-claim score.
    public let borderScore: Int
}

public struct ImprovementSite: Codable, Hashable, Sendable {
    /// `Terrain` case names.
    public let terrains: [String]
    /// `Elevation` case names.
    public let elevations: [String]
    /// `Feature` case names.
    public let features: [String]
}

public struct ImprovementDef: Codable, Hashable, Sendable {
    /// The `Improvement` case name.
    public let name: String
    public let displayName: String
    public let food: Int
    public let production: Int
    public let gold: Int
    public let tech: TechID?
    /// Extra Food on a tile with a river edge or next to a lake, once `freshWaterTech` is known.
    public let freshWaterFood: Int
    public let freshWaterTech: TechID?
    public let sites: [ImprovementSite]
    /// `Resource` case names it may stand on whatever its sites and the feature (M2 §4.1).
    public let resources: [String]?
    /// May stand on features that allow no improvements (Lumber Mill on forest).
    public let anyFeature: Bool?
    /// Never on a tile with a known resource.
    public let noResource: Bool?
    /// Extra yields once a tech is known (Mine with Apprenticeship).
    public let techBonuses: [TechYieldBonus]?
}

/// A unit's class (M1 §7). Military = every class except civilian.
public enum UnitClass: String, Codable, Hashable, Sendable, CaseIterable {
    case civilian, recon, melee, ranged, antiCavalry, cavalry
    /// M2 §8.1.
    case heavyCavalry, siege
    /// M2 §8.4.
    case navalMelee, navalRanged

    public var isNaval: Bool { self == .navalMelee || self == .navalRanged }
}

public struct ClassBonus: Codable, Hashable, Sendable {
    public let against: UnitClass
    public let strength: Int
}

public struct UnitDef: Codable, Hashable, Sendable {
    public let type: UnitType
    public let unitClass: UnitClass
    public let cost: Int
    public let strength: Int
    /// 0 for units without a ranged attack.
    public let rangedStrength: Int
    public let range: Int
    public let moves: Int
    public let sight: Int
    public let tech: TechID?
    /// Builder charges a new unit starts with.
    public let charges: Int
    public let foundsCity: Bool
    /// The city's population needed for it to complete (a Settler waits at population 1).
    public let minPopulation: Int
    /// Population the city loses when it completes.
    public let populationCost: Int
    public let classBonuses: [ClassBonus]
    /// The unit a captor gets for it (civilians, M1 §7.3).
    public let capturedAs: UnitType?
    /// Charges of the captured unit; nil keeps the old unit's charges.
    public let capturedCharges: Int?
    /// The unit it upgrades to (M2 §8.2), if any.
    public let upgradesTo: UnitType?
    /// False for siege units: no ranged attack after moving in the phase (M2 §8.1). Nil = true.
    public let rangedAfterMove: Bool?
    /// Percent of its damage that wall HP takes (M2 §9.2); nil = `combat.wallDamagePct`.
    public let wallDamagePct: Int?
    /// The strategic `Resource` case name it needs (M2 §3.1), if any.
    public let resource: String?
    /// Strength added when it attacks a city (M2 §8.1: cavalry and ranged −5); nil = 0.
    public let vsCity: Int?

    public var isMilitary: Bool { unitClass != .civilian }
    public var isRanged: Bool { rangedStrength > 0 }

    enum CodingKeys: String, CodingKey {
        case type, unitClass = "class", cost, strength, rangedStrength, range, moves, sight, tech, charges, foundsCity,
             minPopulation, populationCost, classBonuses, capturedAs, capturedCharges, upgradesTo, rangedAfterMove,
             wallDamagePct, resource, vsCity
    }
}

public struct BuildingDef: Codable, Hashable, Sendable {
    public let id: BuildingID
    public let name: String
    public let cost: Int
    public let tech: TechID?
    /// False for the Palace, which is granted, never built.
    public let buildable: Bool
    public let palace: Bool
    public let food: Int
    public let production: Int
    public let gold: Int
    public let science: Int
    public let culture: Int
    /// Wall HP a city gets with it (Walls).
    public let wallHP: Int
    /// City Strength while its wall HP is above 0 (Walls).
    public let cityStrength: Int

    public var yields: Yields { Yields(food: food, production: production, gold: gold, science: science, culture: culture) }
}

public struct TechDef: Codable, Hashable, Sendable {
    public let id: TechID
    public let name: String
    public let cost: Int
    public let requires: [TechID]
    /// The era it belongs to (an `EraDef.id`); nil in rules without eras.
    public let era: String?
    /// Its Insight (M2 §6.2), if any.
    public let insight: InsightDef?
}

/// An era (M2 §2). The rules' `eras` are in order: index 0 is the first era.
/// A promotion (M2 §8.3): offered to units of `classes` at `tier`. Strength applies in a fight
/// matching every condition given (`when` "attack"/"defend", `ranged`, the other side's class in
/// `against`, `vsCity`, the unit standing in an own city `inCity`); `moves` adds to its moves.
public struct PromotionDef: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let classes: [UnitClass]
    public let tier: Int
    public let strength: Int?
    public let when: String?
    public let ranged: Bool?
    public let against: [UnitClass]?
    public let vsCity: Bool?
    public let inCity: Bool?
    public let moves: Int?
    /// Percent of its damage that wall HP takes, replacing the unit's (M2 §9.2).
    public let wallDamagePct: Int?
    /// Added to its range and its sight.
    public let range: Int?
    public let sight: Int?
    /// True lifts the siege rule: it may fire after moving.
    public let rangedAfterMove: Bool?
    /// Its strength applies only against a wounded unit (true).
    public let vsWounded: Bool?
    /// Elevation and feature names whose extra move cost it does not pay.
    public let freeMoveOn: [String]?
    /// It ignores zones of control, except those of units with a `holdsZOC` promotion.
    public let ignoresZOC: Bool?
    public let holdsZOC: Bool?
    /// Attacking costs it one move instead of all; it still attacks once per phase.
    public let moveAfterAttack: Bool?
    /// No river penalty when it attacks.
    public let noRiverPenalty: Bool?
    public let text: String
}

public struct EraDef: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
}

/// Insights and the world era (M2 §2, §6.2).
public struct ProgressionRules: Codable, Hashable, Sendable {
    /// An Insight's credit toward its tech, % of the tech's cost.
    public let insightPct: Int
    /// Credit toward every unknown tech of the era the world leaves, % of cost.
    public let catchUpInsightPct: Int
    /// The world advances when the mean progress of living players reaches this %.
    public let worldEraAdvancePct: Int
    /// …or when a player knows this many techs of the era after the next one.
    public let forceAheadCount: Int
}

/// What fires an Insight (M2 §6.2). Each kind reads `count`, `target` and `classes` as noted.
public enum InsightKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Own `count` cities next to Coast or Lake.
    case ownCoastalCities
    /// Have met `count` other players.
    case meetPlayers
    /// Own `count` cities.
    case ownCities
    /// Have `count` improvements of kind `target` (an `Improvement` case name) in own territory.
    case buildImprovements
    /// Own `count` buildings `target` (a building id) across own cities.
    case ownBuildings
    /// Own `count` units of type `target` (a `UnitType` case name).
    case ownUnits
    /// Kill a unit (of a class in `against`, if given) with a unit of a class in `classes`.
    case killWith
    /// An own city with wall HP left survives an attack.
    case cityDefended
}

public struct InsightDef: Codable, Hashable, Sendable {
    public let kind: InsightKind
    public let count: Int?
    public let target: String?
    public let classes: [UnitClass]?
    public let against: [UnitClass]?
    /// Shown in the tech tree ("Build 2 Mines").
    public let text: String
}

public struct CivDef: Codable, Hashable, Sendable {
    public let id: CivID
    public let name: String
    public let leader: String
    /// Historical city names, in founding order.
    public let cityNames: [String]
}

/// A city focus's tile weights and food floor (M1 §4).
public struct FocusDef: Codable, Hashable, Sendable {
    public let focus: CityFocus
    public let food: Int
    public let production: Int
    public let gold: Int
    public let science: Int
    public let culture: Int
    /// Food surplus the citizen assignment keeps.
    public let foodFloor: Int

    /// The focus-weighted value of some yields.
    public func value(_ y: Yields) -> Int {
        food * y.food + production * y.production + gold * y.gold + science * y.science + culture * y.culture
    }
}

// MARK: Constants

public struct RuleConstants: Codable, Hashable, Sendable {
    public let start: StartRules
    public let growth: GrowthRules
    public let city: CityRules
    public let borders: BorderRules
    public let production: ProductionRules
    public let healing: HealingRules
    public let upkeep: UpkeepRules
    public let combat: CombatRules
    public let diplomacy: DiplomacyRules
    public let knowledge: KnowledgeRules
    public let score: ScoreRules
    public let settle: SettleRules
    /// The score victory comes at the end of this turn.
    public let turnLimit: Int
}

public struct StartRules: Codable, Hashable, Sendable {
    public let gold: Int
    /// Each player's units, placed at the start position (the rest beside it when the tile is full).
    public let units: [UnitType]
}

public struct GrowthRules: Codable, Hashable, Sendable {
    public let foodPerCitizen: Int
    public let base: Int
    public let perPopulation: Int
    /// Weight of the isqrt((p−1)³) term, in percent.
    public let curvePct: Int
}

public struct CityRules: Codable, Hashable, Sendable {
    public let centreMinFood: Int
    public let centreMinProduction: Int
    public let centreProduction: Int
    public let centreScience: Int
    public let centreCulture: Int
    /// Stored progress every city starts with when it is founded (M1 §5).
    public let foundingProduction: Int
    /// p3f experiment (core-young-city-production): extra Production at the centre of a city
    /// below `youngCityPopulation` (M1 §4); 0 adds nothing.
    public let youngCityProduction: Int
    public let youngCityPopulation: Int
    /// p3f experiment: stored progress a city holds right after its capture (M1 §5 Capture);
    /// 0 clears it.
    public let capturedProduction: Int
    /// +1 Science per this many citizens.
    public let populationPerScience: Int
    /// Production of a citizen with no tile to work.
    public let unemployedProduction: Int
    /// Visibility radius around a city centre.
    public let sight: Int
    /// Citizens work tiles within this distance of the centre.
    public let workRadius: Int
    /// A new city owns the unowned tiles within this distance.
    public let initialRadius: Int
    /// Minimum distance between city centres.
    public let minDistance: Int
    public let maxHP: Int
    public let healPerPhase: Int
    public let wallRepairPerPhase: Int
    public let capturedHP: Int
    public let strengthBase: Int
    public let strengthPerPopulation: Int
    public let garrisonStrength: Int
    public let bombardRange: Int
    /// City names after a civ's list runs out: prefix + the list again.
    public let newNamePrefix: String
}

public struct BorderRules: Codable, Hashable, Sendable {
    public let baseCost: Int
    public let costPerTile: Int
    /// Cities claim tiles up to this distance.
    public let radius: Int
    public let foodWeight: Int
    public let productionWeight: Int
    public let goldWeight: Int
}

public struct ProductionRules: Codable, Hashable, Sendable {
    public let maxQueue: Int
    public let purchaseCostMultiplier: Int
    /// Stored progress is capped at this many phases of the city's production.
    public let storedProgressCapMultiplier: Int
    /// A finished unit appears within this distance of its city when the centre is full.
    public let spawnRadius: Int
    /// p3f (core-opening-tempo): a unit at the head of the queue that waits for its city's
    /// population (a Settler at population 1) takes production up to this percentage of its
    /// cost (M1 §5); 0: it takes none, and the production goes to the first item that can
    /// complete.
    public let waitingHeadFillPct: Int
}

public struct HealingRules: Codable, Hashable, Sendable {
    public let maxHP: Int
    public let ownCity: Int
    public let ownTerritory: Int
    public let neutral: Int
    public let foreign: Int
}

public struct UpkeepRules: Codable, Hashable, Sendable {
    /// Military units free of upkeep: freeBase + freePerCity × cities.
    public let freeBase: Int
    public let freePerCity: Int
    public let goldPerUnit: Int
}

public struct CombatRules: Codable, Hashable, Sendable {
    public let damageBase: Int
    public let damageScale: Int
    public let maxDifference: Int
    public let rollRange: Int
    public let fortified: Int
    public let supportPerUnit: Int
    public let supportMax: Int
    public let flankingPerUnit: Int
    public let flankingMax: Int
    /// −1 strength per this many HP missing.
    public let hpPerWoundPenalty: Int
    public let xpMeleeAttack: Int
    public let xpRangedAttack: Int
    public let xpDefend: Int
    /// Percent of a unit's damage that wall HP takes (M2 §9.2); nil = 100 (M1).
    public let wallDamagePct: Int?
}

public struct DiplomacyRules: Codable, Hashable, Sendable {
    /// After a peace treaty, war may be declared again after this many turns.
    public let warAfterPeaceTurns: Int
    /// Peace may be proposed after this many turns of war.
    public let peaceAfterWarTurns: Int
    public let proposalCooldownTurns: Int
}

public struct KnowledgeRules: Codable, Hashable, Sendable {
    /// Unit sightings are dropped when older than this many turns.
    public let sightingMaxAge: Int
}

public struct ScoreRules: Codable, Hashable, Sendable {
    public let perCity: Int
    public let perPopulation: Int
    public let perTech: Int
    /// Per building, the Palace excluded.
    public let perBuilding: Int
}

/// `PlayerView.settleScore(at:)`: weighted yields of the explored tiles around a site plus bonuses.
public struct SettleRules: Codable, Hashable, Sendable {
    public let radius: Int
    public let foodWeight: Int
    public let productionWeight: Int
    public let goldWeight: Int
    /// The site has a river edge or touches a lake.
    public let freshWaterBonus: Int
    /// The site touches coast.
    public let coastBonus: Int
    /// The site is on hills.
    public let hillsBonus: Int
}

public struct MaxCities: Codable, Hashable, Sendable {
    /// `GameState.mapSizeName`.
    public let mapSize: String
    public let cities: Int
}

/// AI tuning (M1 §13). Percentages are integers (130 = 1.3×).
public struct AIRules: Codable, Hashable, Sendable {
    public let maxCities: [MaxCities]
    public let defaultMaxCities: Int
    public let minSettleScore: Int
    public let firstCityMovePct: Int
    public let settleMaxMoveCost: Int
    public let settleMaxCityDistance: Int
    public let settleSiteSpacing: Int
    public let civilianSafetyRadius: Int
    public let scoutTargetSpacing: Int
    public let threatRadius: Int
    public let defendersPerCity: Int
    public let threatenedDefenders: Int
    public let settlersPerCityPct: Int
    public let buildersPerCityPct: Int
    public let archersPerMeleePct: Int
    /// Ships per coastal city (M2 §8.4); nil: none.
    public let shipsPerCoastalCityPct: Int?
    public let warGoldDeficitMultiplier: Int
    public let buyDefenderGoldReserve: Int
    public let buyCivilianGoldPct: Int
    public let warMinTurn: Int
    public let warMinPeaceTurns: Int
    public let warMinRanged: Int
    public let warMinMelee: Int
    public let rallyRadius: Int
    public let warRatioPct: Int
    public let targetCostTolerance: Int
    public let advanceArmyUnits: Int
    public let advanceAfterTurns: Int
    public let sightingMaxAge: Int
    public let cityPowerEstimate: Int
    public let attackKillChancePct: Int
    public let cityAttackHPMargin: Int
    public let cityAttackMaxCityHP: Int
    public let cityAttackFocusHits: Int
    public let retreatHP: Int
    public let rejoinHP: Int
    public let defendCityHP: Int
    public let defendRecallRadius: Int
    public let sortieKillChancePct: Int
    public let civilianCaptureMaxAdjacentEnemies: Int
    public let peaceMinWarTurns: Int
    public let peaceRatioPct: Int
    public let peaceStaleTurns: Int
    public let razeMaxPopulation: Int
    public let razeMinDistance: Int
    /// Research order in expand/develop posture.
    public let researchOrderPeace: [TechID]
    /// Research order in prepare/war posture or when threatened.
    public let researchOrderWar: [TechID]
    // Knobs M1 §13 implies without a number (added by the AI work package, ai-1):
    /// Hard cap on the commands one AI phase issues (its `endTurn` excluded).
    public let maxCommandsPerPhase: Int
    /// A Settler values a site at settleScore − this × its movement cost to the site.
    public let settleCostPenalty: Int
    /// "A Warrior early for exploration": only up to this turn.
    public let earlyTurns: Int
    /// A city keeps a queued item with at least this much of its cost done (percent) instead
    /// of switching to a new, non-urgent first choice.
    public let queueSwitchProgressPct: Int
    /// A free military unit at most this many movement points away garrisons a city without
    /// one (and the city then builds no defender for it).
    public let garrisonMaxMoveCost: Int
    /// A Settler waiting for an escort takes the nearest free military unit at most this many
    /// movement points away.
    public let escortMaxMoveCost: Int
    // Knobs added by ai-2 (tuning, M1 §13 is silent):
    /// In prepare or war posture a city buys its first item when it is an army unit and the
    /// treasury holds at least this percentage of the price.
    public let buyArmyGoldPct: Int
    /// At war, the army stages within this distance of the target (and outside its bombard
    /// range) until enough of it is there to assault.
    public let siegeStageRadius: Int
    // Knobs added by ai-3:
    /// A Builder looks for work within this many movement points first (nearest the best
    /// tiles there), and further only when there is none.
    public let builderMaxMoveCost: Int
    /// In prepare or war posture, once the player has at least this many cities, a city's
    /// priority list puts Builders and then the army unit before Settlers (M1 §13 Cities). A
    /// value above the map's max cities keeps the plain order.
    public let armyFirstCities: Int
    // Knobs added by p3f (ai-prepare-posture, GameAI/AIPreparePosture.swift). Optional: a
    // missing one (or 0) keeps the rule as it was, and leaves the rules' content hash as it was.
    /// B: in prepare posture, while a good site exists and 100 × (own cities + Settlers alive
    /// and queued) < this × the rival's remembered cities, Settlers come before the army
    /// (`armyFirstCities` does not apply). 100: while it has fewer cities than the rival; 125
    /// (the default): while it has fewer than 1.25 × as many (also 4 against 4, 6 against 5).
    public let prepareSettlersRivalPct: Int?
    /// B (with `prepareSettlersRivalPct` on): in prepare posture a Settler values a site this
    /// many points less per tile between the site and the rival's nearest remembered city.
    public let prepareSiteRivalWeight: Int?
    /// C: in prepare posture the army (see `prepareStageUnits`) gathers within this many tiles
    /// of the stage — a tile it may stand on within the target's sight, nearest the rally city
    /// — instead of near the rally city, and the war test counts the units there too.
    public let prepareStageRadius: Int?
    /// C (with `prepareStageRadius` on): at most this many army units, those nearest the
    /// stage, gather there; the others gather by the rally city as before (missing or 0: all).
    public let prepareStageUnits: Int?
}

/// Tribal villages (M1 §7.7): where `newGame` places them and what they give. The rules file's
/// optional top-level section `tribalVillages`; without it (`Ruleset.tribalVillages == nil`) a
/// game has none and plays, and hashes, exactly as before the section existed (the canonical
/// encoding leaves an absent section out, so `contentHash` is unchanged too).
public struct TribalVillageRules: Codable, Hashable, Sendable {
    /// One step band of a placement round: a tile qualifies for a start when it is `min`…`max`
    /// steps from it over passable land and at least `margin` steps nearer it than to any other
    /// start.
    public struct Band: Codable, Hashable, Sendable {
        public let min: Int
        public let max: Int
        public let margin: Int

        public init(min: Int, max: Int, margin: Int) {
            self.min = min
            self.max = max
            self.margin = margin
        }
    }

    /// The shared tribal villages placed after the rounds: `perStart` × starts tries, on tiles at
    /// least `minSteps` from every start and at most `maxMargin` nearer one start than another.
    public struct Shared: Codable, Hashable, Sendable {
        public let perStart: Int
        public let minSteps: Int
        public let maxMargin: Int

        public init(perStart: Int, minSteps: Int, maxMargin: Int) {
            self.perStart = perStart
            self.minSteps = minSteps
            self.maxMargin = maxMargin
        }
    }

    /// What a tribal village gives: Gold, Science toward the current research, or a Builder on
    /// its tile or within `builderRadius` of it.
    public struct Gifts: Codable, Hashable, Sendable {
        public let gold: Int
        public let science: Int
        public let builderRadius: Int

        public init(gold: Int, science: Int, builderRadius: Int) {
            self.gold = gold
            self.science = science
            self.builderRadius = builderRadius
        }
    }

    /// The placement rounds, in order; each lists its bands, tried in order per start.
    public let rounds: [[Band]]
    public let shared: Shared
    /// No two tribal villages lie within `spacing − 1` hexes of each other.
    public let spacing: Int
    public let gifts: Gifts
    /// Explorers seek a known tribal village within this many turns' moves.
    public let seekTurns: Int

    public init(rounds: [[Band]], shared: Shared, spacing: Int, gifts: Gifts, seekTurns: Int) {
        self.rounds = rounds
        self.shared = shared
        self.spacing = spacing
        self.gifts = gifts
        self.seekTurns = seekTurns
    }
}

// MARK: - Validation

extension RulesetData {
    /// Every problem with the data (empty when valid).
    func validationProblems() -> [String] {
        var problems: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { problems.append(message()) }
        }
        func exactlyOne<C: CaseIterable>(_ type: C.Type, _ names: [String], _ table: String) {
            for c in C.allCases {
                let n = names.filter { $0 == caseName(c) }.count
                check(n == 1, "\(table): \(caseName(c)) has \(n) definitions")
            }
            let known = Set(C.allCases.map { caseName($0) })
            for name in names where !known.contains(name) { problems.append("\(table): unknown \(name)") }
        }

        check(!id.isEmpty, "id is empty")
        exactlyOne(Terrain.self, terrains.map(\.name), "terrains")
        exactlyOne(Elevation.self, elevations.map(\.name), "elevations")
        exactlyOne(Feature.self, features.map(\.name), "features")
        exactlyOne(Improvement.self, improvements.map(\.name), "improvements")
        if let resources {
            exactlyOne(Resource.self, resources.map(\.name), "resources")
            let improvementNames = Set(Improvement.allCases.map { caseName($0) })
            for r in resources {
                check(improvementNames.contains(r.improvement), "resource \(r.name): unknown improvement \(r.improvement)")
                check(!r.sites.isEmpty, "resource \(r.name): no sites")
                if let tech = r.revealedBy { check(techs.contains { $0.id == tech }, "resource \(r.name): unknown tech \(tech.rawValue)") }
            }
            check(stockpile != nil, "resources without a stockpile section")
        }
        let strategic = Set((resources ?? []).filter { $0.kind == .strategic }.map(\.name))
        for unit in units {
            if let r = unit.resource { check(strategic.contains(r), "unit \(unit.type): \(r) is not a strategic resource") }
        }
        let resourceNames = Set(Resource.allCases.map { caseName($0) })
        for imp in improvements {
            for r in imp.resources ?? [] { check(resourceNames.contains(r), "improvement \(imp.name): unknown resource \(r)") }
        }
        for type in UnitType.allCases {
            let n = units.filter { $0.type == type }.count
            check(n == 1, "units: \(type) has \(n) definitions")
        }
        for focus in CityFocus.allCases {
            let n = focuses.filter { $0.focus == focus }.count
            check(n == 1, "focuses: \(focus) has \(n) definitions")
        }

        // Techs: unique, known prerequisites listed earlier (tree order), acyclic.
        let techIDs = techs.map(\.id)
        check(!techs.isEmpty, "no techs")
        check(Set(techIDs).count == techIDs.count, "techs: duplicate ids")
        for (i, tech) in techs.enumerated() {
            check(tech.cost > 0, "tech \(tech.id): cost must be positive")
            for r in tech.requires {
                guard let j = techIDs.firstIndex(of: r) else {
                    problems.append("tech \(tech.id): unknown prerequisite \(r)")
                    continue
                }
                check(j != i, "tech \(tech.id) requires itself")
                check(j < i, "tech \(tech.id): prerequisite \(r) must come earlier (tree order)")
            }
        }
        if let cycle = techCycle() { problems.append("techs: cycle through \(cycle)") }
        // Eras (M2 §2): every tech names a known era when the rules have eras, none otherwise;
        // eras never go back in tree order.
        let eraIDs = (eras ?? []).map(\.id)
        check(Set(eraIDs).count == eraIDs.count, "eras: duplicate ids")
        var lastEra = 0
        for tech in techs {
            if eraIDs.isEmpty {
                check(tech.era == nil, "tech \(tech.id): era \(tech.era ?? "") but the rules have no eras")
            } else if let e = tech.era.flatMap({ eraIDs.firstIndex(of: $0) }) {
                check(e >= lastEra, "tech \(tech.id): era \(tech.era!) comes before an earlier tech's era (tree order)")
                lastEra = max(lastEra, e)
            } else {
                problems.append("tech \(tech.id): unknown or missing era \(tech.era ?? "nil")")
            }
            if let insight = tech.insight { problems += insightProblems(insight, "tech \(tech.id)") }
        }
        for p in promotions ?? [] {
            try check(!p.classes.isEmpty && (1...max(1, (promotionXP ?? []).count)).contains(p.tier)
                      && (p.when == nil || p.when == "attack" || p.when == "defend") && (p.wallDamagePct ?? 1) > 0,
                      "promotion \(p.id): bad class, tier, when or wall damage")
        }
        try check(Set((promotions ?? []).map(\.id)).count == (promotions ?? []).count, "promotions: duplicate id")
        try check(zip(promotionXP ?? [], (promotionXP ?? []).dropFirst()).allSatisfy { $0 < $1 }, "promotionXP must increase")
        if let p = progression {
            check((0...100).contains(p.insightPct) && (0...100).contains(p.catchUpInsightPct)
                  && (1...100).contains(p.worldEraAdvancePct) && p.forceAheadCount > 0, "progression: numbers out of range")
        }
        func knownTech(_ tech: TechID?, _ context: String) {
            if let tech { check(techIDs.contains(tech), "\(context): unknown tech \(tech)") }
        }

        // Terrain, elevation, feature, river.
        for t in terrains {
            for bonus in t.techBonuses { knownTech(bonus.tech, "terrain \(t.name)") }
        }
        for e in elevations { check(e.moveCost >= 0, "elevation \(e.name): negative move cost") }
        for f in features { check(f.moveCost >= 0, "feature \(f.name): negative move cost") }
        check(river.crossingMoveCost >= 0, "river: negative crossing cost")

        // Improvements.
        let terrainNames = Set(Terrain.allCases.map { caseName($0) })
        let elevationNames = Set(Elevation.allCases.map { caseName($0) })
        let featureNames = Set(Feature.allCases.map { caseName($0) })
        for imp in improvements {
            knownTech(imp.tech, "improvement \(imp.name)")
            knownTech(imp.freshWaterTech, "improvement \(imp.name)")
            check(!imp.sites.isEmpty || imp.resources?.isEmpty == false, "improvement \(imp.name): no sites")
            check(imp.freshWaterFood >= 0, "improvement \(imp.name): negative fresh water food")
            for site in imp.sites {
                for n in site.terrains where !terrainNames.contains(n) { problems.append("improvement \(imp.name): unknown terrain \(n)") }
                for n in site.elevations where !elevationNames.contains(n) { problems.append("improvement \(imp.name): unknown elevation \(n)") }
                for n in site.features where !featureNames.contains(n) { problems.append("improvement \(imp.name): unknown feature \(n)") }
            }
        }

        // Units.
        for u in units {
            let name = "unit \(u.type)"
            check(u.unitClass == .civilian ? u.type.isCivilian : !u.type.isCivilian,
                  "\(name): class \(u.unitClass) does not match UnitType.isCivilian")
            check(u.unitClass.isNaval == u.type.isNaval, "\(name): class \(u.unitClass) does not match UnitType.isNaval")
            check(u.cost > 0, "\(name): cost must be positive")
            check(u.moves >= 1 && u.moves <= 10, "\(name): moves out of range")
            check(u.sight >= 1 && u.sight <= 5, "\(name): sight out of range")
            check(u.strength >= 0 && u.rangedStrength >= 0, "\(name): negative strength")
            check(u.unitClass == .civilian ? u.strength == 0 && u.rangedStrength == 0 : u.strength > 0,
                  "\(name): civilians have no strength, military units do")
            check(u.rangedStrength == 0 ? u.range == 0 : u.range >= 1, "\(name): range must match the ranged strength")
            check(u.charges >= 0, "\(name): negative charges")
            check(u.minPopulation >= 1, "\(name): minPopulation must be at least 1")
            check(u.populationCost >= 0 && u.populationCost < u.minPopulation, "\(name): populationCost must leave a citizen")
            check(!u.foundsCity || u.unitClass == .civilian, "\(name): only civilians found cities")
            knownTech(u.tech, name)
            if let captured = u.capturedAs { check(captured.isCivilian, "\(name): captured units become civilians") }
            check(u.capturedCharges.map { $0 >= 0 } ?? true, "\(name): negative captured charges")
        }
        check(units.contains { $0.foundsCity }, "no unit founds cities")
        if let e = embark {
            knownTech(e.coastTech, "embark")
            knownTech(e.oceanTech, "embark")
            check(e.strength > 0 && e.moves >= 1 && e.sight >= 1 && e.navalHealInCity >= 0, "embark: numbers out of range")
        }

        // Buildings.
        let buildingIDs = buildings.map(\.id)
        check(Set(buildingIDs).count == buildingIDs.count, "buildings: duplicate ids")
        check(buildings.filter(\.palace).count == 1, "buildings: exactly one palace")
        for b in buildings {
            knownTech(b.tech, "building \(b.id)")
            check(b.palace ? !b.buildable : b.cost > 0, "building \(b.id): buildable buildings cost production; the palace is not buildable")
            check(b.wallHP >= 0 && b.cityStrength >= 0, "building \(b.id): negative wall HP or strength")
        }

        // Civs.
        check(!civs.isEmpty, "no civs")
        check(Set(civs.map(\.id)).count == civs.count, "civs: duplicate ids")
        for civ in civs {
            check(civ.cityNames.count >= 12, "civ \(civ.id): needs at least 12 city names")
            check(Set(civ.cityNames).count == civ.cityNames.count, "civ \(civ.id): duplicate city names")
            check(!civ.leader.isEmpty && !civ.name.isEmpty, "civ \(civ.id): needs a name and a leader")
        }

        // Focuses.
        for f in focuses {
            check(f.food >= 0 && f.production >= 0 && f.gold >= 0 && f.science >= 0 && f.culture >= 0,
                  "focus \(f.focus): negative weight")
        }

        // Constants.
        let c = constants
        check(c.start.gold >= 0, "start gold negative")
        check(c.start.units.contains { u in units.first { $0.type == u }?.foundsCity == true }, "players must start with a city founder")
        check(c.growth.foodPerCitizen > 0 && c.growth.base > 0 && c.growth.perPopulation >= 0 && c.growth.curvePct >= 0,
              "growth constants out of range")
        check(c.city.centreMinFood >= 0 && c.city.centreMinProduction >= 0, "city centre minimums negative")
        check(c.city.foundingProduction >= 0, "founding production negative")
        check(c.city.youngCityProduction >= 0 && c.city.youngCityPopulation >= 0 && c.city.capturedProduction >= 0,
              "young or captured city production negative")
        check(c.production.waitingHeadFillPct >= 0 && c.production.waitingHeadFillPct <= 100,
              "production.waitingHeadFillPct out of range")
        check(c.city.populationPerScience > 0, "populationPerScience must be positive")
        check(c.city.sight >= 1 && c.city.workRadius >= 1 && c.city.initialRadius >= 0 && c.city.minDistance >= 1,
              "city radii out of range")
        check(c.city.maxHP > 0 && c.city.healPerPhase >= 0 && c.city.wallRepairPerPhase >= 0
              && c.city.capturedHP > 0 && c.city.capturedHP <= c.city.maxHP, "city HP constants out of range")
        check(c.borders.baseCost > 0 && c.borders.costPerTile >= 0 && c.borders.radius >= c.city.initialRadius,
              "border constants out of range")
        check(c.production.maxQueue >= 1 && c.production.purchaseCostMultiplier >= 1
              && c.production.storedProgressCapMultiplier >= 0 && c.production.spawnRadius >= 0,
              "production constants out of range")
        check(c.healing.maxHP > 0, "unit max HP must be positive")
        check(c.upkeep.freeBase >= 0 && c.upkeep.freePerCity >= 0 && c.upkeep.goldPerUnit >= 0, "upkeep constants negative")
        check(c.combat.maxDifference > 0 && c.combat.rollRange >= 0 && c.combat.rollRange < 100
              && c.combat.damageScale > 0 && c.combat.hpPerWoundPenalty > 0, "combat constants out of range")
        check(c.knowledge.sightingMaxAge >= 0, "sighting age negative")
        check(c.turnLimit >= 1, "turn limit must be positive")
        check(c.settle.radius >= 0, "settle radius negative")

        // AI.
        check(Set(ai.researchOrderPeace) == Set(techIDs) && ai.researchOrderPeace.count == techIDs.count,
              "ai.researchOrderPeace must list every tech once")
        check(Set(ai.researchOrderWar) == Set(techIDs) && ai.researchOrderWar.count == techIDs.count,
              "ai.researchOrderWar must list every tech once")
        check(ai.maxCities.allSatisfy { $0.cities >= 1 } && ai.defaultMaxCities >= 1, "ai.maxCities out of range")
        for pct in [ai.firstCityMovePct, ai.settlersPerCityPct, ai.buildersPerCityPct, ai.archersPerMeleePct,
                    ai.buyCivilianGoldPct, ai.warRatioPct, ai.attackKillChancePct, ai.sortieKillChancePct, ai.peaceRatioPct,
                    ai.queueSwitchProgressPct, ai.buyArmyGoldPct, ai.shipsPerCoastalCityPct ?? 0] {
            check(pct >= 0 && pct <= 1000, "ai percentage \(pct) out of range")
        }
        check(ai.maxCommandsPerPhase >= 10, "ai.maxCommandsPerPhase must be at least 10")
        for value in [ai.settleCostPenalty, ai.earlyTurns, ai.garrisonMaxMoveCost, ai.escortMaxMoveCost, ai.minSettleScore,
                      ai.settleMaxMoveCost, ai.settleMaxCityDistance, ai.settleSiteSpacing, ai.civilianSafetyRadius,
                      ai.scoutTargetSpacing, ai.threatRadius, ai.defendersPerCity, ai.threatenedDefenders, ai.rallyRadius,
                      ai.retreatHP, ai.rejoinHP, ai.defendRecallRadius, ai.sightingMaxAge, ai.cityPowerEstimate,
                      ai.siegeStageRadius, ai.builderMaxMoveCost, ai.armyFirstCities] {
            check(value >= 0, "ai value \(value) must not be negative")
        }
        for value in [ai.prepareSettlersRivalPct, ai.prepareSiteRivalWeight, ai.prepareStageRadius, ai.prepareStageUnits].compactMap({ $0 }) {
            check(value >= 0 && value <= 1000, "ai value \(value) out of range")
        }

        // Tribal villages (optional section).
        if let v = tribalVillages {
            check(v.rounds.count <= 6, "tribalVillages: at most 6 rounds")
            for (i, round) in v.rounds.enumerated() {
                check(round.count >= 1 && round.count <= 4, "tribalVillages: round \(i) needs 1-4 bands")
                for band in round {
                    check(band.min >= 1 && band.min <= band.max && band.max <= 30,
                          "tribalVillages: round \(i) band \(band.min)-\(band.max) out of range (1 ≤ min ≤ max ≤ 30)")
                    check(band.margin >= 0 && band.margin <= 20, "tribalVillages: round \(i) band margin \(band.margin) out of range (0-20)")
                }
            }
            check(v.shared.perStart >= 0 && v.shared.perStart <= 3, "tribalVillages.shared.perStart out of range (0-3)")
            check(v.shared.minSteps >= 1 && v.shared.minSteps <= 30, "tribalVillages.shared.minSteps out of range (1-30)")
            check(v.shared.maxMargin >= 0 && v.shared.maxMargin <= 10, "tribalVillages.shared.maxMargin out of range (0-10)")
            check(v.spacing >= 1 && v.spacing <= 8, "tribalVillages.spacing out of range (1-8)")
            check(v.gifts.gold >= 0 && v.gifts.gold <= 500, "tribalVillages.gifts.gold out of range (0-500)")
            check(v.gifts.science >= 0 && v.gifts.science <= 500, "tribalVillages.gifts.science out of range (0-500)")
            check(v.gifts.builderRadius >= 0 && v.gifts.builderRadius <= 3, "tribalVillages.gifts.builderRadius out of range (0-3)")
            check(v.seekTurns >= 0 && v.seekTurns <= 10, "tribalVillages.seekTurns out of range (0-10)")
        }
        return problems
    }

    /// Problems with an Insight's arguments (M2 §6.2).
    private func insightProblems(_ insight: InsightDef, _ context: String) -> [String] {
        var problems: [String] = []
        let needsCount: Set<InsightKind> = [.ownCoastalCities, .meetPlayers, .ownCities, .buildImprovements, .ownBuildings, .ownUnits]
        if needsCount.contains(insight.kind), (insight.count ?? 0) < 1 { problems.append("\(context): insight needs a count ≥ 1") }
        switch insight.kind {
        case .buildImprovements:
            if !Improvement.allCases.contains(where: { caseName($0) == insight.target }) {
                problems.append("\(context): insight improvement \(insight.target ?? "nil") unknown")
            }
        case .ownBuildings:
            if !buildings.contains(where: { $0.id.rawValue == insight.target }) {
                problems.append("\(context): insight building \(insight.target ?? "nil") unknown")
            }
        case .ownUnits:
            if UnitType(rawValue: insight.target ?? "") == nil { problems.append("\(context): insight unit \(insight.target ?? "nil") unknown") }
        case .killWith:
            if (insight.classes ?? []).isEmpty { problems.append("\(context): insight needs classes") }
        case .ownCoastalCities, .meetPlayers, .ownCities, .cityDefended:
            break
        }
        if insight.text.isEmpty { problems.append("\(context): insight text is empty") }
        return problems
    }

    /// A tech on a prerequisite cycle, if any (DFS over the graph, unknown references ignored).
    private func techCycle() -> TechID? {
        var state = [Int](repeating: 0, count: techs.count) // 0 new, 1 on stack, 2 done
        func visit(_ i: Int) -> TechID? {
            if state[i] == 1 { return techs[i].id }
            if state[i] == 2 { return nil }
            state[i] = 1
            for r in techs[i].requires {
                if let j = techs.firstIndex(where: { $0.id == r }), let found = visit(j) { return found }
            }
            state[i] = 2
            return nil
        }
        for i in techs.indices { if let found = visit(i) { return found } }
        return nil
    }
}

extension CodingUserInfoKey {
    /// The `Ruleset` a decoded `GameState` plays by (read by `RulesRef`); `Ruleset.standard`
    /// when absent.
    public static let ruleset = CodingUserInfoKey(rawValue: "TenThousandYears.ruleset")!
}

/// Decoding met a state saved under different rules (another ruleset id).
public struct RulesMismatch: Error, Hashable, Sendable, CustomStringConvertible {
    /// The ruleset id the state was saved with.
    public let saved: String
    /// The id of the ruleset it was decoded against.
    public let current: String

    public init(saved: String, current: String) {
        self.saved = saved
        self.current = current
    }

    public var description: String { "saved with rules \(saved), not \(current)" }
}

/// How a `GameState` refers to its rules: encoded as `{id, contentHash}`, never the data itself.
/// Decoding takes the ruleset from `decoder.userInfo[.ruleset]` (default `Ruleset.standard`) and
/// throws `RulesMismatch` when the encoded id differs from it; a different content hash under
/// the same id still loads, and `contentHashChanged` tells the loader to warn (M1 §12.3).
/// Equal when id and content hash are.
public struct RulesRef: Codable, Hashable, Sendable {
    public let rules: Ruleset
    /// The content hash recorded where this reference was decoded from (the rules' own hash for
    /// a new reference). Not part of `==`, the hash or the encoding: re-encoding writes the
    /// current rules' hash.
    public let savedContentHash: UInt64

    public init(rules: Ruleset) {
        self.rules = rules
        self.savedContentHash = rules.contentHash
    }

    /// Whether the state was saved under the same rules id but different rules data (M1 §12.3:
    /// it loads, with a warning).
    public var contentHashChanged: Bool { savedContentHash != rules.contentHash }

    private enum CodingKeys: String, CodingKey {
        case id, contentHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let saved = try container.decode(UInt64.self, forKey: .contentHash)
        let rules = decoder.userInfo[.ruleset] as? Ruleset ?? .standard
        guard id == rules.id else { throw RulesMismatch(saved: id, current: rules.id) }
        self.rules = rules
        self.savedContentHash = saved
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules.id, forKey: .id)
        try container.encode(rules.contentHash, forKey: .contentHash)
    }

    public static func == (a: RulesRef, b: RulesRef) -> Bool {
        a.rules.id == b.rules.id && a.rules.contentHash == b.rules.contentHash
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rules.id)
        hasher.combine(rules.contentHash)
    }
}
