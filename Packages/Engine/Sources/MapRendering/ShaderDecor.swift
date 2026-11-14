extension Shaders {
    /// Decoration sprites: static instances (cast shadows first, then mountains, hills, trees,
    /// plants and rocks sorted back to front). flags.x: billboard (1) or flat (0); flags.y:
    /// hide/dim by tile fog; flags.z: second fog tile index + 1 for sprites that straddle an
    /// edge (0 = none), or -(index + 1) for sprites shown only while that tile is unexplored;
    /// flags.w: packed `DecorFlags` (wind bits 0-1, level-of-detail class bits 2-3, random byte
    /// bits 4-11, cast shadow bit 12, grows-at-strategic-zoom bit 13, relief bit 14: a neighbour's
/// relief reaching onto a city centre stays; bits 15-18: shown only on a tile with that
/// improvement; bit 19: open-land clutter, hidden on farms and mines and thinned on pastures;
/// bit 20: a resource icon, shown only while the viewer knows the tile's resource).
/// A tribal village's tile hides its own plants and their shadows (`kTileTribalVillageBit`).
    static let decorSource = #"""
struct DecorOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;   // premultiplied, includes the level-of-detail fade
    float3 world;
    float dim;
    float shadow;  // < 0: a standing sprite; else a cast shadow, 0 at its foot to 1 at its tip
};

constant uint kDecorShadowBit = 1u << 12;
constant uint kDecorGrowsBit = 1u << 13;
constant uint kDecorReliefBit = 1u << 14;
constant uint kDecorNeedsShift = 15u;
constant uint kDecorClearsBit = 1u << 19;
constant uint kDecorResourceBit = 1u << 20;
// Cast shadows: the cool blue-violet of the art bible's shade, fading to 35% at the tip (the
// shadow family every pass shares).
constant float3 kDecorShadow = float3(0.10, 0.10, 0.20);
constant float kDecorShadowFalloff = 0.65;

// Phase of a motion that completes `cycles` whole cycles per hour, so it carries on seamlessly
// when the animation clock wraps at 3600 s.
static float decorCycle(float t, float cycles) {
    return 6.2831853 * fract(t * (cycles / 3600.0));
}

// Fade of a level-of-detail class at zoom `zoom` (1 = default, larger = farther). Each instance
// fades at its own zoom inside the class's range, so decorations thin out gradually instead of
// popping all at once.
static float decorDetailFade(uint detail, float random, float zoom) {
    if (detail == 0u) return 1.0;
    float2 range = detail == 1u ? float2(1.25, 2.2) : float2(1.9, 3.3); // scatter, secondary trees
    float at = mix(range.x, range.y, random);
    return 1.0 - smoothstep(at - 0.22, at + 0.22, zoom);
}

// Fog level (0 visible, 1 explored, 2 unexplored) of the tile under a world position.
static uint decorFogAt(float2 p, texture2d<uint, access::read> tiles, constant Uniforms& u) {
    float size = u.map.x, tw = u.map.y;
    float px = (p.x - tw * 0.5) / size, py = (p.y - size) / size;
    float fq = 0.57735027 * px - py / 3.0, fr = py * 2.0 / 3.0, fs = -fq - fr;
    float rq = round(fq), rr = round(fr), rs = round(fs);
    float dq = abs(rq - fq), dr = abs(rr - fr), ds = abs(rs - fs);
    if (dq > dr && dq > ds) { rq = -rr - rs; } else if (dr > ds) { rr = -rq - rs; }
    return fetchTile(tiles, int(rq), int(rr), u).fog;
}

