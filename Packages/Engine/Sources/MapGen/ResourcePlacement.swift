import GameCore

/// Resource placement (M2 §3.1), after terrain and starts, from one
/// `SplitMix64(seed: seed, salts: 0x2E50)` stream; candidates in tile-index order.
///
/// - **Allowed:** a resource's site, no resource yet, not a start tile, neither Oasis nor Snow.
/// - **Fairness first:** each start in order gets, within 3 tiles, 2 bonus and 1 luxury, and
///   within 6 tiles Horses or Iron, counting what is already there.
/// - **Then** up to the targets per 1000 land tiles: strategics, luxuries in clusters of
///   `clusterMin…clusterMax` of one kind, then bonuses; a random fill avoids tiles next to
///   another resource.
enum ResourcePlacer {
    static func place(on map: inout HexMap, starts: [HexCoord], seed: UInt64, rules: Ruleset) {
        guard let s = rules.stockpile, !rules.resources.isEmpty else { return }
        var rng = SplitMix64(seed: seed, salts: 0x2E50)
        let startTiles = starts.compactMap { map.index(of: $0) }
        let land = map.tiles.filter(\.isLand).count

        // sites[r][t]: resource r may stand on tile t.
        let sites: [[Bool]] = Resource.allCases.map { r in
            let def = rules.resource(r)!
            return map.tiles.map { tile in
                def.sites.contains { site in
                    site.terrains.contains(String(describing: tile.terrain))
                        && site.elevations.contains(String(describing: tile.elevation))
                        && site.features.contains(String(describing: tile.feature))
                }
            }
        }
        func neighbors(_ t: Int) -> [Int] { map.neighbors(of: map.coord(at: t)).compactMap { map.index(of: $0) } }
        func allowed(_ r: Resource, _ t: Int, spread: Bool) -> Bool {
            let tile = map.tiles[t]
            guard sites[Int(r.rawValue) - 1][t], tile.resource == nil, tile.feature != .oasis, tile.terrain != .snow,
                  !startTiles.contains(t) else { return false }
            if spread {
                var crowded = false
                for n in neighbors(t) where map.tiles[n].resource != nil { crowded = true }
                if crowded { return false }
            }
            return true
        }
        let kinds: (ResourceKind) -> [Resource] = { k in Resource.allCases.filter { rules.resource($0)!.kind == k } }
        let bonus = kinds(.bonus), luxury = kinds(.luxury), strategic = kinds(.strategic)
        var placed: [ResourceKind: Int] = [:]

        /// A random allowed tile for a random one of `pool` (falling back through the pool in
        /// order from the drawn one), among `tiles`.
        func drop(_ pool: [Resource], among tiles: [Int], spread: Bool) -> (Resource, Int)? {
            let offset = rng.nextInt(below: pool.count)
            for k in 0..<pool.count {
                let r = pool[(offset + k) % pool.count]
                let candidates = tiles.filter { allowed(r, $0, spread: spread) }
                guard !candidates.isEmpty else { continue }
                let t = candidates[rng.nextInt(below: candidates.count)]
                map[index: t].resource = r
                placed[rules.resource(r)!.kind, default: 0] += 1
                return (r, t)
            }
            return nil
        }
        func within(_ radius: Int, of t: Int) -> [Int] {
            map.coords(within: radius, of: map.coord(at: t)).compactMap { map.index(of: $0) }.sorted()
        }
        func count(_ pool: [Resource], in tiles: [Int]) -> Int {
            tiles.filter { map.tiles[$0].resource.map(pool.contains) ?? false }.count
        }

        for start in startTiles {
            let near = within(3, of: start), far = within(6, of: start)
            while count(bonus, in: near) < 2, drop(bonus, among: near, spread: false) != nil {}
            if count(luxury, in: near) < 1 { _ = drop(luxury, among: near, spread: false) }
            if count(strategic, in: far) < 1 { _ = drop(strategic, among: far, spread: false) }
        }

        let all = Array(map.tiles.indices)
        let strategicTarget = land * s.strategicPer1000Land / 1000
        while placed[.strategic, default: 0] < strategicTarget, drop(strategic, among: all, spread: true) != nil {}
        let luxuryTarget = land * s.luxuryPer1000Land / 1000
        while placed[.luxury, default: 0] < luxuryTarget, let (r, t) = drop(luxury, among: all, spread: true) {
            var cluster = [t]
            let size = rng.nextInt(in: s.clusterMin...max(s.clusterMin, s.clusterMax))
            while cluster.count < size, placed[.luxury, default: 0] < luxuryTarget {
                var next: [Int] = []
                for c in cluster { for n in neighbors(c) where allowed(r, n, spread: false) && !next.contains(n) { next.append(n) } }
                guard !next.isEmpty else { break }
                let n = next.sorted()[rng.nextInt(below: next.count)]
                map[index: n].resource = r
                placed[.luxury, default: 0] += 1
                cluster.append(n)
            }
        }
        let bonusTarget = land * s.bonusPer1000Land / 1000
        while placed[.bonus, default: 0] < bonusTarget, drop(bonus, among: all, spread: true) != nil {}
    }
}
