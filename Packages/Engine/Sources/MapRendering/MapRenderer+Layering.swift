import CoreGraphics
import GameCore
import Metal
import simd

/// The unit pass of one frame: instances in drawing order, the tile a tap on each selects,
/// and the layers `encodeFrame` draws them in, around the decorations:
///
///  1. `ground`, under the decorations: base fills (contact shadow and wash) and cast shadows,
///     so trees on a unit's tile are not tinted by its base.
///  2. `bands`, over the decorations: base bands and the selection ring (thin UI lines).
///  3. `figures`, one group per spot or city back to front. Each writes its rank into the
///     stencil over its legs (and resets it over its body, shield and standard; a city keeps
///     it everywhere), and decorations standing in front of a figure or a city's walls are
///     drawn again over it, only where the stencil holds a group behind them
///     (`liftedDecorations`): units stand among the trees without being hidden by them.
///  4. `top`: smoke over damaged cities, strategic city tokens and medallions, and turn
///     markers, over everything.
struct UnitFrame {
    struct Figures {
        var range: Range<Int>
        /// The front figure's feet (world) and sprite edge; for a city, the front of its wall
        /// ring and the ring's width.
        var feet: SIMD2<Float>
        var size: Float
        /// A city's ring: its middle (world) and radius. Plants in front of the ring's front
        /// arc are in front of the city.
        var ring: SIMD3<Float>? = nil

        /// The ground line this group stands on at `x` (world): its feet, or for a city the
        /// front of its ring there (its middle beyond the ring's sides).
        func front(at x: Float) -> Float {
            guard let ring else { return feet.y }
            let dx = x - ring.x
            guard abs(dx) < ring.z else { return ring.y }
            return ring.y - (ring.z * ring.z - dx * dx).squareRoot()
        }
    }

    var sprites: [SpriteInstance] = []
    /// Per sprite: what a tap on it selects, a unit's tile (base band, figure, emblem,
    /// standard, medallion) or a city (its pieces and token); nil for shadows, fills, smoke,
    /// the selection ring and turn markers.
    var owners: [PickTarget?] = []
    var ground = 0..<0
    var bands = 0..<0
    var figures: [Figures] = []
    var top = 0..<0

    /// Stencil value a figure group writes: its place back to front, from 1. The stencil is
    /// cleared to `MapRenderer.noFigure`.
    static func rank(_ group: Int) -> UInt32 { UInt32(min(group + 1, Int(MapRenderer.noFigure) - 1)) }
}

/// What a tap on a drawn instance selects: a unit's tile, or a city (its id and tile).
struct PickTarget: Hashable {
    var hex: HexCoord
    var city: Int?

    static func unit(_ hex: HexCoord) -> PickTarget { PickTarget(hex: hex, city: nil) }
}

/// Standing decorations by tile (compressed rows): which instances can stand in front of a
/// unit on a tile or next to it.
struct DecorTileIndex {
    private let starts: [Int32]
    private let items: [Int32]

    init(_ decorations: [SpriteInstance], tileCount: Int) {
        var counts = [Int32](repeating: 0, count: tileCount + 1)
        for d in decorations where d.flags.x > 0.5 {
            let tile = Int(d.position.w)
            if tile >= 0, tile < tileCount { counts[tile + 1] += 1 }
        }
        for i in 1...tileCount { counts[i] += counts[i - 1] }
        var fill = counts
        var items = [Int32](repeating: 0, count: Int(counts[tileCount]))
        for (i, d) in decorations.enumerated() where d.flags.x > 0.5 {
            let tile = Int(d.position.w)
            guard tile >= 0, tile < tileCount else { continue }
            items[Int(fill[tile])] = Int32(i)
            fill[tile] += 1
        }
        starts = counts
        self.items = items
    }

    func instances(on tile: Int) -> ArraySlice<Int32> {
        items[Int(starts[tile])..<Int(starts[tile + 1])]
    }
}

