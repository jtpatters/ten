import CoreGraphics
import Foundation
import GameCore
import Metal
import MetalKit
import QuartzCore
import simd
import Synchronization

// Layouts shared with ShaderCommon.swift (all float4-based, so no padding surprises).
struct Uniforms {
    var viewProj: simd_float4x4
    var cameraUp: SIMD4<Float>
    var eye: SIMD4<Float>
    var sun: SIMD4<Float>
    var viewport: SIMD4<Float>
    var map: SIMD4<Float>
    var dims: SIMD4<Float>
    var ground: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var options: SIMD4<Float>
    var terrain: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                  SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

struct SpriteInstance {
    var position: SIMD4<Float>   // xyz, w = tile index for fog (-1 = none)
    var sizeAnchor: SIMD4<Float> // width, height, anchor x, anchor y
    var uv: SIMD4<Float>
    var tint: SIMD4<Float>
    var flags: SIMD4<Float>      // x: billboard (1) or flat on the ground (0); yzw: owned by the pipeline's shaders
}

struct OverlayVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    /// Style parameters beyond `color` (borders and the movement range's outline).
    var aux: SIMD4<Float> = .zero
}

private final class GPUTimer: Sendable {
    let milliseconds = Mutex<Double>(0)
}

/// Per-frame buffers, one per frame in flight, so the CPU never overwrites data the GPU is reading.
private struct RingBuffer {
    private var buffers: [MTLBuffer?] = [nil, nil, nil]

    mutating func upload<T>(_ items: [T], slot: Int, device: MTLDevice) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        let length = MemoryLayout<T>.stride * items.count
        if (buffers[slot]?.length ?? 0) < length {
            buffers[slot] = device.makeBuffer(length: max(length * 2, 4096), options: .storageModeShared)
        }
        guard let buffer = buffers[slot] else { return nil }
        items.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        return buffer
    }
}

