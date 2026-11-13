extension Shaders {
    /// Overlay pass: borders, the movement range's outline and the path preview (route, its
    /// shadow, the unexplored remainder and the destination ring) as triangles on the ground
    /// plane, over the decorations, instanced once per wrap copy.
    /// `OverlayVertex.position.w` is the `OverlayStyle` and `color` carries that style's
    /// parameters (`MapRenderer+Overlays.swift`); the shapes themselves are shaded here so they
    /// stay crisp at every zoom. The selection ring is drawn by the unit pass, above the bases.
    static var overlaySource: String { #"""
struct OverlayOut {
    float4 position [[position]];
    float4 params;
    float4 aux;
    float3 world;
    float style [[flat]];
    float group [[flat]];
};

// A border's or range outline's band at the current zoom (world units): its half width
// (keylines included) and how far its middle lies inside the edge. Screen-constant, so it
// stays crisp at every zoom, and capped to a share of the tile when zoomed far out, so it
// stays calm there.
static float2 overlayBandMetrics(int style, constant Uniforms& u) {
    float pt = u.eye.w, size = u.map.x;
    if (style == 6) {
        float hw = 1.9 * pt;   // a 2.4 pt band between 0.7 pt keylines
        float k = min(1.0, 0.11 * size / hw);
        return float2(hw, 2.4 * pt) * k;
    }
    float hw = 1.35 * pt;      // a 1.5 pt cream line between 0.6 pt keylines
    float k = min(1.0, 0.08 * size / hw);
    return float2(hw, 5.2 * pt) * k;
}

vertex OverlayOut overlay_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device OverlayVertex* verts [[buffer(0)]],
                                 constant Uniforms& u [[buffer(1)]]) {
    OverlayVertex v = verts[vid];
    float3 p = v.position.xyz;
    int style = int(v.position.w + 0.5);
    if (style == 6 || style == 7) {
        // Ribbons along hex edges: the corner moved along its miter into the region.
        float2 m = overlayBandMetrics(style, u);
        p.xy += v.color.zw * (m.y - v.color.x * m.x);
    }
    if (u.dims.w > 1.5) p.x += (float(iid) - 1.0) * u.map.w;
    OverlayOut o;
    o.position = u.viewProj * float4(p, 1.0);
    o.params = v.color;
    o.aux = v.aux;
    o.style = v.position.w;
    o.group = v.aux.x;
    o.world = p;
    return o;
}

constant float3 kRouteInk = float3(0.12, 0.08, 0.05);
constant float3 kRouteCream = float3(1.0, 0.97, 0.88);
constant float3 kRouteShadow = float3(0.08, 0.07, 0.16);

static float4 overlayOver(float4 below, float4 above) { return above + below * (1.0 - above.a); }

// 1 inside distance `r` (signed distance `d`), antialiased over `aa`.
static float overlayCover(float d, float r, float aa) { return 1.0 - smoothstep(r - aa, r + aa, d); }

static float overlaySegmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
}

// Distance along a repeating pattern of `period`, centered on the nearest repeat.
static float overlayRepeatAlong(float x, float period) { return x - (floor(x / period) + 0.5) * period; }

