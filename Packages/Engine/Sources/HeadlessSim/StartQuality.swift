import Foundation
import GameCore
import MapGen

// `--starts` (p3b coreai-1): how good the generated start positions are, map by map, without
// playing (M1 §2, §4). For every start it measures the land around it with the rules: the
// tiles that can take an improvement (Farm, Mine or Pasture, by M1 §4's site rules, any tech),
// the tiles locked under forest, jungle or marsh, fresh water, a neutral site value (the
// settle score with full knowledge, M1 §13 weights) and the best four tiles a citizen could
// work, as they are and improved. Prints one `START {json}` line per map and a summary,
// including the gap between the players' starts (fairness).

/// One start's land.
struct StartMetrics: Codable {
    var player: Int
    var hex: String
    /// The centre tile: terrain, elevation, feature, "river" when it has a river edge.
    var tile: String
    /// MapGen's own start score (`MapGenerator.startScore`), the one it ranks starts by.
    var startScore: Int
    /// Tiles at distance 1 (resp. within 2, within 3) that a Farm, Mine or Pasture may stand on.
    var improvable1: Int
    var improvable2: Int
    var improvable3: Int
    /// Of those within 2: Mine sites (hills), and Farm sites with fresh water.
    var mineSites2: Int
    var freshFarms2: Int
    /// Land within 2 (centre excluded) under forest, jungle or marsh: never improvable in M1.
    var locked2: Int
    /// Workable land within 2, centre excluded.
    var land2: Int
    /// The centre has fresh water (a river edge or a lake next to it).
    var freshWaterCentre: Bool
    /// Settle score with full knowledge (M1 settle weights, radius 2, bonuses).
    var siteValue: Int
    /// Balanced-focus value (3F + 2P + 1G) of the four best tiles within 2, unimproved, and
    /// with each tile's best improvement (every tech known).
    var bestFour: Int
    var bestFourImproved: Int
    /// The capital's Production and Food surplus when founded on the start (turn 1,
    /// population 1, Palace), by the engine's own citizen assignment; nil if it cannot found.
    var capitalProduction: Int?
    var capitalSurplus: Int?
}

struct StartRecord: Codable {
    var seed: UInt64
    var size: String
    var starts: [StartMetrics]
}

enum StartQuality {
    static func describe(_ tile: Tile) -> String {
        var parts = ["\(tile.terrain)", "\(tile.elevation)"]
        if tile.feature != .none { parts.append("\(tile.feature)") }
        if tile.riverEdges != 0 { parts.append("river") }
        return parts.joined(separator: "/")
    }

    static func touchesLake(_ hex: HexCoord, _ map: HexMap) -> Bool {
        map.neighbors(of: hex).contains { map[$0].terrain == .lake }
    }

    static func freshWater(_ hex: HexCoord, _ map: HexMap) -> Bool {
        map[hex].riverEdges != 0 || touchesLake(hex, map)
    }

    static func improvable(_ tile: Tile, _ rules: Ruleset) -> Bool {
        tile.isLand && Improvement.allCases.contains { rules.allowsImprovement($0, on: tile) }
    }

    static func measure(_ hex: HexCoord, player: Int, map: HexMap, rules: Ruleset) -> StartMetrics {
        let none: (TechID) -> Bool = { _ in false }
        let all: (TechID) -> Bool = { _ in true }
        let balanced = rules.focus(.balanced)
        var m = StartMetrics(player: player, hex: "\(hex)", tile: describe(map[hex]), startScore: MapGenerator.startScore(hex, in: map),
                             improvable1: 0, improvable2: 0, improvable3: 0, mineSites2: 0, freshFarms2: 0, locked2: 0, land2: 0,
                             freshWaterCentre: freshWater(hex, map), siteValue: 0, bestFour: 0, bestFourImproved: 0,
                             capitalProduction: nil, capitalSurplus: nil)
        var plain: [Int] = [], improved: [Int] = []
        for c in map.coords(within: 3, of: hex) where c != hex {
            let tile = map[c]
            let d = map.distance(c, hex)
            if improvable(tile, rules) {
                if d <= 1 { m.improvable1 += 1 }
                if d <= 2 { m.improvable2 += 1 }
                m.improvable3 += 1
            }
            guard d <= 2 else { continue }
            if rules.allowsImprovement(.mine, on: tile) { m.mineSites2 += 1 }
            if rules.allowsImprovement(.farm, on: tile), freshWater(c, map) { m.freshFarms2 += 1 }
            if tile.isLand, tile.feature == .forest || tile.feature == .jungle || tile.feature == .marsh { m.locked2 += 1 }
            guard tile.isLand, rules.isWorkable(tile) else { continue }
            m.land2 += 1
            let lake = touchesLake(c, map)
            plain.append(balanced.value(rules.tileYields(tile, knows: none, touchesLake: lake)))
            var best = balanced.value(rules.tileYields(tile, knows: all, touchesLake: lake))
            for kind in Improvement.allCases where rules.allowsImprovement(kind, on: tile) {
                var t = tile
                t.improvement = kind
                best = max(best, balanced.value(rules.tileYields(t, knows: all, touchesLake: lake)))
            }
            improved.append(best)
        }
        // Water tiles count too: a citizen may work coast and lake.
        for c in map.coords(within: 2, of: hex) where c != hex && map[c].terrain.isWater && rules.isWorkable(map[c]) {
            plain.append(balanced.value(rules.tileYields(map[c], knows: none)))
            improved.append(balanced.value(rules.tileYields(map[c], knows: all)))
        }
        m.bestFour = plain.sorted(by: >).prefix(4).reduce(0, +)
        m.bestFourImproved = improved.sorted(by: >).prefix(4).reduce(0, +)
        // The settle score with full knowledge (PlayerView.settleScore with nothing owned).
        let s = rules.constants.settle
        for c in map.coords(within: s.radius, of: hex) where rules.isWorkable(map[c]) {
            let y = rules.tileYields(map[c], knows: none, isCityCentre: c == hex)
            m.siteValue += s.foodWeight * y.food + s.productionWeight * y.production + s.goldWeight * y.gold
        }
        if m.freshWaterCentre { m.siteValue += s.freshWaterBonus }
        if map.neighbors(of: hex).contains(where: { map[$0].terrain == .coast }) { m.siteValue += s.coastBonus }
        if map[hex].elevation == .hills { m.siteValue += s.hillsBonus }
        return m
    }

