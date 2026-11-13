/// Axial hex coordinate (pointy-top). `r` is the row; `q` is the axial column.
///
/// World layout convention (shared with rendering): +x is east, +y is north,
/// row `r` increases northward, odd rows are shifted half a tile east ("odd-r").
public struct HexCoord: Hashable, Codable, Sendable, CustomStringConvertible {
    public var q: Int
    public var r: Int

    public init(q: Int, r: Int) {
        self.q = q
        self.r = r
    }

    public var s: Int { -q - r }

    public static func + (a: HexCoord, b: HexCoord) -> HexCoord { HexCoord(q: a.q + b.q, r: a.r + b.r) }
    public static func - (a: HexCoord, b: HexCoord) -> HexCoord { HexCoord(q: a.q - b.q, r: a.r - b.r) }

    public func neighbor(_ direction: HexDirection) -> HexCoord { self + direction.offset }

    /// Raw hex distance, ignoring map wrap. Use `HexMap.distance` for wrap-aware distance.
    public func distance(to other: HexCoord) -> Int {
        let d = self - other
        return (abs(d.q) + abs(d.r) + abs(d.s)) / 2
    }

    public var offset: OffsetCoord {
        OffsetCoord(col: q + (r - (r & 1)) / 2, row: r)
    }

    public var description: String { "(\(q),\(r))" }
}

/// The six neighbor directions, in a fixed order. Raw values index hex edges
/// (used later for rivers, so the order must never change).
public enum HexDirection: Int, CaseIterable, Codable, Sendable {
    case east, southEast, southWest, west, northWest, northEast

    public var offset: HexCoord {
        switch self {
        case .east: HexCoord(q: 1, r: 0)
        case .southEast: HexCoord(q: 1, r: -1)
        case .southWest: HexCoord(q: 0, r: -1)
        case .west: HexCoord(q: -1, r: 0)
        case .northWest: HexCoord(q: -1, r: 1)
        case .northEast: HexCoord(q: 0, r: 1)
        }
    }

    public var opposite: HexDirection { HexDirection(rawValue: (rawValue + 3) % 6)! }
}

/// "odd-r" offset coordinate: storage layout of the map (row-major).
public struct OffsetCoord: Hashable, Codable, Sendable, CustomStringConvertible {
    public var col: Int
    public var row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }

    public var hex: HexCoord {
        HexCoord(q: col - (row - (row & 1)) / 2, r: row)
    }

    public var description: String { "[\(col),\(row)]" }
}
