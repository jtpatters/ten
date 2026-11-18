import CoreGraphics
import Dispatch
import Foundation
import Metal
import Synchronization

/// A family of procedurally drawn sprites that share one atlas texture.
protocol SpriteSet: Hashable, Sendable {
    /// Every sprite in the set.
    static var all: [Self] { get }
    /// Cell edge in pixels: a power of two from 32 to 512. Art is laid out in fractions of
    /// its cell.
    var cellSize: Int { get }
    /// Draws the sprite into `rect`: its cell inset by a 1/20 margin, in y-up Core Graphics
    /// coordinates. Drawing is clipped to the cell.
    func draw(in rect: CGRect, ctx: CGContext)
    /// The part of the cell the renderer may sample (lo x, lo y, hi x, hi y as fractions of
    /// the cell, y up), or nil for wherever the sprite paints (plus `SpriteSheet.paintSlack`
    /// texels). The atlas keeps only that part (and a gutter round it), and a quad that
    /// strays outside it reads its neighbours.
    var sampled: SIMD4<Float>? { get }
    /// The bake file's name (`AtlasBaker`).
    static var bakeName: String { get }
    /// What painting the set works out besides pixels (decorations' image layouts), saved
    /// with a bake and restored when the bake is loaded instead of painting.
    static func bakeExtras() -> Data
    static func restoreBakeExtras(_ data: Data) throws
}

extension SpriteSet {
    var sampled: SIMD4<Float>? { [0, 0, 1, 1] }
    static func bakeExtras() -> Data { Data() }
    static func restoreBakeExtras(_ data: Data) throws {}
}

/// How the sprite sets paint their cells: in parallel (at launch, when there is no bake), or one
/// after another (`AtlasBaker`). Core Graphics painting in parallel now and then comes out a
/// level or two different in a few texels of a cell or two; one after another it is the same
/// every time, so a bake depends only on the code.
enum SpritePainting {
    static let serial = Mutex(false)

    static func perform(_ count: Int, _ work: (Int) -> Void) {
        if serial.withLock({ $0 }) {
            for i in 0..<count { work(i) }
        } else {
            DispatchQueue.concurrentPerform(iterations: count, execute: work)
        }
    }
}

/// A `SpriteSet` painted into RGBA8 premultiplied pixels, and each sprite's UV rectangle
/// (top-left origin). Pure CPU work, so it can be painted off the main
/// actor, or read from a bake (`AtlasBaker`).
///
/// Sprites are painted into square cells, then each cell is cut down to the part the
/// renderer samples (`SpriteSet.sampled`) plus a gutter, and those windows are packed
/// tightly. A sprite's UV rectangle is still its whole cell's, placed so that the window
/// lands where it was packed: the rest of that rectangle overlaps other sprites and must not
/// be sampled. Windows sit at multiples of `alignment` texels and are that many texels
/// across, so no texel of the mip levels the sampler uses (`levelCount`, made by the GPU,
/// `SpriteAtlas`) straddles two of them, and a sample `gutter` texels inside a window never
/// filters in a neighbour's texels.
struct SpriteSheet<Key: SpriteSet>: Sendable {
    static var width: Int { 2048 }
    /// Mip levels kept: the sprite sampler clamps its level of detail to 4 (`MapRenderer`).
    static var levelCount: Int { 5 }
    /// Window origins and sizes are multiples of this: a texel of the smallest level.
    static var alignment: Int { 1 << (levelCount - 1) }
    /// Texels kept round what a sprite samples: half a texel of the smallest level.
    static var gutter: Int { alignment / 2 }
    /// Texels kept round the paint of sprites trimmed to it.
    static var paintSlack: Int { 4 }

    let width: Int
    let height: Int
    /// RGBA8 texels, rows packed.
    let pixels: Data
    /// Each sprite's whole cell (see above).
    let uvs: [Key: SIMD4<Float>]
    /// Each sprite's window in the atlas (texels: x, y, width, height).
    let windows: [Key: SIMD4<Int32>]

    var bytesPerRow: Int { width * 4 }