// Instances are drawn `copies` times (wrap); copies of one sprite are interleaved so the
// back-to-front sort order of the instance buffer holds across the seam.
vertex DecorOut decor_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device SpriteInstance* sprites [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]],
                             texture2d<uint, access::read> tiles [[texture(0)]]) {
    uint copies = uint(u.dims.w);
    SpriteInstance s = sprites[iid / copies];
    uint copy = iid % copies;
    float2 corner = float2(float(vid & 1u), float(vid >> 1));
    uint bits = uint(s.flags.w);
    uint wind = bits & 3u, detail = (bits >> 2) & 3u;
    float random = float((bits >> 4) & 255u) / 255.0;
    float zoom = u.eye.w;

    DecorOut o;
    o.uv = float2(s.uv.x + corner.x * s.uv.z, s.uv.y + (1.0 - corner.y) * s.uv.w);
    o.dim = 0.0;
    o.shadow = -1.0;
    float fade = decorDetailFade(detail, random, zoom);
    bool hidden = fade < 0.004;
    float back = 1.0; // a taken tribal village's plants coming back
    bool fogged = s.flags.y > 0.5 && s.position.w >= 0.0;
    if (fogged) {
        uint4 texel = tileTexel(tiles, uint(s.position.w), u);
        uint own = texel.a;
        uint level = own & kTileFogMask;
        // Improvements as the viewer knows them: mines and herds show only on their own;
        // open-land clutter clears from farms and mines and thins out on pastures.
        uint improvement = tileImprovement(texel), needs = (bits >> kDecorNeedsShift) & 15u;
        hidden = hidden || (needs != 0u && improvement != needs);
        hidden = hidden || ((bits & kDecorResourceBit) != 0u && (texel.b & kTileResourceBit) == 0u);
        if ((bits & kDecorClearsBit) != 0u && improvement != 0u) hidden = hidden || improvement != 3u || random < 0.55;
        // A city centre clears its own tile of everything, hills included: the settlement
        // stands where plants, rocks and mounds were (a mound in front of the hall would stand
        // over it), on the ground's baked relief. Of the sprites straddling an edge onto it,
        // plants and rocks go too, but a neighbour's relief stays (a mountain's peaks, the
        // mounds along a shared edge), so a range keeps its skyline.
        bool ownCity = (own & kTileCityBit) != 0u, city = ownCity;
        bool relief = (bits & kDecorReliefBit) != 0u;
        if (s.flags.z > 0.5) { // sprites straddling an edge show only as much as the less-revealed tile
            uint other = tileByte(tiles, uint(s.flags.z) - 1u, u);
            level = max(level, other & kTileFogMask);
            city = city || (other & kTileCityBit) != 0u;
        } else if (s.flags.z < -0.5) { // stand-ins that keep an unexplored neighbor a secret
            hidden = hidden || tileFog(tiles, uint(-s.flags.z) - 1u, u) < 2u;
        }
        hidden = hidden || level == 2u || (relief ? ownCity : city);
        // A tribal village's tile hides the plants standing on it (the sprites that sway) and
        // their cast shadows: its huts stand in a clearing among the tile's relief and rocks,
        // and whatever reaches over from a neighbour stays. While a taken one fades, its tile's
        // plants fade back in (options.w: that tile plus how far they are back, -1 for none).
        if ((own & kTileTribalVillageBit) != 0u && (wind != 0u || ((bits & kDecorShadowBit) != 0u && !relief))) {
            if (u.options.w >= 0.0 && uint(u.options.w) == uint(s.position.w)) back = fract(u.options.w);
            else hidden = true;
        }
        o.dim = level == 1u ? 1.0 : 0.0;
    }
    o.tint = s.tint * (fade * back);

    // The anchor (the sprite's foot) stands exactly on `position`; the part of the quad below
    // it (contact shadow, soft base) continues down the billboard plane.
    float2 off = (corner - s.sizeAnchor.zw) * s.sizeAnchor.xy;
    float3 p;
    if ((bits & kDecorShadowBit) != 0u) {
        // Cast shadow: the image above the foot, laid on the ground and stretched away from the
        // sun (0.6 of the caster's height). It fades out over unexplored ground it reaches.
        float2 away = -u.sun.xy / max(u.sun.z, 0.2) * 0.6;
        float2 q = s.position.xy + float2(off.x + away.x * off.y, away.y * off.y);
        p = float3(q, s.position.z);
        o.shadow = corner.y;
        if (fogged && decorFogAt(q, tiles, u) == 2u) o.tint = float4(0.0);
    } else {
        // Trees that stay at strategic zoom grow into the room their fading neighbors leave.
        if ((bits & kDecorGrowsBit) != 0u) off *= 1.0 + 0.28 * smoothstep(1.7, 3.2, zoom);
        if (wind != 0u) {
            // Gentle sway: the top bends, the foot stays planted. A slow gust travels across the
            // map (period tied to the map width so it wraps) and every plant has its own phase.
            // Every term runs whole cycles per hour (palms about 0.14 Hz, trees 0.2 Hz, grass
            // 0.27 Hz, each with a harmonic 2.3 times faster), so nothing jumps at the clock wrap.
            // Calm when zoomed out, where motion would only read as shimmer.
            float t = u.cameraUp.w;
            float2 tilesPos = s.position.xy / u.map.y;
            float gust = 0.6 + 0.4 * sin(decorCycle(t, 315.0) - tilesPos.x * 6.2831853 * 8.0 / u.dims.x + tilesPos.y * 0.3);
            float phase = random * 6.2831853;
            float2 cycles = wind == 3u ? float2(516.0, 1187.0) : (wind == 2u ? float2(974.0, 2240.0) : float2(716.0, 1647.0));
            float amount = (wind == 3u ? 0.035 : (wind == 2u ? 0.06 : 0.025)) * (1.0 - smoothstep(1.6, 2.6, zoom));
            float sway = (sin(decorCycle(t, cycles.x) + phase) + 0.35 * sin(decorCycle(t, cycles.y) + phase * 1.7)) * gust * amount;
            off.x += sway * s.sizeAnchor.y * max(corner.y - s.sizeAnchor.w, -0.2);
        }
        float3 upAxis = s.flags.x > 0.5 ? u.cameraUp.xyz : float3(0.0, 1.0, 0.0);
        p = s.position.xyz + float3(off.x, 0.0, 0.0) + upAxis * off.y;
    }
    if (copies > 1u) p.x += (float(copy) - 1.0) * u.map.w;

    o.position = hidden ? float4(0.0, 0.0, -2.0, 1.0) : u.viewProj * float4(p, 1.0);
    o.world = p;
    return o;
}

fragment float4 decor_fragment(DecorOut in [[stage_in]],
                               constant Uniforms& u [[buffer(1)]],
                               texture2d<float> atlas [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    float4 c;
    if (in.shadow >= 0.0) {
        // The caster's coverage, sampled from ever smaller mips toward the tip: a shadow that
        // is crisp at the foot and soft and lighter where it falls farther away.
        float a = atlas.sample(smp, in.uv, bias(1.0 + 2.0 * in.shadow)).a;
        c = float4(kDecorShadow, 1.0) * (a * in.tint.a * (1.0 - kDecorShadowFalloff * in.shadow));
    } else {
        // Up close a slight negative bias keeps the painted detail crisp; from default zoom out
        // none, which would only shimmer.
        float sharpen = -0.25 * (1.0 - smoothstep(0.7, 1.0, u.eye.w));
        c = atlas.sample(smp, in.uv, bias(sharpen)) * in.tint;
    }
    // Close to half of a sprite's quad is empty: skip the fog and atmosphere there (their
    // result is transparent anyway).
    if (c.a < 1.0 / 255.0) return float4(0.0);
    if (in.dim > 0.5) c = applyExploredFog(c);
    return applyAtmosphere(c, in.world, in.position, u);
}
"""#
}
