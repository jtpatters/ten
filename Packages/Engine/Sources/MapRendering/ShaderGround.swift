extension Shaders {
    /// Ground pass: one quad; each fragment finds its hex in the tile data texture
    /// (r: terrain, g: elevation | feature << 2, b: river edge bits, a: fog level) and blends
    /// with the six neighbors. Static data baked at startup by the `ground_bake_*` kernels (see
    /// `MapRenderer.makeGroundTextures`) is bound at fragment texture(1...).
    ///
    /// The bake kernels are part of this source, so they live in the main library: the bake
    /// compiles `Shaders.source` again, which the Metal compiler answers from its cache instead
    /// of building a second library.
    static let groundSource = groundShared + groundFrame + groundBake

    /// Helpers shared by the frame shader and the bake, so both agree on hex lookup, noise
    /// periods and the per-tile reach that shapes coastlines. Everything the ground defines
    /// lives in namespace `gnd`, so it can never collide with other passes' shader code.
    static let groundShared = #"""
// ---------------------------------------------------------------- ground (shared)
namespace gnd {

constexpr sampler kRepeat(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(4));
constexpr sampler kWorld(coord::normalized, s_address::repeat, t_address::clamp_to_edge, filter::linear);

// World sizes of the tileable detail textures (world units, or tile widths for `Tiles`);
// `wrapFit` adjusts each to divide the world width.
constant float kFineSize = 128.0;      // fine detail and fine features: about 4 texels per unit
constant float kCoarseSize = 384.0;    // coarse detail
constant float kDuneTiles = 3.2;       // features r: dune ridges (also snow drifts, larger)
constant float kPoolTiles = 2.6;       // features g: marsh pools
constant float kSastrugiSize = 340.0;  // features b (sand ripples), stretched into snow ridges
constant float kReefSize = 90.0;       // coral colonies

// How far (apothems) any tile's baked relief reaches past its own edges, and how far from
// unexplored ground the frame keeps the relief flat: the spill, plus the texel around each
// point the relief bake reads and the texels the frame's bilinear sample blends (12 texels per
// tile width, so 1 + sqrt(2) texels are 0.40 apothem). Relief on explored ground beyond the
// guard depends only on explored tiles and world noise.
constant float kReliefSpill = 0.45;
constant float kReliefGuard = 0.86;

struct HexCell {
    int q, r;
    float2 center;
    float2 local;
};

static HexCell hexCell(float2 p, constant Uniforms& u) {
    float size = u.map.x, tw = u.map.y, rh = u.map.z;
    float px = (p.x - tw * 0.5) / size, py = (p.y - size) / size;
    float fq = 0.57735027 * px - py / 3.0, fr = py * 2.0 / 3.0, fs = -fq - fr;
    float rq = round(fq), rr = round(fr), rs = round(fs);
    float dq = abs(rq - fq), dr = abs(rr - fr), ds = abs(rs - fs);
    if (dq > dr && dq > ds) { rq = -rr - rs; } else if (dr > ds) { rr = -rq - rs; }
    HexCell h;
    h.q = int(rq);
    h.r = int(rr);
    h.center = float2(tw * (rq + rr * 0.5) + tw * 0.5, rh * rr + size);
    h.local = p - h.center;
    return h;
}

// A length near `target` (world units) that divides the world width, so world-space patterns
// repeat exactly with the wrap and never pop when the camera wraps around.
static float wrapFit(float target, constant Uniforms& u) {
    if (u.dims.z < 0.5) return target;
    return u.map.w / max(1.0, round(u.map.w / target));
}

// Period of the noise texture in tile widths (about six tiles).
static float noisePeriod(constant Uniforms& u) { return wrapFit(6.0 * u.map.y, u) / u.map.y; }

// How far (in apothems) a tile's influence reaches past its edges at this point: smooth noise,
// shifted per tile so neighbors disagree and borders bend into organic shapes. It is read at a
// constant mip level, never one picked by pixel footprint: zoomed out, a footprint level would
// average the noise flat and coasts would turn back into hexagons (and change shape on zoom).
// Level 1 drops the finest octave, so coasts bend without fraying into specks.
static float tileReach(texture2d<float> noise, float2 np, float2 offset, float period) {
    float4 n = noise.sample(kRepeat, (np + offset) / period, level(1.0));
    return (n.g - 0.5) * 0.9 + (n.r - 0.5) * 0.75;
}

} // namespace gnd
"""#

    static let groundFrame = #"""
// ---------------------------------------------------------------- ground (frame)

struct GroundOut {
    float4 position [[position]];
    float2 world;
};

vertex GroundOut ground_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(1)]]) {
    float2 c = float2(float(vid & 1u), float(vid >> 1));
    float2 w = mix(u.ground.xy, u.ground.zw, c);
    GroundOut o;
    o.position = u.viewProj * float4(w, 0.0, 1.0);
    o.world = w;
    return o;
}

// Farm fields are costly code even where no farm is, so the ground has two variants
// (`MapRenderer.groundPipeline` without them, `groundFieldsPipeline` with them) and draws each
// only where it is needed: the stencil marks the squares around known farms
// (`ground_mask_vertex`, 1.75 tile sizes each way: the farm and the 0.6 tile sizes its plots
// reach into its neighbours), the plain ground fills the rest, and the fields variant fills
// the marked pixels, restoring the stencil as it goes. Both compute every pixel the same way
// but for the fields.
constant bool kGroundFields [[function_constant(0)]];

struct GroundMaskOut {
    float4 position [[position]];
};

vertex GroundMaskOut ground_mask_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        const device float2* farms [[buffer(0)]],
                                        constant Uniforms& u [[buffer(1)]]) {
    uint copies = uint(u.dims.w);
    float2 c = float2(float(vid & 1u), float(vid >> 1)) * 2.0 - 1.0;
    float2 w = farms[iid / copies] + c * (1.75 * u.map.x);
    if (copies > 1u) w.x += (float(iid % copies) - 1.0) * u.map.w;
    GroundMaskOut o;
    o.position = u.viewProj * float4(w, 0.0, 1.0);
    return o;
}

fragment void ground_mask_fragment() {}