    /// Paints every sprite.
    init() {
        let painted = PaintedCells<Key>()
        var regions: [Key: (x0: Int, y0: Int, x1: Int, y1: Int)] = [:]
        for (key, x, y) in painted.origins {
            let size = key.cellSize
            if let s = key.sampled {
                // Cell texels, y down.
                regions[key] = (Int((s.x * Float(size)).rounded(.down)), Int(((1 - s.w) * Float(size)).rounded(.down)),
                                Int((s.z * Float(size)).rounded(.up)), Int(((1 - s.y) * Float(size)).rounded(.up)))
            } else {
                let box = painted.inkBox(x: x, y: y, size: size)
                    ?? (size / 2 - 1, size / 2 - 1, size / 2 + 1, size / 2 + 1)
                let slack = Self.paintSlack
                regions[key] = (box.0 - slack, box.1 - slack, box.2 + slack, box.3 + slack)
            }
        }
        // Windows: each region plus its gutter, out to the alignment, within its cell.
        let a = Self.alignment, g = Self.gutter
        var cuts: [(key: Key, cx: Int, cy: Int, w: Int, h: Int)] = []
        for key in Key.all {
            guard let r = regions[key] else { continue }
            let size = key.cellSize
            func down(_ v: Int) -> Int { max(0, Int((Double(v - g) / Double(a)).rounded(.down)) * a) }
            func up(_ v: Int) -> Int { min(size, Int((Double(v + g) / Double(a)).rounded(.up)) * a) }
            let x0 = down(r.x0), y0 = down(r.y0), x1 = max(up(r.x1), x0 + a), y1 = max(up(r.y1), y0 + a)
            cuts.append((key, x0, y0, x1 - x0, y1 - y0))
        }
        let (places, height) = Self.pack(cuts.map { ($0.w, $0.h) })
        let width = Self.width

        var level0 = [UInt8](repeating: 0, count: width * height * 4)
        var uvs: [Key: SIMD4<Float>] = [:]
        var windows: [Key: SIMD4<Int32>] = [:]
        let origin = Dictionary(uniqueKeysWithValues: painted.origins.map { ($0.key, ($0.x, $0.y)) })
        painted.withBytes { source, sourceRow in
            level0.withUnsafeMutableBytes { target in
                for (cut, place) in zip(cuts, places) {
                    guard let (cellX, cellY) = origin[cut.key] else { continue }
                    for row in 0..<cut.h {
                        let from = (cellY + cut.cy + row) * sourceRow + (cellX + cut.cx) * 4
                        let to = (place.y + row) * width * 4 + place.x * 4
                        target.baseAddress!.advanced(by: to).copyMemory(from: source.advanced(by: from), byteCount: cut.w * 4)
                    }
                    let size = Float(cut.key.cellSize)
                    uvs[cut.key] = SIMD4(Float(place.x - cut.cx) / Float(width), Float(place.y - cut.cy) / Float(height),
                                         size / Float(width), size / Float(height))
                    windows[cut.key] = SIMD4(Int32(place.x), Int32(place.y), Int32(cut.w), Int32(cut.h))
                }
            }
        }
        self.width = width
        self.height = height
        self.uvs = uvs
        self.windows = windows
        pixels = Data(level0)
    }

    /// Packs rectangles (multiples of `alignment`) into rows `width` texels wide, tallest
    /// first, each at the lowest then leftmost spot on the skyline. Returns each one's origin
    /// (in the order given) and the height used, a multiple of `alignment`.
    static func pack(_ sizes: [(w: Int, h: Int)]) -> (places: [(x: Int, y: Int)], height: Int) {
        let a = alignment, columns = width / a
        let order = sizes.indices.sorted { (sizes[$1].h, sizes[$1].w, $0) < (sizes[$0].h, sizes[$0].w, $1) }
        var sky = [Int](repeating: 0, count: columns)
        var places = [(x: Int, y: Int)](repeating: (0, 0), count: sizes.count)
        for i in order {
            let w = sizes[i].w / a, h = sizes[i].h / a
            precondition(w >= 1 && w <= columns, "a window must fit the atlas width")
            var best = (y: Int.max, x: 0)
            for x in 0...(columns - w) {
                var y = 0
                for c in x..<(x + w) where sky[c] > y { y = sky[c] }
                if y < best.y { best = (y, x) }
            }
            for c in best.x..<(best.x + w) { sky[c] = best.y + h }
            places[i] = (best.x * a, best.y * a)
        }
        return (places, max(sky.max() ?? 1, 1) * a)
    }

    // MARK: Bake

