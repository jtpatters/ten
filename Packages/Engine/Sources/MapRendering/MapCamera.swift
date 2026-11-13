import CoreGraphics
import simd

/// Perspective camera looking north across the ground plane (z = 0), tilted back by `pitch`.
///
/// World space matches `HexLayout`: +x east, +y north, +z up, in points. `scale` is world
/// units per view point at the look-at target, so `scale == 1` shows tiles at their
/// nominal size; larger values zoom out. `pitch == 0` is straight top-down.
public struct MapCamera: Sendable, Equatable {
    public var target: SIMD2<Float>
    public var scale: Float
    public var pitch: Float
    /// View size in points.
    public var viewSize: SIMD2<Float>
    public var fovY: Float
    /// The bands at the view's top and bottom that panels cover (points). The clamp lets the
    /// polar margin reach their inner edges rather than the view's own, so the first and last
    /// rows can still be brought into the uncovered part; under the panels the ground's polar
    /// pack and haze fill the rest. The renderer sets them from its viewport insets.
    public var coveredTop: Float = 0
    public var coveredBottom: Float = 0

    public static let minScale: Float = 0.35

    public init(target: SIMD2<Float> = .zero, scale: Float = 1, pitch: Float = 0.6,
                viewSize: SIMD2<Float> = [1024, 768], fovY: Float = 0.45) {
        self.target = target
        self.scale = scale
        self.pitch = pitch
        self.viewSize = viewSize
        self.fovY = fovY
    }

    public var forward: SIMD3<Float> { [0, sin(pitch), -cos(pitch)] }
    public var up: SIMD3<Float> { [0, cos(pitch), sin(pitch)] }
    public var distance: Float { max(viewSize.y, 1) * scale * 0.5 / tan(fovY * 0.5) }
    public var eye: SIMD3<Float> { SIMD3(target.x, target.y, 0) - forward * distance }