namespace gnd {

// Sharpness (per apothem) of the neighbor weights exp(-k * distance) for: materials (sharp, and
// interlocked by their masks), land against water, the shelf and water bodies, explored dimming,
// and the wide unexplored field that casts the cloud bank's shadow.
constant float kKC = 20.0;
constant float kKL = 9.0;
constant float kKS = 6.0;
constant float kKF = 5.0;
constant float kKU = 2.6;
// How far (apothems) a material's patches push into a neighbor's ground at a border.
constant float kMaskReach = 0.65;
// Rounding (world units) where river segments join: round enough that bends flow.
constant float kRiverRound = 3.0;

// The cloud bank: its colors (crease shade, open tops, sunlit flanks), the world size of the
// cumulus texture's billow layer (the mass layer is three times larger), and how far into
// unexplored ground (apothems) the depth field is exact everywhere: tiles two steps apart are
// at least one hex side (1.1547 apothems) apart, so within this distance only the pixel's own
// tile and its six neighbors can be the nearest explored ground.
constant float3 kCloudDeep = float3(0.15, 0.16, 0.25);
constant float3 kCloudMid = float3(0.28, 0.30, 0.39);
constant float3 kCloudLit = float3(0.46, 0.46, 0.51);
constant float kCloudTiles = 14.0;
constant float kDepthCap = 1.15;

// Whether axial (q, r) is a real tile (off-map rows, and columns without wrap, are not).
static bool onMap(int q, int r, constant Uniforms& u) {
    if (r < 0 || r >= int(u.dims.y)) return false;
    if (u.dims.z > 0.5) return true;
    int col = q + (r - (r & 1)) / 2;
    return col >= 0 && col < int(u.dims.x);
}

// Fog level of the edge tile in a column (wrapped, or clamped on a map that doesn't wrap).
static uint edgeLevel(texture2d<uint, access::read> tiles, int col, int row, constant Uniforms& u) {
    int W = int(u.dims.x);
    int c = u.dims.z > 0.5 ? wrapIndex(col, W) : clamp(col, 0, W - 1);
    return tiles.read(uint2(uint(c), uint(row))).a & kTileFogMask;
}

// Fog level of an off-map tile: seen with the fog off (`options.z`). With it on, the nearest
// edge tile's for a row or more past the edge, so the light over a seen edge and the cloud bank
// over an unexplored one carry on past it instead of stopping there: two or three rows (seeded
// by column) where the edge tiles beside it share its level, else one, so they end raggedly in
// the haze and recede at a slant beside other ground. Farther out, explored: the polar pack
// fades into the haze alike all along the edge. (The edge tile's level all the way out would run
// each column's cloud or clear ice on through the haze, which a view zoomed out past the map's
// height shows: `MapCamera.zoomOutFloor`.) On a wrapping map only rows count, so every wrapped
// copy spills alike.
static uint edgeFog(texture2d<uint, access::read> tiles, int q, int r, constant Uniforms& u) {
    if (u.options.z < 0.5) return 0u;
    int W = int(u.dims.x), H = int(u.dims.y);
    int col = q + (r - (r & 1)) / 2;
    int row = clamp(r, 0, H - 1);
    int c = u.dims.z > 0.5 ? wrapIndex(col, W) : clamp(col, 0, W - 1);
    int past = u.dims.z > 0.5 ? abs(r - row) : max(abs(r - row), abs(col - c));
    if (past > 3) return 1u; // past any spill: most of the haze, zoomed out
    uint level = edgeLevel(tiles, col, row, u);
    if (level == 1u) return 1u;
    bool deep = edgeLevel(tiles, col - 1, row, u) == level && edgeLevel(tiles, col + 1, row, u) == level;
    int spill = deep ? 2 + int(hash2(c, r < 0 ? 4111 : 7193) * 1.999) : 1;
    return past <= spill ? level : 1u;
}

// Cycles completed after `time` seconds by something that repeats `perHour` times an hour. The
// clock wraps every hour, so whole numbers keep every animation seamless across the wrap.
static float cycles(float time, float perHour) { return time * (perHour / 3600.0); }

static float sgn01(float v) { return v * 2.0 - 1.0; }

// Everything the terrain painters need at one pixel.
struct Paint {
    float4 fine;    // fine detail: grass strokes, speckle, stones (pre-lit), leaf daubs; 0.5 = neutral
    float4 coarse;  // coarse detail: clumps, streaks, cell edge distance, cell value
    float4 nz;      // smooth noise: r ~2 cycles per tile, g ~0.5, b ~4, a ~3
    float2 p;       // world position
    float2 dpx, dpy;// screen derivatives of p, for explicit-gradient samples under branches
    float fp;       // pixel footprint in world units
    float time;
};

// A tileable texture laid over the world at `size` units, sampled with explicit gradients (safe
// under divergent branches, and mip filtering fades the detail before it can shimmer).
static float4 sampleWorld(texture2d<float> t, float2 p, float size, Paint d, float2 offset = float2(0.0)) {
    return t.sample(kRepeat, p / size + offset, gradient2d(d.dpx / size, d.dpy / size));
}

// The one water ramp shared by the sea, lakes, rivers and ponds, by depth: 0 the wet edge,
// 0.3 the shelf (palette coast), 0.6 the shelf's edge, 1 the open ocean (palette ocean).
static float3 waterRamp(float depth, constant Uniforms& u) {
    float3 shelf = u.terrain[5].rgb, ocean = u.terrain[6].rgb;
    float3 c = mix(mix(shelf, float3(0.80, 0.94, 0.86), 0.42), shelf, smoothstep(0.0, 0.3, depth));
    c = mix(c, mix(shelf, ocean, 0.45), smoothstep(0.3, 0.62, depth));
    c = mix(c, ocean, smoothstep(0.62, 0.85, depth));
    return mix(c, ocean * float3(0.78, 0.82, 0.88), smoothstep(0.85, 1.0, depth));
}

// ------------------------------------------------ land materials
// Each paints over the blended albedo `a`, at three scales: regional tint (nz), patches (coarse)
// and strokes (fine).

// Grassland: variety in value rather than chroma (the trees carry the strong greens): cool lush
// and warm sunlit regions, darker pasture and sunlit meadow patches, light blades and dark gaps.
static float3 paintGrass(float3 a, Paint d) {
    float3 c = a * mix(float3(0.95, 0.98, 0.99), float3(1.05, 1.03, 0.95), d.nz.g);
    c *= 0.92 + 0.16 * d.nz.b;
    float clump = sgn01(d.coarse.r);
    c = mix(c, c * float3(0.83, 0.86, 0.86), smoothstep(0.05, 0.6, -clump));          // pasture
    c = mix(c, c * float3(1.10, 1.10, 1.04), smoothstep(0.15, 0.7, clump) * 0.8);     // sunlit meadow
    float s = sgn01(d.fine.r);
    c = mix(c, c * float3(1.13, 1.13, 1.07), smoothstep(0.05, 0.45, s) * 0.75);
    c = mix(c, c * float3(0.83, 0.86, 0.86), smoothstep(0.05, 0.45, -s) * 0.6);
    return c;
}

// Plains: khaki grassland that changes character every few tiles (olive-green meadow, golden
// grass, patches of bare ochre soil), combed by the wind into east-west streaks, with the same
// stroke scales as grassland.
static float3 paintPlains(float3 a, Paint d) {
    float3 c = a * (0.92 + 0.16 * d.nz.b);
    c = mix(c, c * float3(0.86, 0.95, 0.81), smoothstep(0.52, 0.22, d.nz.g) * 0.9);   // olive meadow
    c = mix(c, c * float3(1.07, 1.035, 0.92), smoothstep(0.5, 0.8, d.nz.g) * 0.85);   // golden grass
    float patchy = sgn01(d.coarse.r);
    float soil = smoothstep(0.3, 0.8, patchy) * smoothstep(0.45, 0.65, d.nz.a * 0.6 + d.nz.r * 0.4);
    c = mix(c, c * float3(0.93, 0.85, 0.74), soil * 0.8);                               // bare ochre soil
    c = mix(c, c * float3(0.88, 0.91, 0.90), smoothstep(0.05, 0.6, -patchy) * 0.5);
    float streak = sgn01(d.coarse.g);
    c = mix(c, c * float3(1.09, 1.08, 1.03), smoothstep(0.1, 0.6, streak) * 0.55);     // wind-combed
    c = mix(c, c * float3(0.88, 0.88, 0.87), smoothstep(0.1, 0.6, -streak) * 0.4);
    float s = sgn01(d.fine.r);
    c = mix(c, c * float3(1.11, 1.10, 1.04), smoothstep(0.1, 0.5, s) * 0.6);
    c = mix(c, c * float3(0.85, 0.87, 0.87), smoothstep(0.1, 0.5, -s) * 0.5);
    return c;
}

// Pebbles from the pre-lit stone channel: above 0.5 stone (brighter = sunlit), below 0.5 shadow.
static float3 stones(float3 c, float s, float3 rock, float amount) {
    float stone = smoothstep(0.52, 0.56, s) * amount;
    c = mix(c, rock * (0.55 + 0.9 * saturate((s - 0.5) * 2.0)), stone);
    return c * (1.0 - smoothstep(0.48, 0.36, s) * 0.4 * amount);
}

// Desert: open sand, flat gravel plains where the broad noise is low, and dune fields where it is
// high. Dunes are fine sinuous ridges about 0.3 tiles apart, broken into segments a tile or so
// long; their gentle windward ramps catch the sun and their steep lee faces drop into violet
// shade, always softer than the relief of desert hills. A slow warp turns the crests from region
// to region.
static float3 paintDesert(float3 a, Paint d, texture2d<float> feat, constant Uniforms& u) {
    float3 c = a * mix(float3(0.97, 0.96, 0.98), float3(1.04, 1.0, 0.90), d.nz.g);
    float patchy = sgn01(d.coarse.r);
    c = mix(c, c * float3(1.04, 0.99, 0.92), smoothstep(0.1, 0.7, patchy) * 0.4);
    c = mix(c, c * float3(0.96, 0.95, 0.97), smoothstep(0.1, 0.7, -patchy) * 0.3);
    float region = d.nz.g * 0.8 + d.nz.a * 0.2;
    float field = smoothstep(0.47, 0.6, region);
    float gravel = 1.0 - smoothstep(0.3, 0.42, region);
    float duneSize = wrapFit(kDuneTiles * u.map.y, u);
    float2 warp = float2(d.nz.g - 0.5, d.nz.a - 0.5) * float2(0.35, 0.06);
    if (field > 0.0) {
        float sh = (sampleWorld(feat, d.p, duneSize, d, warp).r - 0.5) * 2.0 * field;
        c *= 1.0 + max(sh, 0.0) * float3(0.17, 0.14, 0.06);
        c = mix(c, c * float3(0.80, 0.75, 0.84), saturate(-sh) * 0.55);
    }
    if (gravel > 0.0) {
        c = mix(c, c * float3(0.90, 0.86, 0.80), gravel * 0.5);
        c = stones(c, d.fine.b, a * float3(0.74, 0.68, 0.60), gravel * 0.9);
    }
    c = mix(c, c * float3(0.80, 0.72, 0.62), smoothstep(0.5, 0.8, d.fine.g) * (0.2 + 0.4 * gravel));  // grit
    // Wind ripples on open sand, only close up where they cannot shimmer.
    float ripple = (1.0 - gravel) * (1.0 - 0.4 * field) * (1.0 - smoothstep(0.22, 0.35, d.fp));
    if (ripple > 0.0) {
        float fs = wrapFit(kFineSize, u);
        float r = sampleWorld(feat, d.p, fs, d, warp * (duneSize / fs)).b;
        c *= 1.0 + (r - 0.5) * 0.1 * ripple;
    }
    return c;
}

static float3 paintTundra(float3 a, Paint d) {
    float3 c = a * mix(float3(0.95, 0.98, 1.02), float3(1.04, 1.01, 0.94), d.nz.g);
    c *= 0.95 + 0.1 * d.nz.b;
    float moss = sgn01(d.coarse.r);
    c = mix(c, c * float3(0.84, 0.94, 0.80), smoothstep(-0.1, 0.7, moss) * 0.8);
    c = mix(c, c * float3(1.06, 1.04, 1.0), smoothstep(0.0, 0.6, -moss) * 0.6);
    c = mix(c, c * float3(1.10, 0.90, 0.80), smoothstep(0.55, 0.75, d.nz.a) * 0.35);  // rusty heather
    c = mix(c, c * float3(0.80, 0.86, 0.78), smoothstep(0.65, 0.9, d.fine.a) * 0.5);  // dwarf shrubs
    float s = sgn01(d.fine.r);
    c = mix(c, c * float3(0.88, 0.92, 0.88), smoothstep(0.1, 0.5, -s) * 0.5);
    c = mix(c, c * float3(1.08, 1.06, 1.0), smoothstep(0.1, 0.5, s) * 0.4);
    c = mix(c, float3(0.84, 0.77, 0.52), smoothstep(0.55, 0.85, d.fine.g) * 0.5);   // lichen
    return stones(c, d.fine.b, float3(0.56, 0.56, 0.55), smoothstep(0.1, 0.5, -moss));  // gravel patches
}

// Snow: never paper white. A soft warm white, lowered so lit crests can sit above it, carved by
// the wind: long drifts follow a wind that bends from region to region (the stroke pattern is
// laid on a plane warped by slow world noise), each embossed by the sun (cream-lit crests,
// blue-violet lee sides); broad drifts swell between soft blue hollows; close up, fine sastrugi
// run with the wind; and here and there the wind has scoured the snow down to rock and tundra.
// Warmer and lighter than pack ice, which leans blue, so snow-covered land reads against it.
static float3 paintSnow(float3 a, Paint d, texture2d<float> coarse, texture2d<float> feat, constant Uniforms& u) {
    float3 c = a * float3(0.94, 0.93, 0.90) * (0.95 + 0.06 * d.nz.g);
    c = mix(c, c * float3(0.90, 0.92, 0.99), smoothstep(0.1, 0.6, -sgn01(d.coarse.r)) * 0.4);   // hollows
    float far = smoothstep(1.5, 3.5, d.fp);
    float drifts = smoothstep(0.3, 0.6, d.nz.g) * (1.0 - far);
    if (drifts > 0.0) {
        float ds = wrapFit(kDuneTiles * 1.7 * u.map.y, u);
        float sh = (sampleWorld(feat, d.p, ds, d, float2(0.31, 0.57)).r - 0.5) * 2.0 * drifts;
        c *= 1.0 + max(sh, 0.0) * float3(0.04, 0.035, 0.02);
        c = mix(c, c * float3(0.84, 0.87, 0.97), saturate(-sh) * 0.5);
    }
    // Wind drifts: the stroke pattern three times larger on the warped plane; a stroke is a
    // ridge, lit where it falls away toward the sun.
    float2 toSun = normalize(sunDirection(u).xy);
    float size = wrapFit(kCoarseSize * 3.0, u);
    float2 q = d.p + float2(0.25, 1.6) * (d.nz.g - 0.5) * u.map.y;
    gradient2d g = gradient2d(d.dpx / size, d.dpy / size);
    float h0 = abs(coarse.sample(kRepeat, q / size, g).g - 0.5);
    float h1 = abs(coarse.sample(kRepeat, (q + toSun * 2.5) / size, g).g - 0.5);
    float lit = clamp((h0 - h1) * 9.0, -1.0, 1.0) * (1.0 - far);
    c = mix(c, c * float3(1.06, 1.05, 1.0), saturate(lit) * 0.9);
    c = mix(c, c * float3(0.80, 0.84, 0.96), saturate(-lit) * 0.8);
    // Sastrugi: the sand-ripple pattern turned to run with the wind and stretched three times
    // along it (the x period divides the map width), its lee facing south, away from the sun.
    float amount = smoothstep(0.3, 0.7, d.nz.b) * (1.0 - smoothstep(0.5, 1.2, d.fp));
    if (amount > 0.0) {
        float sy = kSastrugiSize, sx = wrapFit(kSastrugiSize * 3.0, u);
        float2 r2 = float2(-q.y / sy, q.x / sx);
        gradient2d gr = gradient2d(float2(-d.dpx.y / sy, d.dpx.x / sx), float2(-d.dpy.y / sy, d.dpy.x / sx));
        float r = feat.sample(kRepeat, r2, gr).b - 0.5;
        c *= 1.0 + (max(r, 0.0) * 0.08 - max(-r, 0.0) * 0.16) * amount * float3(1.0, 1.0, 0.75);
    }
    // Scoured patches: thin snow, then rock and tundra showing through.
    float scour = d.coarse.r * 0.45 + d.nz.a * 0.35 + d.nz.r * 0.2;
    float3 bare = float3(0.62, 0.61, 0.57) * (0.86 + 0.28 * d.fine.r);
    c = mix(c, c * float3(0.90, 0.92, 0.96), smoothstep(0.58, 0.66, scour) * 0.6);
    c = mix(c, bare, smoothstep(0.67, 0.72, scour + (d.fine.r - 0.5) * 0.14 + (d.fine.a - 0.5) * 0.08) * 0.75);
    float sparkle = smoothstep(0.75, 0.95, d.fine.g) * (1.0 - smoothstep(0.25, 0.6, d.fp));
    return min(c + sparkle * 0.05, float3(0.95));
}

// Forest floor: moss and leaf mould in soft, low-contrast patches (the trees already say forest),
// rusty needle litter close up, and dappled light falling through the canopy.
static float3 paintForest(float3 a, Paint d, texture2d<float> feat, constant Uniforms& u) {
    float3 c = a * (0.95 + 0.1 * d.nz.b);
    float moss = sgn01(d.coarse.r);
    c = mix(c, c * float3(0.93, 1.06, 0.86), smoothstep(0.1, 0.6, moss) * 0.45);
    c = mix(c, c * float3(0.88, 0.87, 0.86), smoothstep(0.1, 0.6, -moss) * 0.4);
    float leaf = sgn01(d.fine.a);
    c = mix(c, c * float3(1.07, 1.05, 0.90), smoothstep(0.3, 0.7, leaf) * 0.3);
    c = mix(c, c * float3(0.88, 0.91, 0.92), smoothstep(0.3, 0.7, -leaf) * 0.3);
    float litter = 1.0 - smoothstep(0.35, 0.9, d.fp);
    if (litter > 0.0) {
        float n = sampleWorld(feat, d.p, wrapFit(kFineSize, u), d).a - 0.5;
        c = mix(c, c * float3(1.2, 0.98, 0.70), smoothstep(0.08, 0.3, n) * 0.55 * litter);
        c = mix(c, c * float3(0.80, 0.80, 0.78), smoothstep(0.08, 0.3, -n) * 0.4 * litter);
    }
    float dapple = smoothstep(0.6, 0.74, d.nz.a * 0.6 + d.nz.b * 0.4);
    return c * (1.0 + dapple * float3(0.13, 0.12, 0.05));
}

static float3 paintJungle(float3 a, Paint d) {
    float3 c = a * (0.94 + 0.12 * d.nz.b);
    float leaf = sgn01(d.fine.a);
    c = mix(c, c * float3(1.08, 1.16, 0.88), smoothstep(0.25, 0.65, leaf) * 0.5);
    c = mix(c, c * float3(0.78, 0.84, 0.84), smoothstep(0.15, 0.6, -leaf) * 0.55);
    float clump = sgn01(d.coarse.r);
    c = mix(c, c * float3(0.88, 0.96, 0.92), smoothstep(0.0, 0.6, -clump) * 0.5);
    c = mix(c, c * float3(1.05, 1.10, 0.92), smoothstep(0.2, 0.7, clump) * 0.4);
    return c;
}

// Bog: olive sedge with brown peat and pale mossy hummocks, and irregular pools edged by mud
// and ochre reeds. Pools are blobs merged in small clusters (so they never line up like a broken
// river) and they shrink away toward the edge of the marsh. Their water is murky but holds the
// sky: shaded under the bank on the sun side, brighter toward the far bank.
static float3 paintMarsh(float3 a, Paint d, float weight, texture2d<float> feat, constant Uniforms& u) {
    float3 c = a * (0.94 + 0.12 * d.nz.b);
    float peat = sgn01(d.coarse.r);
    c = mix(c, c * float3(0.82, 0.78, 0.68), smoothstep(0.0, 0.6, -peat) * 0.6);
    c = mix(c, c * float3(1.08, 1.14, 0.84), smoothstep(0.2, 0.7, peat) * 0.6);
    float s = sgn01(d.fine.r);
    c = mix(c, c * float3(1.14, 1.08, 0.78), smoothstep(0.1, 0.5, s) * 0.45);   // sedge
    c = mix(c, c * float3(0.84, 0.86, 0.82), smoothstep(0.1, 0.5, -s) * 0.3);
    float ps = wrapFit(kPoolTiles * u.map.y, u);
    float pf = sampleWorld(feat, d.p, ps, d).g;   // 0.5 at the waterline, rising 1/20 per texel inward
    float edge = 0.5 + 0.35 * (1.0 - smoothstep(0.5, 0.95, weight));
    float aa = d.fp * 512.0 / ps / 20.0 + 0.01;
    float pool = smoothstep(edge - aa, edge + aa, pf);
    if (pool + smoothstep(edge - 0.3, edge, pf) < 0.001) return c;
    float mud = smoothstep(edge - 0.12, edge - 0.02, pf) * (1.0 - pool);
    c = mix(c, c * float3(0.80, 0.76, 0.64), mud * 0.7);
    float reeds = smoothstep(0.0, 0.4, s) * smoothstep(edge - 0.26, edge - 0.06, pf) * (1.0 - pool);
    c = mix(c, float3(0.68, 0.58, 0.32) * (0.9 + 0.2 * d.fine.g), reeds * 0.7);
    // The pool's own slope toward the sun says which bank shades it.
    float2 toSun = normalize(sunDirection(u).xy);
    float pfS = sampleWorld(feat, d.p + toSun * 1.6, ps, d).g;
    float depth = saturate((pf - edge) / 0.18);
    float3 water = mix(waterRamp(0.12, u), float3(0.36, 0.42, 0.30), 0.45);
    water = mix(water, mix(waterRamp(0.45, u), float3(0.24, 0.32, 0.30), 0.4), smoothstep(0.1, 0.8, depth));
    water += float3(0.06, 0.08, 0.09) * smoothstep(0.35, 0.7, d.nz.r);       // the sky's reflection
    water *= 1.0 - smoothstep(0.0, 0.12, pf - pfS) * 0.3;                     // under the sunward bank
    water *= 1.0 + smoothstep(0.0, 0.12, pfS - pf) * 0.12;
    return mix(c, water, pool);
}

// Floodplain: bright fertile silt along a desert river, never marsh (no standing water, no dark
// olive). Bands of fresh green and light tan run parallel to the river (by the distance to it),
// broken into fields; the green thins out away from the water. Far from any known river the
// wind-combed streaks lay out the bands instead.
static float3 paintFloodplain(float3 a, Paint d, float riverDist, float apothem) {
    float t = riverDist < 1e8 ? max(riverDist, 0.0) / apothem : 0.6 + sgn01(d.coarse.g) * 0.4;
    float bands = 0.5 + 0.5 * sin(6.2831853 * (t * 2.4 + (d.nz.r - 0.5) * 0.9 + (d.coarse.r - 0.5) * 0.25));
    float fields = smoothstep(0.3, 0.7, d.coarse.r * 0.6 + d.nz.a * 0.4);
    float green = saturate(1.25 - t * 0.6) * mix(0.25, 1.0, smoothstep(0.3, 0.7, bands)) * mix(0.55, 1.0, fields);
    float3 silt = mix(float3(0.76, 0.68, 0.50), a, 0.15) * (0.95 + 0.1 * d.nz.g);
    float3 fresh = float3(0.55, 0.65, 0.34) * (0.93 + 0.12 * d.nz.b);
    float3 c = mix(silt, fresh, green);
    float s = sgn01(d.fine.r);
    c = mix(c, c * float3(1.07, 1.07, 1.0), smoothstep(0.1, 0.5, s) * 0.45);    // crop rows and grass
    c = mix(c, c * float3(0.90, 0.92, 0.90), smoothstep(0.1, 0.5, -s) * 0.35);
    return c;
}

// Mountain floor: weathered rock with a little scrub on the range's outer flanks, sinking into
// cool blue-violet shade in the valleys between summits inside a range (calmer there: the
// strata fade into the shadow); stones only where talus fans spill from the summits' feet.
static float3 paintRock(float3 a, Paint d, float talus, float valley) {
    float3 c = a * mix(float3(0.95, 0.96, 1.0), float3(1.03, 1.0, 0.96), d.nz.g);
    float strata = sgn01(d.coarse.g) * (1.0 - 0.5 * valley);
    c = mix(c, c * float3(1.06, 1.05, 1.02), smoothstep(0.1, 0.6, strata) * 0.5);
    c = mix(c, c * float3(0.86, 0.86, 0.92), smoothstep(0.1, 0.6, -strata) * 0.5);
    float clump = sgn01(d.coarse.r);
    c = mix(c, c * float3(0.90, 0.97, 0.84), smoothstep(0.3, 0.8, clump) * 0.35 * (1.0 - valley));   // scrub
    c *= mix(float3(1.0), float3(0.78, 0.78, 0.90) * (0.94 + 0.12 * d.nz.a), valley);
    c = mix(c, c * float3(1.07, 1.05, 1.0), talus * 0.5);                         // paler scree
    return stones(c, d.fine.b, a * mix(1.15, 0.95, valley), talus);
}

// Per-tile base color (the palette, nudged by feature and elevation).
static float3 tileAlbedo(TileInfo t, constant Uniforms& u) {
    float3 c = u.terrain[t.terrain].rgb;
    switch (t.feature) {
        case 1u: c = mix(c, c * float3(0.62, 0.80, 0.56), 0.4); break; // forest floor: the terrain, deeper and greener
        case 2u: c = mix(c, float3(0.12, 0.33, 0.15), 0.6); break;    // jungle floor
        case 3u: c = mix(c, float3(0.43, 0.47, 0.26), 0.7); break;    // bog
        case 4u: c = float3(0.70, 0.64, 0.45); break;                 // floodplain silt
        default: break;
    }
    return c;
}

// Material slot of a land tile: 0 grass, 1 plains, 2 desert, 3 tundra, 4 snow, 5 forest,
// 6 jungle, 7 marsh, 8 floodplain (9 is unused: mountain rock is painted over its terrain, see
// `groundAddRock`).
static uint landMaterial(TileInfo t) {
    switch (t.feature) {
        case 1u: return 5u;
        case 2u: return 6u;
        case 3u: return 7u;
        case 4u: return 8u;
        default: return min(t.terrain, 4u);
    }
}

// Each material's own patch pattern. Where two materials meet, the one whose pattern is higher
// wins the point, so borders interlock as painted patches (grass clumps, straw streaks, snow
// drifts) instead of crossfading. Forest floors get a head start so neighboring forest tiles
// merge into one mass.
static float materialMask(uint slot, Paint d) {
    switch (slot) {
        case 0u: return d.coarse.r;
        case 1u: return d.coarse.g * 0.6 + d.nz.b * 0.4;
        case 2u: return d.nz.a;
        case 3u: return d.fine.a * 0.5 + d.nz.b * 0.5;
        case 4u: return d.coarse.g * 0.6 + d.nz.a * 0.4;
        case 5u: return 0.3 + d.fine.a * 0.3 + d.nz.a * 0.3;
        case 6u: return 0.25 + d.fine.a * 0.3 + d.nz.a * 0.3;
        case 7u: return 1.0 - d.coarse.r;
        case 8u: return 1.0 - d.nz.a;
        default: return d.fine.b * 0.5 + d.nz.b * 0.5;
    }
}

// Sharpness of the smooth minimum over mountain centers (apothems): small enough that a range's
// floor closes at every corner where three mountains meet.
constant float kRockK = 0.25;

// Adds one explored mountain at offset `d` from the pixel to the rock floor's smooth minimum
// distance (sum of exp(-distance / k)) and its smooth count (a bell about 0.9 apothem wide).
static void groundAddRock(thread float& e, thread float& n, float2 d, float apothem) {
    float l = length(d) / apothem;
    e += exp(-l / kRockK);
    n += exp(-l * l / 1.62);
}

static float4 oneHot(uint slot, uint base) {
    return float4(slot == base ? 1.0 : 0.0, slot == base + 1u ? 1.0 : 0.0,
                  slot == base + 2u ? 1.0 : 0.0, slot == base + 3u ? 1.0 : 0.0);
}

// ------------------------------------------------ neighborhood blend

struct Blend {
    float3 landAlb; float landW;  // land albedo and weight (sharp, masked)
    float4 mA, mB; float2 mC;     // material weights by slot
    float lSum, lW;               // land fraction
    float sSum, sW;               // shelf fraction (anything but open ocean)
    float3 wF; float waterW;      // water tiles: reef, ice, lake shares
    float eSum, eW;               // dimmed share (explored or unexplored)
    float uSum, uW;               // unexplored share on a wide kernel, and its gradient terms
    float2 uG, uGW;
};

// Adds tile t at blend distance `de` (world units; 0 for the pixel's own tile). `n` is the edge
// normal toward it (zero for the own tile), for the analytic gradient of the unexplored field.
// Unexplored tiles never contribute terrain: near the cloud bank the explored ground simply
// carries on underneath it, so its soft edge can never reveal a coast or a field.
static void blendTile(thread Blend& b, TileInfo t, uint fog, float de, float2 n, float meMask, Paint d,
                      constant Uniforms& u) {
    float apothem = u.map.y * 0.5;
    bool hidden = fog == 2u;
    float hid = hidden ? 1.0 : 0.0;
    float wu = exp(-kKU / apothem * de);
    b.uSum += hid * wu; b.uW += wu;
    b.uG += hid * wu * n; b.uGW += wu * n;
    float wf = exp(-kKF / apothem * de);
    b.eSum += (fog >= 1u ? 1.0 : 0.0) * wf; b.eW += wf;
    if (hidden) return;
    bool water = isWater(t.terrain);
    float wl = exp(-kKL / apothem * de);
    b.lSum += water ? 0.0 : wl; b.lW += wl;
    float ws = exp(-kKS / apothem * de);
    b.sSum += t.terrain == 6u ? 0.0 : ws; b.sW += ws;
    if (water) {
        b.waterW += ws;
        b.wF += ws * float3(t.feature == 6u ? 1.0 : 0.0, t.feature == 7u ? 1.0 : 0.0, t.terrain == 7u ? 1.0 : 0.0);
    } else {
        uint slot = landMaterial(t);
        float wc = exp(-kKC / apothem * (de - (materialMask(slot, d) - meMask) * kMaskReach * apothem));
        b.landAlb += tileAlbedo(t, u) * wc; b.landW += wc;
        b.mA += wc * oneHot(slot, 0u); b.mB += wc * oneHot(slot, 4u);
        b.mC += wc * float2(slot == 8u ? 1.0 : 0.0, slot == 9u ? 1.0 : 0.0);
    }
}

// ------------------------------------------------ water

// Coral colors by colony hue, muted and sun-bleached: dusty coral, cream, sea green and a little
// dull rose. Each stays at least 15 CIEDE2000 from every player color (and the water over them
// only softens them further).
static float3 coralColor(float hue) {
    float3 c = mix(float3(0.72, 0.60, 0.47), float3(0.74, 0.68, 0.56), smoothstep(0.25, 0.4, hue));
    c = mix(c, float3(0.56, 0.60, 0.50), smoothstep(0.55, 0.7, hue));
    return mix(c, float3(0.64, 0.56, 0.54), smoothstep(0.85, 0.95, hue));
}

// ------------------------------------------------ rivers
// Rivers run along hex edges. Each edge's center line bows away from the edge and returns to it
// at its corners, so segments always join; segments merge by an exponential smooth minimum, so
// joints are round and inside corners filleted, and every tile around a joint computes the same
// shape. Everything here is fog-independent: a river's width at each corner comes from a hash
// of the corner and slow world noise, never from where the river goes beyond the player's sight.

// Corners lie on a lattice of half a tile width by half a tile size. Corners whose lattice row
// is 1 mod 3 (the tops of tiles and their lower side corners) alternate with the others along
// any path of edges.
static int2 riverCorner(float2 world, constant Uniforms& u) {
    int2 c = int2(round(world / float2(u.map.y * 0.5, u.map.x * 0.5)));
    if (u.dims.z > 0.5) c.x = wrapIndex(c.x, 2 * int(u.dims.x));
    return c;
}

// Half-width factor at a corner: about 0.75-1.3, varying slowly along a river.
static float riverCornerWidth(float2 world, int2 corner, constant Uniforms& u) {
    int W = int(u.dims.x);
    int per = max(1, int(round(float(W) / 3.0)));
    float2 np = world / u.map.y;
    float slow = vnoise(float2(np.x * float(per) / float(W), np.y / 3.0) * 1.0, per);
    return 0.72 + 0.6 * (slow * 0.7 + hash2(corner.x + 7919, corner.y * 3 + 11) * 0.3);
}

struct RiverAcc {
    float e;       // sum of exp(-sdf / round); after `riverField`, the merged signed distance
    float across;  // -1 .. 1 between the banks
    float hw;      // half width
};

// Adds the segment between corners a and b (local coordinates). Its center line bows to the left
// of the direction from its odd corner to its even one, so consecutive edges bow to alternate
// sides of any river and runs of edges flow into S-meanders.
static void addRiverSegment(thread RiverAcc& acc, float2 local, float2 a, float2 b, float2 center,
                            float baseHW, float fp, constant Uniforms& u) {
    float size = u.map.x;
    float2 wa = center + a, wb = center + b;
    int2 ca = riverCorner(wa, u), cb = riverCorner(wb, u);
    bool oddA = ((ca.y % 3) + 3) % 3 == 1;
    float2 tng = (b - a) / size;
    float2 nrm = float2(tng.y, -tng.x);   // right of a -> b
    int2 lo = oddA ? ca : cb, hi = oddA ? cb : ca;
    // Bends of uneven depth, their apexes shifted along the edge, so meanders never repeat.
    float bh = hash2(lo.x * 31 + hi.x, lo.y * 17 + hi.y);
    float bow = (0.13 + 0.17 * bh * bh) * (oddA ? -1.0 : 1.0);
    float skew = (hash2(lo.x + hi.y * 7, hi.x - lo.y * 5) - 0.5) * 0.2;
    float2 q = local - (a + b) * 0.5;
    float t = dot(q, tng) / (size * 0.5);
    float tc = clamp(t, -1.0, 1.0);
    float s = dot(q, nrm);
    float m = size * (1.0 - tc * tc) * (bow + skew * tc);
    float slope = 2.0 * ((1.0 - tc * tc) * skew - 2.0 * tc * (bow + skew * tc));
    float dist = abs(t) <= 1.0 ? abs(s - m) * rsqrt(1.0 + slope * slope) : length(local - (t < 0.0 ? a : b));
    float f = (tc + 1.0) * 0.5;
    float wA = riverCornerWidth(wa, ca, u), wB = riverCornerWidth(wb, cb, u);
    float hw = max(baseHW * mix(wA, wB, f), fp * 0.9);
    float e = exp(-(dist - hw) / kRiverRound);
    acc.e += e;
    acc.across += e * clamp((s - m) / hw, -1.0, 1.0);
    acc.hw += e * hw;
}

// Every river segment near a tile: its own river edges, and "spokes" (river edges between two
// neighbors) that end at one of its corners.
static RiverAcc riverField(float2 local, float2 center, uint rivers, uint cornerRivers, float baseHW, float fp,
                           constant Uniforms& u) {
    float size = u.map.x, tw = u.map.y, apothem = tw * 0.5;
    RiverAcc acc = { 0.0, 0.0, 0.0 };
    for (int i = 0; i < 6; i++) {
        if (((rivers >> uint(i)) & 1u) == 0u) continue;
        float2 nc = i < 3 ? kNormals[i] : -kNormals[i];
        float2 tng = float2(-nc.y, nc.x);
        float2 mid = kNormals[i] * apothem;
        addRiverSegment(acc, local, mid - tng * size * 0.5, mid + tng * size * 0.5, center, baseHW, fp, u);
    }
    for (int k = 0; k < 6; k++) {
        if (((cornerRivers >> uint(k)) & 1u) == 0u) continue;
        int i = (11 - k) % 6;   // the neighbor across edge i touches corner k...
        int j = (i + 2) % 6;    // ...and its edge j (toward the next neighbor) is the spoke
        float2 nc = j < 3 ? kNormals[j] : -kNormals[j];
        float2 tng = float2(-nc.y, nc.x);
        float2 mid = kNormals[i] * tw + kNormals[j] * apothem;
        addRiverSegment(acc, local, mid - tng * size * 0.5, mid + tng * size * 0.5, center, baseHW, fp, u);
    }
    float inv = 1.0 / max(acc.e, 1e-30);
    acc.across *= inv;
    acc.hw *= inv;
    acc.e = -kRiverRound * log(max(acc.e, 1e-30));
    return acc;
}

// ------------------------------------------------ fog of war

// Distance from q to a pointy-top hexagon of apothem `a` at the origin (negative inside), and
// its gradient (outside the hexagon).
static float hexDistance(float2 q, float a, thread float2& grad) {
    const float3 k = float3(-0.866025404, 0.5, 0.577350269);
    float2 s = select(float2(-1.0), float2(1.0), q.yx >= 0.0);
    float2 p = abs(q.yx);
    float m = min(dot(k.xy, p), 0.0);
    p -= 2.0 * m * k.xy;
    float2 r = p - float2(clamp(p.x, -k.z * a, k.z * a), a);
    float len = length(r);
    float2 g = len > 1e-5 ? r / len : float2(0.0, 1.0);
    if (m < 0.0) g -= 2.0 * dot(g, k.xy) * k.xy;
    grad = (g * s).yx;
    return len * sign(r.y);
}

// The cumulus texture at one scale, drifting east-south-east by whole periods per hour.
static float4 cloudLayer(texture2d<float> shapes, Paint d, float size, float speed, float2 offset) {
    float2 perHour = max(round(float2(0.92, 0.36) * speed * 3600.0 / size), float2(1.0));
    return sampleWorld(shapes, d.p, size, d, offset + float2(-cycles(d.time, perHour.x), cycles(d.time, perHour.y)));
}

struct Cloud {
    float3 color;
    float cover;
    float height;   // 0-1, the bank's billow tops
};

// Unexplored: a bank of cumulus seen from above. One baked field of domes (masses, billows and
// puffs) is read at two scales, the billows warped by the masses' slope so nothing repeats or
// lines up, and lit by the sun from the upper left: tops facing the sun pale toward a cool
// silver, flanks facing away and the creases between domes sink into blue-violet shade.
// `depth` is the distance into unexplored ground (world units, exact up to kDepthCap apothems,
// so it is seamless) and `depthDir` its gradient. The bank never reaches past the boundary of
// explored ground, so sprites standing on explored tiles never sit on it; its edge recedes
// between billows, its sunlit side catches light and its far side falls into shade. Zoomed out
// the billows flatten and the bank darkens and calms, so it reads as one soft mass.
static Cloud cloudBank(float depth, float2 depthDir, Paint d, texture2d<float> shapes, constant Uniforms& u) {
    float apothem = u.map.y * 0.5;
    float sizeA = wrapFit(kCloudTiles * u.map.y, u), sizeB = wrapFit(kCloudTiles * 2.7 * u.map.y, u);
    float4 b = cloudLayer(shapes, d, sizeB, 0.8, float2(0.37, 0.61));
    float4 a = cloudLayer(shapes, d, sizeA, 1.0, float2(0.0));
    // Zoomed out, the small puffs fade first, then the billows calm and the bank darkens.
    float far = smoothstep(0.55, 1.35, d.fp);
    float shadeA = mix(a.r, a.g, smoothstep(0.5, 1.1, d.fp));

    // The edge follows the puffs: each reaches toward explored ground at its middle and falls
    // back at its rim, so the edge is a chain of rounded billows, scalloped by the small puffs.
    // (The cover ramp ends before the depth field's cap, so deep inside the bank it is whole.)
    float recess = 0.05 + 0.22 * saturate((d.nz.g - 0.5) * 2.5 + 0.5) + 0.3 * (1.0 - a.b) + 0.32 * (1.0 - a.a);
    float e = depth - clamp(recess, 0.04, 0.82) * apothem;
    Cloud c;
    c.cover = smoothstep(0.0, min(0.16 * apothem + d.fp, 0.3 * apothem), e);
    c.height = a.b;

    float shade = mix(0.5, b.g, 0.75);
    shade = mix(shade, shadeA, mix(0.7, 0.45, far));
    shade = mix(shade, 0.45, far * 0.45);
    float3 col = mix(kCloudDeep, kCloudMid, smoothstep(0.12, 0.48, shade));
    col = mix(col, kCloudLit, smoothstep(0.52, 0.88, shade));
    // Tops catch a little warm light.
    col += smoothstep(0.7, 0.95, shade) * float3(0.035, 0.025, 0.005);
    col = mix(col, col * 0.84, far);
    c.color = col;
    return c;
}

// How the baked relief lights the ground: a value multiplier and a share of the way toward
// sunlight's hue (luminance kept).
struct ReliefLight {
    float3 mul;
    float warm;
};

// Slopes facing the sun lighten (value up to x1.2) and warm toward cream sunlight; slopes facing
// away deepen toward cool blue-violet (value x0.78). Both ramp in softly over the slope, so
// broad landforms shade smoothly instead of splitting into a lit and a dark half. The lee at the
// feet of slopes sinks into a little more shade, and lit crowns warm a touch. Snow, already near
// white, warms more than it brightens, and its shade is bluer.
static ReliefLight groundReliefLight(float4 rel, float3 sun, float snow) {
    float2 nxy = rel.rg * 2.0 - 1.0;
    float3 n = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    float s = dot(n, sun) / sun.z - 1.0;   // 0 on flat ground
    float up = smoothstep(0.0, 0.35, s), dn = smoothstep(0.0, 0.62, -s);
    float lee = saturate(1.0 - rel.b * 2.0), crown = saturate(rel.b * 2.0 - 1.0);
    float3 shade = mix(float3(0.80, 0.765, 0.92), float3(0.74, 0.80, 1.0), snow);
    ReliefLight r;
    r.mul = (1.0 + 0.2 * up * mix(1.0, 0.35, snow)) * mix(float3(1.0), shade, dn);
    r.mul *= mix(float3(1.0), shade * 0.95, lee * 0.55 * (1.0 - 0.6 * dn));
    r.mul *= mix(float3(1.0), float3(1.035, 1.015, 0.96), crown * up);
    r.warm = up * mix(0.22, 0.3, snow);
    return r;
}

static float3 groundRelight(float3 c, ReliefLight r) {
    c *= r.mul;
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    return mix(c, y * float3(1.074, 0.999, 0.795), r.warm);
}

struct PolarHaze {
    float3 color;
    float alpha;
};

// Past the edge of the world, `beyond` tile widths out: a pale haze of drifting wisps over the
// polar pack (two scales, so its edge never runs straight), light and low in contrast, so it
// never reads as the dark unexplored bank; `rise` holds it back over the bank's billows. A view
// zoomed out past the map's height sees many rows of it, so farther out broad banks of mist
// drift west over the pack (two more scales): thick, pale and lit on the sides facing the sun,
// or thin, where the pack shows through, fainter with distance. Never a flat, empty band.
static PolarHaze groundPolarHaze(float beyond, float rise, Paint d, float2 toSun, texture2d<float> noise, constant Uniforms& u) {
    float tw = u.map.y;
    float ws = wrapFit(9.0 * tw, u);
    float4 wn = sampleWorld(noise, d.p, ws, d, float2(-cycles(d.time, max(1.0, round(1800.0 / ws))), 0.0));
    float wisp = wn.g * 0.65 + wn.r * 0.35;
    float mist = smoothstep(0.3, 3.8, beyond + (wisp - 0.5) * 2.6 - rise);
    PolarHaze h;
    h.color = mix(float3(0.72, 0.78, 0.84), float3(0.80, 0.85, 0.89), smoothstep(0.5, 4.0, beyond + wisp));
    float density = 0.92;
    float far = smoothstep(3.0, 9.0, beyond);
    if (far > 0.0) {
        float bs = wrapFit(24.0 * tw, u), cs = wrapFit(10.0 * tw, u);
        float2 driftB = float2(-cycles(d.time, 1.0), 0.29), driftC = float2(-cycles(d.time, 2.0), 0.61);
        float b0 = sampleWorld(noise, d.p, bs, d, driftB).g;
        float b1 = sampleWorld(noise, d.p + toSun * (1.2 * tw), bs, d, driftB).g;
        float c0 = sampleWorld(noise, d.p, cs, d, driftC).g;
        float bank = saturate((b0 * 0.7 + c0 * 0.3 - 0.5) * 2.4 + 0.5);
        // Positive on a bank's side facing the sun (it thickens away from the sun), negative
        // on the far side.
        float lit = clamp((b0 - b1) * 9.0, -1.0, 1.0);
        float3 banked = mix(h.color * float3(0.94, 0.955, 0.99), float3(0.83, 0.865, 0.895), bank);
        banked *= mix(float3(1.0), float3(1.03, 1.012, 0.972), saturate(lit) * bank);
        banked *= mix(float3(1.0), float3(0.94, 0.95, 1.0), saturate(-lit) * (0.4 + 0.6 * bank));
        h.color = mix(h.color, banked, far);
        float thin = mix(0.74, 0.88, smoothstep(9.0, 20.0, beyond));
        density = mix(density, mix(thin, 0.97, bank), far);
    }
    h.alpha = mist * density;
    return h;
}

} // namespace gnd