/// Metal map renderer (SPEC §13). A read-only view of `GameState`: it never mutates the
/// simulation, it reflects new states and animates the `GameEvent`s the viewer may see. Cities,
/// territory and improvements come only from its inputs (`MapRenderer+Contracts.swift`), which
/// the App builds from the viewer's knowledge (M1 §15).
///
/// Passes, back to front:
/// 1. Ground: one quad; the fragment shader resolves each pixel's hex from a per-tile data
///    texture and blends neighbors (terrain, coastlines, fog). Fog changes upload ~26 KB.
/// 2. Decorations: trees, hills, mountains as camera-facing sprites, pre-sorted back to front.
/// 3. Overlays: selection ring and path preview, flat on the ground.
/// 4. Units: turn markers, unit shadows and unit tokens, sorted each frame.
///
/// Each pass's art lives in its own files (see `Shaders.swift`): `MapRenderer+Ground.swift`,
/// `+Decor.swift`, `+Units.swift` and `+Overlays.swift` extend this class.
///
/// East–west wrap: the ground shader wraps columns itself; sprite and overlay passes are
/// instanced three times (one world period left/right) and the camera x stays in one period.
@MainActor
public final class MapRenderer: NSObject {
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm
    /// Figures write their rank here so decorations in front can be drawn over them again
    /// (`MapRenderer+Layering.swift`). Memoryless on Apple GPUs: it never leaves tile memory.
    public static let stencilFormat: MTLPixelFormat = .stencil8
    /// No MSAA: every edge is antialiased already (analytic ground, overlay bands and base
    /// rings; texture alpha on sprites), so 4x samples changed under 0.05% of pixels while
    /// costing a 60-90 MB color target and per-sample blending on iPad.
    public static let sampleCount = 1
    public static let tiltPitch: Float = 0.6
    private static let framesInFlight = 3
    private static let clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)

    public let layout: HexLayout
    public let viewer: PlayerID
    public private(set) var state: GameState
    public private(set) var camera: MapCamera

    /// When false, the whole map and all units are shown (debug/benchmark).
    public var fogEnabled = true {
        // Turning the fog back on drops the pictures of units it hides at once.
        didSet { refreshFog(); dropGone(syncUnits()) }
    }
    /// Tilted perspective (true) or straight top-down (false).
    public var tilted = true {
        didSet {
            camera.pitch = tilted ? Self.tiltPitch : 0
            camera.clamp(layout: layout)
        }
    }
    public var showGrid = true

    /// Called once after the 10th frame (automation uses it to know rendering started).
    public var onFirstFrame: (() -> Void)?
    /// Called after each drawn frame (main thread): the App positions text over the map here,
    /// such as city banners and damage numbers (M1 §15).
    public var onFrame: (() -> Void)?
    /// Called when an event's animation reaches its moment (a hit flash), with the view point
    /// it happens at, e.g. to show a damage number.
    public var onEventShown: ((EventRecord, CGPoint) -> Void)?
    /// Called when the last running event animation has finished.
    public var onAnimationsFinished: (() -> Void)?

    // Stats for the benchmark overlay.
    public private(set) var setupMilliseconds: Double = 0
    public private(set) var textureMemoryBytes = 0
    public private(set) var framesPerSecond: Double = 0
    public private(set) var cpuFrameMilliseconds: Double = 0
    public private(set) var spritesDrawn = 0
    public var gpuFrameMilliseconds: Double { gpuTimer.milliseconds.withLock { $0 } }

    public let device: MTLDevice
    let queue: MTLCommandQueue
    /// The ground without farm fields, the ground with them, and the stencil-only pass that
    /// marks where farm fields may be (`kGroundFields` in `ShaderGround.swift`).
    private let groundPipeline: MTLRenderPipelineState
    private let groundFieldsPipeline: MTLRenderPipelineState
    private let groundMaskPipeline: MTLRenderPipelineState
    /// Marking farm squares; the plain ground outside them; the fields inside them, which
    /// restores the stencil to `noFigure` for the unit pass.
    private let markFarms: MTLDepthStencilState
    private let outsideFarms: MTLDepthStencilState
    private let insideFarms: MTLDepthStencilState
    /// The stencil value of a farm square, just below `noFigure`.
    static let farmMark: UInt32 = noFigure - 1
    /// The centres of known farms (world) and the tile texture version they were built from
    /// (`knownFarmCenters`).
    var farmCentersBuffer: MTLBuffer?
    var farmCentersCount = 0
    var farmCentersVersion = -1
    /// Draws the whole ground with the fields variant in one pass (tests compare it with the
    /// split ground).
    var groundFieldsEverywhere = false
    private let decorPipeline: MTLRenderPipelineState
    private let unitPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    /// The unit pass drawn as tap targets (`MapRenderer+Picking.swift`).
    let pickPipeline: MTLRenderPipelineState
    /// No stencil; figures writing their rank; decorations drawn over lower ranks.
    private let plainStencil: MTLDepthStencilState
    private let writeRank: MTLDepthStencilState
    private let belowRank: MTLDepthStencilState
    /// Standing decorations by tile, to find those in front of a unit.
    let decorIndex: DecorTileIndex
    private var liftedRing = RingBuffer()
    /// Draws decorations standing in front of figures over them again (off: tests compare).
    var liftDecorations = true
    /// Resets the stencil over a figure's upper parts (no color), so trees cover legs only.
    private let upperPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    private let groundSampler: MTLSamplerState
    let decorAtlas: SpriteAtlas<DecorSprite>
    let unitAtlas: SpriteAtlas<UnitSprite>
    /// City pieces (`SettlementSprite`), sampled by the unit pass as its second texture.
    let townAtlas: SpriteAtlas<SettlementSprite>
    private var decorAtlasTexture: MTLTexture { decorAtlas.texture }
    private var unitAtlasTexture: MTLTexture { unitAtlas.texture }
    /// The atlases are the same for every map, so they are built once per process and device.
    private static var atlasCache: (device: UInt64, decor: SpriteAtlas<DecorSprite>, units: SpriteAtlas<UnitSprite>,
                                    towns: SpriteAtlas<SettlementSprite>)?
    private let groundTextures: [MTLTexture]
    private let decorationBuffer: MTLBuffer?
    private let decorationCount: Int
    /// The decoration buffer as draw segments: runs sorted by descending y can be cut to the
    /// rows on screen; the rest is drawn whole.
    private let decorSegments: [DecorSegment]
    /// How far any decoration reaches from its anchor (its largest side, plus sway), in world
    /// units: anchors this far outside the view can still show in it.
    private let decorReach: Float
    /// Draws only the decorations near the view (off: everything, for tests).
    var cullDecorations = true
    /// Fixes the animation clock (seconds), for frame-exact tests.
    var animationTime: Float?
    /// The passes `renderImage` draws, and the color behind them (tests isolate one layer).
    var passes = Passes.all
    var backdrop: MTLClearColor?
    /// The ground debug view (`ground_fragment` reads `options.y`): 0 off, 1 relief light.
    var groundDebug: Float = 0

    struct Passes: OptionSet {
        let rawValue: Int
        static let ground = Passes(rawValue: 1 << 0)
        static let decor = Passes(rawValue: 1 << 1)
        static let overlays = Passes(rawValue: 1 << 2)
        static let units = Passes(rawValue: 1 << 3)
        /// The units' layer under the decorations: base fills and cast shadows.
        static let unitGround = Passes(rawValue: 1 << 4)
        static let all: Passes = [.ground, .decor, .overlays, .units, .unitGround]
    }

    /// Per tile, four bytes (the layout is `TileInfo`'s in `ShaderCommon.swift`): terrain and
    /// the territory owner; elevation, feature and improvement; river edges; the fog level (0
    /// visible, 1 explored, 2 unexplored) in bits 0-1 of the last byte, the movement range in
    /// bit 2, the settler score tier in bits 4-6 and a city centre in bit 7. The input bits are
    /// written by `MapRenderer+Territory.swift`.
    var tileBytes: [UInt8]
    /// Bumped whenever `tileBytes` changes (the tile texture is uploaded again).
    var tileVersion = 0
    /// Bumped whenever a tile's fog level changes (borders are rebuilt).
    private(set) var fogVersion = 0
    private let tileTextures: [MTLTexture]
    private var tileTextureVersions: [Int]

    private let inFlight = DispatchSemaphore(value: MapRenderer.framesInFlight)
    private let gpuTimer = GPUTimer()
    private(set) var frameIndex = 0
    /// Bumped whenever the units shown change (tap targets are redrawn).
    private(set) var unitsVersion = 0
    private var dynamicRing = RingBuffer()
    private var overlayRing = RingBuffer()

    var unitVisuals: [UnitID: UnitVisual] = [:]
    /// Event animations: their clock and what runs on it (`MapRenderer+Animation.swift`).
    var animation = AnimationState()
    /// How fast event animations play (1: normal).
    public var animationSpeed: Float = 1
    /// Whether `apply(state:events:)` animates the events. Off (Reduce Motion), everything
    /// lands at once and `onEventShown` reports each event right away.
    public var animatesEvents = true
    /// Present frames in step with Core Animation transactions (`MTKView.presentsWithTransaction`),
    /// so UIKit views placed in `onFrame` (banners, damage numbers) move exactly with the map.
    /// It costs a little latency: turn it on only while such views are shown.
    public var presentsWithTransaction = false
    /// Tap targets, drawn on the first tap after the frame changed.
    var unitPick: UnitPick?
    /// Selection, path preview and marker state, owned by `MapRenderer+Overlays.swift`.
    var unitArt = UnitArtState()
    /// What the App tells the renderer about the viewer's world (cities, territory,
    /// improvements, overlays), owned by `MapRenderer+Contracts.swift`.
    var inputs = MapInputs()
    /// Settlement layouts and tokens, owned by `MapRenderer+Cities.swift`.
    var cityArt = CityArtState()
    /// Border and movement-range ribbons, owned by `MapRenderer+Territory.swift`.
    var territoryArt = TerritoryArtState()
    /// Render-target pixels per view point (2 on Retina).
    private var pixelScale: Float = 2
    /// GPU time of the last `renderImage` call (tests and benchmarks).
    public private(set) var lastOffscreenGPUMilliseconds: Double = 0

    private let startTime = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var decorDrawn = 0
    /// Last input, camera move or unit animation; the view runs at full rate shortly after.
    private var lastActivity: CFTimeInterval = 0
    /// When the render scale last changed (it settles before changing again).
    private var lastRescale: CFTimeInterval = 0
    private var fpsFrames = 0
    private var frameCount = 0
    private var cameraAnimation: (from: SIMD2<Float>, to: SIMD2<Float>, t: Float)?
    private var flyover = false

    /// Starts the slow, map-independent setup in the background, so the first renderer finds it
    /// done: compiling the shaders (a cold compile of `Shaders.source` takes about half a
    /// second on a Mac and longer on older iPads) and painting the sprite sheets. Call it
    /// early, while the start screen is up.
    public static func prewarm() {
        if let device = MTLCreateSystemDefaultDevice() { ShaderLibrary.shared.start(device: device) }
        SpriteSheetPainter.shared.start()
    }

    public init(state: GameState, viewer: PlayerID, tileSize: CGFloat = 32) {
        let clock = ContinuousClock()
        let started = clock.now
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is required")
        }
        let library: MTLLibrary
        do {
            library = try ShaderLibrary.shared.library(device: device)
        } catch {
            fatalError("Map shaders failed to compile: \(error)")
        }
        self.device = device
        self.queue = queue
        self.state = state
        self.viewer = viewer
        let layout = HexLayout(size: tileSize, map: state.map)
        self.layout = layout
        groundPipeline = Self.makePipeline(device, library, "ground_vertex", "ground_fragment", blended: false, fields: false)
        groundFieldsPipeline = Self.makePipeline(device, library, "ground_vertex", "ground_fragment", blended: false, fields: true)
        groundMaskPipeline = Self.makePipeline(device, library, "ground_mask_vertex", "ground_mask_fragment", blended: false,
                                               writesColor: false)
        decorPipeline = Self.makePipeline(device, library, "decor_vertex", "decor_fragment", blended: true)
        unitPipeline = Self.makePipeline(device, library, "unit_vertex", "unit_fragment", blended: true)
        overlayPipeline = Self.makePipeline(device, library, "overlay_vertex", "overlay_fragment", blended: true)
        pickPipeline = Self.makePipeline(device, library, "unit_vertex", "unit_pick_fragment", blended: false, format: UnitPick.format,
                                         stencil: false)
        func stencilState(_ compare: MTLCompareFunction, _ pass: MTLStencilOperation, write: UInt32) -> MTLDepthStencilState {
            let stencil = MTLStencilDescriptor()
            stencil.stencilCompareFunction = compare
            stencil.depthStencilPassOperation = pass
            stencil.writeMask = write
            let desc = MTLDepthStencilDescriptor()
            desc.frontFaceStencil = stencil
            desc.backFaceStencil = stencil
            return device.makeDepthStencilState(descriptor: desc)!
        }
        upperPipeline = Self.makePipeline(device, library, "unit_vertex", "unit_upper_fragment", blended: false, writesColor: false)
        plainStencil = stencilState(.always, .keep, write: 0)
        writeRank = stencilState(.always, .replace, write: 0xFF)
        belowRank = stencilState(.greater, .keep, write: 0)
        markFarms = stencilState(.always, .replace, write: 0xFF)
        outsideFarms = stencilState(.notEqual, .keep, write: 0)
        insideFarms = stencilState(.equal, .incrementClamp, write: 0xFF)

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.lodMaxClamp = 4
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDesc)!
        let groundSamplerDesc = MTLSamplerDescriptor()
        groundSamplerDesc.minFilter = .linear
        groundSamplerDesc.magFilter = .linear
        groundSamplerDesc.mipFilter = .linear
        groundSamplerDesc.sAddressMode = .repeat
        groundSamplerDesc.tAddressMode = .clampToEdge
        groundSampler = device.makeSamplerState(descriptor: groundSamplerDesc)!

        let atlases = Self.atlases(device: device, queue: queue)
        let decorAtlas = atlases.decor
        self.decorAtlas = decorAtlas
        self.unitAtlas = atlases.units
        self.townAtlas = atlases.towns
        groundTextures = Self.makeGroundTextures(map: state.map, layout: layout, device: device, queue: queue,
                                                 footprints: Self.reliefFootprints(map: state.map, layout: layout))

        tileBytes = Self.packTiles(state.map)
        tileTextures = (0..<Self.framesInFlight).map { _ in
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: state.map.width,
                                                                height: state.map.height, mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = .shared
            return device.makeTexture(descriptor: desc)!
        }
        tileTextureVersions = Array(repeating: -1, count: Self.framesInFlight)

        let decorations = Self.makeDecorations(map: state.map, layout: layout, atlas: decorAtlas)
        decorationCount = decorations.count
        decorIndex = DecorTileIndex(decorations, tileCount: state.map.tileCount)
        decorSegments = DecorSegment.split(decorations)
        decorReach = decorations.reduce(0) { max($0, $1.sizeAnchor.x, $1.sizeAnchor.y) } + Float(layout.size) * 0.25
        decorationBuffer = decorations.isEmpty ? nil
            : device.makeBuffer(bytes: decorations, length: MemoryLayout<SpriteInstance>.stride * decorations.count,
                                options: .storageModeShared)
        camera = MapCamera(pitch: Self.tiltPitch)
        super.init()

        refreshFog()
        syncUnits()
        if let start = state.units(of: viewer).first {
            camera.target = Self.vec(layout.center(of: start.position))
        }
        camera.clamp(layout: layout)
        textureMemoryBytes = ([decorAtlasTexture, unitAtlasTexture, townAtlas.texture] + tileTextures + groundTextures)
            .reduce(0) { $0 + $1.allocatedSize }
        let elapsed = clock.now - started
        setupMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Prepares an MTKView to be driven by this renderer.
    public func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorFormat
        view.depthStencilPixelFormat = Self.stencilFormat
        if device.supportsFamily(.apple1) { view.depthStencilStorageMode = .memoryless }
        view.clearStencil = Self.noFigure
        view.sampleCount = Self.sampleCount
        view.clearColor = Self.clearColor
        view.framebufferOnly = true
        view.preferredFramesPerSecond = Self.idleFramesPerSecond
        view.delegate = self
    }

    // MARK: State

    /// Adopt a new state, animating the events the viewer may see (with the fog off, all of
    /// them: diagnostic mode; `MapRenderer+Animation.swift`).
    public func apply(state newState: GameState, events: [EventRecord]) {
        noteActivity()
        let shownBefore = Set(unitVisuals.compactMap { $0.value.ghost ? nil : $0.key })
        let seenBefore = (0..<state.map.tileCount).map { tileBytes[$0 * 4 + 3] & Self.fogMask == 0 }
        state = newState
        refreshFog()
        var records = events.filter { !fogEnabled || $0.isVisible(to: viewer) }
        if !fogEnabled {
            // With the fog off every record shows, but one move comes as its owner's record of
            // the whole path plus one per run of steps each other player saw (M1 §12.5): only
            // the owner's is animated.
            records.removeAll { record in
                guard case let .unitMoved(id, _, _) = record.event,
                      let owner = newState.unit(id)?.owner ?? unitVisuals[id]?.owner else { return false }
                return !record.isVisible(to: owner)
            }
        }
        // Units the events will hurt keep their HP until the blows land.
        var damage: [UnitID: Int] = [:]
        for record in records {
            guard case let .combat(attacker, defender, _, _, _, dealt, taken) = record.event else { continue }
            if case let .unit(id) = defender { damage[id, default: 0] += dealt }
            if case let .unit(id) = attacker { damage[id, default: 0] += taken }
        }
        var gone = syncUnits(damage: damage)
        // A captured civilian keeps its picture (owner and type until it changes colour) under
        // its new id.
        for record in records {
            guard case let .unitCaptured(old, new, _, _, _, _) = record.event, var visual = unitVisuals[old],
                  let fresh = unitVisuals[new] else { continue }
            if visual.steps.isEmpty { visual.position = visual.base }
            visual.base = fresh.base
            visual.dimmed = fresh.dimmed
            visual.fortified = fresh.fortified
            visual.ghost = false
            unitVisuals[new] = visual
            unitVisuals[old] = nil
            gone.remove(old)
            if animation.active.remove(old) != nil { animation.active.insert(new) }
            if let busy = animation.busy.removeValue(forKey: old) { animation.busy[new] = busy }
        }
        scheduleAnimations(records, shownBefore: shownBefore, seenBefore: seenBefore)
        dropGone(gone)
        if !animatesEvents { skipAnimations() }
    }

    /// Pictures of units that left the state or the view (`syncUnits`) go, unless they stay as
    /// ghosts (fading out, or walking out of sight).
    private func dropGone(_ gone: Set<UnitID>) {
        for id in gone where !(unitVisuals[id]?.ghost ?? false) || (unitVisuals[id]?.steps.isEmpty ?? true) {
            unitVisuals[id] = nil
            animation.active.remove(id)
        }
    }

    private func refreshFog() {
        let visible = state.visibleTiles(for: viewer)
        let explored = state.players.first { $0.id == viewer }?.explored
        var changed = false
        for i in 0..<state.map.tileCount {
            let level: UInt8 = !fogEnabled || visible[i] ? 0 : ((explored?[i] ?? false) ? 1 : 2)
            let byte = level | (tileBytes[i * 4 + 3] & ~Self.fogMask)
            if tileBytes[i * 4 + 3] != byte {
                tileBytes[i * 4 + 3] = byte
                changed = true
            }
        }
        if changed {
            tileVersion += 1
            fogVersion += 1
        }
    }

    /// The fog bits of a tile's last byte (`tileBytes`), and its city-centre flag.
    private static let fogMask: UInt8 = 3
    private static let cityCentre: UInt8 = 0x80

    private func isVisibleToViewer(_ hex: HexCoord) -> Bool {
        fogLevel(hex) == 0
    }

    /// A tile's fog level for the viewer: 0 visible, 1 explored, 2 unexplored (0 everywhere
    /// with the fog off; 2 off the map).
    func fogLevel(_ hex: HexCoord) -> UInt8 {
        guard let i = state.map.index(of: hex) else { return 2 }
        guard fogEnabled else { return 0 }
        return tileBytes[i * 4 + 3] & Self.fogMask
    }

    /// Marks the city centres (tile indices) in the tile texture, clearing the rest:
    /// decorations hide there, but for a neighbour's relief reaching onto them (`decor_vertex`).
    func markCityCentres(_ tiles: Set<Int>) {
        var changed = false
        for i in 0..<state.map.tileCount {
            let byte = (tileBytes[i * 4 + 3] & ~Self.cityCentre) | (tiles.contains(i) ? Self.cityCentre : 0)
            if tileBytes[i * 4 + 3] != byte {
                tileBytes[i * 4 + 3] = byte
                changed = true
            }
        }
        if changed { tileVersion += 1 }
    }

    private func basePosition(for unit: GameCore.Unit) -> SIMD2<Float> {
        let c = Self.vec(layout.center(of: unit.position))
        guard state.units(at: unit.position).count > 1 else { return c }
        let d = Float(layout.size) * 0.3
        return unit.type.isCivilian ? c + [-d, -d * 0.6] : c + [d, d * 0.6]
    }

    /// Brings the unit pictures in line with the state: one for every unit the viewer sees (a
    /// new one at rest, its HP bar still showing `damage` the events will take), and resting
    /// ones move to their places (remembering where they were drawn, for a walk to start from).
    /// Returns the units whose pictures no seen unit backs any more.
    @discardableResult
    private func syncUnits(damage: [UnitID: Int] = [:]) -> Set<UnitID> {
        unitsVersion += 1
        var alive = Set<UnitID>()
        for unit in state.units where unit.owner == viewer || isVisibleToViewer(unit.position) {
            alive.insert(unit.id)
            let base = basePosition(for: unit)
            var visual = unitVisuals[unit.id] ?? UnitVisual(type: unit.type, owner: unit.owner, base: base, position: base)
            if visual.steps.isEmpty {
                visual.position = visual.base
                visual.type = unit.type
                visual.owner = unit.owner
                visual.hp = min(unit.hp + (damage[unit.id] ?? 0), 100)
            }
            visual.base = base
            visual.ghost = false
            // Own units with no moves left, an activity or a standing order are dimmed (M1 §15),
            // unless ready to act (`setReadyUnits`).
            visual.dimmed = isDimmed(unit)
            visual.fortified = unit.activity == .fortified || unit.activity == .fortifying
            unitVisuals[unit.id] = visual
        }
        return Set(unitVisuals.keys).subtracting(alive)
    }

    // MARK: Camera & input

    /// The tile on the ground under a view point.
    func groundHex(atViewPoint point: CGPoint) -> HexCoord? {
        guard let g = camera.groundPoint(atViewPoint: point) else { return nil }
        return state.map.normalize(layout.hex(at: CGPoint(x: CGFloat(g.x), y: CGFloat(g.y))))
    }

    public func pan(from a: CGPoint, to b: CGPoint) {
        noteActivity()
        cameraAnimation = nil
        camera.pan(from: a, to: b, layout: layout)
    }

    public func zoom(by factor: CGFloat, aroundViewPoint point: CGPoint) {
        noteActivity()
        camera.zoom(by: Float(factor), around: point, layout: layout)
    }

    /// Brings a hex to the middle of the part of the view the panels leave uncovered
    /// (`setViewportInsets`).
    public func centerCamera(on hex: HexCoord, animated: Bool = true) {
        noteActivity()
        let c = Self.vec(layout.center(of: hex))
        // The camera's target shows at the view's middle; moving the target moves every ground
        // point with it, so the uncovered middle's offset from the target carries over.
        let open = uncoveredRect()
        var offset = SIMD2<Float>.zero
        if let g = camera.groundPoint(atViewPoint: CGPoint(x: open.midX, y: open.midY)) { offset = g - camera.target }
        let to = SIMD2(Float(layout.nearestCopy(of: CGFloat(c.x - offset.x), to: CGFloat(camera.target.x))), c.y - offset.y)
        if animated {
            cameraAnimation = (camera.target, to, 0)
        } else {
            camera.target = to
            camera.clamp(layout: layout)
        }
    }

    /// Moves the camera target to a world point (debug/automation).
    public func setCameraPosition(_ point: CGPoint) {
        camera.target = Self.vec(point)
        camera.clamp(layout: layout)
    }

    /// Sets zoom directly (clamped). 1 = default, larger = zoomed out.
    public func setCameraScale(_ scale: CGFloat) {
        camera.scale = Float(scale)
        camera.clamp(layout: layout)
    }

    /// Continuous eastward pan, for measuring frame rate while scrolling.
    public func setFlyover(_ enabled: Bool) {
        flyover = enabled
    }

    public var statsLine: String {
        String(format: "%.0f fps · CPU %.1f ms · GPU %.1f ms · %d sprites", framesPerSecond, cpuFrameMilliseconds,
               gpuFrameMilliseconds, spritesDrawn)
    }

    // MARK: Frame

    /// More room under the panels applies at once (a centring right after must not be cut
    /// short); less eases in frame by frame (`advance`).
    func widenCoveredBands(to insets: MapInsets) {
        camera.coveredTop = max(camera.coveredTop, Float(insets.top))
        camera.coveredBottom = max(camera.coveredBottom, Float(insets.bottom))
    }

    private func advance(by dt: Float) {
        if flyover { camera.target.x += Float(layout.tileWidth) * 12 * dt }
        if var animation = cameraAnimation {
            animation.t = min(1, animation.t + dt / 0.25)
            let e = animation.t * animation.t * (3 - 2 * animation.t)
            camera.target = animation.from + (animation.to - animation.from) * e
            cameraAnimation = animation.t >= 1 ? nil : animation
        }
        // Panels' bands: more room applies at once, less eases in over a few frames, so the
        // camera glides back onto the map when a panel closes.
        let covered = inputs.viewportInsets
        func ease(_ current: Float, to wanted: Float) -> Float {
            if wanted >= current || current - wanted < 0.5 { return wanted }
            return current + (wanted - current) * min(1, dt * 10)
        }
        camera.coveredTop = ease(camera.coveredTop, to: Float(covered.top))
        camera.coveredBottom = ease(camera.coveredBottom, to: Float(covered.bottom))
        camera.clamp(layout: layout)
        if let animation = cameraAnimation, animation.t < 1 {
            // Clamping may have wrapped the target; keep the animation in the same period.
            let shift = camera.target.x - (animation.from.x + (animation.to.x - animation.from.x) * animation.t * animation.t * (3 - 2 * animation.t))
            if abs(shift) > 1 { cameraAnimation = (animation.from + [shift, 0], animation.to + [shift, 0], animation.t) }
        }
        advanceAnimations(by: dt)
    }

    func makeUniforms(pixelScale: Float? = nil) -> Uniforms {
        let pixelScale = pixelScale ?? self.pixelScale
        let w = Float(layout.worldWidth), h = Float(layout.worldHeight)
        // Remainder in Double: the renderer's age keeps growing, and a Float loses the
        // sub-frame precision animations need after a few hours.
        let t = animationTime ?? Float((CACurrentMediaTime() - startTime).truncatingRemainder(dividingBy: 3600))
        let x0 = layout.wrapsX ? camera.target.x - w : -w * 0.5
        let x1 = layout.wrapsX ? camera.target.x + w : w * 1.5
        // North and south, the ground reaches 60% of the map's height past the poles, or a tile
        // past the ground in view when that is farther (zoomed out past the map's height).
        let span = camera.groundSpanY, tw = Float(layout.tileWidth)
        let y0 = min(-h * 0.6, (span?.south ?? 0) - tw), y1 = max(h * 1.6, (span?.north ?? h) + tw)
        func color(_ terrain: Terrain) -> SIMD4<Float> {
            let c = Palette.terrain(terrain)
            return [Float(c.r), Float(c.g), Float(c.b), 1]
        }
        let sun = simd_normalize(SIMD3<Float>(-0.55, 0.45, 0.70))
        return Uniforms(
            viewProj: camera.viewProjection,
            cameraUp: SIMD4(camera.up, t),
            eye: SIMD4(camera.eye, camera.scale),
            sun: SIMD4(sun, 0),
            viewport: [camera.viewSize.x * pixelScale, camera.viewSize.y * pixelScale, camera.pitch, pixelScale / camera.scale],
            map: [Float(layout.size), Float(layout.tileWidth), Float(layout.rowHeight), w],
            dims: [Float(layout.mapWidth), Float(layout.mapHeight), layout.wrapsX ? 1 : 0, layout.wrapsX ? 3 : 1],
            ground: [x0, y0, x1, y1],
            fogColor: [0.05, 0.06, 0.08, 1],
            options: [showGrid ? 0.14 : 0, groundDebug, fogEnabled ? 1 : 0, tribalVillageFadeSlot()],
            terrain: (color(.grassland), color(.plains), color(.desert), color(.tundra),
                      color(.snow), color(.coast), color(.ocean), color(.lake))
        )
    }

    private func encodeFrame(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, slot: Int) {
        let tiles = tileTextures[slot]
        if tileTextureVersions[slot] != tileVersion {
            tileBytes.withUnsafeBytes {
                tiles.replace(region: MTLRegionMake2D(0, 0, layout.mapWidth, layout.mapHeight), mipmapLevel: 0,
                              withBytes: $0.baseAddress!, bytesPerRow: layout.mapWidth * 4)
            }
            tileTextureVersions[slot] = tileVersion
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = makeUniforms()
        let copies = layout.wrapsX ? 3 : 1

        if passes.contains(.ground) {
            // Farm fields only where known farms are (`kGroundFields`): their squares marked
            // in the stencil, the plain ground around them, the fields variant inside.
            let farms = groundFieldsEverywhere ? (buffer: nil, count: 0) : knownFarmCenters()
            if let buffer = farms.buffer {
                encoder.setRenderPipelineState(groundMaskPipeline)
                encoder.setDepthStencilState(markFarms)
                encoder.setStencilReferenceValue(Self.farmMark)
                Self.bind(&uniforms, to: encoder)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: farms.count * copies)
                encoder.setDepthStencilState(outsideFarms)
            }
            encoder.setRenderPipelineState(groundFieldsEverywhere ? groundFieldsPipeline : groundPipeline)
            Self.bind(&uniforms, to: encoder)
            encoder.setFragmentTexture(tiles, index: 0)
            for (i, texture) in groundTextures.enumerated() { encoder.setFragmentTexture(texture, index: i + 1) }
            encoder.setFragmentSamplerState(groundSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if farms.buffer != nil {
                encoder.setRenderPipelineState(groundFieldsPipeline)
                encoder.setDepthStencilState(insideFarms)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.setStencilReferenceValue(Self.noFigure)
            }
        }

        let frame = passes.isDisjoint(with: [.units, .unitGround]) ? UnitFrame() : unitFrame()
        let unitBuffer = dynamicRing.upload(frame.sprites, slot: slot, device: device)
        func bindUnits(_ buffer: MTLBuffer) {
            encoder.setRenderPipelineState(unitPipeline)
            Self.bind(&uniforms, to: encoder)
            encoder.setVertexTexture(tiles, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(unitAtlasTexture, index: 0)
            encoder.setFragmentTexture(townAtlas.texture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        func drawUnits(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: range.count * copies, baseInstance: range.lowerBound * copies)
        }
        encoder.setDepthStencilState(plainStencil)
        // Base fills and cast shadows lie on the ground, under the decorations.
        if let unitBuffer, !frame.ground.isEmpty, passes.contains(.unitGround) {
            bindUnits(unitBuffer)
            drawUnits(frame.ground)
        }

        decorDrawn = 0
        if let decorationBuffer, passes.contains(.decor) {
            encoder.setRenderPipelineState(decorPipeline)
            Self.bind(&uniforms, to: encoder)
            encoder.setVertexTexture(tiles, index: 0)
            encoder.setVertexBuffer(decorationBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(decorAtlasTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            for range in visibleDecorRanges() {
                // instance_id includes the base instance, so the shader's iid / copies still
                // indexes the whole buffer.
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: range.count * copies, baseInstance: range.lowerBound * copies)
                decorDrawn += range.count
            }
        }

        let overlay = passes.contains(.overlays) ? overlayGeometry() : []
        if let buffer = overlayRing.upload(overlay, slot: slot, device: device) {
            encoder.setRenderPipelineState(overlayPipeline)
            Self.bind(&uniforms, to: encoder)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlay.count, instanceCount: copies)
        }

        // Unit layers over the decorations (`UnitFrame`): bands, figures writing their ranks,
        // the plants in front of them again, then medallions and markers.
        let lifted = liftDecorations && passes.isSuperset(of: [.decor, .units]) ? decorationBuffer.map {
            liftedDecorations(frame, decorations: $0.contents().assumingMemoryBound(to: SpriteInstance.self))
        } ?? [] : []
        if let unitBuffer, passes.contains(.units) {
            bindUnits(unitBuffer)
            drawUnits(frame.bands)
            // Groups behind a lifted plant write their rank over their legs. The rest (all of
            // them when no plant stands in front of a figure, as in most frames) are drawn in
            // as few draws as possible, clearing the stencil so no plant covers them.
            let ranked = min(Int(lifted.map(\.rank).max() ?? 1) - 1, frame.figures.count)
            encoder.setDepthStencilState(ranked > 0 ? writeRank : plainStencil)
            for (group, figures) in frame.figures.prefix(ranked).enumerated() {
                encoder.setRenderPipelineState(unitPipeline)
                encoder.setStencilReferenceValue(UnitFrame.rank(group))
                drawUnits(figures.range)
                var cut = legHeight(of: figures, in: frame)
                encoder.setRenderPipelineState(upperPipeline)
                encoder.setFragmentBytes(&cut, length: 4, index: 3)
                encoder.setStencilReferenceValue(Self.noFigure)
                drawUnits(figures.range)
            }
            encoder.setRenderPipelineState(unitPipeline)
            encoder.setStencilReferenceValue(Self.noFigure)
            var run: Range<Int>?
            for figures in frame.figures.dropFirst(ranked) {
                if let r = run, r.upperBound == figures.range.lowerBound {
                    run = r.lowerBound..<figures.range.upperBound
                } else {
                    if let r = run { drawUnits(r) }
                    run = figures.range
                }
            }
            if let run { drawUnits(run) }
            encoder.setDepthStencilState(plainStencil)
        }
        if let decorationBuffer, !lifted.isEmpty {
            let source = decorationBuffer.contents().assumingMemoryBound(to: SpriteInstance.self)
            if let buffer = liftedRing.upload(lifted.map { source[$0.index] }, slot: slot, device: device) {
                encoder.setRenderPipelineState(decorPipeline)
                Self.bind(&uniforms, to: encoder)
                encoder.setVertexTexture(tiles, index: 0)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentTexture(decorAtlasTexture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setDepthStencilState(belowRank)
                var start = 0
                while start < lifted.count {
                    let rank = lifted[start].rank
                    var end = start + 1
                    while end < lifted.count, lifted[end].rank == rank { end += 1 }
                    encoder.setStencilReferenceValue(rank)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                           instanceCount: (end - start) * copies, baseInstance: start * copies)
                    start = end
                }
                encoder.setDepthStencilState(plainStencil)
            }
        }
        if let unitBuffer, passes.contains(.units) {
            bindUnits(unitBuffer)
            drawUnits(frame.top)
        }
        spritesDrawn = (decorDrawn + frame.sprites.count + lifted.count) * copies
        encoder.endEncoding()
    }

    /// Renders one frame offscreen (tests, screenshots). Size in pixels; `scale` is pixels per point.
    public func renderImage(width: Int, height: Int, scale: CGFloat = 2) -> CGImage? {
        camera.viewSize = [Float(CGFloat(width) / scale), Float(CGFloat(height) / scale)]
        pixelScale = Float(scale)
        camera.clamp(layout: layout)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = backdrop ?? Self.clearColor
        pass.colorAttachments[0].storeAction = .store
        let stencilDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.stencilFormat, width: width, height: height, mipmapped: false)
        stencilDesc.usage = .renderTarget
        stencilDesc.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        pass.stencilAttachment.texture = device.makeTexture(descriptor: stencilDesc)
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = Self.noFigure
        pass.stencilAttachment.storeAction = .dontCare

        inFlight.wait()
        let slot = frameIndex % Self.framesInFlight
        frameIndex += 1
        encodeFrame(into: commandBuffer, pass: pass, slot: slot)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastOffscreenGPUMilliseconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        inFlight.signal()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Uniforms go to buffer(1) of both stages in every pass. A static helper rather than a
    /// closure: capturing the encoder in a closure trips Swift 6's data-race check in -O builds.
    static func bind(_ uniforms: inout Uniforms, to encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
    }

    // MARK: Setup helpers

    static func vec(_ p: CGPoint) -> SIMD2<Float> { [Float(p.x), Float(p.y)] }

    /// `fields`: the value of the ground's `kGroundFields` function constant, for
    /// `ground_fragment` only.
    private static func makePipeline(_ device: MTLDevice, _ library: MTLLibrary, _ vertex: String, _ fragment: String,
                                     blended: Bool, format: MTLPixelFormat = colorFormat, stencil: Bool = true,
                                     writesColor: Bool = true, fields: Bool? = nil) -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        if var fields {
            let values = MTLFunctionConstantValues()
            values.setConstantValue(&fields, type: .bool, index: 0)
            do {
                desc.fragmentFunction = try library.makeFunction(name: fragment, constantValues: values)
            } catch {
                fatalError("Specializing \(fragment) failed: \(error)")
            }
        } else {
            desc.fragmentFunction = library.makeFunction(name: fragment)
        }
        desc.rasterSampleCount = sampleCount
        if stencil { desc.stencilAttachmentPixelFormat = stencilFormat }
        let color = desc.colorAttachments[0]!
        color.pixelFormat = format
        if !writesColor { color.writeMask = [] }
        if blended { // premultiplied alpha
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Pipeline \(vertex)/\(fragment) failed: \(error)")
        }
    }

    /// The process-wide atlases for `device`, uploading the painted sheets on first use.
    private static func atlases(device: MTLDevice, queue: MTLCommandQueue)
        -> (decor: SpriteAtlas<DecorSprite>, units: SpriteAtlas<UnitSprite>, towns: SpriteAtlas<SettlementSprite>) {
        if let cache = atlasCache, cache.device == device.registryID { return (cache.decor, cache.units, cache.towns) }
        let sheets = SpriteSheetPainter.shared.take()
        let decor = SpriteAtlas(sheets.decor, device: device, queue: queue)
        let units = SpriteAtlas(sheets.units, device: device, queue: queue)
        let towns = SpriteAtlas(sheets.towns, device: device, queue: queue)
        atlasCache = (device.registryID, decor, units, towns)
        return (decor, units, towns)
    }

    private static func packTiles(_ map: HexMap) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: map.tileCount * 4)
        for i in 0..<map.tileCount {
            let tile = map[index: i]
            bytes[i * 4] = tile.terrain.rawValue
            bytes[i * 4 + 1] = tile.elevation.rawValue | (tile.feature.rawValue << 2)
            bytes[i * 4 + 2] = tile.riverEdges
            bytes[i * 4 + 3] = 2
        }
        return bytes
    }

}

