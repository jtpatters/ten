import Foundation
import GameCore

public enum MapSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case duel, small, standard, large

    public var id: String { rawValue }

    /// Dimensions from SPEC §3.1.
    public var dimensions: (width: Int, height: Int) {
        switch self {
        case .duel: (44, 26)
        case .small: (60, 38)
        case .standard: (80, 50)
        case .large: (104, 64)
        }
    }

    public var defaultPlayers: Int {
        switch self {
        case .duel: 2
        case .small: 4
        case .standard: 6
        case .large: 8
        }
    }

    public var displayName: String { rawValue.capitalized }
}

/// Map scripts (SPEC §3.1, M2 §3.5). Raw values go into game settings; append only.
public enum MapScript: String, CaseIterable, Codable, Sendable, Identifiable {
    /// M1's generator: one fractal land pattern, every start on the largest landmass.
    case pangaea
    /// Two large landmasses split by ocean seams; on Small and larger, starts on both.
    case continents
    /// Many smaller islands (finer noise, less land); on Small and larger, starts spread over them.
    case archipelago

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    /// Noise periods across the map's width (finer = more, smaller landmasses).
    var basePeriod: Int { self == .archipelago ? 12 : 4 }
    /// Share of `landFraction` kept (Archipelago is wetter).
    var landScale: Double { self == .archipelago ? 0.75 : 1 }
}

public struct MapGenSettings: Sendable {
    public var size: MapSize
    public var script: MapScript
    public var seed: UInt64
    public var playerCount: Int
    public var landFraction: Double
    public var wrapsX: Bool
    /// Resource definitions for placement (M2 §3.1); rules without resources place none.
    public var rules: Ruleset

    public init(size: MapSize, seed: UInt64, script: MapScript = .pangaea, playerCount: Int? = nil, landFraction: Double = 0.38,
                wrapsX: Bool = true, rules: Ruleset = .standard) {
        self.rules = rules
        self.size = size
        self.script = script
        self.seed = seed
        self.playerCount = playerCount ?? size.defaultPlayers
        self.landFraction = landFraction
        self.wrapsX = wrapsX
    }

    /// Duel keeps every start on one landmass (M2 §3.5).
    var separatesStarts: Bool { script != .pangaea && size != .duel }
}

public struct GeneratedMap: Sendable {
    public let map: HexMap
    public let startPositions: [HexCoord]
}

/// Fractal elevation → land/water by quantile, relief → hills/mountains,
/// latitude + noise → temperature, noise → moisture, then terrain/features and start positions.
public enum MapGenerator {
    /// Minimum distance between starts (M1 §2), and the floor it may be lowered to.
    static let startDistance = 6
    static let lowestStartDistance = 3
    /// Regenerations with derived seeds before the start distance is lowered.
    static let retryAttempts = 20

    /// Generates a map and its start positions (M1 §2). Every start is on the largest passable
    /// landmass (Continents and Archipelago off Duel: on the landmasses `startLandmasses` picks), at least `startDistance` apart. When the chosen seed cannot place them, the
    /// terrain is regenerated with derived seeds `SplitMix64(seed: seed, salts: attempt, 0x57A7)`
    /// for up to 20 attempts; then the minimum distance is lowered step by step to 3 on the best
    /// attempt (most starts placed; ties: the earliest). Starts are never on separate
    /// landmasses. The game keeps the chosen seed (the caller passes `settings.seed` on).
    public static func generate(_ settings: MapGenSettings) -> GeneratedMap {
        var generated = generateTerrainAndStarts(settings)
        var map = generated.map
        ResourcePlacer.place(on: &map, starts: generated.startPositions, seed: settings.seed, rules: settings.rules)
        generated = GeneratedMap(map: map, startPositions: generated.startPositions)
        return generated
    }

