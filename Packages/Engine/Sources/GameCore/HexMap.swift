/// The world grid. Stored row-major in odd-r offset layout; optionally wraps east-west.
public struct HexMap: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let wrapsX: Bool
    public private(set) var tiles: [Tile]

    public init(width: Int, height: Int, wrapsX: Bool, fill: Tile = Tile(terrain: .ocean)) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.wrapsX = wrapsX
        self.tiles = Array(repeating: fill, count: width * height)
    }

    public var tileCount: Int { tiles.count }

    // MARK: Coordinates

    /// Canonical form of a coordinate (column wrapped into range), or nil if off-map.
    public func normalize(_ hex: HexCoord) -> HexCoord? {
        var o = hex.offset
        guard o.row >= 0, o.row < height else { return nil }
        if wrapsX {
            o.col = ((o.col % width) + width) % width
        } else if o.col < 0 || o.col >= width {
            return nil
        }
        return o.hex
    }

    public func index(of hex: HexCoord) -> Int? {
        guard let n = normalize(hex) else { return nil }
        let o = n.offset
        return o.row * width + o.col
    }

    public func coord(at index: Int) -> HexCoord {
        OffsetCoord(col: index % width, row: index / width).hex
    }

    public var allCoords: [HexCoord] { (0..<tileCount).map(coord(at:)) }

    // MARK: Tiles

    public subscript(hex: HexCoord) -> Tile {
        get { tiles[index(of: hex)!] }
        set { tiles[index(of: hex)!] = newValue }
    }

    public subscript(index index: Int) -> Tile {
        get { tiles[index] }
        set { tiles[index] = newValue }
    }

    public func tile(at hex: HexCoord) -> Tile? {
        index(of: hex).map { tiles[$0] }
    }

    // MARK: Topology

    /// Canonical neighbors that exist on the map.
    public func neighbors(of hex: HexCoord) -> [HexCoord] {
        HexDirection.allCases.compactMap { normalize(hex.neighbor($0)) }
    }

    /// Wrap-aware hex distance between two on-map coordinates.
    public func distance(_ a: HexCoord, _ b: HexCoord) -> Int {
        let direct = a.distance(to: b)
        guard wrapsX else { return direct }
        // Shifting by `width` offset columns shifts axial q by `width`.
        let east = a.distance(to: HexCoord(q: b.q + width, r: b.r))
        let west = a.distance(to: HexCoord(q: b.q - width, r: b.r))
        return min(direct, east, west)
    }

    /// All canonical on-map coordinates within `radius` of `center` (inclusive), deduplicated.
    public func coords(within radius: Int, of center: HexCoord) -> [HexCoord] {
        var result: [HexCoord] = []
        var seen = Set<HexCoord>()
        for dq in -radius...radius {
            for dr in max(-radius, -dq - radius)...min(radius, -dq + radius) {
                if let c = normalize(HexCoord(q: center.q + dq, r: center.r + dr)), seen.insert(c).inserted {
                    result.append(c)
                }
            }
        }
        return result
    }
}

// MARK: - Index helpers (allocation-free, for the engine's inner loops)

extension HexMap {
    /// The index of the neighbor of tile `index` in `direction`, or nil off the map.
    @inline(__always)
    func neighborIndex(of index: Int, _ direction: HexDirection) -> Int? {
        let row = index / width, col = index % width
        let q = col - (row - (row & 1)) / 2
        let o = direction.offset
        let r2 = row + o.r
        guard r2 >= 0, r2 < height else { return nil }
        var col2 = q + o.q + (r2 - (r2 & 1)) / 2
        if wrapsX {
            if col2 < 0 { col2 += width } else if col2 >= width { col2 -= width }
        } else if col2 < 0 || col2 >= width {
            return nil
        }
        return r2 * width + col2
    }

    /// Calls `body` with each existing neighbor of tile `index` and its direction, in
    /// `HexDirection` order.
    @inline(__always)
    func forEachNeighbor(of index: Int, _ body: (Int, HexDirection) -> Void) {
        for direction in HexDirection.allCases {
            if let n = neighborIndex(of: index, direction) { body(n, direction) }
        }
    }

    /// Calls `body` with the index of every on-map tile within `radius` of `center`. On a
    /// wrapping map narrower than 2·radius + 1 a tile may come up more than once.
    func forEachIndex(within radius: Int, of center: HexCoord, _ body: (Int) -> Void) {
        guard radius >= 0 else { return }
        for dq in -radius...radius {
            for dr in max(-radius, -dq - radius)...min(radius, -dq + radius) {
                let r = center.r + dr
                guard r >= 0, r < height else { continue }
                var col = center.q + dq + (r - (r & 1)) / 2
                if wrapsX {
                    col = ((col % width) + width) % width
                } else if col < 0 || col >= width {
                    continue
                }
                body(r * width + col)
            }
        }
    }

    /// Wrap-aware distance between two tiles given by index.
    func distance(index a: Int, _ b: Int) -> Int {
        distance(coord(at: a), coord(at: b))
    }

    /// The direction from tile `a` to its neighbor `b`, if they are neighbors.
    func direction(from a: Int, to b: Int) -> HexDirection? {
        HexDirection.allCases.first { neighborIndex(of: a, $0) == b }
    }
}