// MARK: Decoration culling

/// A contiguous range of the decoration buffer and whether it is sorted by descending y.
struct DecorSegment {
    var range: Range<Int>
    /// Anchor y of each instance in a sorted segment (descending); empty when unsorted.
    var ys: [Float]

    /// Splits instances into sorted runs long enough to be worth cutting, and the rest.
    static func split(_ instances: [SpriteInstance], minimumRun: Int = 256) -> [DecorSegment] {
        var segments: [DecorSegment] = []
        func add(_ range: Range<Int>, sorted: Bool) {
            guard !range.isEmpty else { return }
            if !sorted, let last = segments.last, last.ys.isEmpty, last.range.upperBound == range.lowerBound {
                segments[segments.count - 1].range = last.range.lowerBound..<range.upperBound // merge unsorted
            } else {
                segments.append(DecorSegment(range: range, ys: sorted ? instances[range].map(\.position.y) : []))
            }
        }
        var start = 0
        while start < instances.count {
            var end = start + 1
            while end < instances.count, instances[end].position.y <= instances[end - 1].position.y { end += 1 }
            add(start..<end, sorted: end - start >= minimumRun)
            start = end
        }
        return segments
    }

    /// The part of the segment anchored within `low...high` (all of it when unsorted).
    func cut(low: Float, high: Float) -> Range<Int> {
        guard !ys.isEmpty else { return range }
        // ys descends: first index with y <= high, first index with y < low.
        func firstIndex(where predicate: (Float) -> Bool) -> Int {
            var lo = 0, hi = ys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if predicate(ys[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let from = firstIndex { $0 <= high }, to = firstIndex { $0 < low }
        return (range.lowerBound + from)..<(range.lowerBound + max(from, to))
    }
}

extension MapRenderer {
    /// Index ranges of the decoration buffer to draw this frame, in buffer order: anchors
    /// between the view's near and far ground edges, widened by the largest sprite.
    func visibleDecorRanges() -> [Range<Int>] {
        // The part of the view panels leave uncovered (`setViewportInsets`), with a margin.
        let open = uncoveredRect(margin: Self.insetCullMargin)
        guard cullDecorations,
              let near = camera.groundPoint(atViewPoint: CGPoint(x: open.midX, y: open.maxY)),
              let far = camera.groundPoint(atViewPoint: CGPoint(x: open.midX, y: open.minY)) else {
            return decorSegments.map(\.range)
        }
        return decorSegments.map { $0.cut(low: near.y - decorReach, high: far.y + decorReach) }.filter { !$0.isEmpty }
    }
}

// MARK: Frame pacing and render scale

extension MapRenderer {
    /// Frame rate while only ambient motion runs (water, clouds, sway, banners): slow enough
    /// motion to read smoothly at 30 fps, and it lets an iPad's GPU idle most of the time.
    static let idleFramesPerSecond = 30
    /// How long after input or an animation the view keeps its full frame rate.
    static let activeLinger: CFTimeInterval = 0.75

    /// Marks the map as in use (gestures, taps, camera and unit moves): full frame rate.
    func noteActivity() { lastActivity = CACurrentMediaTime() }

    /// Picks the frame rate for the next frames, and on iOS adapts the render scale to the GPU
    /// time: a GPU that cannot hold 60 fps at native resolution renders slightly smaller
    /// instead (down to 72%), and goes back up once it has headroom.
    func pace(_ view: MTKView, now: CFTimeInterval) {
        if cameraAnimation != nil || flyover || !animation.isIdle {
            lastActivity = now
        }
        let gpu = gpuFrameMilliseconds
        // ProMotion only when the frame is cheap enough to hold it; otherwise 60.
        let active = gpu > 0 && gpu < 6 ? 120 : 60
        let rate = now - lastActivity < Self.activeLinger ? active : Self.idleFramesPerSecond
        if view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }

        // Only on devices: the simulator's GPU times say nothing about an iPad's.
        #if canImport(UIKit) && !targetEnvironment(simulator)
        guard gpu > 0, let native = view.window?.screen.nativeScale else { return }
        let current = view.contentScaleFactor
        if gpu > 14, current > native * 0.75, now - lastRescale > 1 {
            view.contentScaleFactor = max(native * 0.72, current - native * 0.08)
            lastRescale = now
        } else if gpu < 7, current < native, now - lastRescale > 4 {
            view.contentScaleFactor = min(native, current + native * 0.08)
            lastRescale = now
        }
        #endif
    }
}

extension MapRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.viewSize = [Float(view.bounds.width), Float(view.bounds.height)]
        camera.clamp(layout: layout)
    }