    static func run(_ o: Options, rules: Ruleset) {
        var records: [StartRecord] = []
        for g in 0..<o.games {
            let seed = o.seed &+ UInt64(g)
            let generated = MapGenerator.generate(MapGenSettings(size: o.size, seed: seed, script: o.script))
            var starts = generated.startPositions.enumerated().map { measure($0.element, player: $0.offset, map: generated.map, rules: rules) }
            // Each player founds its capital on its start, in its own phase, through the engine.
            var state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions,
                                          humanPlayers: [], rules: rules, mapSizeName: o.size.rawValue)
            for i in starts.indices {
                let me = PlayerID(i)
                guard state.currentPlayer == me else { break }
                if let settler = state.units(of: me).first(where: { $0.type == .settler }),
                   (try? GameEngine.apply(.foundCity(unit: settler.id), by: me, to: &state)) != nil,
                   let city = state.cities(of: me).first {
                    let y = state.cityYields(city)
                    starts[i].capitalProduction = y.total.production
                    starts[i].capitalSurplus = y.foodSurplus
                }
                _ = try? GameEngine.apply(.endTurn, by: me, to: &state)
            }
            let record = StartRecord(seed: seed, size: o.size.rawValue, starts: starts)
            records.append(record)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(record), let json = String(data: data, encoding: .utf8) { print("START " + json) }
        }
        summarize(records)
    }

    static func summarize(_ records: [StartRecord]) {
        let starts = records.flatMap(\.starts)
        guard !starts.isEmpty else { return }
        func mean(_ xs: [Int]) -> String { String(format: "%.2f", Double(xs.reduce(0, +)) / Double(max(xs.count, 1))) }
        func line(_ name: String, _ f: (StartMetrics) -> Int) {
            let xs = starts.map(f)
            let p0 = starts.filter { $0.player == 0 }.map(f), others = starts.filter { $0.player != 0 }.map(f)
            print("  \(name): min \(xs.min()!), mean \(mean(xs)), max \(xs.max()!); p0 mean \(mean(p0)), others mean \(mean(others))")
        }
        print("starts: \(records.count) maps (\(records[0].size), seeds \(records.first!.seed)–\(records.last!.seed)), \(starts.count) starts")
        line("improvable tiles at distance 1", \.improvable1)
        line("improvable tiles within 2", \.improvable2)
        line("improvable tiles within 3", \.improvable3)
        line("mine sites within 2", \.mineSites2)
        line("farm sites with fresh water within 2", \.freshFarms2)
        line("forest/jungle/marsh tiles within 2", \.locked2)
        line("site value (settle score, full knowledge)", \.siteValue)
        line("best four tiles, unimproved", \.bestFour)
        line("best four tiles, improved", \.bestFourImproved)
        line("capital Production at founding", { $0.capitalProduction ?? 0 })
        line("capital Food surplus at founding", { $0.capitalSurplus ?? 0 })
        for k in [3, 5, 8] {
            print("  starts with ≤ \(k) improvable tiles within 2: \(starts.filter { $0.improvable2 <= k }.count)/\(starts.count)")
        }
        print("  starts with fresh water at the centre: \(starts.filter(\.freshWaterCentre).count)/\(starts.count); "
            + "centre on forest/jungle/marsh: \(starts.filter { $0.tile.contains("forest") || $0.tile.contains("jungle") || $0.tile.contains("marsh") }.count)")
        // Fairness: per map, best minus worst start.
        func gaps(_ f: (StartMetrics) -> Int) -> [Int] { records.map { r in r.starts.map(f).max()! - r.starts.map(f).min()! } }
        let measures: [(String, (StartMetrics) -> Int)] = [("site value", { $0.siteValue }), ("improvable within 2", { $0.improvable2 }),
                                                           ("best four improved", { $0.bestFourImproved }), ("MapGen start score", { $0.startScore })]
        for (name, f) in measures {
            let g = gaps(f)
            print("  gap between best and worst start per map, \(name): mean \(mean(g)), max \(g.max()!)")
        }
        if records.allSatisfy({ $0.starts.count == 2 }) {
            let d = records.map { $0.starts[0].siteValue - $0.starts[1].siteValue }
            print("  p0 − p1 site value: mean \(mean(d)); p0 better in \(d.filter { $0 > 0 }.count), p1 better in \(d.filter { $0 < 0 }.count)")
        }
    }
}