// Each fragment finds its hex, then blends its own tile with the six neighbors. Tile j gets
// weight exp(-k * (|p - c_j|^2 / (2 * tileWidth) - reach_j(p))): a function of the point and
// the tile only, so every fragment agrees on it (continuous across edges and corners).
// Relative to the own tile, the distance term reduces to the distance to the shared edge.
// Per-tile noisy reach bends borders into organic coastlines and soft fog fronts.
fragment float4 ground_fragment(GroundOut in [[stage_in]],
                                constant Uniforms& u [[buffer(1)]],
                                texture2d<uint, access::read> tiles [[texture(0)]],
                                texture2d<float> relief [[texture(1)]],
                                texture2d<float> fineTex [[texture(2)]],
                                texture2d<float> coarseTex [[texture(3)]],
                                texture2d<float> noise [[texture(4)]],
                                texture2d<uint, access::read> riverCorners [[texture(5)]],
                                texture2d<float> shapesTex [[texture(6)]],
                                texture2d<float> featTex [[texture(7)]],
                                texture2d<float> coralTex [[texture(8)]]) {
    using namespace gnd;
    float size = u.map.x, tw = u.map.y, apothem = tw * 0.5;
    float2 p = in.world;
    HexCell h = hexCell(p, u);
    float2 local = h.local;
    float time = u.cameraUp.w;
    float3 sun = sunDirection(u);
    float2 toSun = normalize(sun.xy);

    // Pixel footprint and the lookups every material shares (hoisted out of the tile loop).
    float2 dpx = dfdx(p), dpy = dfdy(p);
    float fp = max(length(dpx), length(dpy));
    float2 np = p / tw;
    float P = noisePeriod(u);
    float2 nuv = np / P;
    gradient2d nGrad = gradient2d(dpx / (tw * P), dpy / (tw * P));
    float4 nz = noise.sample(kRepeat, nuv, nGrad);
    float fineSize = wrapFit(kFineSize, u), coarseSize = wrapFit(kCoarseSize, u);
    Paint d;
    d.fine = fineTex.sample(kRepeat, p / fineSize);
    d.coarse = coarseTex.sample(kRepeat, p / coarseSize);
    d.nz = nz;
    d.p = p;
    d.dpx = dpx;
    d.dpy = dpy;
    d.fp = fp;
    d.time = time;

    // Past the north and south edges of the world lies the polar pack: closed ice under a haze.
    TileInfo me = fetchTile(tiles, h.q, h.r, u);
    if (h.r < 0 || h.r >= int(u.dims.y)) me.feature = 7u;
    bool meOn = onMap(h.q, h.r, u);
    uint meFog = meOn ? me.fog : edgeFog(tiles, h.q, h.r, u);
    float meReach = tileReach(noise, np, me.noiseOffset, P);
    // (An unexplored tile adds no terrain, and its mask only scales every neighbor's weight
    // alike: a constant keeps even the rounding independent of what lies under the cloud.)
    float meMask = (meFog == 2u || isWater(me.terrain)) ? 0.5 : materialMask(landMaterial(me), d);

    Blend b = { float3(0.0), 0.0, float4(0.0), float4(0.0), float2(0.0), 0.0, 0.0, 0.0, 0.0, float3(0.0), 0.0,
                0.0, 0.0, 0.0, 0.0, float2(0.0), float2(0.0) };
    blendTile(b, me, meFog, 0.0, float2(0.0), meMask, d, u);
    // Explored mountains around the pixel: a smooth minimum of the distances to their centers
    // (for the rock floor's edge) and a smooth count of them (for the valleys inside ranges).
    float rockE = 0.0, rockN = 0.0;
    if (meFog != 2u && me.elevation == 2u && !isWater(me.terrain)) groundAddRock(rockE, rockN, local, apothem);
    float minD = 1e9;
    int nearest = 0;
    uint cornerRivers = 0u; // corners touched by a river edge between two neighbors
    uint hidden = 0u;       // neighbors still unexplored
    float hidEdge = 1e9;    // distance to the nearest unexplored neighbor's edge line
    // Renderer inputs (M1 §15), explored tiles only: the distance to the nearest edge with
    // another owner (both tiles explored), to the nearest edge of a tile that is not a farm (or
    // not explored) and to the nearest edge of a tile outside the movement range.
    bool meKnown = meFog != 2u;
    uint meImprovement = meKnown ? me.improvement : 0u;
    bool meInRange = meKnown && (me.marks & kTileRangeBit) != 0u;
    float ownEdge = 1e9, farmNear = meImprovement == 1u ? 0.0 : 1e9, rangeEdge = 1e9;
    uint farms = meImprovement == 1u ? 1u : 0u;   // farms here (bit 0) and next door (bit i + 1)
    for (int i = 0; i < 6; i++) {
        float dEdge = apothem - dot(local, kNormals[i]);
        if (dEdge < minD) { minD = dEdge; nearest = i; }
        int2 nh = int2(h.q, h.r) + kDirs[i];
        TileInfo nb = fetchTile(tiles, nh.x, nh.y, u);
        if (nh.y < 0 || nh.y >= int(u.dims.y)) nb.feature = 7u;
        if (((nb.rivers >> uint((i + 2) % 6)) & 1u) != 0u) cornerRivers |= 1u << uint((5 - i + 6) % 6);
        uint fog = onMap(nh.x, nh.y, u) ? nb.fog : edgeFog(tiles, nh.x, nh.y, u);
        if (fog == 2u) { hidden |= 1u << uint(i); hidEdge = min(hidEdge, dEdge); }
        if (meKnown && fog != 2u && nb.owner != me.owner) ownEdge = min(ownEdge, dEdge);
        if (meKnown && fog != 2u && nb.improvement == 1u) { farms |= 2u << uint(i); farmNear = min(farmNear, dEdge); }
        if (meInRange && (nb.marks & kTileRangeBit) == 0u) rangeEdge = min(rangeEdge, dEdge);
        float de = dEdge - (tileReach(noise, np, nb.noiseOffset, P) - meReach) * apothem;
        blendTile(b, nb, fog, de, kNormals[i], meMask, d, u);
        if (fog != 2u && nb.elevation == 2u && !isWater(nb.terrain)) groundAddRock(rockE, rockN, local - kNormals[i] * tw, apothem);
    }
    // Only rivers the player knows of: an edge is known when a tile beside it is explored. (The
    // tile data carries every river, and the cloud's edge recedes into unexplored tiles.)
    uint meRivers = me.rivers;
    if (meFog == 2u) meRivers &= ~hidden;
    for (int k = 0; k < 6; k++) {
        int i = (11 - k) % 6;   // the spoke at corner k lies between neighbors i and i + 1
        if (((hidden >> uint(i)) & (hidden >> uint((i + 1) % 6)) & 1u) != 0u) cornerRivers &= ~(1u << uint(k));
    }

    // Signed distance to the shoreline (world units, + on land), from the land fraction: near
    // a coast the blend is a logistic curve of the distance to the boundary. The same for the
    // shelf's edge (+ on the shelf).
    float L = b.lW > 0.0 ? clamp(b.lSum / b.lW, 1e-4, 1.0 - 1e-4) : 1e-4;
    float shore = log(L / (1.0 - L)) * apothem / kKL;
    float aaShore = max(fwidth(shore), 1e-4);
    float landMask = smoothstep(-aaShore, aaShore, shore);
    float S = b.sW > 0.0 ? clamp(b.sSum / b.sW, 1e-4, 1.0 - 1e-4) : 1e-4;
    float shelfD = log(S / (1.0 - S)) * apothem / kKS;
    float aaShelf = max(fwidth(shelfD), 1e-3);

    // Depth into unexplored ground (world units, negative on explored ground): the distance to
    // the nearest tile of the other kind, exact up to kDepthCap apothems, and its gradient.
    bool meHid = meFog == 2u;
    bool anyHid = meHid || hidden != 0u;
    Cloud cloud = { float3(0.0), 0.0, 0.0 };
    if (anyHid) {
        float depth = kDepthCap * apothem;
        float2 depthDir = float2(0.0);
        for (int i = 0; i < 6; i++) {
            if ((((hidden >> uint(i)) & 1u) != 0u) == meHid) continue;
            float2 g;
            float dd = hexDistance(local - kNormals[i] * tw, apothem, g);
            if (dd < depth) { depth = dd; depthDir = g; }
        }
        if (!meHid) { depth = -depth; depthDir = -depthDir; }
        cloud = cloudBank(depth, depthDir, d, shapesTex, u);
    }

    // Baked relief: slope normal, occlusion.
    float rTexel = tw / 12.0;
    float2 rOrigin = float2(u.dims.z > 0.5 ? 0.0 : -tw, -tw);
    float2 ruv = (p - rOrigin) / (float2(relief.get_width(), relief.get_height()) * rTexel);
    if (u.dims.z < 0.5) ruv.x = clamp(ruv.x, 0.0, 1.0);
    float4 rel = relief.sample(kWorld, ruv);
    // The relief is baked from every tile, so it lies flat near unexplored ground: no slope,
    // lee or talus may hint at the hills and mountains under the cloud. Every tile's relief
    // reaches less than kReliefGuard past its edges (straight-line distance), so beyond it the
    // relief depends only on explored tiles.
    float frontier = meFog == 2u ? 0.0 : hidEdge;
    rel = mix(float4(0.5, 0.5, 0.5, 0.0), rel, smoothstep(kReliefGuard * apothem, (kReliefGuard + 0.4) * apothem, frontier));
    ReliefLight rlight = { float3(1.0), 0.0 };

    float3 col = cloud.color;
    uint scoreTier = 0u;   // the settler overlay's tier here, washed over the explored fog below
    if (cloud.cover < 0.999) {
        // -------------------------------------------------------- land
        // Weights are relative (they can all be tiny deep inside an unexplored tile), so normalize
        // without a floor that would leave them unnormalized.
        float norm = 1.0 / max(dot(b.mA, 1.0) + dot(b.mB, 1.0) + b.mC.x + b.mC.y, 1e-30);
        float4 mA = b.mA * norm, mB = b.mB * norm;
        float2 mC = b.mC * norm;
        float3 water3 = b.waterW > 0.0 ? b.wF / b.waterW : float3(0.0);
        float3 land = float3(0.0);
        // Rivers the player knows of near this tile: for the ribbons below and the floodplain's
        // bands. They widen a little where they meet the sea or a lake (the shore distance only
        // sees explored ground).
        bool riverNear = meOn && (meRivers != 0u || cornerRivers != 0u);
        RiverAcc rv = { 1e9, 0.0, 1.0 };
        if (riverNear) {
            float flare = 1.0 + 0.45 * (1.0 - smoothstep(0.0, apothem * 0.9, shore));
            rv = riverField(local, h.center, meRivers, cornerRivers, size * 0.075 * (0.85 + 0.3 * nz.b) * flare, fp, u);
        }
        // The rock floor: round about each mountain, its edge broken by noise at two scales, and
        // merged into one floor inside a range (no tile's hexagon shows), spilling up to about
        // half a tile onto the land around; the footprints' scree widens it below the summits.
        float rockD = -kRockK * apothem * log(max(rockE, 1e-20));
        float rockWobble = (nz.r - 0.5) * 0.6 + (d.coarse.r - 0.5) * 0.35 + (nz.b - 0.5) * 0.25;
        float rockIn = mix(0.62, 1.0, smoothstep(0.85, 1.25, rockN)) * apothem;   // a lone peak's apron is smaller
        float rock = 1.0 - smoothstep(rockIn, rockIn + 0.36 * apothem, rockD + rockWobble * apothem);
        rock = max(rock, smoothstep(0.1, 0.45, rel.a) * 0.85);
        float valley = smoothstep(1.02, 1.42, rockN + (nz.g - 0.5) * 0.2);
        float gridRock = rock;   // no grid on rock
        if (landMask > 0.0) {
            float3 alb = b.landW > 0.0 ? b.landAlb / b.landW : tileAlbedo(me, u);
            const float eps = 0.003;
            if (mA.x > eps) land += mA.x * paintGrass(alb, d);
            if (mA.y > eps) land += mA.y * paintPlains(alb, d);
            if (mA.z > eps) land += mA.z * paintDesert(alb, d, featTex, u);
            if (mA.w > eps) land += mA.w * paintTundra(alb, d);
            if (mB.x > eps) land += mB.x * paintSnow(alb, d, coarseTex, featTex, u);
            if (mB.y > eps) land += mB.y * paintForest(alb, d, featTex, u);
            if (mB.z > eps) land += mB.z * paintJungle(alb, d);
            if (mB.w > eps) land += mB.w * paintMarsh(alb, d, mB.w, featTex, u);
            if (mC.x > eps) land += mC.x * paintFloodplain(alb, d, rv.e, apothem);
            // Mountain floor over the terrain: scree around the summits, cool shade in the
            // valleys where neighboring mountains' patches overlap, stones in the talus fans.
            if (rock > 0.001) {
                float3 rockAlb = mix(float3(0.52, 0.49, 0.45), alb, 0.3 + 0.3 * mA.z);
                land = mix(land, paintRock(rockAlb, d, rel.a, valley), rock);
            }

            // Shore: a sand band (gravel in the cold, dark mud and reeds by forest, jungle and bog
            // water, none under snow or cliffs), darker where the swash has just wet it.
            float beachWidth = (2.5 + 4.5 * nz.b) * (1.0 - mB.x) * (1.0 - 0.7 * rock);
            float muddy = saturate(mB.y + mB.z + mB.w) * mix(0.6, 1.0, water3.z);
            float3 sand = mix(float3(0.88, 0.81, 0.62), float3(0.66, 0.65, 0.60), mA.w);
            sand = mix(sand, float3(0.40, 0.37, 0.26), muddy);
            float beach = 1.0 - smoothstep(beachWidth * 0.55, beachWidth + aaShore, shore);
            land = mix(land, sand * (0.94 + 0.12 * d.fine.r), beach * 0.85);
            float reeds = smoothstep(0.1, 0.5, sgn01(d.fine.r)) * muddy
                        * (1.0 - smoothstep(beachWidth * 0.8, beachWidth * 1.6, shore)) * smoothstep(0.0, 1.5, shore);
            land = mix(land, float3(0.62, 0.55, 0.30), reeds * 0.7);
            float swashAmp = 1.0 - smoothstep(1.0, 1.5, fp);   // far away the swash stops moving
            float swash = 1.6 + 0.9 * sin(6.2831853 * cycles(time, 516.0) + nz.a * 9.0) * swashAmp;
            float wet = (1.0 - smoothstep(swash * 0.5, swash + aaShore, shore)) * step(0.01, beachWidth);
            land = mix(land, land * float3(0.76, 0.78, 0.82), wet * 0.8);

            // Oasis: a pond in the middle of the tile, a wet rim and a lush ring.
            if (me.feature == 5u && meFog != 2u) {
                float dd = length(local / float2(1.0, 0.82)) / size + (nz.b - 0.5) * 0.12;
                float aa = fp / size;
                float pond = 1.0 - smoothstep(0.23 - aa, 0.23 + aa, dd);
                float rim = (1.0 - smoothstep(0.23, 0.29, dd)) * (1.0 - pond);
                float ring = (1.0 - smoothstep(0.28, 0.5, dd)) * (1.0 - pond);
                land = mix(land, paintGrass(float3(0.30, 0.52, 0.22), d), ring * 0.9);
                land = mix(land, float3(0.52, 0.47, 0.34), rim * 0.8);
                land = mix(land, waterRamp(0.04 + 0.5 * smoothstep(0.0, 0.18, 0.23 - dd), u), pond);
            }

            // Improvements as the viewer knows them: farm fields in whole plots, so farmland
            // runs on across neighboring farms and ends along plot edges (also a little way into
            // the tiles beside it), off the beach; a pasture's fenced paddock in the middle of
            // its tile.
            if (kGroundFields && farms != 0u && farmNear < 0.6 * size) {
                land = markFields(land, smoothstep(2.0, 6.0, shore), farms, alb, p, local, tw, size, fp, d.fine, d.coarse, nz, u);
            }
            if (meImprovement == 3u) {
                land = markPasture(land, local, size, fp, me.noiseOffset, d.fine, nz);
            }

            rlight = groundReliefLight(rel, sun, mB.x);
            land = groundRelight(land, rlight);
        }

        // -------------------------------------------------------- water
        float3 water = float3(0.0);
        if (landMask < 1.0) {
            float lake = water3.z, sea = 1.0 - lake;
            float out = max(-shore, 0.0);
            // One depth field: shallow at the shore, deepening across the shelf (coast tiles),
            // a soft but defined drop-off at the shelf's edge, deep blue beyond.
            float shelfDepth = 0.08 + 0.42 * smoothstep(0.0, apothem * 1.1, out);
            float drop = smoothstep(-aaShelf - 3.0, aaShelf + 3.0, -shelfD);
            float deep = 0.66 + 0.34 * smoothstep(0.0, apothem * 1.5, -shelfD) + (nz.g - 0.5) * 0.12;
            water = waterRamp(mix(shelfDepth, deep, drop), u);
            water += float3(0.02, 0.04, 0.04) * exp(-(shelfD - 2.5) * (shelfD - 2.5) / 12.0) * sea;  // the shelf's lip
            if (lake > 0.001) {
                // Lakes: calm, a pale rim, a cooler darker middle and a faint sky reflection.
                float ld = smoothstep(0.0, apothem * 0.9, out);
                float3 lc = mix(waterRamp(0.1, u), u.terrain[7].rgb, smoothstep(0.1, 0.8, ld));
                lc = mix(lc, lc * float3(0.84, 0.9, 0.97), smoothstep(0.6, 1.0, ld));
                lc += float3(0.05, 0.06, 0.07) * smoothstep(0.45, 0.75, nz.g) * ld;
                water = mix(water, lc, lake);
            }
            float fade = 1.0 - smoothstep(1.0, 3.0, fp);

            // Slow wind slicks and soft swells, lit by a difference toward the sun.
            float slick = noise.sample(kRepeat, nuv + float2(cycles(time, 7.0), cycles(time, 5.0)), nGrad).g;
            water *= 0.95 + 0.1 * slick;
            gradient2d sGrad = gradient2d(dpx * 2.0 / (tw * P), dpy * 2.0 / (tw * P));
            float2 suv = nuv * 2.0 + float2(cycles(time, 14.0), cycles(time, 9.0));
            float s0 = noise.sample(kRepeat, suv, sGrad).r;
            float s1 = noise.sample(kRepeat, suv + toSun * 0.006, sGrad).r;
            float swell = clamp((s1 - s0) * 40.0, -1.0, 1.0);
            float depth01 = smoothstep(0.2, 0.9, mix(0.3, 1.0, drop));
            // (calmer when zoomed out, where the swells would read as a rough texture)
            float swellAmp = 0.05 * mix(1.0, 0.55, smoothstep(0.4, 1.2, fp));
            water *= 1.0 + swell * swellAmp * (0.4 + 0.6 * depth01) * mix(1.0, 0.4, lake);

            // Wave crests: short painted dashes riding the swells, sparser in the shallows; and
            // a few sun glints that twinkle.
            float dashSize = wrapFit(256.0, u);
            float2 cuv = p / dashSize + float2(cycles(time, 20.0), cycles(time, 7.0));
            gradient2d cg = gradient2d(dpx.yx / dashSize, dpy.yx / dashSize);
            float dash = smoothstep(0.62, 0.8, fineTex.sample(kRepeat, cuv.yx, cg).r);  // blades turned sideways
            dash *= smoothstep(0.5, 0.75, s0) * smoothstep(0.2, 0.7, depth01) * sea;
            water = mix(water, water * 1.15 + float3(0.06, 0.07, 0.07), dash * 0.5 * fade);
            float2 guv = p / fineSize + float2(cycles(time, 14.0), -cycles(time, 11.0));
            gradient2d gg = gradient2d(dpx / fineSize, dpy / fineSize);
            float glint = smoothstep(0.7, 0.95, fineTex.sample(kRepeat, guv, gg).g) * smoothstep(0.2, 0.9, swell);
            glint *= 0.5 + 0.5 * sin(6.2831853 * cycles(time, 1318.0) + nz.b * 40.0);
            water += glint * float3(0.42, 0.40, 0.32) * fade * (1.0 - smoothstep(0.4, 1.0, fp));

            // Reef: one structure. Along its seaward rim a crest of coral beds (brain corals,
            // boulders, table plates and knob clusters on rubble and algae) crowds together, parted
            // by sandy channels, with surf breaking just outside it; inside lies a calm turquoise
            // lagoon over pale sand with a few patch reefs, hazier with depth. Colonies come in
            // sizes more than three to one. Sun-bleached, muted tones drawn toward the water: the
            // shallows stay less saturated than the coast water, and the lagoon's edge is ragged.
            if (water3.x > 0.01) {
                // Distance into the reef (apothems, + inside), recovered from the blend's logistic
                // profile across an edge, then bent by noise so no rim follows a hex edge.
                float wx = clamp(water3.x, 0.002, 0.998);
                float xr = log(wx / (1.0 - wx)) / kKS;
                float xs = xr + (nz.r - 0.5) * 0.8 + (nz.b - 0.5) * 0.5;
                float reef = smoothstep(-0.22, 0.1, xs);
                // The crest: from the lagoon's seaward rim about a third of a tile inward.
                float xin = xr + (nz.a - 0.5) * 0.5 + (d.coarse.g - 0.5) * 0.15;
                float crest = smoothstep(-0.12, 0.0, xs) * (1.0 - smoothstep(0.28, 0.55, xin));
                float3 lagoon = mix(float3(0.56, 0.73, 0.71), float3(0.64, 0.76, 0.70), d.coarse.r);
                water = mix(water, mix(lagoon, water, 0.25), reef * 0.75);
                float rs = wrapFit(kReefSize, u);
                gradient2d rg = gradient2d(dpx / rs, dpy / rs);
                float4 cr = coralTex.sample(kRepeat, p / rs, rg);
                // Beds crowd the crest, parted by sandy channels; a few patch reefs dot the lagoon.
                // On the crest a second, larger layer of colonies fills in beneath the first.
                float bedField = nz.g * 0.3 + nz.r * 0.2 + d.coarse.r * 0.5;
                float crestBed = smoothstep(0.35, 0.43, bedField) * crest;
                float bed = max(crestBed, smoothstep(0.6, 0.68, bedField) * 0.75 * reef * (1.0 - crest));
                if (crestBed > 0.01) {
                    float4 cr2 = coralTex.sample(kRepeat, p * 0.77 / rs + float2(0.31, 0.57),
                                                   gradient2d(dpx * 0.77 / rs, dpy * 0.77 / rs));
                    float under = cr2.r * crestBed * (1.0 - cr.r);
                    cr = float4(cr.r + under, mix(cr.g, cr2.g, under), mix(cr.b, cr2.b, under), max(cr.a, cr2.a * crestBed));
                }
                // Rubble and algae: a sandy ochre ridge under the colonies, mottled; patch reefs
                // only shade the sand around their heads.
                float3 rubble = float3(0.70, 0.65, 0.52) * (0.86 + 0.26 * d.fine.r);
                water = mix(water, rubble, crestBed * 0.5);
                water *= 1.0 - cr.a * 0.3 * bed;
                float3 coral = coralColor(fract(cr.b * 0.37 + nz.g * 1.3 + nz.r * 0.2)) * (0.55 + 0.8 * cr.g);
                water = mix(water, mix(coral, water, mix(0.55, 0.28, crest)), saturate(cr.r) * bed);
                // Surf breaks just outside the crest, white and broken.
                float lip = smoothstep(-0.26, -0.11, xs) * (1.0 - smoothstep(-0.11, 0.03, xs));
                float surf = lip * smoothstep(0.4, 0.7, d.coarse.g + 0.25 * sin(6.2831853 * cycles(time, 360.0) + nz.a * 7.0));
                water = mix(water, float3(0.90, 0.95, 0.96), surf * 0.65 * fade);
            }

            // Foam: a bright swash line at the waterline and bands washing in toward the shore.
            // Both fade before they can crawl when zoomed out, and the swash stops moving.
            float swashAmp = 1.0 - smoothstep(1.0, 1.5, fp);
            float sw = sin(6.2831853 * cycles(time, 516.0) + nz.a * 9.0) * 0.8 * swashAmp;
            float lineW = max(1.7, 1.5 * aaShore);
            float line = 1.0 - smoothstep(0.3 * lineW, lineW + aaShore, out + sw * 0.6);
            float phase = out / 5.0 + cycles(time, 792.0) + nz.r * 2.0;
            float band = smoothstep(0.62, 0.8, fract(phase)) * (1.0 - smoothstep(0.84, 0.98, fract(phase)));
            band *= (1.0 - smoothstep(2.0, 13.0, out)) * smoothstep(0.35, 0.65, d.coarse.r + nz.b * 0.4) * sea;
            band *= 1.0 - smoothstep(1.0, 2.0, fp);
            float foam = saturate(line * (0.3 + 0.6 * sea) + band * 0.5);
            water = mix(water, float3(0.92, 0.96, 0.97), foam);

            // Pack ice: floes crowd together and close into a sheet toward the heart of an ice
            // tile (and the polar cap past the edge of the world), and break up and thin out
            // along the pack's ragged edge. Floes come at three scales: plates about 0.7 tiles
            // across, cut by the middle scale's cracks where the pack loosens and by the small
            // scale's into brash at its very edge, so sizes run more than five to one; a gap
            // shrinks them apart. Their borders wander (the floe field is drawn on a warped plane)
            // and their corners are rounded. Each floe is a low slab: a sunlit rim on its upper-left
            // edges, a cool blue side on its lower right, a short shadow on the water beside it and
            // pale aqua where its foot shows through. Leads inside the pack skin over with grey
            // new ice. Floes stay well below the snow in value and lean blue, so ice never reads
            // as snow-covered land. Zoomed out, floes average into soft coverage.
            if (water3.y > 0.01) {
                float pack = smoothstep(0.15, 0.85, water3.y + (nz.g - 0.5) * 0.45 + (nz.b - 0.5) * 0.25);
                float gap = mix(0.45, 0.07, pack);
                float wE = 1.5 * fp / (coarseSize / 22.0);           // a pixel, in middle-cell units
                float near = 1.0 - smoothstep(0.08, 0.2, wE);        // floes resolvable on screen
                float aw = wE + 0.015;
                float broken = smoothstep(0.3, 0.6, 1.0 - pack + (nz.a - 0.5) * 0.9);
                float brash = smoothstep(0.55, 0.85, 1.0 - pack + (nz.r - 0.5) * 0.7);
                float bigSize = wrapFit(kCoarseSize * 2.3, u), bigScale = bigSize / coarseSize;
                float smallSize = wrapFit(kCoarseSize * 0.42, u), smallScale = smallSize / coarseSize;
                float wob = (nz.b - 0.5) * 0.08;
                // Distance into the floe (middle-cell units) at p and a step toward and away from
                // the sun. Some plates in the closed pack are cracked into smaller floes too.
                float2 off = toSun * 1.4;
                float4 big = sampleWorld(coarseTex, p, bigSize, d);
                float4 sml = sampleWorld(coarseTex, p, smallSize, d);
                float split = max(broken, smoothstep(0.64, 0.7, big.a));
                float cut = (1.0 - split) * 4.0, cutS = (1.0 - brash) * 4.0;
                float cb = min(min(big.b * bigScale, d.coarse.b + cut), sml.b * smallScale + cutS) + wob;
                float id = mix(mix(big.a, d.coarse.a, split), sml.a, brash);   // each floe its own tone
                float sT = min(sampleWorld(coarseTex, p + off, bigSize, d).b * bigScale,
                               sampleWorld(coarseTex, p + off, coarseSize, d).b + cut) + wob;
                float sA = min(sampleWorld(coarseTex, p - off, bigSize, d).b * bigScale,
                               sampleWorld(coarseTex, p - off, coarseSize, d).b + cut) + wob;
                if (brash > 0.001) {
                    sT = min(sT, sampleWorld(coarseTex, p + off, smallSize, d).b * smallScale + cutS + wob);
                    sA = min(sA, sampleWorld(coarseTex, p - off, smallSize, d).b * smallScale + cutS + wob);
                }
                // Each floe shrinks by its own share of the gap, so the pack's edge breaks into
                // scattered floes rather than one outline.
                float g = gap * mix(0.75, 1.3, id);
                float onFloe = smoothstep(g - aw, g + aw, cb);
                float floe = mix(smoothstep(0.22, 0.5, pack), onFloe, near);
                float litRim = (1.0 - smoothstep(g - aw, g + aw, sT)) * onFloe;
                float sideRim = (1.0 - smoothstep(g - aw, g + aw, sA)) * onFloe;
                float cast = smoothstep(g - aw, g + aw, sT) * (1.0 - onFloe);
                float foot = smoothstep(g - 0.14, g - 0.01, cb) * (1.0 - onFloe);
                float3 lead = mix(water * float3(0.80, 0.88, 0.92), float3(0.57, 0.66, 0.73), pack * pack * 0.85);
                lead = mix(lead, float3(0.38, 0.62, 0.70), foot * 0.25 * near * (1.0 - pack));
                lead *= 1.0 - cast * 0.28 * near;
                float3 top = mix(float3(0.68, 0.77, 0.85), float3(0.81, 0.87, 0.92), id * 0.6 + nz.b * 0.4);
                top = mix(top, float3(0.87, 0.90, 0.93), smoothstep(0.55, 0.85, d.fine.g) * 0.3 * near);  // fresh snow
                top = mix(top, float3(0.93, 0.93, 0.90), litRim * 0.55 * near);
                top = mix(top, top * float3(0.64, 0.74, 0.88), sideRim * 0.55 * near);
                // Zoomed out, the leads and shaded rims can no longer be drawn: keep their share of
                // the pack's tone so the ice stays as deep (and as distinct from snow) as close up.
                float3 ice = mix(lead, top, floe) * mix(float3(0.91, 0.935, 0.97), float3(1.0), near);
                water = mix(water, ice, smoothstep(0.02, 0.2, water3.y));
            }
        }

        col = mix(water, land, landMask);

        // -------------------------------------------------------- rivers
        float gridMask = 1.0;
        if (riverNear) {
            float river = (1.0 - smoothstep(-0.7 * fp, 0.7 * fp, rv.e)) * smoothstep(-2.0, 1.0, shore);
            float bank = (1.0 - smoothstep(0.0, rv.hw * 1.4 + 1.5 * fp, rv.e)) * landMask;
            // The same water ramp as lakes and the sea: shallow at the banks, deeper mid-stream,
            // so inflows match the water they run into. Glints drift slowly over the stream (in
            // no particular direction: which way a river runs depends on land the player may not
            // have seen).
            float x = rv.across;
            float3 rcol = waterRamp(0.06 + 0.34 * (1.0 - x * x), u);
            gradient2d gG = gradient2d(dpx * 3.0 / (tw * P), dpy * 3.0 / (tw * P));
            float gl = noise.sample(kRepeat, nuv * 3.0 + float2(cycles(time, 36.0), -cycles(time, 24.0)), gG).b;
            float flow = smoothstep(0.6, 0.82, gl) * (1.0 - abs(x) * 0.8) * (1.0 - smoothstep(0.5, 1.5, fp));
            rcol = mix(rcol, rcol * 1.12 + float3(0.10, 0.12, 0.11), flow * 0.7);
            col = mix(col, col * float3(0.80, 0.86, 0.74), bank * 0.6);
            // At a mouth, the river's paler water fans out a little way into the sea or lake.
            float plume = exp(-max(rv.e, 0.0) / (apothem * 0.3)) * (1.0 - landMask);
            col = mix(col, waterRamp(0.12, u), plume * 0.35);
            col = mix(col, rcol, river);
            gridMask = (1.0 - river) * (1.0 - 0.6 * bank);
        }

        // -------------------------------------------------------- grid
        // A faint guide, never a design element: even width in pixels (the distance to the
        // nearest edge over its screen-space gradient), a little uneven in width and strength so
        // it reads hand-drawn, a warm darker tone of the ground under it rather than black,
        // strength by surface (strongest on grass, invisible on water, ice and rock), weaker on
        // dimmed ground, and fading out as tiles get small on screen.
        float2 gn = kNormals[nearest];
        float gradPx = length(float2(dot(gn, dpx), dot(gn, dpy)));
        float edgePx = minD / max(gradPx, 1e-5);
        float tilePx = tw / max(fp, 1e-5);
        float wobble = d.coarse.g * 0.6 + nz.a * 0.4;
        float line = 1.0 - smoothstep(0.3, 1.2 + 0.5 * wobble, edgePx);
        float surface = dot(mA, float4(0.088, 0.066, 0.062, 0.066)) + dot(mB, float4(0.046, 0.075, 0.075, 0.062))
                      + mC.x * 0.064;
        surface *= landMask * (1.0 - gridRock);
        float grid = line * smoothstep(30.0, 80.0, tilePx) * (u.options.x / 0.14) * gridMask * surface * (0.7 + 0.45 * wobble);
        grid *= mix(1.0, 0.6, smoothstep(0.15, 0.85, b.eSum / b.eW));
        col = mix(col, col * float3(0.80, 0.75, 0.66), saturate(grid / 0.25));

        // Renderer inputs on explored ground (M1 §15): the territory's tint, the movement
        // range's wash and the settler scores. Unexplored tiles show none of them; the explored
        // fog below dims the first two with the ground, while the scores' wash goes on over it,
        // so remembered land keeps their tiers.
        if (meKnown) {
            if (me.owner != 0u) col = markTerritory(col, me.owner, ownEdge, apothem, u.eye.w);
            if (meInRange) col = markRange(col, rangeEdge, apothem);
            scoreTier = (me.marks >> kTileScoreShift) & 7u;
        }
    }

    // Debug view: the relief's light factor alone (its effect on a grey ground), as grey at
    // half scale.
    if (u.options.y > 0.5) return float4(float3(dot(groundRelight(float3(0.5), rlight), float3(0.2126, 0.7152, 0.0722))), 1.0);

    // ------------------------------------------------------------ fog of war
    float E = b.eSum / b.eW;
    if (E > 0.001) col = mix(col, applyExploredFog(float4(col, 1.0)).rgb, smoothstep(0.15, 0.85, E));
    if (scoreTier != 0u) col = markScore(col, scoreTier, minD, apothem, smoothstep(0.15, 0.85, E));
    if (anyHid) {
        // The bank's soft shadow falls toward the lower right, onto the explored ground beside
        // it: the wide unexplored field, shifted toward the sun by its analytic gradient.
        float U = b.uSum / b.uW;
        float2 gradU = (kKU / apothem) * (b.uG - U * b.uGW) / b.uW;
        float Ush = U + dot(gradU, toSun) * 0.8 * apothem;
        float shadow = smoothstep(0.32, 0.68, Ush) * (1.0 - cloud.cover);
        col *= 1.0 - shadow * float3(0.34, 0.31, 0.24);
        col = mix(col, cloud.color, cloud.cover);
    }

    // Past the edge of the world the polar pack fades into a pale haze (`groundPolarHaze`).
    float worldH = u.map.z * (u.dims.y - 1.0) + 2.0 * size;
    float beyond = max(-p.y, p.y - worldH);
    if (u.dims.z < 0.5) beyond = max(beyond, max(-p.x, p.x - u.map.w));
    beyond /= tw;
    float hazed = 0.0;
    if (beyond > -1.0) {
        // Over the cloud bank, the billows' tops rise through the haze and the gaps between
        // them fill first, so the bank meets the haze along its billows, never a straight line.
        PolarHaze haze = groundPolarHaze(beyond, cloud.cover * (cloud.height - 0.35) * 2.2, d, toSun, noise, u);
        col = mix(col, haze.color, haze.alpha);
        hazed = haze.alpha;
    }
    // Cloud shadows fall on the ground, not on the haze over it.
    return applyAtmosphere(float4(col, 1.0), float3(p, 0.0), in.position, u, 1.0 - hazed);
}
"""#

    static let groundBake = #"""