    public func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? Float(1.0 / 60) : Float(min(frameStart - lastFrameTime, 0.1))
        lastFrameTime = frameStart
        fpsFrames += 1
        if fpsWindowStart == 0 { fpsWindowStart = frameStart }
        if frameStart - fpsWindowStart >= 0.5 {
            framesPerSecond = Double(fpsFrames) / (frameStart - fpsWindowStart)
            fpsFrames = 0
            fpsWindowStart = frameStart
        }

        camera.viewSize = [Float(view.bounds.width), Float(view.bounds.height)]
        if view.bounds.height > 0 { pixelScale = Float(view.drawableSize.height / view.bounds.height) }
        advance(by: dt)
        pace(view, now: frameStart)
        var work = CACurrentMediaTime() - frameStart

        // Waiting for a free frame slot and the next drawable is not counted as CPU work.
        inFlight.wait()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let encodeStart = CACurrentMediaTime()
        let slot = frameIndex % Self.framesInFlight
        frameIndex += 1
        encodeFrame(into: commandBuffer, pass: pass, slot: slot)
        if view.presentsWithTransaction != presentsWithTransaction { view.presentsWithTransaction = presentsWithTransaction }
        if !presentsWithTransaction { commandBuffer.present(drawable) }
        let semaphore = inFlight, timer = gpuTimer
        commandBuffer.addCompletedHandler { buffer in
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            timer.milliseconds.withLock { $0 = $0 == 0 ? ms : $0 * 0.9 + ms * 0.1 }
            semaphore.signal()
        }
        commandBuffer.commit()
        if presentsWithTransaction {
            // In step with this run loop's Core Animation transaction, which carries the views
            // `onFrame` moves.
            commandBuffer.waitUntilScheduled()
            drawable.present()
        }

        work += CACurrentMediaTime() - encodeStart
        cpuFrameMilliseconds = cpuFrameMilliseconds * 0.9 + work * 100
        frameCount += 1
        if frameCount == 10, let callback = onFirstFrame {
            onFirstFrame = nil
            callback()
        }
        onFrame?()
    }
}
