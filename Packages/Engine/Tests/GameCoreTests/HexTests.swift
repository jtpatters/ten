import Testing
@testable import GameCore

@Suite struct HexTests {
    @Test func offsetRoundTrip() {
        for row in -3...7 {
            for col in -3...9 {
                let o = OffsetCoord(col: col, row: row)
                #expect(o.hex.offset == o)
            }
        }
    }

    @Test func neighborsAreDistanceOne() {
        let c = HexCoord(q: 3, r: -2)
        for d in HexDirection.allCases {
            #expect(c.distance(to: c.neighbor(d)) == 1)
            #expect(c.neighbor(d).neighbor(d.opposite) == c)
        }
    }

    @Test func distance() {
        #expect(HexCoord(q: 0, r: 0).distance(to: HexCoord(q: 3, r: -1)) == 3)
        #expect(HexCoord(q: -2, r: 4).distance(to: HexCoord(q: 1, r: 1)) == 3)
    }

    @Test func wrapNormalization() {
        let map = HexMap(width: 10, height: 6, wrapsX: true)
        let west = OffsetCoord(col: -1, row: 2).hex
        #expect(map.normalize(west)?.offset == OffsetCoord(col: 9, row: 2))
        #expect(map.normalize(OffsetCoord(col: 0, row: 6).hex) == nil)

        let flat = HexMap(width: 10, height: 6, wrapsX: false)
        #expect(flat.normalize(west) == nil)
    }

    @Test func wrapAwareDistanceAndNeighbors() {
        let map = HexMap(width: 10, height: 6, wrapsX: true)
        let a = OffsetCoord(col: 0, row: 2).hex
        let b = OffsetCoord(col: 9, row: 2).hex
        #expect(map.distance(a, b) == 1)
        #expect(map.neighbors(of: a).contains(b))
        #expect(map.neighbors(of: a).count == 6)
        // Top row has only 4 neighbors on a wrapping map.
        #expect(map.neighbors(of: OffsetCoord(col: 4, row: 5).hex).count == 4)
    }

    @Test func coordsWithinRadius() {
        let map = HexMap(width: 20, height: 20, wrapsX: false)
        let center = OffsetCoord(col: 10, row: 10).hex
        #expect(map.coords(within: 1, of: center).count == 7)
        #expect(map.coords(within: 2, of: center).count == 19)
        // Wrapping small map dedups overlapping coords.
        let tiny = HexMap(width: 3, height: 9, wrapsX: true)
        let all = tiny.coords(within: 3, of: OffsetCoord(col: 1, row: 4).hex)
        #expect(Set(all).count == all.count)
    }
}

@Suite struct RNGTests {
    @Test func splitMixReferenceValue() {
        // Reference output of SplitMix64 seeded with 0.
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
    }

    @Test func sameSeedSameSequence() {
        var a = SplitMix64(seed: 1234, salts: 7, 9)
        var b = SplitMix64(seed: 1234, salts: 7, 9)
        for _ in 0..<100 { #expect(a.next() == b.next()) }
        var c = SplitMix64(seed: 1234, salts: 7, 10)
        #expect(SplitMix64(seed: 1234, salts: 7, 9).state != c.state || a.next() != c.next())
    }

    @Test func boundedIntsInRange() {
        var rng = SplitMix64(seed: 99)
        var seen = Set<Int>()
        for _ in 0..<2000 {
            let v = rng.nextInt(below: 7)
            #expect((0..<7).contains(v))
            seen.insert(v)
        }
        #expect(seen.count == 7)
        for _ in 0..<1000 { #expect((0..<1).contains(rng.nextUnit())) }
    }
}