    /// Identifies the set's layout inputs (every sprite, its cell size and sampled region) and
    /// the format, so a bake made from other code is ignored.
    static var fingerprint: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        mix("v1|\(width)|\(levelCount)|\(alignment)|\(gutter)|\(paintSlack)|")
        for key in Key.all { mix("\(key)|\(key.cellSize)|\(key.sampled.map { "\($0)" } ?? "paint");") }
        return hash
    }

    private static var magic: UInt32 { 0x5441_5954 } // "TYAT"

    /// The sheet as a bake file: a header, each sprite's window (in `Key.all` order), the
    /// set's extras and the pixels, LZFSE-compressed.
    func encoded() throws -> Data {
        var out = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(Self.magic)
        put(Self.fingerprint)
        put(UInt32(width))
        put(UInt32(height))
        let keys = Key.all
        put(UInt32(keys.count))
        for key in keys {
            let window = windows[key] ?? .zero, uv = uvs[key] ?? .zero
            // The cell's origin relative to the window, in texels.
            let dx = Int32((uv.x * Float(width)).rounded()) - window.x, dy = Int32((uv.y * Float(height)).rounded()) - window.y
            for v in [window.x, window.y, window.z, window.w, dx, dy] { put(v) }
        }
        let extras = Key.bakeExtras()
        put(UInt32(extras.count))
        out.append(extras)
        let packed = try (pixels as NSData).compressed(using: .lzfse) as Data
        put(UInt32(packed.count))
        out.append(packed)
        return out
    }

    enum BakeError: Error { case malformed, otherCode }

    /// Reads a bake file, restoring the set's extras. Throws `BakeError.otherCode` for a bake
    /// of another layout.
    init(decoding data: Data) throws {
        var at = data.startIndex
        func take<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            guard data.endIndex - at >= n else { throw BakeError.malformed }
            var value = T.zero
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: data[at..<(at + n)]) }
            at += n
            return T(littleEndian: value)
        }
        func bytes(_ n: Int) throws -> Data {
            guard n >= 0, data.endIndex - at >= n else { throw BakeError.malformed }
            defer { at += n }
            return data.subdata(in: at..<(at + n))
        }
        guard try take(UInt32.self) == Self.magic else { throw BakeError.malformed }
        guard try take(UInt64.self) == Self.fingerprint else { throw BakeError.otherCode }
        let width = Int(try take(UInt32.self)), height = Int(try take(UInt32.self))
        let keys = Key.all
        guard width == Self.width, height > 0, height % Self.alignment == 0,
              Int(try take(UInt32.self)) == keys.count else { throw BakeError.otherCode }
        var uvs: [Key: SIMD4<Float>] = [:], windows: [Key: SIMD4<Int32>] = [:]
        for key in keys {
            let v = try (0..<6).map { _ in try take(Int32.self) }
            let size = Float(key.cellSize)
            windows[key] = SIMD4(v[0], v[1], v[2], v[3])
            uvs[key] = SIMD4(Float(v[0] + v[4]) / Float(width), Float(v[1] + v[5]) / Float(height), size / Float(width), size / Float(height))
        }
        try Key.restoreBakeExtras(bytes(Int(take(UInt32.self))))
        let pixels = try (bytes(Int(take(UInt32.self))) as NSData).decompressed(using: .lzfse) as Data
        guard pixels.count == width * height * 4 else { throw BakeError.malformed }
        self.width = width
        self.height = height
        self.uvs = uvs
        self.windows = windows
        self.pixels = pixels
    }
}

/// Every sprite of a set painted into its own square cell of one big bitmap, cells packed at
/// multiples of their own size: the painting canvas `SpriteSheet` cuts its windows from.
private final class PaintedCells<Key: SpriteSet> {
    let origins: [(key: Key, x: Int, y: Int)]
    private let ctx: CGContext