// The route: light cream chevrons, each a brush stroke that tapers toward its tips, with a
// thin warm-ink edge, marching toward the destination over a faint dark line, spaced like a
// painted dotted line. Strokes stay between about 1.4 and 2.4 points wide at any zoom, no
// heavier than a base's band. Past this turn's reach (negative opacity) the route turns into
// translucent dots, 6.4 to 7.2 points across at any zoom and anywhere on screen (sized by the
// points there, `ptHere`, where the tilt's perspective shrinks the far side). Over remembered
// land (`remembered` 1), whose ground the explored fog greys and darkens, dots go opaque with
// a firmer ink edge and line, so the way stays easy to follow. Zoomed out until a chevron
// would span fewer than about ten pixels, chevrons give way to plain dashes rather than
// shimmer (ART.md §4). The pattern moves 0.45 repeats a second, a whole 1620 an hour. `px` is
// world units per pixel, `pt` world units per point at the camera's focus, `ptHere` across
// the screen at this fragment.
static float4 overlayTrail(float4 p, float px, float pt, float ptHere, float time, float remembered) {
    float hw = p.w;
    float across = abs(p.x) * hw;
    bool later = p.z < 0.0;
    float opacity = abs(p.z);
    float period = hw * 2.3;
    float2 q = float2(overlayRepeatAlong(p.y - time * period * 0.45, period), across);
    float aa = px * 0.8;
    float stroke = clamp(hw * 0.2, 0.7 * pt, 1.2 * pt);
    float d;
    if (later) {
        float dotPt = max(pt, ptHere);
        d = length(q) - clamp(hw * 0.32, 3.2 * dotPt, 3.6 * dotPt);
    } else {
        float arm = hw * 0.6, depth = arm * 0.85;
        float2 a = float2(-depth * 0.5, arm), b = float2(depth * 0.5, 0.0);
        float2 pa = q - a, ba = b - a;
        float t = saturate(dot(pa, ba) / dot(ba, ba));   // 0 at the arm's tip, 1 at the point
        float chevron = length(pa - ba * t) - stroke * (0.55 + 0.45 * t);
        float dash = overlaySegmentDistance(q, float2(-period * 0.2, 0.0), float2(period * 0.2, 0.0)) - stroke;
        d = mix(dash, chevron, smoothstep(9.0, 14.0, period / px));
    }
    float line = overlayCover(across, min(hw * 0.12, 0.6 * pt), aa) * (later ? 0.14 : 0.24) * (1.0 + 0.6 * remembered);
    float edge = overlayCover(d, min(hw * 0.12, 0.65 * pt), aa) * (0.55 + 0.35 * remembered);
    float fill = overlayCover(d, 0.0, aa);
    float4 c = float4(kRouteInk * line, line);
    c = overlayOver(c, float4(kRouteInk * edge, edge));
    c = overlayOver(c, float4(kRouteCream * fill, fill));
    return c * opacity * (later ? mix(0.62, 1.0, remembered) : 1.0);
}

// Dashed ring around the destination, slowly turning; or (style 5) the rest of a route through
// unexplored land: faint open rings, a guess where the route's filled dots are a plan. `p.z` is
// the dash period, `p.w` the half width.
static float4 overlayDashes(float4 p, float px, float time, bool rings) {
    float hw = p.w;
    float2 q = float2(overlayRepeatAlong(p.y - time * p.z * 0.2, p.z), p.x * hw);
    float aa = px * 0.8;
    float d = rings ? abs(length(q) - hw * 0.6) - hw * 0.14
                    : overlaySegmentDistance(q, float2(-p.z * 0.25, 0.0), float2(p.z * 0.25, 0.0)) - hw * 0.45;
    float edge = overlayCover(d, hw * (rings ? 0.16 : 0.35), aa) * 0.75;
    float fill = overlayCover(d, 0.0, aa);
    float4 c = overlayOver(float4(kRouteInk * edge, edge), float4(kRouteCream * fill, fill));
    return rings ? c * 0.6 : c;
}