// ---------------------------------------------------------------- ground (bake)

struct GroundBakeParams {
    float4 relief; // texel size, origin x, origin y, texels per tile width
    float4 blur;   // y: footprints present (0/1), w: wraps in x
};

namespace gnd {

// Gradient noise on an integer lattice; `per` > 0 wraps that axis (tileable textures, map wrap).
static float gnoise(float2 p, int2 per, int seed) {
    float2 i = floor(p), f = p - i;
    int2 c = int2(i);
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float v[4];
    for (int k = 0; k < 4; k++) {
        int2 o = int2(k & 1, k >> 1);
        int2 g = c + o;
        if (per.x > 0) g.x = ((g.x % per.x) + per.x) % per.x;
        if (per.y > 0) g.y = ((g.y % per.y) + per.y) % per.y;
        float a = hash2(g.x + seed * 7919, g.y - seed * 3571) * 6.2831853;
        v[k] = dot(float2(cos(a), sin(a)), f - float2(o));
    }
    return mix(mix(v[0], v[1], w.x), mix(v[2], v[3], w.x), w.y);
}

// Fractal gradient noise, roughly in [0, 1]. `cells` = lattice cells over the period.
static float gfbm(float2 uv, int cells, int octaves, int2 wrap, int seed) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    int c = cells;
    for (int o = 0; o < octaves; o++) {
        sum += gnoise(uv * float(c), int2(wrap.x * c, wrap.y * c), seed + o * 31) * amp;
        norm += amp;
        amp *= 0.5;
        c *= 2;
    }
    return saturate(0.5 + sum / norm * 0.95);
}