    init() {
        let (origins, height) = Self.layout()
        self.origins = origins
        ctx = CGContext(data: nil, width: SpriteSheet<Key>.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (key, x, y) in origins {
            let size = CGFloat(key.cellSize)
            // Bitmap contexts are y-up; memory row 0 is the top.
            let rect = CGRect(x: CGFloat(x), y: CGFloat(height - y) - size, width: size, height: size)
            ctx.saveGState()
            ctx.clip(to: rect)
            key.draw(in: rect.insetBy(dx: size / 20, dy: size / 20), ctx: ctx)
            ctx.restoreGState()
        }
    }

    func withBytes<R>(_ body: (UnsafeRawPointer, Int) -> R) -> R { body(UnsafeRawPointer(ctx.data!), ctx.bytesPerRow) }

    /// The box round a cell's painted texels (any channel: data cells write numbers where
    /// alpha is zero), cell texels with y down and exclusive upper ends; nil when it paints
    /// nothing.
    func inkBox(x: Int, y: Int, size: Int) -> (Int, Int, Int, Int)? {
        withBytes { base, row in
            let p = base.assumingMemoryBound(to: UInt32.self), stride = row / 4
            var x0 = size, y0 = size, x1 = 0, y1 = 0
            for j in 0..<size {
                let line = (y + j) * stride + x
                for i in 0..<size where p[line + i] != 0 {
                    x0 = min(x0, i)
                    x1 = max(x1, i + 1)
                    y0 = min(y0, j)
                    y1 = j + 1
                }
            }
            return x1 > x0 ? (x0, y0, x1, y1) : nil
        }
    }

    /// Largest cells first (in `all` order within a size), each in the first free place, row
    /// by row, at a multiple of its own size.
    private static func layout() -> (origins: [(key: Key, x: Int, y: Int)], height: Int) {
        let keys = Key.all.enumerated().sorted { ($1.element.cellSize, $0.offset) < ($0.element.cellSize, $1.offset) }.map(\.element)
        let block = 32, columns = SpriteSheet<Key>.width / block
        var used: [[Bool]] = [] // rows of 32-texel blocks
        func free(_ bx: Int, _ by: Int, _ n: Int) -> Bool {
            for row in by..<(by + n) where row < used.count {
                for column in bx..<(bx + n) where used[row][column] { return false }
            }
            return true
        }
        var origins: [(key: Key, x: Int, y: Int)] = []
        var bottom = 0
        for key in keys {
            let size = key.cellSize
            precondition(size >= 32 && size <= 512 && size & (size - 1) == 0, "cell size must be a power of two in 32...512")
            let n = size / block
            var by = 0
            var placed: Int?
            while placed == nil {
                var bx = 0
                while bx + n <= columns {
                    if free(bx, by, n) { placed = bx; break }
                    bx += n
                }
                if placed == nil { by += n }
            }
            let bx = placed!
            while used.count < by + n { used.append([Bool](repeating: false, count: columns)) }
            for row in by..<(by + n) { for column in bx..<(bx + n) { used[row][column] = true } }
            origins.append((key, bx * block, by * block))
            bottom = max(bottom, (by + n) * block)
        }
        let maxCell = keys.first?.cellSize ?? 32
        return (origins, max(maxCell, (bottom + maxCell - 1) / maxCell * maxCell))
    }
}

/// A sprite atlas on the GPU: a private, mipmapped (`SpriteSheet.levelCount` levels),
/// GPU-optimized texture and each sprite's UV rectangle (top-left origin). The sheet's pixels
/// are not kept once uploaded.
struct SpriteAtlas<Key: SpriteSet> {
    let width: Int
    let height: Int
    let texture: MTLTexture
    private let uvs: [Key: SIMD4<Float>]

    /// The sprite's whole cell (`SpriteSheet`): only its sampled part is its own.
    func uv(_ key: Key) -> SIMD4<Float> { uvs[key] ?? .zero }