    public var viewMatrix: simd_float4x4 {
        let x = SIMD3<Float>(1, 0, 0), y = up, z = -forward, e = eye
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, e), -simd_dot(y, e), -simd_dot(z, e), 1)
        ))
    }

    /// Right-handed perspective projection with Metal's [0, 1] clip depth.
    public var projectionMatrix: simd_float4x4 {
        let aspect = viewSize.x / max(viewSize.y, 1)
        let ys = 1 / tan(fovY * 0.5), xs = ys / aspect
        let near = distance * 0.05, far = distance * 8
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)
        ))
    }

    public var viewProjection: simd_float4x4 { projectionMatrix * viewMatrix }

    /// Direction of the ray from the eye through a view point (points, origin top-left).
    public func rayDirection(atViewPoint p: CGPoint) -> SIMD3<Float> {
        let ndcX = 2 * Float(p.x) / max(viewSize.x, 1) - 1
        let ndcY = 1 - 2 * Float(p.y) / max(viewSize.y, 1)
        let t = tan(fovY * 0.5)
        let aspect = viewSize.x / max(viewSize.y, 1)
        return simd_normalize(forward + SIMD3<Float>(1, 0, 0) * (ndcX * t * aspect) + up * (ndcY * t))
    }

    /// Where the ray through a view point meets the ground (unwrapped world coordinates).
    public func groundPoint(atViewPoint p: CGPoint) -> SIMD2<Float>? {
        let d = rayDirection(atViewPoint: p)
        guard d.z < -1e-4 else { return nil }
        let e = eye
        let t = -e.z / d.z
        return SIMD2(e.x + d.x * t, e.y + d.y * t)
    }

    /// Projects a world point to view points (origin top-left), or nil if behind the camera.
    public func viewPoint(of world: SIMD3<Float>) -> CGPoint? {
        let clip = viewProjection * SIMD4(world, 1)
        guard clip.w > 1e-5 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat((ndc.x + 1) * 0.5 * viewSize.x), y: CGFloat((1 - ndc.y) * 0.5 * viewSize.y))
    }

    // MARK: Navigation

    /// Drag: the ground point under `from` ends up under `to`.
    public mutating func pan(from a: CGPoint, to b: CGPoint, layout: HexLayout) {
        guard let ga = groundPoint(atViewPoint: a), let gb = groundPoint(atViewPoint: b) else { return }
        target += ga - gb
        clamp(layout: layout)
    }

    /// Pinch: zoom by `factor` (> 1 zooms in), keeping the ground point under `anchor` fixed.
    public mutating func zoom(by factor: Float, around anchor: CGPoint, layout: HexLayout) {
        guard factor > 0, let before = groundPoint(atViewPoint: anchor) else { return }
        scale = min(max(scale / factor, Self.minScale), maxScale(layout: layout))
        if let after = groundPoint(atViewPoint: anchor) { target += before - after }
        clamp(layout: layout)
    }

    /// How far past the map's north and south rows the view may reach, in rows: enough for a
    /// soft polar margin. A view taller than the map plus these margins (zoomed out past the
    /// map's height, see `zoomOutFloor`) centres the map, with the ground's polar pack and haze
    /// beyond it.
    public static let edgeMarginRows: Float = 0.6

    /// The map's height never stops zoom-out short of this scale: an upright phone or iPad on a
    /// small map zooms on out past the poles, as far as the wrap allows, so it gets an overview
    /// and reaches the strategic level (`MapRenderer.strategicEnter`, 2.1).
    public static let zoomOutFloor: Float = 2.3

    /// Largest zoom-out that keeps the visible ground narrower than one world period
    /// (so wrapped copies never show twice) and no taller than the map plus its polar margins,
    /// or `zoomOutFloor` if that is wider.
    public func maxScale(layout: HexLayout) -> Float {
        var unit = self
        unit.scale = 1
        let w = CGFloat(viewSize.x), h = CGFloat(viewSize.y)
        guard let tl = unit.groundPoint(atViewPoint: CGPoint(x: 0, y: 0)),
              let tr = unit.groundPoint(atViewPoint: CGPoint(x: w, y: 0)),
              let top = unit.groundPoint(atViewPoint: CGPoint(x: w / 2, y: 0)),
              let bottom = unit.groundPoint(atViewPoint: CGPoint(x: w / 2, y: h)) else { return Self.minScale }
        let topWidth = max(tr.x - tl.x, 1e-3), height = max(top.y - bottom.y, 1e-3)
        let worldW = Float(layout.worldWidth), worldH = Float(layout.worldHeight)
        let byWidth = (layout.wrapsX ? 0.92 : 1.2) * worldW / topWidth
        let byHeight = (worldH + 2 * Float(layout.rowHeight) * Self.edgeMarginRows) / height
        return max(Self.minScale, min(byWidth, max(byHeight, Self.zoomOutFloor), 4))
    }

    /// The world y of the ground at the view's bottom and top edges: the camera never rolls, so
    /// those edges meet the ground on lines of constant y, the south and north ends of the
    /// ground in view. Nil when the view reaches the horizon.
    public var groundSpanY: (south: Float, north: Float)? {
        let midX = CGFloat(viewSize.x) / 2
        guard let near = groundPoint(atViewPoint: CGPoint(x: midX, y: CGFloat(viewSize.y))),
              let far = groundPoint(atViewPoint: CGPoint(x: midX, y: 0)) else { return nil }
        return (near.y, far.y)
    }

    /// Wraps x into one world period (or clamps when the map doesn't wrap), clamps zoom, and
    /// keeps the near and far ground edges of the view's uncovered part (see `coveredTop`)
    /// within the map plus its polar margins.
    public mutating func clamp(layout: HexLayout) {
        scale = min(max(scale, Self.minScale), maxScale(layout: layout))
        let w = Float(layout.worldWidth)
        if layout.wrapsX {
            target.x = target.x - (target.x / w).rounded(.down) * w
        } else {
            target.x = min(max(target.x, 0), w)
        }
        // The camera never rolls, so the screen's bottom and top edges meet the ground on lines
        // of constant y, at offsets from the target that do not depend on where it is.
        let worldH = Float(layout.worldHeight)
        let margin = Float(layout.rowHeight) * Self.edgeMarginRows
        var low: Float = 0, high = worldH
        let midX = CGFloat(viewSize.x) / 2
        // The uncovered part's top and bottom (each covered band counts up to 45% of the view,
        // so they never cross).
        let farY = CGFloat(min(max(coveredTop, 0), viewSize.y * 0.45))
        let nearY = CGFloat(viewSize.y - min(max(coveredBottom, 0), viewSize.y * 0.45))
        if let near = groundPoint(atViewPoint: CGPoint(x: midX, y: nearY)),
           let far = groundPoint(atViewPoint: CGPoint(x: midX, y: farY)) {
            low = target.y - near.y - margin
            high = worldH + margin - (far.y - target.y)
        }
        // A view taller than the map plus its margins (zoomed out past its height) centers it.
        target.y = low <= high ? min(max(target.y, low), high) : (low + high) / 2
    }
}
