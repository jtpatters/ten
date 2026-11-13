import CoreGraphics
import GameCore

/// Hex ↔ world-space geometry (pointy-top, y up, odd-r rows shifted east).
/// World units are points. Tile (col 0, row 0) has its bounding box at the origin.
public struct HexLayout: Sendable {
    /// Center-to-corner radius.
    public let size: CGFloat
    public let mapWidth: Int
    public let mapHeight: Int
    public let wrapsX: Bool

    public init(size: CGFloat, mapWidth: Int, mapHeight: Int, wrapsX: Bool) {
        self.size = size
        self.mapWidth = mapWidth
        self.mapHeight = mapHeight
        self.wrapsX = wrapsX
    }

    public init(size: CGFloat, map: HexMap) {
        self.init(size: size, mapWidth: map.width, mapHeight: map.height, wrapsX: map.wrapsX)
    }

    public var tileWidth: CGFloat { size * 1.7320508075688772 }
    public var rowHeight: CGFloat { size * 1.5 }

    /// Horizontal period of the world (wrap distance).
    public var worldWidth: CGFloat { tileWidth * CGFloat(mapWidth) + (wrapsX ? 0 : tileWidth / 2) }
    public var worldHeight: CGFloat { rowHeight * CGFloat(mapHeight - 1) + size * 2 }

    /// Center of any (possibly unnormalized) hex; unnormalized coords map to wrapped copies.
    public func center(of hex: HexCoord) -> CGPoint {
        CGPoint(x: tileWidth * (CGFloat(hex.q) + CGFloat(hex.r) / 2) + tileWidth / 2,
                y: rowHeight * CGFloat(hex.r) + size)
    }

    /// The hex containing a world point (not normalized for wrap).
    public func hex(at point: CGPoint) -> HexCoord {
        let px = (point.x - tileWidth / 2) / size
        let py = (point.y - size) / size
        let q = 0.5773502691896258 * px - py / 3 // sqrt(3)/3
        let r = py * 2 / 3
        return Self.round(q: q, r: r)
    }

    public func corners(around center: CGPoint, inset: CGFloat = 0) -> [CGPoint] {
        let radius = size - inset
        // Pointy-top: corners at 30° + 60°·i. Precomputed unit vectors avoid trig.
        let unit: [(CGFloat, CGFloat)] = [
            (0.8660254037844386, 0.5), (0, 1), (-0.8660254037844386, 0.5),
            (-0.8660254037844386, -0.5), (0, -1), (0.8660254037844386, -0.5),
        ]
        return unit.map { CGPoint(x: center.x + $0.0 * radius, y: center.y + $0.1 * radius) }
    }

    public func hexPath(around center: CGPoint, inset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: corners(around: center, inset: inset))
        path.closeSubpath()
        return path
    }

    /// Shift `x` by whole world periods so it lies closest to `reference` (wrap support).
    public func nearestCopy(of x: CGFloat, to reference: CGFloat) -> CGFloat {
        guard wrapsX else { return x }
        let k = ((reference - x) / worldWidth).rounded()
        return x + k * worldWidth
    }

    private static func round(q: CGFloat, r: CGFloat) -> HexCoord {
        let s = -q - r
        var rq = q.rounded(), rr = r.rounded()
        let rs = s.rounded()
        let dq = abs(rq - q), dr = abs(rr - r), ds = abs(rs - s)
        if dq > dr && dq > ds {
            rq = -rr - rs
        } else if dr > ds {
            rr = -rq - rs
        }
        return HexCoord(q: Int(rq), r: Int(rr))
    }
}