    static func generateTerrainAndStarts(_ settings: MapGenSettings) -> GeneratedMap {
        var best: (map: HexMap, placed: Int)?
        for attempt in 0...retryAttempts {
            let seed = attempt == 0 ? settings.seed : terrainSeed(settings.seed, attempt: attempt)
            let map = generateTerrain(settings, seed: seed)
            let starts = pickStartPositions(map: map, playerCount: settings.playerCount, minDistance: startDistance,
                                            separate: settings.separatesStarts)
            if starts.count >= settings.playerCount { return GeneratedMap(map: map, startPositions: starts) }
            if best == nil || starts.count > best!.placed { best = (map, starts.count) }
        }
        let map = best!.map
        var starts: [HexCoord] = []
        for distance in stride(from: startDistance - 1, through: lowestStartDistance, by: -1) {
            starts = pickStartPositions(map: map, playerCount: settings.playerCount, minDistance: distance,
                                        separate: settings.separatesStarts)
            if starts.count >= settings.playerCount { break }
        }
        if starts.count < settings.playerCount {
            // A landmass too small for everyone: still one landmass, as far apart as it allows.
            starts = pickStartPositions(map: map, playerCount: settings.playerCount, minDistance: 1, separate: settings.separatesStarts)
        }
        return GeneratedMap(map: map, startPositions: starts)
    }

    /// The terrain seed of retry `attempt` (M1 §2).
    static func terrainSeed(_ seed: UInt64, attempt: Int) -> UInt64 {
        var stream = SplitMix64(seed: seed, salts: UInt64(attempt), 0x57A7)
        return stream.next()
    }

    /// The terrain for one seed (no start positions).
    static func generateTerrain(_ settings: MapGenSettings, seed: UInt64) -> HexMap {
        let (w, h) = settings.size.dimensions
        let count = w * h
        let script = settings.script
        let period: Int? = settings.wrapsX ? script.basePeriod : nil
        let basePeriod = Double(script.basePeriod)

        var streams = SplitMix64(seed: seed, salts: 0x3A9)
        let elevationNoise = ValueNoise(seed: streams.next())
        let ruggedNoise = ValueNoise(seed: streams.next())
        let moistureNoise = ValueNoise(seed: streams.next())
        let temperatureNoise = ValueNoise(seed: streams.next())
        var featureRNG = SplitMix64(seed: streams.next())
        // Continents: where the two ocean seams run (a fraction of the width), from the seed.
        var seamStream = SplitMix64(seed: seed, salts: 0xC047)
        let seamPhase = script == .continents ? Double(seamStream.next() % 1000) / 1000 : 0

        // Sample positions in noise space, keeping hex aspect ratio (row step = 0.866 tile widths).
        func samplePoint(_ i: Int) -> (x: Double, y: Double, row: Int, col: Int) {
            let col = i % w, row = i / w
            let x = (Double(col) + 0.5 * Double(row & 1)) / Double(w) * basePeriod
            let y = Double(row) * 0.8660254037844386 / Double(w) * basePeriod
            return (x, y, row, col)
        }

        func latitude(_ row: Int) -> Double {
            let mid = Double(h - 1) / 2
            return abs(Double(row) - mid) / mid // 0 = equator, 1 = pole
        }

        // 1. Elevation with polar (and, without wrap, edge) falloff.
        var elevation = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let p = samplePoint(i)
            var e = elevationNoise.fbm(x: p.x, y: p.y, octaves: 5, period: period)
            e -= max(0, latitude(p.row) - 0.72) * 1.4
            if script == .continents {
                // Two seams half a map apart: land swells between them and drowns along them.
                let u = (Double(p.col) + 0.5 * Double(p.row & 1)) / Double(w) - seamPhase
                let toSeam = abs(u * 2 - (u * 2).rounded()) / 2 // 0 at a seam … 0.25 midway
                e += (toSeam - 0.125) * 1.2
                if toSeam < seamHalfWidth(w) { e -= 2 }
            }
            if !settings.wrapsX {
                let edge = min(Double(p.col), Double(w - 1 - p.col)) / Double(w)
                e -= max(0, 0.08 - edge) * 4
            }
            elevation[i] = e
        }
        let seaLevel = quantile(elevation, 1 - settings.landFraction * script.landScale)
        let isLand = elevation.map { $0 >= seaLevel }

