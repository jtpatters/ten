import CoreGraphics
import GameCore
import Metal
import simd

/// Bake parameters shared with `GroundBakeParams` in `ShaderGround.swift` (float4 only).
struct GroundBakeParams {
    /// x: relief texel size (world units), y, z: world position of texel (0, 0)'s corner, w: texels per tile width.
    var relief: SIMD4<Float>
    /// y: footprints present (0/1), w: wraps in x (0/1); x and z unused.
    var blur: SIMD4<Float>
}

extension MapRenderer {
    /// Relief texels per tile width. The relief only carries smooth fields (slopes, occlusion);
    /// everything sharp is painted per pixel.
    static let reliefTexelsPerTile = 12

    /// Extra static textures for the ground pass, bound at fragment texture(1...) in order,
    /// sampled with a linear sampler (repeat in x for the wrap) at sampler(0). Built once at
    /// startup; fog changes never touch them.
    ///
    /// Baked on the GPU by the `ground_bake_*` kernels in `ShaderGround.swift`:
    /// 1. relief (world-aligned, `reliefTexelsPerTile` texels per tile width, rgba8): rg surface
    ///    normal xy, b lee shade or crown (0.5 neutral), a footprint talus.
    /// 2. fine and 3. coarse detail (tileable, mipmapped): painted stroke patterns that the
    ///    terrain painters combine; mip filtering fades them before they can shimmer.
    /// 4. noise (tileable, mipmapped): smooth noise for per-tile reach, tints, waves and clouds.
    /// 5. rivers (rgba8Uint, three texels per tile): per corner, the distance downstream to the
    ///    mouth and the length upstream to the farthest source, so flow runs downstream and
    ///    agrees between tiles.
    /// 6. shapes (tileable, mipmapped): round cells and shaded cloud puffs.
    /// 7. features (tileable, mipmapped, each channel at its own world size): pre-lit dune
    ///    ridges, marsh pools, sand ripples, needle litter.
    /// 8. coral (tileable, mipmapped): coral colonies (cover, pre-lit shade, hue, soft shadow).
    ///
    /// `footprints` raise the relief under standing decorations: x, y (world units), radius and
    /// relative height (1 = `kSplatHeight`). Each only reaches as far as its tile's own relief.
    ///
    /// The relief is baked from every tile, explored or not; every tile's share stays within
    /// `kReliefSpill` of its edges, and the frame shader flattens the relief within
    /// `kReliefGuard` of unexplored ground, so it never hints at what lies under the cloud.
    /// Bakes write into scratch textures; the frame samples read-only copies, which the GPU can
    /// keep losslessly compressed.
    static func makeGroundTextures(map: HexMap, layout: HexLayout, device: MTLDevice, queue: MTLCommandQueue,
                                   footprints: [SIMD4<Float>] = []) -> [MTLTexture] {
        // The kernels are part of the main shader source, which the renderer has just compiled:
        // compiling the identical source again is answered by Metal's compiler cache.
        let library: MTLLibrary
        do {
            library = try ShaderLibrary.shared.library(device: device)
        } catch {
            fatalError("Ground bake shaders failed to compile: \(error)")
        }
        func kernel(_ name: String) -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: function) else {
                fatalError("Ground bake kernel \(name) failed")
            }
            return state
        }
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, mipmapped: Bool = false,
                     writable: Bool = true) -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                mipmapped: mipmapped)
            desc.usage = writable ? [.shaderRead, .shaderWrite] : [.shaderRead]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)!
        }

        let noise = texture(.rgba8Unorm, 256, 256, mipmapped: true)
        let fine = texture(.rgba8Unorm, 512, 512, mipmapped: true)
        let coarse = texture(.rgba8Unorm, 512, 512, mipmapped: true)
        let shapes = texture(.rgba8Unorm, 512, 512, mipmapped: true)
        let features = texture(.rgba8Unorm, 512, 512, mipmapped: true)
        let coral = texture(.rgba8Unorm, 512, 512, mipmapped: true)

        // Relief covers one world period in x when wrapping (so the sampler's repeat is the
        // wrap), otherwise the map plus a tile of margin; y always gets a tile of margin.
        let texelsPerTile = Self.reliefTexelsPerTile
        let tw = Float(layout.tileWidth)
        let texel = tw / Float(texelsPerTile)
        let originX: Float = layout.wrapsX ? 0 : -tw
        let originY: Float = -tw
        let reliefWidth = layout.wrapsX ? layout.mapWidth * texelsPerTile
            : Int((Float(layout.worldWidth) + 2 * tw) / texel) + 1
        let reliefHeight = Int((Float(layout.worldHeight) + 2 * tw) / texel) + 1
        let fields = texture(.rg16Float, reliefWidth, reliefHeight)
        let relief = texture(.rgba8Unorm, reliefWidth, reliefHeight)

        let tiles = makeBakeTileTexture(map, device: device)
        let rivers = makeRiverCornerTexture(map, layout: layout, device: device)
        let splats = splatBuffers(footprints, map: map, layout: layout, device: device)
        var uniforms = bakeUniforms(layout)
        var params = GroundBakeParams(relief: [texel, originX, originY, Float(texelsPerTile)],
                                      blur: [0, footprints.isEmpty ? 0 : 1, 0, layout.wrapsX ? 1 : 0])

        guard let commandBuffer = queue.makeCommandBuffer() else { fatalError("Ground bake: no command buffer") }
        func compute(_ body: (MTLComputeCommandEncoder) -> Void) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { fatalError("Ground bake: no command encoder") }
            body(encoder)
            encoder.endEncoding()
        }
        func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, _ textures: [MTLTexture],
                      width: Int, height: Int) {
            encoder.setComputePipelineState(state)
            for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<GroundBakeParams>.stride, index: 1)
            encoder.setBuffer(splats.splats, offset: 0, index: 2)
            encoder.setBuffer(splats.start, offset: 0, index: 3)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: group)
        }
        compute { encoder in
            dispatch(encoder, kernel("ground_bake_noise"), [noise], width: 256, height: 256)
            dispatch(encoder, kernel("ground_bake_detail"), [fine, coarse, shapes], width: 512, height: 512)
            dispatch(encoder, kernel("ground_bake_features"), [features, coral], width: 512, height: 512)
            dispatch(encoder, kernel("ground_bake_fields"), [tiles, fields], width: reliefWidth, height: reliefHeight)
            dispatch(encoder, kernel("ground_bake_relief"), [fields, relief], width: reliefWidth, height: reliefHeight)
        }
        // Read-only copies for the frame (mipmaps first).
        let baked = [relief, fine, coarse, noise, shapes, features, coral]
        let finals = baked.map { texture($0.pixelFormat, $0.width, $0.height, mipmapped: $0.mipmapLevelCount > 1, writable: false) }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for t in baked where t.mipmapLevelCount > 1 { blit.generateMipmaps(for: t) }
            for (from, to) in zip(baked, finals) {
                blit.copy(from: from, to: to)
                blit.optimizeContentsForGPUAccess(texture: to)
            }
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return [finals[0], finals[1], finals[2], finals[3], rivers, finals[4], finals[5], finals[6]]
    }

    /// Footprints binned by tile for the relief bake: each splat relative to its tile's center,
    /// grouped by tile index, and each tile's first splat (tile count + 1 entries).
    private static func splatBuffers(_ footprints: [SIMD4<Float>], map: HexMap, layout: HexLayout,
                                     device: MTLDevice) -> (splats: MTLBuffer, start: MTLBuffer) {
        var bins = [[SIMD4<Float>]](repeating: [], count: footprints.isEmpty ? 0 : map.tileCount)
        for f in footprints {
            let hex = layout.hex(at: CGPoint(x: CGFloat(f.x), y: CGFloat(f.y)))
            guard let tile = map.normalize(hex), let i = map.index(of: tile) else { continue }
            let c = layout.center(of: hex)
            bins[i].append([f.x - Float(c.x), f.y - Float(c.y), f.z, f.w])
        }
        var splats = bins.flatMap { $0 }
        var start = [UInt32](repeating: 0, count: map.tileCount + 1)
        var total: UInt32 = 0
        for (i, bin) in bins.enumerated() {
            start[i] = total
            total += UInt32(bin.count)
        }
        start[map.tileCount] = total
        if splats.isEmpty { splats = [.zero] }
        let splatBuffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SIMD4<Float>>.stride * splats.count,
                                            options: .storageModeShared)!
        let startBuffer = device.makeBuffer(bytes: start, length: MemoryLayout<UInt32>.stride * start.count,
                                            options: .storageModeShared)!
        return (splatBuffer, startBuffer)
    }

    /// Uniforms with only the map fields the bake needs (`fetchTile`, periods).
    private static func bakeUniforms(_ layout: HexLayout) -> Uniforms {
        func color(_ terrain: Terrain) -> SIMD4<Float> {
            let c = Palette.terrain(terrain)
            return [Float(c.r), Float(c.g), Float(c.b), 1]
        }
        let sun = simd_normalize(SIMD3<Float>(-0.55, 0.45, 0.70))
        return Uniforms(
            viewProj: matrix_identity_float4x4, cameraUp: .zero, eye: .zero, sun: SIMD4(sun, 0), viewport: .zero,
            map: [Float(layout.size), Float(layout.tileWidth), Float(layout.rowHeight), Float(layout.worldWidth)],
            dims: [Float(layout.mapWidth), Float(layout.mapHeight), layout.wrapsX ? 1 : 0, 1],
            ground: .zero, fogColor: .zero, options: .zero,
            terrain: (color(.grassland), color(.plains), color(.desert), color(.tundra),
                      color(.snow), color(.coast), color(.ocean), color(.lake)))
    }

    /// The tile data texture layout (see `MapRenderer.packTiles`), fully revealed.
    private static func makeBakeTileTexture(_ map: HexMap, device: MTLDevice) -> MTLTexture {
        var bytes = [UInt8](repeating: 0, count: map.tileCount * 4)
        for i in 0..<map.tileCount {
            let tile = map[index: i]
            bytes[i * 4] = tile.terrain.rawValue
            bytes[i * 4 + 1] = tile.elevation.rawValue | (tile.feature.rawValue << 2)
            bytes[i * 4 + 2] = tile.riverEdges
        }
        return makeUIntTexture(bytes, width: map.width, height: map.height, device: device)
    }

    private static func makeUIntTexture(_ bytes: [UInt8], width: Int, height: Int, device: MTLDevice) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let texture = device.makeTexture(descriptor: desc)!
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    /// River data, three texels per tile: the downstream distance (edges to the river's mouth,
    /// mod 256) at corners 0-5, then the upstream length (edges to the farthest source, capped
    /// at 255) at corners 0-5. Corner k sits at 30° + 60°·k. Rivers are walks along edges that
    /// end at a corner touching water (or join another river), so a breadth-first search from
    /// those corners gives every river corner its downstream distance; the shader interpolates
    /// it along each edge and the flow animation runs toward smaller values. The upstream length
    /// tapers rivers toward their sources. Corners off rivers get 0.
    private static func makeRiverCornerTexture(_ map: HexMap, layout: HexLayout, device: MTLDevice) -> MTLTexture {
        // Corners live on a lattice of half a tile width by half a tile size.
        struct Corner: Hashable { let x: Int, y: Int }
        let period = 2 * map.width
        let offsets: [(Int, Int)] = [(1, 1), (0, 2), (-1, 1), (-1, -1), (0, -2), (1, -1)]
        func corner(_ hex: HexCoord, _ k: Int) -> Corner {
            var x = 2 * hex.q + hex.r + 1 + offsets[k].0
            if map.wrapsX { x = ((x % period) + period) % period }
            return Corner(x: x, y: 3 * hex.r + 2 + offsets[k].1)
        }
        func neighbor(_ hex: HexCoord, _ d: Int) -> Tile? {
            map.normalize(hex.neighbor(HexDirection(rawValue: d)!)).flatMap { map.tile(at: $0) }
        }

        var links: [Corner: [Corner]] = [:]
        var mouths: [Corner] = []
        for i in 0..<map.tileCount where map[index: i].riverEdges != 0 {
            let tile = map[index: i], hex = map.coord(at: i)
            for e in 0..<6 where tile.riverEdges & (1 << e) != 0 {
                let a = corner(hex, (5 - e) % 6), b = corner(hex, (6 - e) % 6)
                links[a, default: []].append(b)
                links[b, default: []].append(a)
            }
            for k in 0..<6 {
                // Corner k touches this tile and its neighbors across edges (5 - k) and (6 - k).
                let touching = [neighbor(hex, (5 - k) % 6), neighbor(hex, (6 - k) % 6)]
                if touching.contains(where: { $0?.terrain.isWater == true }) { mouths.append(corner(hex, k)) }
            }
        }
        var distance: [Corner: Int] = [:]
        var queue: [Corner] = []
        for m in mouths where links[m] != nil && distance[m] == nil {
            distance[m] = 0
            queue.append(m)
        }
        var head = 0
        while head < queue.count {
            let c = queue[head]
            head += 1
            for n in links[c] ?? [] where distance[n] == nil {
                distance[n] = distance[c]! + 1
                queue.append(n)
            }
        }
        // Upstream length, from the far ends down: one more than the longest upstream neighbor's.
        // The search queue holds corners by nondecreasing distance, so walking it backwards
        // visits every upstream neighbor before the corner below it.
        var upstream: [Corner: Int] = [:]
        for c in queue.reversed() {
            let below = distance[c]!
            upstream[c] = (links[c] ?? []).reduce(0) { best, n in
                guard let d = distance[n], d > below else { return best }
                return max(best, (upstream[n] ?? 0) + 1)
            }
        }

        var bytes = [UInt8](repeating: 0, count: map.tileCount * 12)
        for i in 0..<map.tileCount {
            let hex = map.coord(at: i)
            let o = hex.offset
            let base = (o.row * map.width + o.col) * 12
            for k in 0..<6 {
                let c = corner(hex, k)
                bytes[base + k] = UInt8((distance[c] ?? 0) & 255)
                bytes[base + 6 + k] = UInt8(min(upstream[c] ?? 0, 255))
            }
        }
        return makeUIntTexture(bytes, width: map.width * 3, height: map.height, device: device)
    }
}