extension MapRenderer {
    /// Stencil clear value: no figure's legs here.
    nonisolated static let noFigure: UInt32 = 255
    /// How much of a figure plants in front may cover, as a fraction of its body cell above
    /// the feet (`UnitSprite.groundLine`): legs, hooves and wheels, never the body, shield,
    /// wagon or standard. Measured on the body art: the front-rank infantryman's skirt, kilt
    /// or tunic hem (and the wheelbarrow's tray) starts 0.13 above the feet, the horse's belly
    /// 0.19 and the ox's body and the wagon bed 0.14.
    static func legHeight(_ type: UnitType) -> Float {
        switch type {
        case .warrior, .archer, .spearman, .builder: 0.10
        case .scout: 0.17
        case .settler: 0.12
        }
    }

    /// The leg line of a figure group: the lowest of its tile's units, so no unit in a stack
    /// is covered above its legs.
    func legHeight(of figures: UnitFrame.Figures, in frame: UnitFrame) -> Float {
        let fallback = UnitType.allCases.map(Self.legHeight).min() ?? 0
        guard figures.range.lowerBound < frame.owners.count, let tile = frame.owners[figures.range.lowerBound]?.hex else { return fallback }
        return state.units(at: tile).map { Self.legHeight($0.type) }.min() ?? fallback
    }
    /// Plants this close in front of a figure's feet (tile sizes, south) and within half its
    /// cell to either side are drawn over its legs.
    static let liftDepth: Float = 0.45

    /// Plants (trees, palms, grass; never relief) standing just in front of a figure (or of a
    /// city's wall ring) and reaching up over it on screen, back to front, each with its
    /// stencil reference: the rank of the first figure group in front of it. Drawn again after
    /// the figures with a `greater` test, a plant covers exactly the legs of the figures (and
    /// whatever of the cities) behind it.
    func liftedDecorations(_ frame: UnitFrame, decorations: UnsafePointer<SpriteInstance>) -> [(index: Int, rank: UInt32)] {
        guard !frame.figures.isEmpty else { return [] }
        // A standing sprite of height h covers as much of the screen as h / cos(pitch) of
        // ground behind its foot.
        let reach = 1 / max(cos(camera.pitch), 0.3)
        var seen = Set<Int32>()
        var lifted: [(index: Int, rank: UInt32)] = []
        let depth = Self.liftDepth * Float(layout.size)
        for group in frame.figures {
            let feet = group.feet, half = group.size * 0.5
            // A city's ring spans its hex: plants on the tiles around its middle.
            let anchor = group.ring.map { SIMD2($0.x, $0.y) } ?? feet
            let hex = layout.hex(at: CGPoint(x: CGFloat(anchor.x), y: CGFloat(anchor.y)))
            for tile in [hex] + HexDirection.allCases.map({ hex.neighbor($0) }) {
                guard let tile = state.map.normalize(tile), let t = state.map.index(of: tile) else { continue }
                for i in decorIndex.instances(on: t) where !seen.contains(i) {
                    let d = decorations[Int(i)]
                    guard UInt32(d.flags.w) & 3 != 0 else { continue } // swaying in the wind: a plant
                    let foot = d.position.y
                    let x = Float(layout.nearestCopy(of: CGFloat(d.position.x), to: CGFloat(feet.x)))
                    guard abs(x - feet.x) < half else { continue }
                    let ground = group.front(at: x)
                    guard foot < ground, ground - foot < min(depth, reach * (1 - d.sizeAnchor.w) * d.sizeAnchor.y) else { continue }
                    seen.insert(i)
                    // Figure groups are drawn back to front; those standing behind this foot
                    // come first.
                    let behind = frame.figures.firstIndex { $0.front(at: x) <= foot } ?? frame.figures.count
                    lifted.append((Int(i), UnitFrame.rank(behind)))
                }
            }
        }
        // Back to front, as the decoration buffer is sorted; ranks then never decrease.
        lifted.sort { $0.index < $1.index }
        return lifted
    }
}