        // 2. Relief (hills/mountains) from land elevation rank + high-frequency ruggedness.
        let landIndices = (0..<count).filter { isLand[$0] }
        let landRank = ranks(of: landIndices.map { elevation[$0] })
        var relief = [Double](repeating: -1, count: count)
        for (k, i) in landIndices.enumerated() {
            let p = samplePoint(i)
            let rugged = ruggedNoise.fbm(x: p.x * 3, y: p.y * 3, octaves: 3, period: period.map { $0 * 3 })
            relief[i] = 0.55 * landRank[k] + 0.45 * rugged
        }
        let landRelief = landIndices.map { relief[$0] }
        let mountainLevel = quantile(landRelief, 0.93)
        let hillLevel = quantile(landRelief, 0.77)

        // 3. Moisture (rank-normalized to uniform [0,1]) and temperature.
        let rawMoisture = (0..<count).map { i -> Double in
            let p = samplePoint(i)
            return moistureNoise.fbm(x: p.x * 1.5, y: p.y * 1.5, octaves: 4, period: period.map { $0 * 3 / 2 })
        }
        let moisture = ranks(of: rawMoisture)

        var map = HexMap(width: w, height: h, wrapsX: settings.wrapsX)
        for i in 0..<count {
            let p = samplePoint(i)
            let tempJitter = temperatureNoise.fbm(x: p.x * 2, y: p.y * 2, octaves: 3, period: period.map { $0 * 2 }) - 0.5
            guard isLand[i] else {
                var tile = Tile(terrain: .ocean)
                let t = 1 - latitude(p.row) + tempJitter * 0.2
                if t < 0.1, featureRNG.chance(0.7) { tile.feature = .ice }
                map[index: i] = tile
                continue
            }
            let elevationClass: Elevation = relief[i] >= mountainLevel ? .mountains : (relief[i] >= hillLevel ? .hills : .flat)
            var t = 1 - latitude(p.row) + tempJitter * 0.25
            if elevationClass == .hills { t -= 0.06 }
            if elevationClass == .mountains { t -= 0.12 }
            let m = moisture[i]

            let terrain: Terrain
            if t < 0.12 { terrain = .snow }
            else if t < 0.27 { terrain = .tundra }
            else if m < 0.28 && t > 0.55 { terrain = .desert }
            else if m < 0.55 { terrain = .plains }
            else { terrain = .grassland }

            var feature = Feature.none
            if elevationClass != .mountains {
                switch terrain {
                case .desert:
                    if elevationClass == .flat, featureRNG.chance(0.04) { feature = .oasis }
                case .tundra:
                    if m > 0.5, featureRNG.chance(0.5) { feature = .forest }
                case .grassland, .plains:
                    if terrain == .grassland, elevationClass == .flat, m > 0.86, featureRNG.chance(0.4) { feature = .marsh }
                    else if t > 0.72, m > 0.62, featureRNG.chance(0.75) { feature = .jungle }
                    else if m > 0.5, featureRNG.chance(0.55) { feature = .forest }
                default: break
                }
            }
            map[index: i] = Tile(terrain: terrain, elevation: elevationClass, feature: feature)
        }

        // 4. Small enclosed water bodies become lakes; ocean touching land becomes coast.
        for component in components(in: map, where: { $0.terrain.isWater }) where component.count < 12 {
            for i in component { map[index: i] = Tile(terrain: .lake) }
        }
        for i in 0..<count where map[index: i].terrain == .ocean {
            let hex = map.coord(at: i)
            if map.neighbors(of: hex).contains(where: { map[$0].isLand }) {
                var tile = map[index: i]
                tile.terrain = .coast
                let t = 1 - latitude(i / w)
                if tile.feature == .none, t > 0.6, featureRNG.chance(0.05) { tile.feature = .reef }
                map[index: i] = tile
            }
        }

        // 5. Rivers along hex edges, from wet highlands down to the sea; desert banks flood.
        var riverRNG = SplitMix64(seed: streams.next())
        carveRivers(in: &map, elevation: elevation, moisture: moisture, rng: &riverRNG)
        for i in 0..<count {
            var tile = map[index: i]
            if tile.riverEdges != 0, tile.terrain == .desert, tile.elevation == .flat, tile.feature == .none {
                tile.feature = .floodplain
                map[index: i] = tile
            }
        }