// Gradient noise at `freq` cycles per tile width, its x period fitted to the map width when the
// map wraps (`mapW` > 0), so the baked relief joins seamlessly at the seam.
static float wnoise(float2 np, float freq, int mapW, int seed) {
    if (mapW <= 0) return gnoise(np * freq, int2(0), seed);
    int per = max(1, int(round(float(mapW) * freq)));
    return gnoise(float2(np.x * float(per) / float(mapW), np.y * freq), int2(per, 0), seed);
}

// ---- painted marks (texture bombing on a wrapped cell grid)

static int2 wrapCell(int2 c, int cells) { return int2(((c.x % cells) + cells) % cells, ((c.y % cells) + cells) % cells); }

static float rnd(int2 cell, int k, int salt) { return hash2(cell.x * 13 + k * 7 + salt * 101, cell.y * 17 - salt * 59 + k); }

// Distance to a capsule from a to b whose radius tapers from r0 to r1.
static float capsule(float2 p, float2 a, float2 b, float r0, float r1) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(r0, r1, h);
}

// Keeps the two top-most marks under a texel, so overlapping strokes layer like paint.
struct Layers {
    float c1, t1, z1, c2, t2, z2;
};

static void addMark(thread Layers& l, float cov, float tone, float z) {
    if (cov <= 0.002) return;
    if (z > l.z1) {
        l.c2 = l.c1; l.t2 = l.t1; l.z2 = l.z1;
        l.c1 = cov; l.t1 = tone; l.z1 = z;
    } else if (z > l.z2) {
        l.c2 = cov; l.t2 = tone; l.z2 = z;
    }
}

