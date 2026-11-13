extension Shaders {
    /// What the renderer inputs paint (M1 §15), shared by the passes that come after it in the
    /// source: the players' colours and ring patterns (`Palette.playerStyles`), the ring
    /// pattern itself (base bands, medallions and borders draw the same ones), and the ground's
    /// marks: the territory tint, farm fields, pasture fences, the movement range's fill and the
    /// settler scores (`ground_fragment` calls them; `MapRenderer+Territory.swift` writes the
    /// tile bits they read). Helpers carry the `mark` prefix.
    static var marksSource: String {
        let styles = Palette.playerStyles
        let colors = styles.map { "float3(\($0.r), \($0.g), \($0.b))" }.joined(separator: ", ")
        let patterns = styles.map { "\($0.ring.rawValue)" }.joined(separator: ", ")
        return #"""
// ---------------------------------------------------------------- marks (renderer inputs)

// The players' colours and ring patterns by style index (`Palette.playerStyles`).
constant float3 kPlayerColors[\#(styles.count)] = { \#(colors) };
constant int kPlayerPatterns[\#(styles.count)] = { \#(patterns) };
constant float3 kMarkInk = float3(0.11, 0.075, 0.05);     // warm brown-black (ART.md §2)
constant float3 kMarkCream = float3(1.0, 0.97, 0.88);
// The settler overlay's best sites: gilt, a colour no player uses.
constant float3 kMarkGilt = float3(1.0, 0.80, 0.36);

// Ownership pattern of a band (`RingPattern`): how much of the band shows the owner's colour,
// the rest being dark. `along` counts repeats along the band (a whole number closes a ring),
// `across` runs from -1 at the band's inner edge to 1 at its outer edge, `span` is one repeat's
// length in half band widths and `aa` the antialiasing width in half band widths. Base bands,
// medallion frames and borders all draw these.
static float markPattern(int pattern, float along, float across, float span, float aa) {
    float x = (fract(along) - 0.5) * span;   // from the middle of this repeat, in half bands
    float v = across;
    switch (pattern) {
    case 1: // double: two lines with a dark rule between them
        return smoothstep(0.34 - aa, 0.34 + aa, abs(v));
    case 2: // dashed
        return 1.0 - smoothstep(0.3 * span - aa, 0.3 * span + aa, abs(x));
    case 3: // beaded: round beads on a dark cord
        return 1.0 - smoothstep(0.92 - aa, 0.92 + aa, length(float2(x, v)));
    case 4: { // notched: a dark V cut into the outer edge once per repeat
        float notch = v - (1.0 - 1.3 * saturate(1.0 - abs(x) / 1.1));
        return 1.0 - smoothstep(-aa, aa, notch);
    }
    case 5: { // rope: dark twists slanting across the band
        float twist = abs(fract((x + 0.7 * v) / span) - 0.5) * span;
        return smoothstep(0.36 - aa, 0.36 + aa, twist);
    }
    case 6: { // chevron: a zigzag between the keylines
        float zig = (abs(fract(along) - 0.5) * 4.0 - 1.0) * 0.5;
        return 1.0 - smoothstep(0.5 - aa, 0.5 + aa, abs(v - zig));
    }
    default: // solid, and thick-thin (whose thin line lies outside the band)
        return 1.0;
    }
}

// A pattern's repeat length, in band widths, as the base bands space them.
static float markPatternPeriod(int pattern) {
    return pattern == 2 ? 4.0 : (pattern == 3 ? 1.5 : (pattern == 4 ? 2.5 : 2.0));
}

// Territory: a soft wash of the owner's colour, stronger toward a border (`edge`: the distance
// to the nearest edge with another owner, world units; huge when none) and over the whole
// territory when zoomed out, so regions read at strategic zoom. Mixed into `c`.
static float3 markTerritory(float3 c, uint owner, float edge, float apothem, float zoom) {
    float3 team = kPlayerColors[(owner - 1u) % \#(styles.count)u];
    float inner = mix(0.05, 0.13, smoothstep(1.3, 2.6, zoom));
    float a = inner + 0.15 * exp(-max(edge, 0.0) / (0.3 * apothem));
    return mix(c, team, a);
}

// Farm fields (an improvement): a patchwork of plots on a sheared, gently warped world-space
// lattice (cells about half a tile across, a whole number per world period so the wrap seam
// never shows), each plot its own crop, tone and furrow direction, with hedgerows between
// them. A plot is part of the farmland when its middle lies on a farm, so the farmland ends
// along plot edges, wherever they fall, never along a hex edge. `farms` has bit 0 set when the
// pixel's own tile is a farm and bit i + 1 when neighbor i (`kDirs`) is one (explored ones
// only); `local` is the pixel's position from its tile's centre and `tw` the tile width.
// `albedo` is the ground's own colour, which every crop leans toward, so fields belong to
// their biome; `fine`, `coarse` and `nz` are the ground's detail samples, `fp` the pixel
// footprint (world units). `keep` (0...1) fades the fields out (the shore).
static float3 markFields(float3 c, float keep, uint farms, float3 albedo, float2 p, float2 local, float tw, float size, float fp,
                         float4 fine, float4 coarse, float4 nz, constant Uniforms& u) {
    bool wraps = u.dims.z > 0.5;
    int n = wraps ? max(1, int(round(u.map.w / (size * 0.5)))) : 0;
    float cw = wraps ? u.map.w / float(n) : size * 0.5, ch = size * 0.36;
    // Rows slide sideways (the shear), so plot edges never run along the hex rows.
    float2 warp = (nz.rg - 0.5) * 0.5 + (coarse.gb - 0.5) * 0.12;
    float2 q = float2(p.x / cw + 0.37 * p.y / ch, p.y / ch) + warp;
    float2 i0 = floor(q);
    float f1 = 1e9, f2 = 1e9;
    float2 id = float2(0.0), mid = float2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = i0 + float2(float(x), float(y));
            int gx = wraps ? wrapIndex(int(g.x), n) : int(g.x), gy = int(g.y);
            float2 o = float2(hash2(gx * 7 + 3, gy * 13 + 5), hash2(gx * 11 + 17, gy * 5 + 23));
            float2 at = g + 0.15 + 0.7 * o;
            // Plots are longer east-west than north-south.
            float2 d = (at - q) * float2(0.75, 1.0);
            float dd = dot(d, d);
            if (dd < f1) { f2 = f1; f1 = dd; id = g; mid = at; } else if (dd < f2) { f2 = dd; }
        }
    }
    // Which tile the plot's middle lies on (the warp is smooth, so it is the same for every
    // pixel of the plot): the farmland takes whole plots.
    float2 m = mid - warp;
    float2 plot = local + float2((m.x - 0.37 * m.y) * cw, m.y * ch) - p;
    float best = dot(plot, plot);
    uint tile = 0u;
    for (int i = 0; i < 6; i++) {
        float2 dv = plot - kNormals[i] * tw;
        float dd = dot(dv, dv);
        if (dd < best) { best = dd; tile = uint(i + 1); }
    }
    if (((farms >> tile) & 1u) == 0u) return c;
    float edge = (sqrt(f2) - sqrt(f1)) * ch * 0.5;        // ≈ distance to the plot's edge (world)
    int ix = wraps ? wrapIndex(int(id.x), n) : int(id.x), iy = int(id.y);
    float r0 = hash2(ix * 31 + 7, iy * 17 + 3), r1 = hash2(ix * 5 + 11, iy * 29 + 1), r2 = hash2(ix * 13 + 19, iy * 3 + 41);
    // Crops: ripe grain (a muted ochre, well away from the yellow player), young and deep
    // green, ploughed earth, hay and fallow.
    float3 crop = r0 < 0.28 ? float3(0.78, 0.67, 0.40) : (r0 < 0.46 ? float3(0.50, 0.62, 0.30)
               : (r0 < 0.6 ? float3(0.37, 0.50, 0.24) : (r0 < 0.76 ? float3(0.55, 0.42, 0.28)
               : (r0 < 0.9 ? float3(0.68, 0.63, 0.43) : float3(0.58, 0.60, 0.37)))));
    crop = mix(crop, albedo, 0.2) * (0.93 + 0.12 * r1);
    // Furrows along the plot in its own direction (continuous inside the plot, so the seam
    // never cuts them); they fade before they can shimmer.
    float ang = r2 * 3.14159265;
    float2 dir = float2(cos(ang), sin(ang));
    float period = size * 0.06;
    float stripe = sin(6.2831853 * dot((q - id) * float2(cw, ch), dir) / period);
    float furrow = (1.0 - smoothstep(period * 0.2, period * 0.42, fp)) * (r0 >= 0.6 && r0 < 0.76 ? 1.0 : 0.7);
    crop *= 1.0 + 0.13 * stripe * furrow;
    crop *= 0.95 + 0.1 * fine.r;
    // Hedgerows: thin and dark green on most plot edges, a pale track on the rest; they fade
    // as plots get small on screen.
    float hedgeW = max(size * 0.016, fp * 0.8);
    float line = (1.0 - smoothstep(hedgeW * 0.5, hedgeW * 0.5 + fp, edge)) * smoothstep(3.0, 6.0, ch / fp);
    float3 hedgeC = r1 < 0.7 ? mix(float3(0.24, 0.32, 0.14), albedo * 0.6, 0.25) : mix(float3(0.72, 0.66, 0.50), albedo, 0.3);
    crop = mix(crop, hedgeC, line * 0.7);
    // The farmland's own edge is a plot edge: antialiased over a pixel.
    float cover = keep * smoothstep(0.0, fp, edge);
    return mix(c, crop, cover);
}

// A pasture (an improvement): a fence of posts and rails around a wobbly paddock in the middle
// of the tile, its shadow toward the lower right, and the grass inside a little lusher with a
// worn trail. `local` is the position from the tile's centre (world units), `seed` the tile's
// noise offset.
static float3 markPasture(float3 c, float2 local, float size, float fp, float2 seed, float4 fine, float4 nz) {
    float r = length(local / float2(1.0, 0.88));
    float ang = atan2(local.y, local.x);
    // The paddock: about 0.6 tile sizes out, wobbling with the tile's own seed.
    float R = size * (0.6 + 0.045 * sin(ang * 3.0 + seed.x) + 0.03 * sin(ang * 5.0 + seed.y) + (nz.b - 0.5) * 0.03);
    float d = r - R;                                       // + outside the fence
    float inside = 1.0 - smoothstep(-fp, fp, d);
    // Lusher grass inside, with a worn trail along the fence.
    float3 lush = c * float3(0.93, 1.03, 0.9);
    float3 g = mix(c, lush, inside * 0.7);
    float trail = (1.0 - smoothstep(size * 0.03, size * 0.07, abs(d + size * 0.06))) * inside;
    g = mix(g, g * float3(1.08, 1.02, 0.9) + float3(0.03, 0.02, 0.0), trail * 0.35 * (0.7 + 0.6 * fine.g));
    // The fence's shadow, toward the lower right.
    float2 sl = local - float2(0.77, -0.63) * size * 0.035;
    float sr = length(sl / float2(1.0, 0.88));
    float sd = sr - R;
    float railW = max(size * 0.012, fp * 0.7);
    float shadow = 1.0 - smoothstep(railW, railW + 1.5 * fp, abs(sd));
    g = mix(g, g * float3(0.70, 0.70, 0.82), shadow * 0.55);
    // Rails, and posts every 0.09 tile sizes along the fence.
    float rail = 1.0 - smoothstep(railW * 0.5, railW * 0.5 + fp, abs(d));
    float along = ang * R;
    float spacing = size * 0.09;
    float k = (fract(along / spacing) - 0.5) * spacing;
    float postR = max(size * 0.017, fp * 0.9);
    float post = 1.0 - smoothstep(postR - fp * 0.5, postR + fp * 0.5, length(float2(k, d)));
    float3 wood = float3(0.47, 0.33, 0.2) * (0.9 + 0.2 * fine.r);
    g = mix(g, wood * 1.12, rail * 0.85);
    g = mix(g, wood * 0.82, post);
    // Zoomed far out the paddock reads only as a lusher patch.
    return g;
}

// The movement range: a soft cream wash, a little stronger toward the range's edge (`edge`:
// the distance to the nearest edge of a tile outside it, world units).
static float3 markRange(float3 c, float edge, float apothem) {
    float a = 0.12 + 0.12 * exp(-max(edge, 0.0) / (0.18 * apothem));
    return mix(c, kMarkCream, a);
}

// The settler overlay: tier 1 (poor) ... 7 (best). Poor sites dim, good ones glow gilt; a
// soft step at the tile's edge (`edge`: the distance to its nearest edge, world units). It goes
// on over the explored fog, and stronger where that greys the ground (`fogged` 1), so the
// tiers keep apart in remembered land and over pale desert. The two best tiers also get a ring
// over the decorations (`unitSiteHex` in the unit pass).
static float3 markScore(float3 c, uint tier, float edge, float apothem, float fogged) {
    float v = float(tier - 1u) / 6.0;
    float soft = smoothstep(0.0, 0.12 * apothem, edge);
    // Over the fog's grey any gilt reads, so there the fair tiers get less of it and the poor
    // ones more ink: the ends of the scale stand apart.
    float ink = mix(0.22, 0.4, fogged) * (1.0 - v) * (1.0 - v);
    float gilt = mix(0.08 + 0.34 * v * v, 0.03 + 0.44 * v * v * v, fogged);
    c = mix(c, kMarkInk, ink * soft);
    return mix(c, kMarkGilt, gilt * soft);
}
"""#
    }
}