        return map
    }

    // MARK: Start positions

    /// Start scoring (M1 §2): land the capital can work and improve. Forest, jungle and marsh
    /// never take an improvement in M1 (§4), so forest earns no bonus (jungle and marsh lose
    /// 2). Each tile within 2 that a Farm, Mine or Pasture may stand on earns
    /// `improvableBonus`, up to `improvableWanted` tiles (beyond that, raw yields decide), and
    /// those at distance 1, which the capital owns from turn 1, earn `firstRingBonus` more, up
    /// to `firstRingWanted`. The capital's first citizens grow on 2-Food tiles next to it:
    /// `foodTileBonus` each, up to `foodTilesWanted`.
    static let improvableBonus = 2
    static let improvableWanted = 8
    static let firstRingBonus = 2
    static let firstRingWanted = 3
    static let foodTileBonus = 4
    static let foodTilesWanted = 2

    /// How good a start the tile is: its land within 2, coast next to it, fresh water.
    public static func startScore(_ hex: HexCoord, in map: HexMap) -> Int {
        var score = 0
        var improvable = 0, firstRing = 0, foodTiles = 0
        for c in map.coords(within: 2, of: hex) {
            let tile = map[c]
            var v: Int
            switch tile.terrain {
            case .grassland, .plains: v = 6
            case .coast, .lake: v = 4
            case .ocean: v = 1
            case .tundra: v = 2
            case .desert: v = tile.feature == .oasis ? 6 : 0
            case .snow: v = 0
            }
            if tile.elevation == .hills { v += 1 }
            if tile.elevation == .mountains { v = 1 }
            if tile.feature == .marsh || tile.feature == .jungle { v -= 2 }
            score += v
            guard c != hex else { continue }
            let near = map.distance(c, hex) == 1
            if near, food(tile) >= 2 { foodTiles += 1 }
            if isImprovable(tile) {
                improvable += 1
                if near { firstRing += 1 }
            }
        }
        score += improvableBonus * min(improvable, improvableWanted) + firstRingBonus * min(firstRing, firstRingWanted)
            + foodTileBonus * min(foodTiles, foodTilesWanted)
        if map.neighbors(of: hex).contains(where: { map[$0].terrain == .coast }) { score += 8 }
        if hasFreshWater(hex, in: map) { score += 6 }
        return score
    }

    /// Whether a Farm, Mine or Pasture may stand on the tile, by M1 §4's sites (Farms on flat
    /// Grassland, Plains, Tundra, or Desert with Floodplain; Mines on Hills, not Snow; Pastures
    /// on flat Grassland, Plains, Tundra; never with forest, jungle or marsh). Any tech.
    static func isImprovable(_ tile: Tile) -> Bool {
        guard tile.isLand, tile.feature == .none || tile.feature == .floodplain else { return false }
        switch tile.elevation {
        case .flat: return [.grassland, .plains, .tundra].contains(tile.terrain) || (tile.terrain == .desert && tile.feature == .floodplain)
        case .hills: return tile.terrain != .snow
        case .mountains: return false
        }
    }

    /// The tile's Food by M1 §4, unimproved and without techs (0 on unworkable mountains).
    static func food(_ tile: Tile) -> Int {
        guard tile.elevation != .mountains else { return 0 }
        var food: Int
        switch tile.terrain {
        case .grassland, .lake: food = 2
        case .plains, .tundra, .coast, .ocean: food = 1
        case .desert, .snow: food = 0
        }
        switch tile.feature {
        case .jungle, .marsh, .reef: food += 1
        case .floodplain: food += 2
        case .oasis: food += 3
        case .none, .forest, .ice: break
        }
        return food
    }

    /// Fresh water (M1 §4): a river edge, or a lake next to the tile.
    static func hasFreshWater(_ hex: HexCoord, in map: HexMap) -> Bool {
        map[hex].riverEdges != 0 || map.neighbors(of: hex).contains { map[$0].terrain == .lake }
    }

    /// Continents' ocean seams: at least 2 tiles of water on each side of the seam line.
    static func seamHalfWidth(_ width: Int) -> Double { max(0.02, 2.5 / Double(width)) }

    /// The passable landmasses that get starts and how many each (separate starts: those with
    /// at least `minStartLand` tiles per start, by largest remainder of land per start — each
    /// start goes to the landmass with the most land per start it would hold; ties: larger,
    /// then lower first index). Otherwise, or when none qualifies: all on the largest.
    static func startLandmasses(_ map: HexMap, playerCount: Int, separate: Bool) -> [(tiles: [Int], starts: Int)] {
        let all = components(in: map, where: { $0.landMovementCost != nil })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
        guard let largest = all.first else { return [] }
        guard separate, playerCount > 1 else { return [(largest, playerCount)] }
        let candidates = all.filter { $0.count >= minStartLand }
        guard candidates.count > 1 else { return [(largest, playerCount)] }
        var starts = [Int](repeating: 0, count: candidates.count)
        for _ in 0..<playerCount {
            var best = -1
            for k in candidates.indices where candidates[k].count / (starts[k] + 1) >= minStartLand {
                if best < 0 || candidates[k].count * (starts[best] + 1) > candidates[best].count * (starts[k] + 1) { best = k }
            }
            if best < 0 { best = 0 }
            starts[best] += 1
        }
        return candidates.indices.filter { starts[$0] > 0 }.map { (candidates[$0], starts[$0]) }
    }

    /// The least land a start needs on its own landmass when starts are separated.
    static let minStartLand = 45

    /// The largest passable landmass (tile indices, increasing; ties: the one with the lowest
    /// index).
    static func largestLandmass(_ map: HexMap) -> [Int] {
        components(in: map, where: { $0.landMovementCost != nil }).max { $0.count < $1.count || ($0.count == $1.count && $0[0] > $1[0]) } ?? []
    }

    /// Start positions on the largest passable landmass, at least `minDistance` apart (fewer
    /// than `playerCount` when they do not fit). Starts spread out: the spacing begins at
    /// √(landmass / players) and shrinks to `minDistance`; Grassland and Plains (not marsh)
    /// with the best `startScore` come first, other land that allows a city only when they
    /// run out.
    static func pickStartPositions(map: HexMap, playerCount: Int, minDistance: Int, separate: Bool = false) -> [HexCoord] {
        var chosen: [HexCoord] = []
        for (landmass, count) in startLandmasses(map, playerCount: playerCount, separate: separate) {
            chosen += pickStartPositions(map: map, landmass: landmass, playerCount: count, minDistance: minDistance, chosen: chosen)
        }
        return chosen
    }

    static func pickStartPositions(map: HexMap, landmass: [Int], playerCount: Int, minDistance: Int, chosen earlier: [HexCoord]) -> [HexCoord] {
        func scored(_ indices: [Int]) -> [HexCoord] {
            // Highest score first; ties: lower tile index (explicit, not left to sort stability).
            indices.map { (index: $0, score: startScore(map.coord(at: $0), in: map)) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                .map { map.coord(at: $0.index) }
        }
        let preferred = scored(landmass.filter { i in
            let tile = map[index: i]
            return (tile.terrain == .grassland || tile.terrain == .plains) && tile.feature != .marsh
        })
        let others = scored(landmass.filter { i in
            let tile = map[index: i]
            return !((tile.terrain == .grassland || tile.terrain == .plains) && tile.feature != .marsh)
                && tile.feature != .oasis && tile.terrain != .snow
        })

        var chosen: [HexCoord] = []
        func place(from candidates: [HexCoord], spacing: Int) -> Bool {
            guard let next = candidates.first(where: { c in
                chosen.allSatisfy { map.distance($0, c) >= spacing } && earlier.allSatisfy { map.distance($0, c) >= minDistance }
            }) else { return false }
            chosen.append(next)
            return true
        }
        var spacing = max(minDistance, Int((Double(landmass.count) / Double(max(playerCount, 1))).squareRoot()))
        while chosen.count < playerCount, spacing >= minDistance {
            if !place(from: preferred, spacing: spacing) { spacing -= 1 }
        }
        while chosen.count < playerCount, place(from: preferred + others, spacing: minDistance) {}
        return chosen
    }

    // MARK: Rivers

    /// A hex corner, named by the three tiles that meet there (sorted indices).
    struct Corner: Hashable {
        let tiles: [Int]
        init(_ a: Int, _ b: Int, _ c: Int) { tiles = [a, b, c].sorted() }
    }

    static func neighborIndex(_ i: Int, _ d: HexDirection, in map: HexMap) -> Int? {
        map.normalize(map.coord(at: i).neighbor(d)).flatMap(map.index(of:))
    }

    static func direction(from a: Int, to b: Int, in map: HexMap) -> HexDirection? {
        HexDirection.allCases.first { neighborIndex(a, $0, in: map) == b }
    }

    /// The corners one edge away from `corner`, each with the tile pair whose shared edge leads there.
    static func adjacentCorners(_ corner: Corner, in map: HexMap) -> [(corner: Corner, edge: (Int, Int))] {
        let t = corner.tiles
        var result: [(Corner, (Int, Int))] = []
        for (p, q, r) in [(t[0], t[1], t[2]), (t[1], t[2], t[0]), (t[0], t[2], t[1])] {
            guard let d = direction(from: p, to: q, in: map) else { continue }
            let sides = [HexDirection(rawValue: (d.rawValue + 1) % 6)!, HexDirection(rawValue: (d.rawValue + 5) % 6)!]
            guard let e = sides.compactMap({ neighborIndex(p, $0, in: map) }).first(where: { $0 != r }) else { continue }
            result.append((Corner(p, q, e), (p, q)))
        }
        return result
    }

    /// Rivers walk corner to corner along hex edges, always taking the lowest unvisited next
    /// corner, until they reach water or join an existing river. Walks that wander too long
    /// without reaching either are dropped. Both tiles sharing a river edge get its bit.
    ///
    /// Greedy descent circles a tile lower than its neighbours, since every corner of that
    /// tile is low, and a tributary can close the ring another river started: either way a
    /// tile ends up in a moat. No tile may border more than `maxEdgesAroundTile` river edges
    /// (half a hex: a U-bend or a confluence fork).
    static let maxEdgesAroundTile = 3

    /// Added to a corner's height when stepping there bends the river around half a tile
    /// (two turns the same way). Rivers then mostly alternate turns and run straighter, so
    /// their shape follows the land rather than the hex outlines; a real valley still wins.
    static let bendPenalty = 0.02

    /// The longest run of adjacent river edges in a tile's six-bit edge mask (edges wrap).
    static func longestEdgeRun(_ mask: UInt8) -> Int {
        if mask & 0b11_1111 == 0b11_1111 { return 6 }
        var best = 0, run = 0
        for i in 0..<12 { // twice around, so a run through edge 5 into edge 0 counts whole
            run = mask & (1 << (i % 6)) != 0 ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    static func carveRivers(in map: inout HexMap, elevation: [Double], moisture: [Double], rng: inout SplitMix64) {
        let count = map.tileCount
        func height(_ c: Corner) -> Double { c.tiles.reduce(0) { $0 + elevation[$1] } / 3 }
        func touchesWater(_ c: Corner) -> Bool { c.tiles.contains { map[index: $0].terrain.isWater } }
        /// Edge bits of the walk in progress, per tile (committed rivers are in the map).
        var walkEdges: [Int: UInt8] = [:]
        /// The bit `edge` sets on each of its two tiles.
        func bits(_ edge: (Int, Int)) -> (UInt8, UInt8)? {
            direction(from: edge.0, to: edge.1, in: map).map { (UInt8(1) << $0.rawValue, UInt8(1) << $0.opposite.rawValue) }
        }
        /// The cost of stepping along `edge` to `corner`: the corner's height, plus the bend
        /// penalty when either tile of the edge would then wrap half a tile; nil when either
        /// would be ringed by more than `maxEdgesAroundTile` river edges (a moat).
        func cost(_ corner: Corner, _ edge: (Int, Int)) -> Double? {
            guard let bit = bits(edge) else { return nil }
            let a = map[index: edge.0].riverEdges | (walkEdges[edge.0] ?? 0) | bit.0
            let b = map[index: edge.1].riverEdges | (walkEdges[edge.1] ?? 0) | bit.1
            guard a.nonzeroBitCount <= maxEdgesAroundTile, b.nonzeroBitCount <= maxEdgesAroundTile else { return nil }
            let bends = longestEdgeRun(a) >= 3 || longestEdgeRun(b) >= 3
            return height(corner) + (bends ? bendPenalty : 0)
        }

        let landCount = (0..<count).filter { map[index: $0].isLand }.count
        let target = max(2, landCount / 40)
        var sources = (0..<count).filter { i in
            let tile = map[index: i]
            return tile.isLand && tile.elevation != .flat && tile.terrain != .snow && moisture[i] > 0.3
        }
        // Deterministic shuffle.
        for k in stride(from: sources.count - 1, to: 0, by: -1) { sources.swapAt(k, rng.nextInt(below: k + 1)) }

        var riverCorners = Set<Corner>()
        var sourceTiles: [HexCoord] = []
        var made = 0
        for source in sources where made < target {
            let hex = map.coord(at: source)
            if sourceTiles.contains(where: { map.distance($0, hex) < 4 }) { continue }
            let corners = HexDirection.allCases.compactMap { d -> Corner? in
                guard let a = neighborIndex(source, d, in: map),
                      let b = neighborIndex(source, HexDirection(rawValue: (d.rawValue + 1) % 6)!, in: map) else { return nil }
                return Corner(source, a, b)
            }
            guard let start = corners.filter({ !touchesWater($0) && !riverCorners.contains($0) }).min(by: { height($0) < height($1) })
            else { continue }

            var current = start
            var visited: Set<Corner> = [start]
            var edges: [(Int, Int)] = []
            var finished = false
            walkEdges.removeAll(keepingCapacity: true)
            for _ in 0..<60 {
                if touchesWater(current) || (!edges.isEmpty && riverCorners.contains(current)) {
                    finished = true
                    break
                }
                var best: (corner: Corner, edge: (Int, Int), cost: Double)?
                for step in adjacentCorners(current, in: map) where !visited.contains(step.corner) {
                    guard let c = cost(step.corner, step.edge), c < best?.cost ?? .infinity else { continue }
                    best = (step.corner, step.edge, c)
                }
                guard let next = best, let bit = bits(next.edge) else { break }
                edges.append(next.edge)
                walkEdges[next.edge.0, default: 0] |= bit.0
                walkEdges[next.edge.1, default: 0] |= bit.1
                visited.insert(next.corner)
                current = next.corner
            }
            guard finished, edges.count >= 3 else { continue }
            for (a, b) in edges {
                guard let d = direction(from: a, to: b, in: map) else { continue }
                var ta = map[index: a], tb = map[index: b]
                ta.riverEdges |= 1 << d.rawValue
                tb.riverEdges |= 1 << d.opposite.rawValue
                map[index: a] = ta
                map[index: b] = tb
            }
            riverCorners.formUnion(visited)
            sourceTiles.append(hex)
            made += 1
        }
    }

    // MARK: Helpers

    /// Connected components (tile indices) of tiles matching `predicate`, in index order.
    static func components(in map: HexMap, where predicate: (Tile) -> Bool) -> [[Int]] {
        var visited = [Bool](repeating: false, count: map.tileCount)
        var result: [[Int]] = []
        for start in 0..<map.tileCount where !visited[start] && predicate(map[index: start]) {
            var component: [Int] = []
            var stack = [start]
            visited[start] = true
            while let i = stack.popLast() {
                component.append(i)
                for n in map.neighbors(of: map.coord(at: i)) {
                    let ni = map.index(of: n)!
                    if !visited[ni], predicate(map[index: ni]) {
                        visited[ni] = true
                        stack.append(ni)
                    }
                }
            }
            result.append(component.sorted())
        }
        return result
    }

    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(q * Double(sorted.count))))
        return sorted[idx]
    }

    /// Rank-normalize to [0, 1]; ties broken by index for determinism.
    static func ranks(of values: [Double]) -> [Double] {
        guard values.count > 1 else { return values.map { _ in 0.5 } }
        let order = values.indices.sorted { (values[$0], $0) < (values[$1], $1) }
        var result = [Double](repeating: 0, count: values.count)
        let denom = Double(values.count - 1)
        for (rank, i) in order.enumerated() { result[i] = Double(rank) / denom }
        return result
    }
}