static float resolve(Layers l, float bg) { return mix(mix(bg, l.t2, l.c2), l.t1, l.c1); }

// Signed tone in [-1, 1]: `lightShare` of the marks are light, the rest dark, never near zero.
static float markTone(float v, float lightShare) {
    return v < lightShare ? mix(0.35, 1.0, v / lightShare) : -mix(0.35, 1.0, (v - lightShare) / (1.0 - lightShare));
}

// Strokes: `cells` per side, `count` per cell, angle around `angle` (radians); lengths and
// widths in texels; result is the tone encoded around 0.5.
static float strokes(float2 x, float N, int cells, int count, int reach, float angle, float jitter,
                     float2 len, float2 wid, float lightShare, int salt) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    Layers l = { 0, 0, -1, 0, 0, -1 };
    for (int dy = -reach; dy <= reach; dy++) {
        for (int dx = -reach; dx <= reach; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            for (int k = 0; k < count; k++) {
                float2 ctr = (float2(c) + float2(rnd(w, k, salt), rnd(w, k, salt + 1))) * cs;
                float a = angle + (rnd(w, k, salt + 2) - 0.5) * 2.0 * jitter;
                float L = mix(len.x, len.y, rnd(w, k, salt + 3));
                float r = mix(wid.x, wid.y, rnd(w, k, salt + 4)) * 0.5;
                float2 dir = float2(cos(a), sin(a));
                float dist = capsule(x, ctr - dir * L * 0.5, ctr + dir * L * 0.5, r, r * 0.25);
                float cov = 1.0 - smoothstep(-0.6, 0.6, dist);
                addMark(l, cov, 0.5 + 0.5 * markTone(rnd(w, k, salt + 5), lightShare), rnd(w, k, salt + 6));
            }
        }
    }
    return resolve(l, 0.5);
}

// Irregular lobed daubs (soft-edged), tones in [-1, 1] around 0.5.
static float daubs(float2 x, float N, int cells, int count, float2 radius, float softness, int salt) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    Layers l = { 0, 0, -1, 0, 0, -1 };
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            for (int k = 0; k < count; k++) {
                float2 ctr = (float2(c) + float2(rnd(w, k, salt), rnd(w, k, salt + 1))) * cs;
                float a = rnd(w, k, salt + 2) * 3.14159;
                float r = mix(radius.x, radius.y, rnd(w, k, salt + 3));
                float aspect = mix(0.55, 1.0, rnd(w, k, salt + 4));
                float2 q = x - ctr;
                q = float2(dot(q, float2(cos(a), sin(a))), dot(q, float2(-sin(a), cos(a)))) / float2(1.0, aspect);
                float th = atan2(q.y, q.x);
                float lobes = 1.0 + 0.2 * sin(3.0 * th + rnd(w, k, salt + 7) * 6.28)
                                  + 0.12 * sin(5.0 * th + rnd(w, k, salt + 8) * 6.28)
                                  + 0.06 * sin(9.0 * th + rnd(w, k, salt + 9) * 6.28);
                float dist = length(q) - r * lobes;
                float cov = 1.0 - smoothstep(-softness, softness, dist);
                float tone = rnd(w, k, salt + 5) * 2.0 - 1.0;
                addMark(l, cov, 0.5 + 0.5 * tone, rnd(w, k, salt + 6));
            }
        }
    }
    return resolve(l, 0.5);
}

// Sparse dots: 1 at a dot, 0 elsewhere.
static float speckle(float2 x, float N, int cells, float chance, float2 radius, int salt) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    float v = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            if (rnd(w, 0, salt) > chance) continue;
            float2 ctr = (float2(c) + float2(rnd(w, 1, salt), rnd(w, 2, salt))) * cs;
            float r = mix(radius.x, radius.y, rnd(w, 3, salt));
            float cov = 1.0 - smoothstep(r - 0.6, r + 0.6, length(x - ctr));
            v = max(v, cov * mix(0.5, 1.0, rnd(w, 4, salt)));
        }
    }
    return v;
}

