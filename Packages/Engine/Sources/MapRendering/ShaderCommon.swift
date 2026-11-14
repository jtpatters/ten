extension Shaders {
    /// Shared declarations. Struct layouts must match `Uniforms`, `SpriteInstance` and
    /// `OverlayVertex` in `MapRenderer.swift`: everything is float4/float4x4, so no padding
    /// ambiguity. Treat this file as a frozen contract between the areas.
    static let common = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4 cameraUp;   // xyz: camera up (billboard axis), w: time in seconds
    float4 eye;        // xyz: camera eye position (world), w: zoom scale (1 = default, larger = zoomed out)
    float4 sun;        // xyz: unit vector toward the sun (world: +x east, +y north, +z up), w: 0
    float4 viewport;   // xy: render target size in pixels, z: camera pitch (0 = top-down), w: pixels per world unit at the look-at point
    float4 map;        // tile size (center-to-corner), tile width, row height, world width
    float4 dims;       // map width, map height, wraps (0/1), copies drawn (1 or 3)
    float4 ground;     // ground quad x0, y0, x1, y1
    float4 fogColor;
    float4 options;    // x: grid alpha, y: ground debug view (0 off, 1 relief light), z: fog on (1) or off (0),
                       // w: the fading tribal village's tile plus how far its plants are back (0...0.99), -1 for none
    float4 terrain[8]; // base colors by Terrain raw value
};

// One sprite. Decorations and units are separate pipelines with separate shaders; each owns
// the meaning of flags.yzw.
struct SpriteInstance {
    float4 position;   // xyz world (anchor point), w: tile index for fog (-1 = none)
    float4 sizeAnchor; // width, height, anchor x, anchor y (0..1 within the quad)
    float4 uv;         // u0, v0 (top), du, dv; du < 0 mirrors horizontally
    float4 tint;       // premultiplied multiplier
    float4 flags;      // x: billboard (1, stands toward the camera) or flat on the ground (0); yzw: per pipeline
};

struct OverlayVertex {
    float4 position;   // xyz world, w: the `OverlayStyle`
    float4 color;      // premultiplied, or the style's parameters
    float4 aux;        // more parameters (borders, the movement range's outline)
};

// ---------------------------------------------------------------- noise

static float hash2(int x, int y) {
    uint h = uint(x) * 1597334677u ^ uint(y) * 3812015801u;
    h ^= h >> 15; h *= 2246822519u; h ^= h >> 13; h *= 3266489917u; h ^= h >> 16;
    return float(h & 0x00ffffffu) / 16777215.0;
}

// Wraps x into [0, n) with float math. Apple GPUs have no integer divider, so `%` by a
// non-constant becomes a slow software routine, and these wraps sit in the hottest loops of
// the frame. The half-unit bias keeps exact multiples of n from rounding the wrong way; it is
// exact for |x| far beyond any column or lattice index used here.
static int wrapIndex(int x, int n) {
    return x - n * int(floor((float(x) + 0.5) / float(n)));
}

// Value noise; `period` (lattice cells, 0 = none) makes it tile in x for map wrap.
static float vnoise(float2 p, int period) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 s = f * f * (3.0 - 2.0 * f);
    int x0 = int(i.x), y0 = int(i.y);
    int x1 = x0 + 1, y1 = y0 + 1;
    if (period > 0) {
        x0 = wrapIndex(x0, period);
        x1 = wrapIndex(x1, period);
    }
    float a = hash2(x0, y0), b = hash2(x1, y0), c = hash2(x0, y1), d = hash2(x1, y1);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// p is in tile-width units, so a period of mapW * freq tiles exactly with the world.
static float fbm(float2 p, int freq, int mapW) {
    int per = mapW * freq;
    return 0.6 * vnoise(p * float(freq), per) + 0.4 * vnoise(p * float(freq * 2), per * 2);
}

// ---------------------------------------------------------------- tiles

struct TileInfo {
    float2 noiseOffset; // per-tile noise domain shift (from wrapped col/row)
    uint terrain;
    uint elevation;
    uint feature;
    uint rivers;
    uint fog;
    uint owner;         // territory as the viewer knows it: 0 none, else the owner's style index + 1
    uint improvement;   // `Improvement` raw value as the viewer knows it, 0 none
    uint marks;         // the whole alpha byte: fog, overlay flags, city centre
};