    init(_ sheet: SpriteSheet<Key>, device: MTLDevice, queue: MTLCommandQueue) {
        width = sheet.width
        height = sheet.height
        uvs = sheet.uvs
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        desc.mipmapLevelCount = SpriteSheet<Key>.levelCount
        desc.usage = .shaderRead
        desc.storageMode = .private
        texture = device.makeTexture(descriptor: desc)!
        let staging = sheet.pixels.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
        }
        let commandBuffer = queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: sheet.bytesPerRow,
                  sourceBytesPerImage: sheet.bytesPerRow * height, sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.generateMipmaps(for: texture)
        // Private textures the GPU optimizes can be stored losslessly compressed, which saves
        // bandwidth on every sprite fragment.
        blit.optimizeContentsForGPUAccess(texture: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The atlas's top level as an image, read back from the GPU (tests dump it for inspection).
    func makeImage() -> CGImage? {
        let bytesPerRow = width * 4, length = bytesPerRow * height
        guard let queue = texture.device.makeCommandQueue(),
              let buffer = texture.device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let provider = CGDataProvider(data: Data(bytes: buffer.contents(), count: length) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Makes the decoration, unit and settlement sheets once per process, all at once on
/// background threads: read from the bake (`AtlasBaker`) when there is one for this code,
/// else painted. `MapRenderer.prewarm()` starts it while the start screen is up; a renderer
/// created before it finishes waits for it instead of repeating it.
final class SpriteSheetPainter: Sendable {
    static let shared = SpriteSheetPainter()

    /// Where bakes are read from (`MapRenderer.bakedAtlasDirectory`).
    static let directory = Mutex<URL?>(Bundle.main.url(forResource: "Atlases", withExtension: nil))

    private struct State {
        var started = false
        var decor: SpriteSheet<DecorSprite>?
        var units: SpriteSheet<UnitSprite>?
        var towns: SpriteSheet<SettlementSprite>?
        var baked: Set<String> = []
    }
    private let group = DispatchGroup()
    private let state = Mutex(State())

    /// The sets whose sheets came from a bake (by `bakeName`).
    var bakedSets: Set<String> { state.withLock { $0.baked } }

    /// The bake of `Key` in `directory`, if there is one made from this code.
    static func loadBake<Key: SpriteSet>(_: Key.Type, from directory: URL?) -> SpriteSheet<Key>? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(Key.bakeName)) else { return nil }
        return try? SpriteSheet<Key>(decoding: data)
    }

    /// Starts in the background; later calls do nothing.
    func start() {
        guard state.withLock({ s in defer { s.started = true }; return !s.started }) else { return }
        let directory = Self.directory.withLock { $0 }
        func make<Key: SpriteSet>(_: Key.Type, _ store: @escaping @Sendable (inout State, SpriteSheet<Key>) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let baked = Self.loadBake(Key.self, from: directory)
                let sheet = baked ?? SpriteSheet<Key>()
                self.state.withLock {
                    store(&$0, sheet)
                    if baked != nil { $0.baked.insert(Key.bakeName) }
                }
                self.group.leave()
            }
        }
        make(DecorSprite.self) { $0.decor = $1 }
        make(SettlementSprite.self) { $0.towns = $1 }
        make(UnitSprite.self) { $0.units = $1 }
    }

    /// The sheets, waiting for the background work if it is still running. The sheets are
    /// handed over, not kept: renderers cache the uploaded atlases instead.
    func take() -> (decor: SpriteSheet<DecorSprite>, units: SpriteSheet<UnitSprite>, towns: SpriteSheet<SettlementSprite>) {
        start()
        group.wait()
        let sheets = state.withLock { s in
            defer { s.decor = nil; s.units = nil; s.towns = nil }
            return (s.decor, s.units, s.towns)
        }
        return (sheets.0 ?? SpriteSheet(), sheets.1 ?? SpriteSheet(), sheets.2 ?? SpriteSheet())
    }
}

/// Paints the sprite atlases ahead of time, so the app reads them instead of painting them
/// at launch. The App's build runs it (`atlas-baker`, App/Tools/bake-atlases.sh) into its
/// bundle's `Atlases` folder; a bake that does not match the code is ignored and the atlas
/// painted as before.
public enum AtlasBaker {
    /// A bake file written, with how long painting it took.
    public struct Baked: Sendable {
        public let file: URL
        public let bytes: Int
        public let height: Int
        public let paintSeconds: Double
    }

    /// Paints every set, one after another and each serially (`SpritePainting`), and writes
    /// its bake file into `directory`.
    public static func bake(into directory: URL) throws -> [Baked] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SpritePainting.serial.withLock { $0 = true }
        defer { SpritePainting.serial.withLock { $0 = false } }
        func write<Key: SpriteSet>(_: Key.Type) throws -> Baked {
            let clock = ContinuousClock(), started = clock.now
            let sheet = SpriteSheet<Key>()
            let elapsed = clock.now - started
            let url = directory.appendingPathComponent(Key.bakeName), data = try sheet.encoded()
            try data.write(to: url, options: .atomic)
            return Baked(file: url, bytes: data.count, height: sheet.height,
                         paintSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        return [try write(DecorSprite.self), try write(UnitSprite.self), try write(SettlementSprite.self)]
    }

    /// Reads every bake in `directory`, as the app does at launch; the names of the sets
    /// whose bake matches this code, with how long reading took.
    public static func check(_ directory: URL) -> (matching: [String], seconds: Double) {
        let clock = ContinuousClock(), started = clock.now
        var matching: [String] = []
        if SpriteSheetPainter.loadBake(DecorSprite.self, from: directory) != nil { matching.append(DecorSprite.bakeName) }
        if SpriteSheetPainter.loadBake(UnitSprite.self, from: directory) != nil { matching.append(UnitSprite.bakeName) }
        if SpriteSheetPainter.loadBake(SettlementSprite.self, from: directory) != nil { matching.append(SettlementSprite.bakeName) }
        let elapsed = clock.now - started
        return (matching, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}