// Pebbles pre-lit by the sun from the upper left: 0.5 bare ground, above 0.5 stone (brighter
// = lit side), below 0.5 the stone's shadow falling to the lower right.
static float pebbles(float2 x, float N, int cells, float chance, float2 radius, int salt) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    float2 sunDir = normalize(float2(-0.55, 0.45));
    float v = 0.5;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            if (rnd(w, 0, salt) > chance) continue;
            float2 ctr = (float2(c) + float2(0.2, 0.2) + float2(rnd(w, 1, salt), rnd(w, 2, salt)) * 0.6) * cs;
            float r = mix(radius.x, radius.y, pow(rnd(w, 3, salt), 2.5));   // many small, few large
            float aspect = mix(0.6, 0.95, rnd(w, 4, salt));
            float a = rnd(w, 5, salt) * 3.14159;
            float2 rot = float2(cos(a), sin(a));
            float2 q = x - ctr;
            q = float2(dot(q, rot), dot(q, float2(-rot.y, rot.x)));
            float2 e = q / (r * float2(1.0, aspect));
            float dist = length(e);
            // Shadow: the same ellipse pushed away from the sun.
            float2 qs = x - ctr + sunDir * r * 0.55;
            qs = float2(dot(qs, rot), dot(qs, float2(-rot.y, rot.x)));
            float shadow = 1.0 - smoothstep(0.85, 1.25, length(qs / (r * float2(1.0, aspect))));
            if (dist < 1.0 + 0.6 / r) {
                // Dome normal, rotated back to texture space, lit by the sun.
                float2 nl = e * 0.8;
                float2 nw = float2(nl.x * rot.x - nl.y * rot.y, nl.x * rot.y + nl.y * rot.x);
                float shade = saturate(0.55 + dot(nw, sunDir) * 0.6);
                float cov = 1.0 - smoothstep(1.0 - 0.6 / r, 1.0 + 0.6 / r, dist);
                v = mix(v, 0.56 + 0.44 * shade, cov);
            } else if (shadow > 0.0 && v <= 0.5) {
                v = min(v, 0.5 - 0.5 * shadow);
            }
        }
    }
    return v;
}

// Ice floes: Voronoi cells on a wrapped grid, fully jittered (no grid shows) and drawn on a
// warped plane, so every border wanders instead of running straight. x = distance into the floe
// from its border, over the cell size, with the corners rounded off (a smooth minimum with the
// third-nearest site) and the crease along the border softened; y = random value of the floe.
static float2 floeField(float2 x, float N, int cells, int salt) {
    float cs = N / float(cells);
    float2 uv = x / N;
    int f1 = cells, f2 = cells * 3;
    float2 warp = float2(gnoise(uv * float(f1), int2(f1), salt + 1), gnoise(uv * float(f1), int2(f1), salt + 2)) * 0.32
                + float2(gnoise(uv * float(f2), int2(f2), salt + 3), gnoise(uv * float(f2), int2(f2), salt + 4)) * 0.1;
    float2 xw = x + warp * cs;
    int2 base = int2(floor(xw / cs));
    float d1 = 1e9, d2 = 1e9, d3 = 1e9, id = 0.0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            float2 ctr = (float2(c) + float2(rnd(w, 0, salt), rnd(w, 1, salt))) * cs;
            float dd = length(xw - ctr);
            if (dd < d1) { d3 = d2; d2 = d1; d1 = dd; id = rnd(w, 2, salt); }
            else if (dd < d2) { d3 = d2; d2 = dd; }
            else if (dd < d3) { d3 = dd; }
        }
    }
    float e2 = (d2 - d1) / cs, e3 = (d3 - d1) / cs;
    const float k = 0.05;
    float e = -k * log(exp(-e2 / k) + exp(-e3 / k)) + k * 0.6931;
    // Round the crease along each border too, so bilinear magnification never beads a thin crack.
    e = sqrt(e * e + 0.0036) - 0.06;
    return float2(saturate(e), id);
}

// A soft composite of cloud puffs, like dabs of a soft brush: each puff is a disc shaded as a
// sphere lit from the upper left, with a soft rim, and where puffs overlap the one in front wins
// smoothly (a softmax over each puff's priority: its dome height, lifted for nearer, southern
// puffs). Sums of weight, weight * shade and weight * profile (1 at a puff's middle, 0 at its rim).
struct PuffSum {
    float w, shade, prof;
    float small;   // the small puffs' own profile (their largest)
};

// One class of puffs on a wrapped grid. Each cell holds up to two puffs (with the chances given),
// fully jittered and of varied size, so nothing lines up in rows.
static void cumulusPuffs(thread PuffSum& acc, float2 x, float N, int cells, float2 chance, float2 radius,
                         float k, int salt, bool small = false) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    float3 light = normalize(float3(-0.55, 0.45, 0.7));
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            for (int j = 0; j < 2; j++) {
                if (rnd(w, 6 * j, salt) > (j == 0 ? chance.x : chance.y)) continue;
                float2 ctr = (float2(c) + float2(rnd(w, 6 * j + 1, salt), rnd(w, 6 * j + 2, salt))) * cs;
                float r = mix(radius.x, radius.y, rnd(w, 6 * j + 3, salt));
                float2 q = (x - ctr) / r;
                float dd = dot(q, q);
                if (dd >= 1.0) continue;
                float dome = sqrt(1.0 - dd);
                float3 n = float3(q, dome);
                float shade = saturate(dot(n, light) * 0.85 + 0.15);
                // Soft feet: a puff's lower rim darkens where it settles into the bank.
                shade *= 1.0 - 0.35 * smoothstep(0.5, 1.0, dd) * saturate(0.4 - q.y);
                float alpha = 1.0 - smoothstep(0.55, 1.0, dd);
                float wt = alpha * exp(k * (r * dome - (ctr.y - x.y) * 0.35));
                acc.w += wt;
                acc.shade += wt * shade;
                acc.prof += wt * dome;
                if (small) acc.small = max(acc.small, dome * alpha);
            }
        }
    }
}

// The cloud bank's cumulus: masses, billows and puffs (radii about 1 : 0.45 : 0.18) in one
// texture. Returns the shade of all three (0.42 the bank between puffs), the shade of the masses
// and billows alone (zoomed-out views use it, so they never fill with tiny bubbles), the profile
// of the puffs in front (1 at the middle of a puff, 0 at its rim or between puffs) and that of
// the small puffs alone, which scallop the bank's edge.
static float4 cumulus(float2 x, float N, int salt) {
    // Priorities are relative to the texel, so the exponentials stay in range.
    const float k = 0.16;
    float bg = exp(-2.0 * k);
    PuffSum acc = { bg, bg * 0.42, 0.0, 0.0 };
    cumulusPuffs(acc, x, N, 6, float2(0.95, 0.6), float2(34.0, 60.0), k, salt);
    cumulusPuffs(acc, x, N, 14, float2(0.8, 0.45), float2(14.0, 28.0), k, salt + 11);
    float big = acc.shade / acc.w;
    cumulusPuffs(acc, x, N, 30, float2(0.6, 0.3), float2(5.5, 11.0), k, salt + 23, true);
    return float4(acc.shade / acc.w, big, acc.prof / acc.w, acc.small);
}

// Dune field as a height field (texels): sinuous transverse ridges across a westerly wind,
// broken into barchanoid segments whose ends curl downwind into horns. Each ridge has a long
// gentle windward ramp rising toward the east, a sharp crest and a short steep lee face. The
// ridge index only changes in the troughs, where the height is zero, so per-ridge heights never
// leave a seam. `tile` = texels per tile width.
static float duneHeight(float2 x, float N, int count, float tile, int salt) {
    float2 uv = x / N;
    float seg = smoothstep(0.36, 0.64, gfbm(uv, 5, 2, int2(1), salt + 2));
    float warp = gnoise(uv * 3.0, int2(3), salt) * 0.9 + gnoise(uv * 7.0, int2(7), salt + 1) * 0.3;
    float ph = uv.x * float(count) + warp - (1.0 - seg) * 0.35;
    float f = fract(ph);
    int idx = ((int(floor(ph)) % count) + count) % count;
    const float crest = 0.74;
    float prof = f < crest ? pow(f / crest, 1.3) : (1.0 - (f - crest) / (1.0 - crest)) * (1.0 - (f - crest) / (1.0 - crest));
    float amp = mix(0.6, 1.0, hash2(idx * 7 + salt, salt * 3 + 11));
    return 0.1 * tile * amp * seg * prof;
}

// Dunes pre-lit by the sun: 0.5 flat sand, above lit, below shade.
static float duneShade(float2 x, float N, int count, float tile, int salt) {
    float h0 = duneHeight(x, N, count, tile, salt);
    float hx = duneHeight(x + float2(1.0, 0.0), N, count, tile, salt);
    float hy = duneHeight(x + float2(0.0, 1.0), N, count, tile, salt);
    float3 n = normalize(float3(h0 - hx, h0 - hy, 1.0));
    float3 sun = normalize(float3(-0.55, 0.45, 0.70));
    return saturate(0.5 + (dot(n, sun) / sun.z - 1.0) * 0.5);
}

// Marsh pools: clusters of one to three elongated blobs merged by a smooth union, with lumpy
// shores. 0.5 at the waterline, rising 1/20 per texel inward.
static float pools(float2 x, float N, int cells, int salt) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    const float k = 5.0;
    float e = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            if (rnd(w, 0, salt) > 0.62) continue;
            float2 ctr = (float2(c) + 0.3 + 0.4 * float2(rnd(w, 1, salt), rnd(w, 2, salt))) * cs;
            float a0 = (rnd(w, 3, salt) - 0.5) * 1.4;
            int blobs = 1 + int(rnd(w, 4, salt) * 2.99);
            for (int j = 0; j < 3; j++) {
                if (j >= blobs) break;
                float aj = a0 + (rnd(w, 5 + j, salt) - 0.5) * 1.2;
                float2 off = j == 0 ? float2(0.0)
                           : float2(cos(aj), sin(aj)) * cs * mix(0.14, 0.28, rnd(w, 8 + j, salt)) * (j == 1 ? 1.0 : -1.0);
                float r = cs * mix(0.15, 0.27, rnd(w, 11 + j, salt));
                float asp = mix(0.42, 0.72, rnd(w, 14 + j, salt));
                float2 q = x - ctr - off;
                q = float2(q.x * cos(aj) + q.y * sin(aj), -q.x * sin(aj) + q.y * cos(aj));
                float dist = (length(q / float2(1.0, asp)) - r) * mix(asp, 1.0, 0.5);
                e += exp(-dist / k);
            }
        }
    }
    float dist = -k * log(max(e, 1e-20));
    float2 uv = x / N;
    dist += gnoise(uv * 12.0, int2(12), salt) * 6.0 + gnoise(uv * 32.0, int2(32), salt + 1) * 2.0;
    return saturate(0.5 - dist / 20.0);
}

// Sand ripples: thin wavy crests across a westerly wind, broken here and there. The gentle
// windward side faces the sun; the short lee drops into shade. 0.5 flat.
static float ripples(float2 x, float N, int count, int salt) {
    float2 uv = x / N;
    float warp = gnoise(uv * 5.0, int2(5), salt) * 1.6 + gnoise(uv * 13.0, int2(13), salt + 1) * 0.5;
    float f = fract(uv.x * float(count) + warp);
    float aa = float(count) / N * 1.5;
    float stoss = smoothstep(0.0, 0.1, f) * (1.0 - smoothstep(0.8 - aa, 0.8 + aa, f));
    float lee = smoothstep(0.8 - aa, 0.8 + aa, f) * (1.0 - smoothstep(1.0 - aa, 1.0, f));
    float broken = smoothstep(0.35, 0.6, gfbm(uv, 20, 2, int2(1), salt + 2));
    return 0.5 + (0.22 * stoss - 0.45 * lee) * broken;
}

// ---- coral colonies, as seen from above. Each returns (cover, shade): shade is pre-lit from the
// upper left around 0.5. `q` is relative to the colony, `r` its radius (texels).

static float2 brainCoral(float2 q, float r, float seed) {
    float e = length(q) / r, ang = atan2(q.y, q.x);
    float lump = 1.0 + 0.08 * sin(5.0 * ang + seed * 30.0) + 0.05 * sin(9.0 * ang + seed * 17.0);
    float cov = 1.0 - smoothstep(1.0 - 1.2 / r, 1.0 + 1.2 / r, e / lump);
    float dome = sqrt(saturate(1.0 - e * e));
    float2 sunDir = normalize(float2(-0.55, 0.45));
    float sh = 0.5 + dot(q / r, sunDir) * 0.4 + (dome - 0.5) * 0.12;
    // Meandering grooves over the dome.
    float g = gnoise(q / r * 2.6 + seed * 37.0, int2(0), int(seed * 1000.0));
    float groove = abs(fract(g * 3.2 + e * 1.4) - 0.5);
    sh -= (1.0 - smoothstep(0.04, 0.12, groove)) * 0.22 * dome;
    return float2(cov, saturate(sh));
}

// A massive (boulder) coral: a lumpy dome, lit from the upper left, finely pitted with polyps.
static float2 boulderCoral(float2 q, float r, float seed) {
    float e = length(q) / r, ang = atan2(q.y, q.x);
    float lump = 1.0 + 0.1 * sin(3.0 * ang + seed * 23.0) + 0.06 * sin(7.0 * ang + seed * 11.0);
    float cov = 1.0 - smoothstep(1.0 - 1.2 / r, 1.0 + 1.2 / r, e / lump);
    float dome = sqrt(saturate(1.0 - e * e));
    float2 sunDir = normalize(float2(-0.55, 0.45));
    float sh = 0.5 + dot(q / r, sunDir) * 0.42 + (dome - 0.5) * 0.15;
    sh -= 0.05 * smoothstep(0.3, 0.9, gnoise(q * 0.9 + seed * 50.0, int2(0), int(seed * 997.0) + 3)) * dome;
    return float2(cov, saturate(sh));
}

static float2 tableCoral(float2 q, float r, float seed) {
    float dd = length(q), e = dd / r, ang = atan2(q.y, q.x);
    float lump = 1.0 + 0.1 * sin(4.0 * ang + seed * 20.0) + 0.06 * sin(11.0 * ang + seed * 9.0);
    float cov = 1.0 - smoothstep(1.0 - 1.2 / r, 1.0 + 1.2 / r, e / lump);
    float2 sunDir = normalize(float2(-0.55, 0.45));
    float facing = dot(q / max(dd, 1e-3), sunDir);
    float rim = smoothstep(0.72, 0.97, e / lump);
    float sh = 0.5 + 0.06 * sin(ang * 22.0 + e * 3.0) * e + rim * facing * 0.12;
    return float2(cov, saturate(sh));
}

static float2 knobCoral(float2 q, float r, int2 w, int s) {
    float2 sunDir = normalize(float2(-0.55, 0.45));
    float m = 1e9;
    float2 mq = float2(0.0);
    for (int i = 0; i < 5; i++) {
        float2 o = (float2(rnd(w, 25 + i, s), rnd(w, 30 + i, s)) - 0.5) * r * 1.2;
        float rr = r * mix(0.2, 0.32, rnd(w, 35 + i, s));
        float dk = length(q - o) - rr;
        if (dk < m) { m = dk; mq = (q - o) / rr; }
    }
    return float2(1.0 - smoothstep(-0.7, 0.7, m), saturate(0.55 + dot(mq, sunDir) * 0.35));
}