// The tile texture (`MapRenderer.tileBytes`), per tile:
//   r: terrain (bits 0-2), territory owner (bits 3-6: 0 none, else style index + 1),
//      improvement bit 3 (bit 7)
//   g: elevation (bits 0-1), feature (bits 2-4), improvement bits 0-2 (bits 5-7)
//   b: river edges (bits 0-5), the viewer knows the tile's resource (bit 7)
//   a: fog level (bits 0-1: 0 visible, 1 explored, 2 unexplored), movement range (bit 2),
//      a tribal village (bit 3: the plants standing on the tile hide), settler score tier
//      (bits 4-6: 0 none, 1-7), city centre (bit 7: decorations hide there)
// The renderer inputs (owner, improvement, range, score) come from the App, built from the
// viewer's knowledge; shaders still never show them on unexplored tiles.
constant uint kTileFogMask = 3u;
constant uint kTileRangeBit = 0x04u;
constant uint kTileTribalVillageBit = 0x08u;
constant uint kTileScoreShift = 4u;
constant uint kTileCityBit = 0x80u;
constant uint kTileResourceBit = 0x80u; // in b

// The `Improvement` raw value of a tile texel (0 none).
static uint tileImprovement(uint4 v) { return ((v.g >> 5) & 7u) | ((v.r >> 7) << 3); }

static TileInfo fetchTile(texture2d<uint, access::read> tiles, int q, int r, constant Uniforms& u) {
    TileInfo t;
    int W = int(u.dims.x), H = int(u.dims.y);
    int col = q + (r - (r & 1)) / 2;
    bool ok = r >= 0 && r < H;
    if (u.dims.z > 0.5) {
        col = wrapIndex(col, W);
    } else {
        ok = ok && col >= 0 && col < W;
    }
    if (!ok) {
        t.noiseOffset = float2(float(col), float(r)) * 0.37;
        t.terrain = 6; t.elevation = 0; t.feature = 0; t.rivers = 0; t.fog = 2;
        t.owner = 0; t.improvement = 0; t.marks = 2;
        return t;
    }
    uint4 v = tiles.read(uint2(uint(col), uint(r)));
    t.noiseOffset = float2(hash2(col, r), hash2(r + 911, col)) * 53.0;
    t.terrain = v.r & 7u;
    t.owner = (v.r >> 3) & 15u;
    t.elevation = v.g & 3u;
    t.feature = (v.g >> 2) & 7u;
    t.improvement = tileImprovement(v);
    t.rivers = v.b & 63u;
    t.fog = v.a & kTileFogMask;
    t.marks = v.a;
    return t;
}

static bool isWater(uint terrain) { return terrain >= 5u; } // coast, ocean, lake

// Edge normals in HexDirection order (east, southEast, southWest, west, northWest, northEast).
constant float2 kNormals[6] = {
    float2(1.0, 0.0), float2(0.5, -0.8660254), float2(-0.5, -0.8660254),
    float2(-1.0, 0.0), float2(-0.5, 0.8660254), float2(0.5, 0.8660254)
};
constant int2 kDirs[6] = { int2(1, 0), int2(1, -1), int2(0, -1), int2(-1, 0), int2(-1, 1), int2(0, 1) };

// A tile's texel by index (see `TileInfo` for the layout).
static uint4 tileTexel(texture2d<uint, access::read> tiles, uint index, constant Uniforms& u) {
    float W = u.dims.x, i = float(index);
    float row = floor((i + 0.5) / W); // float division: see wrapIndex
    return tiles.read(uint2(uint(i - row * W), uint(row)));
}

// A tile's alpha byte by index: fog level and flags.
static uint tileByte(texture2d<uint, access::read> tiles, uint index, constant Uniforms& u) {
    return tileTexel(tiles, index, u).a;
}

// Fog level of a tile by index: 0 visible, 1 explored, 2 unexplored.
static uint tileFog(texture2d<uint, access::read> tiles, uint index, constant Uniforms& u) {
    return tileByte(tiles, index, u) & kTileFogMask;
}
"""#
}
