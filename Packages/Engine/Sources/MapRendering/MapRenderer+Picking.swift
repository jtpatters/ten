import CoreGraphics
import GameCore
import Metal
import simd

/// Tap targets: the unit pass drawn into a coarse map of which unit's tile or city covers each
/// texel, so a tap selects a unit exactly where it is drawn (figure, standard, base ring or
/// medallion), a city where its buildings or token are (units standing in it, drawn over
/// them, win), and the ground beside them selects the tile under the finger.
struct UnitPick {
    static let format = MTLPixelFormat.r16Uint
    /// View points per texel.
    static let pointsPerTexel: Float = 1

    /// What the targets were drawn for; any change redraws them on the next tap.
    struct Key: Equatable {
        var frame: Int
        var target: SIMD2<Float>
        var scale: Float
        var pitch: Float
        var viewSize: SIMD2<Float>
        var units: Int
        var cities: Int
        var selection: HexCoord?
    }

    let key: Key
    let width: Int
    let height: Int
    /// Per texel, top row first: 0 for no token, else an index into `targets` plus one.
    let ids: [UInt16]
    /// What the drawn tokens select.
    let targets: [PickTarget]

    /// The target whose token covers `point`, else the one whose token comes nearest within
    /// `slop` view points.
    func token(at point: CGPoint, slop: Float) -> (target: PickTarget, exact: Bool)? {
        guard !targets.isEmpty else { return nil }
        let x = Float(point.x) / Self.pointsPerTexel, y = Float(point.y) / Self.pointsPerTexel
        let cx = Int(x.rounded(.down)), cy = Int(y.rounded(.down))
        func id(_ i: Int, _ j: Int) -> UInt16 { i >= 0 && j >= 0 && i < width && j < height ? ids[j * width + i] : 0 }
        let here = id(cx, cy)
        if here > 0 { return (targets[Int(here) - 1], true) }
        let r = Int((slop / Self.pointsPerTexel).rounded(.up))
        var best: (d: Float, id: UInt16)?
        for j in (cy - r)...(cy + r) {
            for i in (cx - r)...(cx + r) {
                let k = id(i, j)
                guard k > 0 else { continue }
                let d = simd_length(SIMD2(Float(i) + 0.5 - x, Float(j) + 0.5 - y)) * Self.pointsPerTexel
                if d <= slop, d < (best?.d ?? .infinity) { best = (d, k) }
            }
        }
        return best.map { (targets[Int($0.id) - 1], false) }
    }
}

extension MapRenderer {
    /// Extra reach around a drawn unit token, in view points, so thin spears and poles are
    /// easy to hit.
    static let tapSlop: Float = 6
    /// Within this distance of its center (in tile sizes), a tile with no unit keeps taps that
    /// land on a neighbor's token; within the larger one, taps that only come near it.
    static let tapCenterKeep: Float = 0.3
    static let tapInnerKeep: Float = 0.7

    /// The hex under a view point: a unit's tile where its token is drawn (or within the slop
    /// of it), else the tile on the ground. A neighbor's token never takes the middle of a
    /// tile: its center stays with the tile, and so does its inner part against the slop.
    public func hex(atViewPoint point: CGPoint) -> HexCoord? {
        tap(atViewPoint: point)?.hex
    }

    /// What `hex(atViewPoint:)` resolves, and the unit's tile or city whose token (rather
    /// than the ground) took the point.
    func tap(atViewPoint point: CGPoint) -> (hex: HexCoord, hit: PickTarget?)? {
        noteActivity() // a tap: selection rings and route previews animate in
        let ground = groundHex(atViewPoint: point)
        guard let pick = currentPick(), let hit = pick.token(at: point, slop: Self.tapSlop) else { return ground.map { ($0, nil) } }
        let tile = hit.target.hex
        guard let ground, ground != tile, let g = camera.groundPoint(atViewPoint: point) else { return (tile, hit.target) }
        let center = layout.center(of: ground)
        let offset = SIMD2(Float(layout.nearestCopy(of: center.x, to: CGFloat(g.x))), Float(center.y)) - g
        let inner = simd_length(offset) / Float(layout.size)
        if hit.exact {
            return inner < Self.tapCenterKeep && !pick.targets.contains(where: { $0.hex == ground }) ? (ground, nil) : (tile, hit.target)
        }
        return inner < Self.tapInnerKeep ? (ground, nil) : (tile, hit.target)
    }

    private func currentPick() -> UnitPick? {
        let key = UnitPick.Key(frame: frameIndex, target: camera.target, scale: camera.scale, pitch: camera.pitch,
                               viewSize: camera.viewSize, units: unitsVersion, cities: cityArt.version, selection: unitArt.selection)
        if let unitPick, unitPick.key == key { return unitPick }
        unitPick = renderPick(key: key)
        return unitPick
    }

    /// Draws the unit pass's tappable instances into an ID map and reads it back (a fraction
    /// of a millisecond of GPU time, once per tap).
    private func renderPick(key: UnitPick.Key) -> UnitPick? {
        let frame = unitFrame()
        let sprites = frame.sprites
        var targets: [PickTarget] = [], index: [PickTarget: UInt16] = [:]
        let ids: [UInt16] = frame.owners.map { owner in
            guard let owner else { return 0 }
            if let i = index[owner] { return i }
            targets.append(owner)
            index[owner] = UInt16(targets.count)
            return UInt16(targets.count)
        }
        guard !targets.isEmpty else { return UnitPick(key: key, width: 0, height: 0, ids: [], targets: []) }
        let width = max(1, Int((camera.viewSize.x / UnitPick.pointsPerTexel).rounded(.up)))
        let height = max(1, Int((camera.viewSize.y / UnitPick.pointsPerTexel).rounded(.up)))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: UnitPick.format, width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc),
              let spriteBuffer = device.makeBuffer(bytes: sprites, length: MemoryLayout<SpriteInstance>.stride * sprites.count,
                                                   options: .storageModeShared),
              let idBuffer = device.makeBuffer(bytes: ids, length: MemoryLayout<UInt16>.stride * ids.count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = makeUniforms(pixelScale: 1 / UnitPick.pointsPerTexel)
        encoder.setRenderPipelineState(pickPipeline)
        Self.bind(&uniforms, to: encoder)
        encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(idBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(unitAtlas.texture, index: 0)
        encoder.setFragmentTexture(townAtlas.texture, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: sprites.count * (layout.wrapsX ? 3 : 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var texels = [UInt16](repeating: 0, count: width * height)
        texels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 2, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return UnitPick(key: key, width: width, height: height, ids: texels, targets: targets)
    }
}