// Coral colonies on a wrapped cell grid: r cover, g shade (pre-lit, 0.5 neutral), b colony hue,
// a the colonies' soft shadow on the sand, falling to the lower right. Colonies gather loosely
// (a low-frequency field thins them out between; the frame gathers them into beds along the
// reef's crest) and are mostly small with a few big heads
// (radii vary more than three to one): brain corals, boulders, table plates and knob clusters.
static float4 coralColonies(float2 x, float N, int cells, int salt) {
    float cs = N / float(cells);
    int2 base = int2(floor(x / cs));
    float2 sunDir = normalize(float2(-0.55, 0.45));
    float c1 = 0.0, s1 = 0.5, h1 = 0.0, z1 = -1.0, c2 = 0.0, s2 = 0.5, h2 = 0.0, z2 = -1.0, shadow = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = base + int2(dx, dy);
            int2 w = wrapCell(c, cells);
            for (int k = 0; k < 3; k++) {
                int s = salt + k * 17;
                float2 ctr = (float2(c) + float2(rnd(w, 1, s), rnd(w, 2, s))) * cs;
                float bed = gfbm(fract(ctr / N), 3, 2, int2(1), salt + 5);
                if (rnd(w, 0, s) > smoothstep(0.22, 0.5, bed) * 0.95) continue;
                float r = cs * mix(0.14, 0.48, pow(rnd(w, 3, s), 1.6));
                float2 q = x - ctr;
                if (length(q) > r * 1.5) continue;
                float type = rnd(w, 4, s), seed = rnd(w, 5, s), z = rnd(w, 6, s), hue = rnd(w, 40, s);
                // The colony's shadow: its footprint pushed away from the sun.
                float sd = length(q + sunDir * r * 0.22) / (r * (type < 0.6 ? 0.95 : 0.8));
                shadow = max(shadow, (1.0 - smoothstep(0.55, 1.05, sd)) * (type < 0.6 ? 1.0 : 0.6));
                float2 cv = type < 0.35 ? brainCoral(q, r, seed)
                          : type < 0.6 ? boulderCoral(q, r, seed)
                          : type < 0.8 ? tableCoral(q, r, seed)
                          : knobCoral(q, r, w, s);
                if (cv.x < 0.01) continue;
                if (z > z1) { c2 = c1; s2 = s1; h2 = h1; z2 = z1; c1 = cv.x; s1 = cv.y; h1 = hue; z1 = z; }
                else if (z > z2) { c2 = cv.x; s2 = cv.y; h2 = hue; z2 = z; }
            }
        }
    }
    float cover = 1.0 - (1.0 - c1) * (1.0 - c2);
    float shade = mix(mix(0.5, s2, c2), s1, c1);
    float hue = c1 > 0.5 || c2 < 0.01 ? h1 : mix(h2, h1, c1);
    return float4(cover, shade, hue, shadow * (1.0 - cover));
}

// ---- relief
// The relief is a smooth height field baked from every tile at startup: gentle undulation
// everywhere, a broad dome under each hill, massif shoulders under mountains and the bumps of
// the decorations' footprints. Every tile's share reaches at most kReliefSpill apothems past
// its own edges (see `reliefSupport`), so the frame can flatten the relief next to unexplored
// ground and never show the shape of a tile under the cloud.

// Heights (world units): hill country's broad rise, each hill tile's dome on it and the
// hillocks rolling over both; a range's massif shoulders and each mountain's crown; and a
// footprint of relative height 1. Where decorations give footprints, their mounds carry most
// of the hills' shape and the domes stay lower.
constant float kHillRise = 4.0;
constant float kHillDome = 17.0;
constant float kHillDomeSplats = 8.0;
constant float kHillRoll = 2.5;
constant float kMassifRise = 7.0;
constant float kMassifCrown = 12.0;
constant float kSplatHeight = 16.0;

// The relief's falloffs are C2 (zero slope and curvature at both ends): the lee and crowns
// come from the height's curvature, which a plain smoothstep would break into creases.
static float smootherstep(float e0, float e1, float x) {
    float t = saturate((x - e0) / (e1 - e0));
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// How much of a tile's own relief reaches offset `d` from its center: all of it in the tile's
// core, fading out by kReliefSpill apothems past its edges. Round (the distance from the center
// is never less than the hex distance, so it stays inside that reach), and pulled in further by
// `shrink` >= 0 (world noise) so landforms never trace the hexagon.
static float reliefSupport(float2 d, float apothem, float shrink) {
    float reach = apothem * (1.0 + kReliefSpill);
    return 1.0 - smootherstep(reach - 0.75 * apothem, reach, length(d) + shrink * apothem);
}

// A tile's landform: a dome around a point jittered off the tile center, stretched along the
// land's grain (a slowly turning direction that neighbors share), so the domes of neighbors
// in line merge into a ridge and those side by side part at a saddle. 1 at the top, with a
// bell profile (1 - r^2)^3 that is C2 at its foot.
static float landformDome(float2 d, float2 crown, float2 grain, float along, float across) {
    float2 q = d - crown;
    float2 e = float2(dot(q, grain) / along, dot(q, float2(-grain.y, grain.x)) / across);
    float t = saturate(1.0 - dot(e, e));
    return t * t * t;
}

// A footprint's bump: 1 at its center, 0 at its radius.
static float splatBell(float2 d, float radius) {
    float t = 1.0 - saturate(length_squared(d) / max(radius * radius, 1e-3));
    return t * t * t;
}

static float heightAt(texture2d<float, access::read> fields, int2 c, bool wraps) {
    int W = int(fields.get_width()), H = int(fields.get_height());
    c.x = wraps ? wrapIndex(c.x, W) : clamp(c.x, 0, W - 1);
    c.y = clamp(c.y, 0, H - 1);
    return fields.read(uint2(c)).r;
}

} // namespace gnd

kernel void ground_bake_noise(texture2d<float, access::write> out [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    using namespace gnd;
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    // The texture spans about six tile widths: r ~2 cycles per tile, g ~0.5, b ~4, a ~3.
    float r = gfbm(uv, 12, 3, int2(1), 1);
    float g = gfbm(uv, 3, 2, int2(1), 2);
    float b = gfbm(uv, 24, 2, int2(1), 3);
    float a = gfbm(uv, 18, 2, int2(1), 4);
    out.write(float4(r, g, b, a), gid);
}

kernel void ground_bake_detail(texture2d<float, access::write> fine [[texture(0)]],
                               texture2d<float, access::write> coarse [[texture(1)]],
                               texture2d<float, access::write> shapes [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
    using namespace gnd;
    if (gid.x >= fine.get_width() || gid.y >= fine.get_height()) return;
    float N = float(fine.get_width());
    float2 x = float2(gid) + 0.5;
    // Fine (about 4 texels per world unit): grass blades leaning north, speckle, pebbles, leaf daubs.
    float grass = strokes(x, N, 48, 3, 1, 1.5708, 0.4, float2(7.0, 14.0), float2(1.6, 2.6), 0.6, 11);
    float dots = speckle(x, N, 64, 0.22, float2(0.7, 1.4), 23);
    float stone = pebbles(x, N, 26, 0.3, float2(1.3, 6.0), 37);
    float leaf = daubs(x, N, 40, 3, float2(2.5, 5.5), 0.8, 41);
    fine.write(float4(grass, dots, stone, leaf), gid);
    // Coarse (about 1.3 texels per world unit): clumps, east-west streaks, ice floes.
    float clump = daubs(x, N, 20, 2, float2(6.0, 13.0), 3.0, 53);
    float streak = strokes(x, N, 16, 2, 2, 0.0, 0.25, float2(18.0, 40.0), float2(1.4, 2.8), 0.55, 67);
    float2 floe = floeField(x, N, 22, 79);
    coarse.write(float4(clump, streak, floe.x, floe.y), gid);
    // Shapes: the cloud bank's cumulus (shade, shade without the small puffs, profiles).
    shapes.write(cumulus(x, N, 97), gid);
}

// Feature textures. Each channel is sampled at its own world size (see the k...Size constants):
// r dunes (pre-lit), g marsh pools, b sand ripples (also snow ridges), a needle litter strokes.
// Coral: r cover, g shade, b colony hue, a shadow.
kernel void ground_bake_features(texture2d<float, access::write> features [[texture(0)]],
                                 texture2d<float, access::write> coral [[texture(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    using namespace gnd;
    if (gid.x >= features.get_width() || gid.y >= features.get_height()) return;
    float N = float(features.get_width());
    float2 x = float2(gid) + 0.5;
    float dune = duneShade(x, N, 11, N / kDuneTiles, 101);
    float pool = pools(x, N, 6, 113);
    float rip = ripples(x, N, 46, 127);
    float litter = strokes(x, N, 64, 2, 1, 0.0, 3.14159, float2(4.0, 8.0), float2(0.9, 1.4), 0.3, 131);
    features.write(float4(dune, pool, rip, litter), gid);
    coral.write(coralColonies(x, N, 11, 149), gid);
}

// Height field (world units) and footprint talus at a world point. Reads only the point's own
// tile and its six neighbors, each within its `reliefSupport`, plus world noise.
kernel void ground_bake_fields(texture2d<uint, access::read> tiles [[texture(0)]],
                               texture2d<float, access::write> out [[texture(1)]],
                               constant Uniforms& u [[buffer(0)]],
                               constant GroundBakeParams& b [[buffer(1)]],
                               constant float4* splats [[buffer(2)]],
                               constant uint* splatStart [[buffer(3)]],
                               uint2 gid [[thread_position_in_grid]]) {
    using namespace gnd;
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 p = b.relief.yz + (float2(gid) + 0.5) * b.relief.x;
    float tw = u.map.y, apothem = tw * 0.5;
    HexCell h = hexCell(p, u);
    float2 np = p / tw;
    int W = int(u.dims.x), rows = int(u.dims.y);
    bool wraps = u.dims.z > 0.5;
    int mapW = wraps ? W : 0;
    bool anySplats = b.blur.y > 0.5;
    float2 toGround = -normalize(u.sun.xy);   // where shadows and talus run (east-south-east)

    // Landform presence: each tile's support, normalized over the point's seven tiles (a
    // partition of unity), summed over hills and over mountains, so hill country is one broad
    // rise. On it every hill tile raises a dome: stretched along the land's grain, lifted or
    // lowered by slow world noise read at the tile's center (so neighbors agree and the domes
    // run into ridges, rises and saddles across several tiles) and varied by the tile's hash.
    float sn = 0.5 + wnoise(np, 1.7, mapW, 11);
    float shrink = 0.02 + 0.3 * sn * sn;   // smooth and never negative
    float ga = wnoise(np, 0.3, mapW, 21) * 7.0;
    float2 grain = float2(cos(ga), sin(ga));
    float domeHeight = anySplats ? kHillDomeSplats : kHillDome;
    float wSum = 0.0, hillW = 0.0, massifW = 0.0, domes = 0.0, peaks = 0.0, bumps = 0.0, talus = 0.0;
    for (int j = 0; j < 7; j++) {
        int2 t = int2(h.q, h.r) + (j == 0 ? int2(0) : kDirs[j - 1]);
        float2 d = j == 0 ? h.local : h.local - kNormals[j - 1] * tw;
        float support = reliefSupport(d, apothem, shrink);
        if (support <= 0.0) continue;
        wSum += support;
        if (t.y < 0 || t.y >= rows) continue;
        int col = t.x + (t.y - (t.y & 1)) / 2;
        if (wraps) col = wrapIndex(col, W); else if (col < 0 || col >= W) continue;
        TileInfo ti = fetchTile(tiles, t.x, t.y, u);
        if (isWater(ti.terrain)) continue;
        // Each tile's dome: jittered, shaped and raised by its own hash and the slow lift.
        float2 crown = (float2(hash2(col * 3 + 17, t.y * 7 + 5), hash2(col * 5 + 3, t.y * 11 + 9)) - 0.5) * 0.55 * apothem;
        float lift = saturate(0.5 + 1.4 * wnoise(np - d / tw, 0.45, mapW, 23));
        float amp = 0.45 + 0.4 * lift + 0.3 * hash2(col + 101, t.y * 13 + 7);
        float along = apothem * (1.35 + 0.35 * hash2(col * 7 + 13, t.y + 211));
        float across = apothem * (0.95 + 0.25 * hash2(col * 11 + 5, t.y * 3 + 71));
        if (ti.elevation == 1u) {
            hillW += support;
            domes += landformDome(d, crown, grain, along, across) * support * amp;
        } else if (ti.elevation == 2u) {
            massifW += support;
            peaks += landformDome(d, crown * 0.5, grain, along * 0.95, across * 1.1) * support * amp;
        }
        if (!anySplats) {
            // Without footprints, talus fans spill from where the summits stand (south of the
            // tile center), down toward the east-south-east.
            for (int f = 0; ti.elevation == 2u && f < 2; f++) {
                float2 foot = float2((hash2(col * 9 + f, t.y * 5 + 3) - 0.5) * 0.9,
                                     -0.3 - 0.35 * hash2(col + 7 * f, t.y * 3 + 1)) * apothem;
                float2 q = d - foot;
                float along = dot(q, toGround), across = dot(q, float2(-toGround.y, toGround.x));
                talus = max(talus, splatBell(float2(along - apothem * 0.3, across * 0.9), apothem * 0.6) * support);
            }
            continue;
        }
        uint index = uint(t.y * W + col);
        for (uint k = splatStart[index]; k < splatStart[index + 1]; k++) {
            float4 s = splats[k];
            float2 q = d - s.xy;
            bumps += splatBell(q, s.z) * s.w * support;
            // Scree spills from the foot of tall footprints, down toward the east-south-east.
            float along = dot(q, toGround), across = dot(q, float2(-toGround.y, toGround.x));
            float fan = splatBell(float2(along - s.z * 0.75, across * 0.8), s.z * 0.85);
            talus = max(talus, fan * smoothstep(0.45, 0.8, s.w) * support);
        }
    }
    float hills = hillW / max(wSum, 1e-4), massif = massifW / max(wSum, 1e-4);

    // Gentle undulation everywhere; hillocks roll over hill country (on a warped plane, so they
    // never line up), and a soft spine runs along each massif's grain.
    float und = wnoise(np, 0.5, mapW, 5) * 4.0 + wnoise(np, 1.3, mapW, 6) * 1.2;
    float2 warped = np + float2(wnoise(np, 0.7, mapW, 13), wnoise(np, 0.7, mapW, 17)) * 0.6;
    float roll = wnoise(warped, 1.4, mapW, 7) + 0.4 * wnoise(warped, 2.9, mapW, 8);
    float spine = wnoise(np, 1.1, mapW, 9);
    float H = und + hills * (kHillRise + kHillRoll * roll) + domes * domeHeight
            + massif * (kMassifRise + 3.0 * spine) + peaks * kMassifCrown + bumps * kSplatHeight;
    out.write(float4(H, talus, 0.0, 0.0), gid);
}

// Relief: the surface normal, the lee shade at the feet of slopes and in valleys or a crown on
// convex tops (b: 0.5 neutral, below lee, above crown), and footprint talus. Reads one texel
// around each point: with the frame's bilinear sample, that is the reach kReliefGuard allows
// for beyond kReliefSpill.
kernel void ground_bake_relief(texture2d<float, access::read> fields [[texture(0)]],
                               texture2d<float, access::write> out [[texture(1)]],
                               constant Uniforms& u [[buffer(0)]],
                               constant GroundBakeParams& b [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    using namespace gnd;
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    bool wraps = u.dims.z > 0.5;
    int2 g = int2(gid);
    float texel = b.relief.x;
    float2 f = fields.read(gid).rg;
    float x0 = heightAt(fields, g - int2(1, 0), wraps), x1 = heightAt(fields, g + int2(1, 0), wraps);
    float y0 = heightAt(fields, g - int2(0, 1), wraps), y1 = heightAt(fields, g + int2(0, 1), wraps);
    float2 grad = float2(x1 - x0, y1 - y0) / (2.0 * texel);
    float3 n = normalize(float3(-grad, 1.0));
    // Curvature: positive in hollows and at the feet of slopes, negative on crowns. The lee is
    // a hollow whose rise faces the sun (uphill toward it), deepest there; valleys get less.
    float lap = (x0 + x1 + y0 + y1 - 4.0 * f.x) / (texel * texel);
    float2 toSun = normalize(u.sun.xy);
    float facing = dot(grad, toSun) / max(length(grad), 0.25);
    float lee = smoothstep(0.0, 0.25, lap) * mix(0.3, 1.0, smoothstep(-0.3, 0.7, facing));
    float crown = smoothstep(0.0, 0.3, -lap);
    out.write(float4(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, 0.5 + 0.5 * (crown - lee), f.y), gid);
}
"""#
}
