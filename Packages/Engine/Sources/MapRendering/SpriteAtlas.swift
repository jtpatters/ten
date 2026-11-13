import CoreGraphics
import Dispatch
import Foundation
import Metal
import Synchronization

/// A family of procedurally drawn sprites that share one atlas texture.
protocol SpriteSet: Hashable, Sendable {
    /// Every sprite in the set.
    static var all: [Self] { get }
    /// Cell edge in pixels: a power of two from 32 to 512. Cells are packed at multiples of
    /// their own size, so mipmap levels never blend neighboring cells.
    var cellSize: Int { get }
    /// Draws the sprite into `rect`: its cell inset by a 1/20 margin, in y-up Core Graphics
    /// coordinates. Drawing is clipped to the cell. May run on any thread.
    func draw(in rect: CGRect, ctx: CGContext)
}

/// A `SpriteSet` painted into RGBA8 premultiplied pixels, with each sprite's UV rectangle
/// (top-left origin). Pure CPU work, so it can be painted off the main actor.
struct SpriteSheet<Key: SpriteSet>: Sendable {
    static var width: Int { 2048 }

    /// The sheet's height in pixels: as tall as its cells need, in whole cells of the largest
    /// size. Known without painting, so shaders can be built for it (`kUnitAtlasTexels`).
    static var height: Int { layout().height }

    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data
    let uvs: [Key: SIMD4<Float>]

    /// Where each cell goes (pixels, top-left origin) and the sheet's height. Largest cells
    /// first (in `all` order within a size), each in the first free place, row by row, at a
    /// multiple of its own size: smaller cells fill whatever the rows of larger ones leave, so
    /// (sizes being powers of two) no space is lost before the last row.
    private static func layout() -> (origins: [(key: Key, x: Int, y: Int)], height: Int) {
        let keys = Key.all.enumerated().sorted { ($1.element.cellSize, $0.offset) < ($0.element.cellSize, $1.offset) }.map(\.element)
        let block = 32, columns = width / block
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

    init() {
        let (origins, height) = Self.layout()
        let width = Self.width
        self.width = width
        self.height = height

        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var uvs: [Key: SIMD4<Float>] = [:]
        for (key, x, y) in origins {
            let size = CGFloat(key.cellSize)
            // Bitmap contexts are y-up; memory row 0 is the top, which is texture v = 0.
            let rect = CGRect(x: CGFloat(x), y: CGFloat(height - y) - size, width: size, height: size)
            ctx.saveGState()
            ctx.clip(to: rect)
            key.draw(in: rect.insetBy(dx: size / 20, dy: size / 20), ctx: ctx)
            ctx.restoreGState()
            uvs[key] = SIMD4(Float(x) / Float(width), Float(y) / Float(height), Float(size) / Float(width), Float(size) / Float(height))
        }
        self.uvs = uvs
        bytesPerRow = ctx.bytesPerRow
        pixels = Data(bytes: ctx.data!, count: ctx.bytesPerRow * height)
    }
}

/// A sprite atlas on the GPU: a private, mipmapped, GPU-optimized texture and each sprite's UV
/// rectangle (top-left origin). The painted pixels are not kept once uploaded.
struct SpriteAtlas<Key: SpriteSet> {
    let width: Int
    let height: Int
    let texture: MTLTexture
    private let uvs: [Key: SIMD4<Float>]

    func uv(_ key: Key) -> SIMD4<Float> { uvs[key] ?? .zero }

    init(_ sheet: SpriteSheet<Key>, device: MTLDevice, queue: MTLCommandQueue) {
        width = sheet.width
        height = sheet.height
        uvs = sheet.uvs
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
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

/// Paints the decoration, unit and settlement sheets once per process, all at once on background
/// threads.
/// `MapRenderer.prewarm()` starts it while the start screen is up; a renderer created before it
/// finishes waits for that paint instead of repeating it.
final class SpriteSheetPainter: Sendable {
    static let shared = SpriteSheetPainter()

    private struct State {
        var started = false
        var decor: SpriteSheet<DecorSprite>?
        var units: SpriteSheet<UnitSprite>?
        var towns: SpriteSheet<SettlementSprite>?
    }
    private let group = DispatchGroup()
    private let state = Mutex(State())

    /// Starts painting in the background; later calls do nothing.
    func start() {
        guard state.withLock({ s in defer { s.started = true }; return !s.started }) else { return }
        group.enter()
        group.enter()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let sheet = SpriteSheet<DecorSprite>()
            self.state.withLock { $0.decor = sheet }
            self.group.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let sheet = SpriteSheet<SettlementSprite>()
            self.state.withLock { $0.towns = sheet }
            self.group.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let sheet = SpriteSheet<UnitSprite>()
            self.state.withLock { $0.units = sheet }
            self.group.leave()
        }
    }

    /// The sheets, waiting for the background paint if it is still running. The sheets are
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