// A border: a band in the owner's colour and ring pattern between dark keylines, just inside
// the territory's edge (`MapRenderer+Territory.swift`). The pattern repeats a power of two
// times per hex edge (so it runs on around corners), as many as fit at the base bands'
// spacing, crossfading as the zoom changes; the dark parts inside the band are a deep shade of
// the owner's colour. `across` is -1...1 across the band (+1 on the edge's side), `along` in
// hex edges, `aaAcross` the antialiasing width in the same units as `across`.
static float4 overlayBorder(float across, float along, int owner, float aaAcross, constant Uniforms& u) {
    float2 m = overlayBandMetrics(6, u);
    float halfAll = m.x, halfBand = halfAll * (1.2 / 1.9);
    float o = across * halfAll, aa = max(aaAcross * halfAll, 1e-4);
    float3 team = kPlayerColors[owner % \#(Palette.playerStyles.count)];
    int pattern = kPlayerPatterns[owner % \#(Palette.playerStyles.count)];
    float v = o / halfBand, av = aa / halfBand;
    float cover = 1.0;
    if (pattern == 7) {
        // thick-thin: a wide inner line and a thin outer one
        cover = max(1.0 - smoothstep(0.2 - av, 0.2 + av, v), smoothstep(0.56 - av, 0.56 + av, v));
    } else if (pattern == 1) {
        cover = markPattern(1, 0.0, v, 1.0, av);
    } else if (pattern >= 2 && pattern <= 6) {
        float edge = u.map.x;
        float ideal = edge / (markPatternPeriod(pattern) * 2.0 * halfBand);
        float lg = log2(max(ideal, 1.0));
        float n0 = exp2(floor(lg)), t = smoothstep(0.35, 0.65, fract(lg));
        float c0 = markPattern(pattern, along * n0, v, edge / n0 / halfBand, av);
        float c1 = markPattern(pattern, along * n0 * 2.0, v, edge / (n0 * 2.0) / halfBand, av);
        cover = mix(c0, c1, t);
    }
    float bandA = 1.0 - smoothstep(halfBand - aa, halfBand, abs(o));
    float keyA = (1.0 - smoothstep(halfAll - aa, halfAll, abs(o))) * mix(0.85, 0.65, smoothstep(1.6, 3.0, u.eye.w));
    float3 band = team * 0.95;
    float3 keyColor = mix(kRouteInk, band * 0.3, bandA);
    float4 c = float4(keyColor * keyA, keyA);
    float colorA = bandA * cover;
    return overlayOver(c, float4(band * colorA, colorA));
}

// The movement range's outline: a cream line between soft ink keylines.
static float4 overlayRangeEdge(float across, float aaAcross, constant Uniforms& u) {
    float2 m = overlayBandMetrics(7, u);
    float halfAll = m.x, halfLine = halfAll * (0.75 / 1.35);
    float o = across * halfAll, aa = max(aaAcross * halfAll, 1e-4);
    float lineA = 1.0 - smoothstep(halfLine - aa, halfLine, abs(o));
    float keyA = (1.0 - smoothstep(halfAll - aa, halfAll, abs(o))) * 0.55;
    return overlayOver(float4(kRouteInk * keyA, keyA), float4(kRouteCream * lineA, lineA));
}

fragment float4 overlay_fragment(OverlayOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    int style = int(in.style + 0.5);
    float time = u.cameraUp.w;
    // World units per pixel along the band, taken before any branch so it is well defined; and
    // the change of `across` per pixel (ribbons).
    float px = max(length(float2(dfdx(in.params.y), dfdy(in.params.y))), 1e-3);
    float aaAcross = max(fwidth(in.params.x), 1e-4);
    // World units per point across the screen here (`viewport.w · eye.w` is pixels per point).
    float ptHere = length(dfdx(in.world.xy)) * u.viewport.w * u.eye.w;
    float4 c;
    if (style == 6 || style == 7) {
        c = style == 6 ? overlayBorder(in.params.x, in.params.y, int(in.group + 0.5), aaAcross, u)
                       : overlayRangeEdge(in.params.x, aaAcross, u);
        // Open ends (where an edge meets unexplored land) fade out; out of sight it takes the
        // explored-fog look, as the ground under it does.
        float fade = smoothstep(0.0, 0.35, in.params.y - in.aux.z) * smoothstep(0.0, 0.35, in.aux.w - in.params.y);
        c *= fade;
        c = mix(c, applyExploredFog(c), saturate(in.aux.y));
    } else if (style == 2) {
        c = overlayTrail(in.params, px, u.eye.w, ptHere, time, saturate(in.aux.y));
    } else if (style == 3) {
        float a = 0.24 * in.params.z * (1.0 - smoothstep(0.2, 1.0, abs(in.params.x)));
        c = float4(kRouteShadow * a, a);
    } else if (style == 4 || style == 5) {
        c = overlayDashes(in.params, px, time, style == 5);
    } else {
        c = in.params;
    }
    return applyAtmosphere(c, in.world, in.position, u);
}
"""#
    }
}
