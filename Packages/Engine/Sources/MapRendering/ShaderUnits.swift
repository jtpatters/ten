extension Shaders {
    /// Unit pass: per-frame instances sorted back to front on the CPU (`unitFrame`).
    /// flags.y is the `UnitSpriteKind`; tint, flags.z and flags.w mean what that kind says
    /// (`MapRenderer+Units.swift`). A unit with no moves left gets flags.z (its dim amount).
    static let unitSource = #"""
constant float kUnitCastLength = 0.6;                      // cast shadow length per unit of painted height
constant float3 kUnitCastTint = float3(0.10, 0.10, 0.20);  // the shared shadow family (ART.md §5)
constant float3 kUnitContactTint = float3(0.09, 0.09, 0.19);
constant float3 kUnitInk = float3(0.11, 0.075, 0.05);      // warm brown-black keylines
constant float3 kUnitCream = float3(1.0, 0.96, 0.86);      // the figures' outer rim, light keylines
constant float3 kUnitSelectCream = float3(1.0, 0.97, 0.88);    // selection: a color no player uses
constant float3 kUnitThreat = float3(0.80, 0.13, 0.10);    // attack targets: crimson corner brackets, a shape no ring pattern has
constant float3 kUnitWorked = float3(1.0, 0.83, 0.42);     // a selected city's worked tiles: gilt
constant float kUnitStandardFootY = \#(UnitSprite.standardFoot.y);
constant float kUnitClothTop = \#(UnitSprite.standardClothTop);
constant float kUnitClothBottom = \#(UnitSprite.standardClothBottom);
constant float kUnitStandardFit = \#(UnitSprite.standardArtFit);  // the standard's share of its cell
constant float kUnitBaseMargin = \#(UnitSprite.baseMargin);
constant float kUnitGroundLine = \#(UnitSprite.groundLine);
constant float kUnitLegTop = \#(UnitSprite.legTop);
// The atlas is 2048 texels wide and as tall as its cells need (`SpriteSheet.height`): bodies
// (and their data cells) are 256-texel cells, everything else 128. Every cell sits at a multiple
// of its own size, so its origin follows from any uv in it. A figure instance names its data
// cell by its index in rows of body cells (`UnitAtlasTable.maskCode`).
constant float2 kUnitAtlasTexels = float2(\#(Float(SpriteSheet<UnitSprite>.width)), \#(Float(SpriteSheet<UnitSprite>.height)));
constant float2 kUnitBodyCell = float2(\#(Float(UnitSprite.bodyCell)), \#(Float(UnitSprite.bodyCell))) / kUnitAtlasTexels;
constant uint kUnitBodiesPerRow = \#(SpriteSheet<UnitSprite>.width / UnitSprite.bodyCell)u;
constant float2 kUnitSmallCell = float2(128.0, 128.0) / kUnitAtlasTexels;
// The settlement atlas (`SettlementSprite`), bound as fragment texture 1: city pieces sample it,
// and a piece with team paint finds its team cell by its index in rows of cells its size.
constant float2 kTownAtlasTexels = float2(\#(Float(SpriteSheet<SettlementSprite>.width)), \#(Float(SpriteSheet<SettlementSprite>.height)));
// Strategic medallions (`UnitSprite.medallion*`), in radii of the frame: the dark rim, the band
// in the owner's color and pattern, the keyline inside it and the cream field, which shows the
// middle `kUnitBadgeField` of the type's badge cell. Quads leave room for the ink outline.
constant float kUnitMedallionQuad = \#(UnitSprite.medallionQuad);
constant float kUnitMedallionRim = \#(2 * UnitSprite.medallionRim);
constant float kUnitMedallionBand = \#(2 * UnitSprite.medallionBand);
constant float kUnitMedallionField = \#(2 * UnitSprite.medallionField);
constant float kUnitBadgeField = \#(UnitSprite.badgeField);
// Emblem badges, in radii of the badge: its colored disc inside a dark rim, the emblem cell's
// emblem (0.8 of the cell) spanning `kUnitBadgeEmblem` of the disc's width.
constant float kUnitBadgeQuad = \#(UnitSprite.badgeQuad);
constant float kUnitBadgeDisc = 0.889;
constant float kUnitBadgeEmblem = \#(UnitSprite.badgeEmblem);
// Outer rim (ART.md §3): cream, screen-constant width, drawn from the silhouette distance
// fields (data cells' green is 1 - distance / `kUnitRimRange` texels, `UnitSprite.rimField`);
// on lighter ground a thin dark line runs outside it. Data cells leave `kUnitDataBorder`
// texels empty around their edge.
constant float kUnitRimRange = \#(UnitSprite.rimRange);
constant float kUnitRimPoints = \#(UnitSprite.rimPoints);
constant float kUnitRimLinePoints = \#(UnitSprite.rimLinePoints);
constant float kUnitRimAlpha = 0.5;       // at its outer edge, 0.4 at its inner one
constant float kUnitRimLineAlpha = 0.7;
constant float kUnitRimBackAlpha = 0.6;  // ink behind the figure's own outline
constant float kUnitDataBorder = \#(Float(UnitSprite.dataBorder));
// Base quads: the ellipse's radii times this, plus this many band widths (room for the band,
// its keylines, rim and glow).
constant float kUnitBaseBandRoom = \#(UnitSprite.baseBandRoom);
constant float kUnitBandPoints = \#(UnitSprite.baseBandPoints);

// Phase of an animation running `cycles` whole cycles per hour, so nothing jumps when the
// clock wraps (ART.md §7).
static float unitPhase(float time, float cycles) { return 6.2831853 * fract(time * (cycles / 3600.0)); }

struct UnitOut {
    float4 position [[position]];
    float2 uv;
    float2 maskUV;              // figures: the data cell, one cell right of the body
    float2 local;               // 0...1 across the quad, y up
    float2 cellLocal;           // figures and standards: 0...1 across the whole atlas cell, y up
    float4 tint;
    float3 world;
    float4 cell [[flat]];       // figures and standards: the whole atlas cell; else the instance's rect
    float4 params [[flat]];     // kind, flags.z, flags.w, quad width
    float quadHeight [[flat]];  // figures: the whole cell's height (the quad may be trimmed)
    float maskHigh [[flat]];    // figures: 1 when the data is in the cell's blue and alpha
    uint instance [[flat]];     // index into the instance buffer (tap picking)
    float rise;                 // height above the anchor (world units): a figure's feet
    float reach [[flat]];       // figures: how far (texels) the rim can reach past the art
    float3 shade;               // cast shadows, base fills: their color through the atmosphere, at full strength
    float3 shade2;              // base fills: the owner's color through the atmosphere
};

vertex UnitOut unit_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device SpriteInstance* sprites [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]]) {
    uint copies = uint(u.dims.w);
    SpriteInstance s = sprites[iid / copies];
    uint copy = iid % copies;
    float2 corner = float2(float(vid & 1u), float(vid >> 1));
    int kind = int(s.flags.y + 0.5);
    float2 off = (corner - s.sizeAnchor.zw) * s.sizeAnchor.xy;
    float3 p;
    if (kind == 2) {
        // Cast shadow: the silhouette laid on the ground straight away from the sun. Height
        // above the figure's ground line (flags.w) becomes distance along the shadow, 0.6 of
        // it, so the shadow starts exactly under the feet and leans to the lower right.
        float h = (corner.y - s.flags.w) * s.sizeAnchor.y;
        float2 away = -normalize(u.sun.xy) * kUnitCastLength;
        p = s.position.xyz + float3(off.x + away.x * h, away.y * h, 0.0);
    } else if (s.flags.x > 0.5) {
        if (kind == 1 && s.flags.z <= 0.0) {
            // A carried standard sways gently about its pole foot (the anchor).
            float t = u.cameraUp.w;
            float lean = 0.035 * sin(unitPhase(t, 745.0) + s.flags.w) + 0.012 * sin(unitPhase(t, 1662.0) + s.flags.w * 1.7);
            off.x += lean * off.y;
        }
        if (kind == 19) {
            // An arrow turns along its flight as it appears on screen (flags.w, radians).
            float ca = cos(s.flags.w), sa = sin(s.flags.w);
            off = float2(off.x * ca - off.y * sa, off.x * sa + off.y * ca);
        }
        p = s.position.xyz + float3(off.x, 0.0, 0.0) + u.cameraUp.xyz * off.y;
    } else {
        p = s.position.xyz + float3(off, 0.0);
    }
    if (copies > 1u) p.x += (float(copy) - 1.0) * u.map.w;

    UnitOut o;
    o.position = u.viewProj * float4(p, 1.0);
    o.uv = float2(s.uv.x + corner.x * s.uv.z, s.uv.y + (1.0 - corner.y) * s.uv.w);
    o.maskUV = o.uv;
    o.maskHigh = 0.0;
    o.local = corner;
    o.cell = s.uv;
    o.cellLocal = corner;
    o.quadHeight = s.sizeAnchor.y;
    if (kind == 0 || kind == 1) {
        // Trimmed quads (`UnitSprite.bounds`) still know their place in the whole cell.
        float2 size = kind == 0 ? kUnitBodyCell : kUnitSmallCell;
        float2 origin = floor(s.uv.xy / size + 1e-3) * size;
        o.cell = float4(origin, size);
        o.cellLocal = float2((o.uv.x - origin.x) / size.x, 1.0 - (o.uv.y - origin.y) / size.y);
        o.quadHeight = s.sizeAnchor.y * size.y / max(abs(s.uv.w), 1e-6);
    }
    if (kind == 0) {
        // The data cell: position.w is its index in rows of body cells plus one, negative
        // when this east-facing body reads its west-facing twin's data mirrored.
        float code = s.position.w;
        uint index = uint(max(abs(code) - 0.5, 0.0));
        float2 maskOrigin = float2(float(index % kUnitBodiesPerRow), float(index / kUnitBodiesPerRow)) * kUnitBodyCell;
        float2 at = float2(code < 0.0 ? 1.0 - o.cellLocal.x : o.cellLocal.x, 1.0 - o.cellLocal.y);
        o.maskUV = maskOrigin + at * kUnitBodyCell;
        o.maskHigh = fract(abs(code)) > 0.1 ? 1.0 : 0.0;
    }
    if (kind == 11 && s.flags.w > 0.5) {
        // A city piece's team cell: flags.w is its index in rows of cells its size, plus one.
        float cellTexels = s.uv.z * kTownAtlasTexels.x;
        uint perRow = uint(kTownAtlasTexels.x / cellTexels + 0.5);
        uint index = uint(s.flags.w - 0.5);
        float2 origin = float2(float(index % perRow), float(index / perRow)) * cellTexels / kTownAtlasTexels;
        o.maskUV = origin + (o.uv - s.uv.xy);
    }
    o.tint = s.tint;
    o.world = p;
    o.params = float4(float(kind), s.flags.z, s.flags.w, s.sizeAnchor.x);
    o.instance = iid / copies;
    o.rise = (corner.y - s.sizeAnchor.w) * s.sizeAnchor.y;
    // Mip-0 texels per point across the quad, times the rim's widest reach, with a point of
    // slack (`unit_fragment` skips empty texels further out).
    o.reach = abs(s.uv.z) * kUnitAtlasTexels.x / max(s.sizeAnchor.x, 1e-4) * u.eye.w * (kUnitRimPoints + kUnitRimLinePoints + 1.0);
    // A cast shadow is one color at varying strength, and the atmosphere scales with strength
    // (premultiplied), so it is worked out here, at the corners, rather than for every pixel:
    // its cloud shadow, haze and vignette change over tiles, not across a shadow. A base fill
    // mixes two colors (`unitBase`), each worked out the same way (within 2/255 of doing it
    // per pixel).
    o.shade = float3(0.0);
    o.shade2 = float3(0.0);
    if (kind == 2 || kind == 8) {
        float2 ndc = o.position.xy / max(o.position.w, 1e-4);
        float4 fragCoord = float4((ndc.x * 0.5 + 0.5) * u.viewport.x, (0.5 - ndc.y * 0.5) * u.viewport.y, 0.0, 1.0);
        o.shade = applyAtmosphere(float4(kind == 2 ? kUnitCastTint : kUnitContactTint, 1.0), p, fragCoord, u).rgb;
        if (kind == 8) o.shade2 = applyAtmosphere(float4(s.tint.rgb, 1.0), p, fragCoord, u).rgb;
    }
    return o;
}

static float4 unitOver(float4 below, float4 above) { return above + below * (1.0 - above.a); }

// No moves left: muted (desaturated, a little darker and cooler) but still solid, so it reads
// as "done", not ghostly. Premultiplied in and out.
static float4 unitDimmed(float4 c, float amount) {
    float lum = dot(c.rgb, float3(0.30, 0.59, 0.11));
    c.rgb = mix(c.rgb, lum * float3(0.94, 0.97, 1.04), 0.38 * amount) * (1.0 - 0.15 * amount);
    return c;
}

// A shared body with the owner's color multiplied into its grey team paint. The grey is half
// the base value, so its painted light and shade carry over; above the base, highlights also
// lift toward cream, as they do on the neutral parts. Team paint dims less than the rest, so
// a finished unit keeps its owner's color.
static float4 unitFigure(float4 body, float team, float3 color, float dim) {
    float3 tinted = body.rgb * color * 2.0;
    float value = dot(body.rgb, float3(0.30, 0.59, 0.11)) / max(body.a, 1e-3);
    tinted += float3(1.0, 0.95, 0.82) * saturate(value * 2.0 - 1.0) * 0.22 * body.a;
    float4 c = float4(mix(body.rgb, tinted, team), body.a);
    return unitDimmed(c, dim * (1.0 - 0.65 * team));
}

// Mip-0 atlas texels per pixel at atlas position `uv`.
static float unitTexelsPerPixel(float2 uv) {
    float2 t = uv * kUnitAtlasTexels;
    return max(0.5 * (length(dfdx(t)) + length(dfdy(t))), 1e-3);
}

// How much a unit's rim needs the dark line outside its cream (none on dark ground, where the
// cream lifts it; full on ground lighter than about L* 60, where cream alone cannot).
// `ground` is the L* / 100 of the ground under the unit.
static float unitRimLine(float ground) { return smoothstep(0.5, 0.6, ground); }

// The rim around a figure or standard (ART.md §3), premultiplied, from the inside out: ink
// backing the figure's own soft outline to half a pixel past its silhouette; cream, a
// constant 1.75 points wide and a little stronger at its outer edge; and on lighter ground a
// dark line outside that, so the silhouette's outer edge always stands off what is around
// it. Ink and cream meet in a hard step: any blend of the two passes through a warm mid grey,
// which is the ground's own value on tundra or hills, and would leave a dull seam in the
// edge. `field` is the silhouette distance field (0 inside, 1 = kUnitRimRange texels out),
// `perPixel` mip-0 texels per pixel there (`unitTexelsPerPixel`), `cellLocal` the position in
// the cell (the field ends at its border).
static float4 unitRim(float field, float perPixel, float2 cellLocal, float cellTexels, float ground, constant Uniforms& u) {
    float perPoint = u.viewport.w * u.eye.w * perPixel;
    float width = kUnitRimPoints * perPoint;
    float line = kUnitRimLinePoints * perPoint * unitRimLine(ground);
    // Zoomed far out the field may not reach that far: both narrow together.
    float k = min(1.0, (kUnitRimRange - perPixel) / max(width + line, 1e-3));
    width *= k;
    line *= k;
    float d = field * kUnitRimRange;
    float cream = step(0.5 * perPixel, d);
    // The cream's outer end: hard against a dark line, soft where there is none (the step
    // softens as the line narrows away on darker ground). The outermost edge is antialiased
    // over a little over half a pixel, so it stays crisp.
    float soft = 0.6 * perPixel * saturate(1.0 - line / perPixel);
    float end = saturate((d - width) / max(soft, 1e-4) + 0.5);
    float creamA = cream * (1.0 - end) * kUnitRimAlpha * (0.8 + 0.2 * saturate(d / max(width, 1e-3)));
    float lineA = end * (1.0 - smoothstep(width + line - 0.6 * perPixel, width + line, d)) * saturate(line / perPixel);
    float inkA = (1.0 - cream) * kUnitRimBackAlpha + lineA * kUnitRimLineAlpha;
    float edge = min(min(cellLocal.x, 1.0 - cellLocal.x), min(cellLocal.y, 1.0 - cellLocal.y)) * cellTexels;
    float fade = smoothstep(kUnitDataBorder, kUnitDataBorder + 2.0 * perPixel, edge);
    return float4(kUnitCream * creamA + kUnitInk * inkA, creamA + inkA) * fade;
}

// Where a standard's cloth is sampled: soft folds travel down it and the swallowtail flutters;
// the pole and crossbar stay still. A unit with no moves left lets it hang limp, gathered
// toward the pole. `local` is the position in the standard's cell; returns the cell position
// to sample (xy) and the fold shading (z). Distances are in the standard's own size
// (`kUnitStandardFit` of the cell).
static float3 unitStandardWarp(float2 local, float dim, float phase, float time) {
    float along = saturate((kUnitClothTop - local.y) / (kUnitClothTop - kUnitClothBottom));
    float2 l = local;
    float live = dim > 0.0 ? 0.0 : 1.0;
    float x = (local.x - 0.5) / kUnitStandardFit, y = local.y / kUnitStandardFit;
    // Tails flutter; near the pole (which shows between them) they barely move.
    float away = smoothstep(0.03, 0.12, abs(x));
    float wave = unitPhase(time, 1490.0) + phase - y * 9.0;
    l.x += 0.022 * kUnitStandardFit * along * along * sin(wave) * away * live;
    if (live < 0.5) l.x = 0.5 + (l.x - 0.5) * (1.0 + 0.45 * along * smoothstep(0.02, 0.1, abs(x)));
    float fold = sin(x * 18.0 - unitPhase(time, 1260.0) * live + phase) * along * live;
    return float3(l, 1.0 + 0.1 * fold);
}

// Ownership pattern of a base band (`RingPattern`; medallion frames paint the same ones in
// `UnitSprites.swift`, borders in `ShaderOverlay.swift`): `markPattern` in `ShaderMarks.swift`.
// Every feature is at least a point wide at the band's screen-constant width.
static float unitPattern(int pattern, float along, float across, float span, float aa) {
    return markPattern(pattern, along, across, span, aa);
}

// On pale ground, a soft dark pad under a base's band that fades inward, so the band lifts
// off the ground; nothing of it reaches past the band's outer keyline (`outer`), whose crisp
// edge is what sets the base apart. The fill draws the part inside the band's inner edge, the
// band pass the rest, so the fill's quad need not reach the band.
static float unitPad(float d, float halfBand, float band, float outer, float aa, float dim, float ground) {
    return 0.16 * exp(-max(-d - halfBand, 0.0) / (band * 1.2)) * (1.0 - smoothstep(outer - aa, outer, d))
         * (1.0 - 0.4 * dim) * unitRimLine(ground);
}

// Painted base under a unit, flat on the ground: a matte band in the owner's color and
// ownership pattern between dark keylines, with a light keyline inside (so it reads on grass,
// sand, snow and dark woods alike), around a light wash of that color with the soft contact
// shadow of what stands on it. On dark ground a cream rim runs outside, as around the
// figures. `band` is the band's width in world units (screen-constant); `state` packs the dim
// amount, plus 2 when the unit is selected, plus 4 x the pattern, plus 32 x the ground's
// lightness in 255ths. Drawn in two parts: the fill (`part` 1: contact shadow, wash and the
// inner part of the pad, `unitPad`) under the decorations, so trees on the tile are not
// tinted, on a quad just the ellipse's size; and the band (`part` 0) with its keylines over
// them. `part` 2 gives the fill as its two colors' weights (`unit_fragment`).
static float4 unitBase(float2 local, float2 quad, float4 tint, float band, float state, float time, int part, float2 room) {
    float level = floor(state / 32.0 + 1e-3);
    state -= 32.0 * level;
    float ground = level / 255.0;
    int pattern = int(floor(state * 0.25 + 1e-3));
    state -= 4.0 * float(pattern);
    bool selected = state >= 1.5;
    float dim = selected ? state - 2.0 : state;
    float3 team = tint.rgb;
    float halfBand = band * 0.5, key = band * 0.3;
    // The quad is the ellipse's radii times room.x plus room.y band widths (a selected base's
    // has room for its glow, `MapRenderer+Units.swift`).
    float2 r = (quad * 0.5 - band * room.y) / room.x;
    float2 q = (local * 2.0 - 1.0) * quad * 0.5;
    float e = length(q / r);
    float d = (e - 1.0) * e / max(length(q / (r * r)), 1e-4);   // ≈ distance to the ellipse
    // Thick-thin's thin line lies outside its outer keyline, so its whole ring sits that much
    // further in: every pattern's base keeps the same footprint.
    if (pattern == 7) d += key + 0.64 * band;
    float aa = max(fwidth(d), 1e-3);
    float outer = pattern == 7 ? halfBand + 2.0 * key + 0.64 * band : halfBand + key;   // the outer keyline's edge

    if (part != 0) {
        // Contact shadow: darkest under the feet, offset away from the sun.
        float2 sq = (q - r * float2(0.12, -0.16)) / (r * float2(0.78, 0.66));
        float shadowA = 0.42 * pow(saturate(1.0 - length(sq)), 1.4);
        // Wash, a little stronger toward the band, and the pad's inner part.
        float inside = 1.0 - smoothstep(-halfBand - aa, -halfBand, d);
        float washA = inside * mix(0.12, 0.24, smoothstep(0.3, 1.0, e)) * (1.0 - 0.4 * dim);
        float padA = unitPad(d, halfBand, band, outer, aa, dim, ground) * inside;
        // Shadow, wash over it, pad over both: two colors, so (premultiplied) the shadow
        // color's weight and the owner color's.
        float tintW = padA + shadowA * (1.0 - washA) * (1.0 - padA), teamW = washA * (1.0 - padA);
        if (part == 2) return float4(tintW, teamW, tintW + teamW, 0.0) * tint.a;
        return float4(kUnitContactTint * tintW + team * teamW, tintW + teamW) * tint.a;
    }

    // Nothing of the band reaches this far (the selected glow does).
    float rimW = band * (kUnitRimPoints / kUnitBandPoints);
    float outerMost = outer + rimW + aa;
    if (!selected && (d > outerMost || d < -halfBand - key - 0.6 * band - aa)) return float4(0.0);

    // Around the ring: arc length of the ellipse (a series good to a few percent at these
    // proportions), counted in whole repeats of the pattern so it closes without a seam. Only
    // the patterns that change along the ring need it.
    float v = d / halfBand, av = aa / halfBand;
    float cover = 1.0;
    if (pattern == 1) {
        cover = unitPattern(pattern, 0.0, v, 1.0, av);
    } else if (pattern >= 2 && pattern <= 6) {
        float theta = atan2(q.y / r.y, q.x / r.x);
        float arc = 0.5 * (r.x + r.y) * theta - 0.25 * (r.x - r.y) * sin(2.0 * theta);
        float perimeter = 3.14159265 * (r.x + r.y);
        float period = pattern == 2 ? 4.0 * band : (pattern == 3 ? 1.5 * band : (pattern == 4 ? 2.5 * band : 2.0 * band));
        float repeats = max(round(perimeter / period), 3.0);
        float along = (arc / perimeter + 0.5) * repeats;
        float span = perimeter / repeats / halfBand;
        cover = unitPattern(pattern, along, v, span, av);
    }

    float bandA = 1.0 - smoothstep(halfBand - aa, halfBand, abs(d));
    // thick-thin: a thin line of the colour outside the outer keyline, keyed in turn.
    float thin = pattern == 7 ? (1.0 - smoothstep(0.32 * band - aa, 0.32 * band, abs(d - halfBand - key - 0.32 * band))) : 0.0;
    // Where a dark keyline meets a light one (the light keyline inside, the cream rim outside
    // on dark ground) the two meet in a hard step, as around the figures (`unitRim`): a blend
    // would pass through the ground's own value. The outer edge is soft where there is no rim.
    float rimAmount = 1.0 - unitRimLine(ground);
    float lightIn = -halfBand - key;
    float keyIn = step(lightIn, d);
    float keyOut = mix(1.0 - smoothstep(outer - aa, outer, d), 1.0 - step(outer, d), rimAmount);
    float keyA = keyIn * keyOut * 0.8;
    // The light keyline just inside the inner dark one.
    float lightA = (1.0 - keyIn) * smoothstep(-aa, 0.0, d - lightIn + (0.42 + 0.18 * rimAmount) * band) * (0.6 + 0.2 * rimAmount);

    // The band: matte, faintly lifted on its sunward (upper left) side.
    float lift = dot(normalize(q / (r * r) + 1e-5), float2(-0.62, 0.78));
    float3 bandColor = team * (0.92 + 0.12 * lift);
    float lum = dot(bandColor, float3(0.30, 0.59, 0.11));
    bandColor = mix(bandColor, lum * float3(0.95, 0.97, 1.03), 0.3 * dim) * (1.0 - 0.12 * dim);
    float padA = unitPad(d, halfBand, band, outer, aa, dim, ground) * smoothstep(-halfBand - aa, -halfBand, d);
    float4 c = unitOver(float4(kUnitContactTint * padA, padA), float4(kUnitCream * lightA, lightA));
    // The cream rim outside the outer keyline, on dark ground only (on light ground the dark
    // keyline is the edge that reads).
    float rimA = step(outer, d) * (1.0 - smoothstep(outer + rimW - 0.6 * aa, outer + rimW, d)) * kUnitRimAlpha * rimAmount;
    c = unitOver(c, float4(kUnitCream * rimA, rimA));
    if (selected) {
        float pulse = 0.5 + 0.5 * sin(unitPhase(time, 1490.0));
        bandColor = mix(bandColor, kUnitSelectCream, 0.25 + 0.15 * pulse);
        float glowA = exp(-max(d - outer, 0.0) / (band * 1.6)) * step(0.0, d) * (0.35 + 0.25 * pulse);
        glowA *= 1.0 - smoothstep(0.75, 1.0, length(local * 2.0 - 1.0));
        c = unitOver(c, float4(kUnitSelectCream * glowA, glowA));
    }
    // The pattern's dark parts inside the band are a deep shade of the owner's color (the
    // keylines either side stay ink), so a patterned band keeps its color's richness.
    float3 keyColor = mix(kUnitInk, bandColor * 0.3, bandA);
    c = unitOver(c, float4(keyColor * keyA, keyA));
    float colorA = bandA * cover + thin;
    c = unitOver(c, float4(bandColor * colorA, colorA));
    return c * tint.a;
}

// Selection: a cream ring just inside the hex edge between dark keylines, with a soft glow
// that breathes, a glint that travels around it and a faint cream wash over the hex, so the
// selected hex reads at a glance. `width` is the band width in world units.
// The rings on the ground around a tile (selection, attack targets, worked tiles): a
// pointy-top hexagon with rounded corners for a hex of `hexSize` (corner radius), on a quad
// `quad` wide, its center line `inset` inside the hex's edge. Returns the signed distance from
// the center line (+ outside); `q` is the point from the middle, `fromCorner` how far along its
// edge the point lies from the nearest corner (< 0 around the corner).
static float unitHexRing(float2 local, float quad, float hexSize, float inset, thread float2& q, thread float& fromCorner) {
    q = (local * 2.0 - 1.0) * quad * 0.5;
    float2 p = abs(q.yx);   // pointy-top hexagon, as a flat-top one with the axes swapped
    const float3 k = float3(-0.866025404, 0.5, 0.577350269);
    float rc = hexSize * 0.16;
    float inner = hexSize * 0.866 - inset - rc;
    p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
    fromCorner = k.z * inner - abs(p.x);
    p -= float2(clamp(p.x, -k.z * inner, k.z * inner), inner);
    return length(p) * sign(p.y) - rc;
}

// Selection: a cream band between dark keylines with a breathing glow and a glint running round.
static float4 unitSelectionHex(float2 local, float quad, float width, float time, float hexSize) {
    float2 q;
    float fromCorner;
    float d = unitHexRing(local, quad, hexSize, width * 1.3, q, fromCorner);
    float aa = max(fwidth(d), 1e-3);
    float pulse = 0.5 + 0.5 * sin(unitPhase(time, 1375.0));
    float halfBand = width * 0.5, key = width * 0.34;
    float glowA = exp(-abs(d) / (width * (1.9 + 0.8 * pulse))) * (0.3 + 0.22 * pulse);
    float washA = d < 0.0 ? 0.1 * exp(d / (hexSize * 0.22)) : 0.0;
    // Fade the glow before the quad's edge so it never ends in a hard line.
    float fade = 1.0 - smoothstep(quad * 0.38, quad * 0.5, max(abs(q.x), abs(q.y)));
    float4 c = float4(kUnitSelectCream, 1.0) * (max(glowA, washA) * fade);
    float keyA = (1.0 - smoothstep(halfBand + key - aa, halfBand + key, abs(d))) * 0.85;
    c = unitOver(c, float4(kUnitInk * keyA, keyA));
    float bandA = 1.0 - smoothstep(halfBand - aa, halfBand, abs(d));
    float angle = atan2(q.y, q.x) / 6.2831853;
    float glint = pow(0.5 + 0.5 * cos((angle - time * 0.11) * 6.2831853), 30.0);
    float3 band = mix(kUnitSelectCream * 0.92, float3(1.0), 0.45 * saturate(1.0 - abs(d) / halfBand) + 0.6 * glint);
    return unitOver(c, float4(band * bandA, bandA));
}

// An attack target: crimson corner brackets between ink keylines, joined by a thin crimson line,
// over a warm wash that pulses slowly: a reticle, which neither the selection nor any player's
// ring pattern resembles.
static float4 unitThreatHex(float2 local, float quad, float width, float time, float hexSize) {
    float2 q;
    float fromCorner;
    float d = unitHexRing(local, quad, hexSize, width * 1.4, q, fromCorner);
    float aa = max(fwidth(d), 1e-3);
    float pulse = 0.5 + 0.5 * sin(unitPhase(time, 2880.0));
    float halfBand = width * 0.5, key = width * 0.34;
    float arm = hexSize * 0.2;
    float bracket = 1.0 - smoothstep(arm - aa, arm + aa, fromCorner);
    float fade = 1.0 - smoothstep(quad * 0.38, quad * 0.5, max(abs(q.x), abs(q.y)));
    float washA = d < 0.0 ? (0.1 + 0.07 * pulse) * exp(d / (hexSize * 0.24)) : 0.0;
    float glowA = exp(-abs(d) / (width * (1.4 + 0.8 * pulse))) * (0.2 + 0.2 * pulse) * bracket;
    float4 c = float4(kUnitThreat, 1.0) * (max(glowA, washA) * fade);
    float keyA = (1.0 - smoothstep(halfBand + key - aa, halfBand + key, abs(d))) * 0.85 * bracket;
    c = unitOver(c, float4(kUnitInk * keyA, keyA));
    float thin = halfBand * 0.42;
    float thinA = (1.0 - smoothstep(thin - aa, thin + aa, abs(d))) * 0.8 * (1.0 - bracket);
    c = unitOver(c, float4(kUnitThreat * thinA, thinA));
    float bandA = (1.0 - smoothstep(halfBand - aa, halfBand, abs(d))) * bracket;
    float3 band = mix(kUnitThreat, float3(1.0, 0.6, 0.46), 0.4 * saturate(1.0 - abs(d) / halfBand));
    return unitOver(c, float4(band * bandA, bandA));
}

// A worked tile: a thin gilt line between faint ink keylines, further in than the selection
// ring, over a faint gilt wash; still, as it stays on screen while a city is selected.
static float4 unitWorkedHex(float2 local, float quad, float width, float hexSize) {
    float2 q;
    float fromCorner;
    float d = unitHexRing(local, quad, hexSize, width * 2.0, q, fromCorner);
    float aa = max(fwidth(d), 1e-3);
    float halfLine = width * 0.3, key = width * 0.28;
    float washA = d < 0.0 ? 0.11 * exp(d / (hexSize * 0.18)) : 0.0;
    float4 c = float4(kUnitWorked, 1.0) * washA;
    float keyA = (1.0 - smoothstep(halfLine + key - aa, halfLine + key, abs(d))) * 0.6;
    c = unitOver(c, float4(kUnitInk * keyA, keyA));
    float bandA = 1.0 - smoothstep(halfLine - aa, halfLine, abs(d));
    return unitOver(c, float4(kUnitWorked * bandA, bandA));
}

// A Builder's job: an ink line between cream keylines, `inset` inside the tile's edge (further
// in than the selection ring), so it reads on light and dark ground alike. Solid where the
// Builder can start the job this phase; else (`solid` 0) dashed: a dash across the middle of
// each edge and one round each corner, so the hexagon still reads.
static float4 unitJobHex(float2 local, float quad, float width, float hexSize, float inset, float solid) {
    float2 q;
    float fromCorner;
    float d = unitHexRing(local, quad, hexSize, inset, q, fromCorner);
    float aa = max(fwidth(d), 1e-3);
    float halfLine = width * 0.5, key = width * 0.42;
    // Distance along the edge from its middle; past `halfEdge` it runs round the corner.
    float halfEdge = 0.57735027 * (hexSize * 0.8660254 - inset - hexSize * 0.16);
    float along = halfEdge - fromCorner;
    float dash = 1.0 - smoothstep(0.3 * halfEdge - aa, 0.3 * halfEdge + aa, along)
               + smoothstep(0.7 * halfEdge - aa, 0.7 * halfEdge + aa, along);
    float on = mix(saturate(dash), 1.0, solid);
    float keyA = (1.0 - smoothstep(halfLine + key - aa, halfLine + key, abs(d))) * 0.85 * on;
    float4 c = float4(kUnitCream * keyA, keyA);
    float lineA = (1.0 - smoothstep(halfLine - aa, halfLine, abs(d))) * on;
    return unitOver(c, float4(kUnitInk * lineA, lineA));
}

// One of the settler overlay's best sites: a gilt band between ink keylines `inset` inside the
// tile's edge, over the decorations, so hills and trees never hide it; `strength` 1 for the best
// tier, less (a narrower, fainter band) for the next.
static float4 unitSiteHex(float2 local, float quad, float width, float hexSize, float inset, float strength) {
    float2 q;
    float fromCorner;
    float d = unitHexRing(local, quad, hexSize, inset, q, fromCorner);
    float aa = max(fwidth(d), 1e-3);
    float halfBand = width * (0.3 + 0.2 * strength), key = width * 0.3;
    float keyA = (1.0 - smoothstep(halfBand + key - aa, halfBand + key, abs(d))) * (0.45 + 0.4 * strength);
    float4 c = float4(kUnitInk * keyA, keyA);
    float bandA = (1.0 - smoothstep(halfBand - aa, halfBand, abs(d))) * (0.75 + 0.25 * strength);
    float3 band = mix(kUnitWorked, float3(1.0, 0.94, 0.72), 0.35 * saturate(1.0 - abs(d) / halfBand));
    return unitOver(c, float4(band * bandA, bandA));
}

// A hurt unit's HP bar: a pill with an ink outline round a dark well, filled to `hp` (0...1)
// in green, amber or red by how hurt the unit is, lit from above, with faint quarter ticks.
// Just after a hit the part it lost (from `hp` up to `was`) shows cream, shrinking away.
// `size` is the quad (world units).
static float4 unitHPBar(float2 local, float2 size, float hp, float was) {
    float2 q = (local - 0.5) * size;
    float r = size.y * 0.5;
    float d = length(float2(max(abs(q.x) - (size.x * 0.5 - r), 0.0), q.y)) - r;   // + outside the pill
    float aa = max(fwidth(d), 1e-4);
    float edge = r * 0.36;
    float pill = 1.0 - smoothstep(-aa, 0.0, d);
    float well = 1.0 - smoothstep(-edge - aa, -edge, d);
    float x = (q.x + size.x * 0.5 - edge) / max(size.x - 2.0 * edge, 1e-4);
    float ax = max(fwidth(x), 1e-4);
    float filled = 1.0 - smoothstep(hp - ax, hp, x);
    float lost = (1.0 - smoothstep(was - ax, was, x)) * (1.0 - filled);
    float3 green = float3(0.44, 0.74, 0.27), amber = float3(0.96, 0.71, 0.21), red = float3(0.86, 0.21, 0.13);
    float3 fill = hp > 0.5 ? mix(amber, green, smoothstep(0.5, 0.85, hp)) : mix(red, amber, smoothstep(0.2, 0.5, hp));
    fill *= 0.84 + 0.3 * saturate(0.5 + q.y / (2.0 * max(r - edge, 1e-4)));
    float tick = 0.0;
    for (int i = 1; i < 4; i++) tick = max(tick, 1.0 - smoothstep(0.5 * ax, 1.5 * ax, abs(x - 0.25 * float(i))));
    float3 c = mix(float3(0.17, 0.13, 0.10), fill, filled);
    c = mix(c, float3(1.0, 0.95, 0.8), lost);
    c *= 1.0 - 0.3 * tick * filled;
    float4 o = float4(kUnitInk, 1.0) * (pill * 0.92);
    return unitOver(o, float4(c, 1.0) * well);
}

static float unitBoxDistance(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// The fortified marker: a little stone tower front (a block crowned by three merlons, a dark
// gate) with an ink outline and a cream halo, standing beside the unit's base.
static float4 unitFortified(float2 local) {
    float2 p = local;
    float d = unitBoxDistance(p - float2(0.5, 0.37), float2(0.25, 0.23)) - 0.03;
    for (int i = -1; i <= 1; i++) d = min(d, unitBoxDistance(p - float2(0.5 + 0.19 * float(i), 0.67), float2(0.055, 0.09)) - 0.02);
    float aa = max(fwidth(d), 1e-4);
    float ink = 0.06, halo = 0.055;
    float haloA = (1.0 - smoothstep(ink + halo - aa, ink + halo, d)) * 0.9;
    float inkA = 1.0 - smoothstep(ink - aa, ink, d);
    float stoneA = 1.0 - smoothstep(-aa, 0.0, d);
    float3 stone = mix(float3(0.55, 0.52, 0.48), float3(0.88, 0.84, 0.76), saturate(p.y * 1.2 - p.x * 0.35 + 0.05));
    float gate = min(unitBoxDistance(p - float2(0.5, 0.21), float2(0.075, 0.08)), length(p - float2(0.5, 0.29)) - 0.075);
    float3 c = mix(stone, float3(0.2, 0.14, 0.1), 1.0 - smoothstep(-aa, 0.0, gate));
    float4 o = float4(kUnitCream, 1.0) * haloA;
    o = unitOver(o, float4(kUnitInk, 1.0) * inkA);
    return unitOver(o, float4(c, 1.0) * stoneA);
}

// An arrow in flight along the quad's x (tip to the right): a wooden shaft, a broad steel head
// and red fletching swept back toward the nock (widest at the tail, so it never reads as a
// second head), outlined in ink. `size` is the quad (world units).
static float4 unitArrow(float2 local, float2 size) {
    float2 p = float2(local.x * size.x, (local.y - 0.5) * size.y);
    float L = size.x, w = size.y;
    float shaft = unitBoxDistance(p - float2(L * 0.45, 0.0), float2(L * 0.37, w * 0.07));
    float hx = (p.x - L * 0.74) / (L * 0.24);
    float head = max(abs(p.y) - w * 0.4 * saturate(1.0 - hx), max(-hx, hx - 1.0) * L * 0.24);
    float fx = (p.x - L * 0.06) / (L * 0.22);
    float fletch = max(abs(p.y) - w * (0.34 - 0.2 * saturate(fx)), max(-fx, fx - 1.0) * L * 0.22);
    // The nock: a notch cut into the tail between the vanes.
    fletch = max(fletch, -(L * 0.1 - p.x - abs(p.y) * 0.6));
    float d = min(min(shaft, head), fletch);
    float aa = max(fwidth(d), 1e-4);
    float ink = w * 0.12;
    float inkA = 1.0 - smoothstep(ink - aa, ink, d);
    float3 c = float3(0.55, 0.38, 0.22);
    float3 steel = mix(float3(0.50, 0.52, 0.57), float3(0.80, 0.82, 0.86), saturate(0.5 + p.y / (w * 0.5)));
    c = mix(c, steel, 1.0 - smoothstep(-aa, 0.0, head));
    c = mix(c, float3(0.72, 0.29, 0.20), 1.0 - smoothstep(-aa, 0.0, fletch));
    float4 o = float4(kUnitInk, 1.0) * (inkA * 0.9);
    return unitOver(o, float4(c, 1.0) * (1.0 - smoothstep(-aa, 0.0, d)));
}

// A blow landing (`t` 0...1 over its life): a warm flash with spikes thrown out and a ring
// that spreads as it fades.
static float4 unitBurst(float2 local, float t) {
    float2 q = local * 2.0 - 1.0;
    float r = length(q);
    float a = atan2(q.y, q.x);
    float aa = max(fwidth(r), 1e-3);
    float grow = 1.0 - (1.0 - t) * (1.0 - t);
    float ringR = 0.3 + 0.62 * grow, ringW = 0.06 * (1.0 - t) + aa;
    float ring = (1.0 - smoothstep(ringW, ringW + aa, abs(r - ringR))) * (1.0 - t) * 0.9;
    float spikes = pow(0.5 + 0.5 * cos(a * 7.0 + 1.3), 5.0);
    float star = (1.0 - smoothstep(0.0, 0.25 + 0.6 * spikes * grow + aa, r)) * (1.0 - smoothstep(0.25, 0.9, t)) * 0.9;
    float core = exp(-r * r / (0.02 + 0.06 * grow)) * (1.0 - t);
    float al = saturate(max(max(ring, star), core));
    float3 col = mix(float3(1.0, 0.78, 0.38), float3(1.0, 0.98, 0.9), saturate(core * 1.4));
    float edge = (1.0 - smoothstep(ringW + aa, ringW + 2.5 * aa, abs(r - ringR))) * (1.0 - ring) * (1.0 - t) * 0.5;
    float4 o = float4(kUnitInk, 1.0) * edge;
    return unitOver(o, float4(col, 1.0) * al);
}

// A strategic medallion (`MapRenderer+Units.swift`), premultiplied: a dark rim with a soft ink
// outline, the band in the owner's color and ring pattern on that dark ground (the same
// patterns as the base bands, `unitPattern`), a dark keyline, and the cream field with the
// type's pictogram, the middle of its badge cell. Lit from the upper left like the figures.
static float4 unitMedallion(float2 local, float4 cell, float3 team, int pattern, texture2d<float> atlas, sampler smp) {
    float2 q = (local * 2.0 - 1.0) * kUnitMedallionQuad;
    q.y = -q.y;   // local y runs up; flip so q is y-down like the cell
    float rho = length(q);
    float aa = max(fwidth(rho), 1e-4);
    if (rho > 1.0 + 0.06 + aa) return float4(0.0);
    float light = saturate(0.5 + 0.5 * dot(normalize(q + 1e-5), float2(-0.62, -0.78)));
    // Ground: the dark frame with an ink outline outside it.
    float3 frame = float3(0.27, 0.17, 0.10) * (0.82 + 0.36 * light);
    float frameA = 1.0 - smoothstep(1.0 - aa, 1.0, rho);
    float outlineA = (1.0 - smoothstep(1.0 + 0.04 - aa, 1.0 + 0.04, rho)) * 0.45;
    float4 c = float4(kUnitInk * outlineA, outlineA);
    c = unitOver(c, float4(frame * frameA, frameA));
    // The band and its pattern.
    float r1 = 1.0 - kUnitMedallionRim, r0 = r1 - kUnitMedallionBand, mid = 0.5 * (r0 + r1), halfBand = 0.5 * kUnitMedallionBand;
    float across = (rho - mid) / halfBand, aaHalf = aa / halfBand;
    float cover = 1.0;
    if (pattern == 7) {
        // thick-thin: a wide inner line and a thin outer one
        cover = max(1.0 - smoothstep(0.2 - aaHalf, 0.2 + aaHalf, across), smoothstep(0.56 - aaHalf, 0.56 + aaHalf, across));
    } else if (pattern == 1) {
        cover = unitPattern(pattern, 0.0, across, 1.0, aaHalf);
    } else if (pattern >= 2 && pattern <= 6) {
        float period = pattern == 2 ? 4.0 : (pattern == 3 ? 1.5 : (pattern == 4 ? 2.5 : 2.0));
        float perimeter = 6.2831853 * mid;
        float repeats = max(round(perimeter / (period * kUnitMedallionBand)), 6.0);
        float along = (atan2(q.y, q.x) / 6.2831853 + 0.5) * repeats;
        cover = unitPattern(pattern, along, across, perimeter / repeats / halfBand, aaHalf);
    }
    float bandA = (1.0 - smoothstep(halfBand - aa, halfBand, abs(rho - mid))) * cover;
    c = unitOver(c, float4(team * (0.86 + 0.26 * light) * bandA, bandA));
    // The cream field with the pictogram.
    float fieldA = 1.0 - smoothstep(kUnitMedallionField - aa, kUnitMedallionField, rho);
    if (fieldA > 0.0) {
        float2 at = 0.5 + q * (kUnitBadgeField / kUnitMedallionField);
        float4 field = atlas.sample(smp, cell.xy + at * cell.zw);
        c = unitOver(c, field * fieldA);
    }
    return c;
}

// A badge of the owner's color with their emblem (strategic medallions, city tokens): a dark
// rim with an ink outline around the colored disc, lit from the upper left, and the emblem
// cell's emblem over it.
static float4 unitEmblemBadge(float2 local, float4 cell, float3 team, texture2d<float> atlas, sampler smp) {
    float2 q = (local * 2.0 - 1.0) * kUnitBadgeQuad;
    q.y = -q.y;
    float rho = length(q);
    float aa = max(fwidth(rho), 1e-4);
    if (rho > 1.0 + 0.1 + aa) return float4(0.0);
    float light = saturate(0.5 + 0.5 * dot(normalize(q + 1e-5), float2(-0.62, -0.78)));
    float outlineA = (1.0 - smoothstep(1.0 + 0.1 - aa, 1.0 + 0.1, rho)) * 0.45;
    float rimA = 1.0 - smoothstep(1.0 - aa, 1.0, rho);
    float4 c = float4(kUnitInk * outlineA, outlineA);
    c = unitOver(c, float4(float3(0.27, 0.17, 0.10) * (0.85 + 0.3 * light) * rimA, rimA));
    float discA = 1.0 - smoothstep(kUnitBadgeDisc - aa, kUnitBadgeDisc, rho);
    float shade = 0.84 + 0.3 * light - 0.12 * saturate(rho / kUnitBadgeDisc);
    c = unitOver(c, float4(team * shade * discA, discA));
    // The emblem cell's emblem spans 0.8 of it.
    float2 at = 0.5 + q * (0.4 / (kUnitBadgeEmblem * kUnitBadgeDisc));
    if (all(at > 0.0) && all(at < 1.0)) c = unitOver(c, atlas.sample(smp, cell.xy + at * cell.zw) * discA);
    return c;
}

// Smoke rising from a damaged city's roof (`citySmoke`), premultiplied: round puffs that
// billow up from embers at the quad's foot, drift east, swell, lighten and thin out, each lit
// from the upper left. `local` is 0...1 across the quad (y up), `aspect` its width over its
// height, `seed` the column's own timing. A puff rises for six seconds (the clock wraps after
// an hour, a whole number of rises). `pale`: a tribal village's cooking fire instead, smaller
// puffs of pale smoke with no embers (they glow in its hearth, `tribalVillageGround`).
static float4 citySmoke(float2 local, float aspect, float seed, float time, bool pale) {
    float4 c = float4(0.0);
    if (!pale) {
        float2 e = (local - float2(0.5, 0.05)) * float2(aspect, 1.0) / 0.05;
        float flicker = 0.65 + 0.35 * sin(unitPhase(time, 4680.0) + seed * 5.0);
        float ember = exp(-dot(e, e)) * flicker;
        c = float4(float3(1.0, 0.46, 0.12) * ember, ember * 0.85);
    }
    // The pale column's puffs are smaller and closer together, so they run into one wisp.
    int puffs = pale ? 10 : 6;
    for (int i = 0; i < puffs; i++) {
        float age = fract(time * (600.0 / 3600.0) + float(i) / float(puffs) + seed * 0.37);
        float2 center = float2(0.5 + 0.07 * sin(age * 4.0 + seed * 3.0 + float(i) * 1.7) + (pale ? 0.1 : 0.14) * age * age,
                               0.06 + 0.76 * age);
        float r = pale ? 0.04 + 0.075 * age : 0.06 + 0.14 * age;
        float2 d = (local - center) * float2(aspect, 1.0) / r;
        float body = saturate(1.0 - dot(d, d));
        float alpha = sqrt(body) * (1.0 - age * age) * smoothstep(0.0, 0.08, age) * (pale ? 0.75 : 1.0);
        float lit = saturate(0.55 - 0.35 * d.x + 0.4 * d.y);
        float3 tone = pale ? mix(float3(0.7, 0.69, 0.68), float3(0.97, 0.96, 0.95), saturate(age * 1.4)) * (0.74 + 0.3 * lit)
                           : mix(float3(0.1, 0.09, 0.085), float3(0.47, 0.46, 0.47), saturate(age * 1.2)) * (0.75 + 0.45 * lit);
        c = unitOver(c, float4(tone * alpha, alpha));
    }
    return c;
}

// How much darker and paler soil covers a point of a tribal village's ground (`g`, in blotch
// cells): soft flattened blots, one per cell, as the kit's grounds are painted.
static float2 tribalVillageBlotches(float2 g) {
    float2 cell = floor(g);
    float dark = 0.0, pale = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int cx = int(cell.x) + dx, cy = int(cell.y) + dy;
            float a = hash2(cx, cy), b = hash2(cx + 57, cy - 31), k = hash2(cx - 83, cy + 19);
            float2 d = (g - float2(float(cx) + a, float(cy) + b)) / float2(0.5 + 0.35 * k, 0.32 + 0.22 * a);
            float w = (1.0 - smoothstep(0.55, 1.0, dot(d, d))) * (0.16 + 0.16 * b);
            if (k < 0.5) dark = max(dark, w); else pale = max(pale, w);
        }
    }
    return float2(dark, pale);
}

// A tribal village's trodden ground (`CitySpriteKind.ground` with w 1), premultiplied: packed
// earth in a soft patch with a lobed rim, blotched with darker and paler soil at two scales,
// worn paler round the hearth, with scuffs and pebbles; the hearth a ring of stones round a bed
// of ash, its embers glowing while the village is in sight. No lanes and no square: it is no
// town. `local` is 0...1 across the quad (y north); `data`: the hearth (quad fractions) and the
// village's seed (z); `tint`: the terrain's, as a city's ground takes it.
static float4 tribalVillageGround(float2 local, float4 data, float3 tint, bool fogged, float time) {
    float2 p = local - 0.5;
    float seed = data.z, rho = length(p);
    if (rho > 0.5) return float4(0.0);
    // A ragged rim (noise round the circle: lobes and bays of its own), trodden thinner toward
    // it, where the grass shows through in places.
    float2 o = float2(seed * 53.0, seed * 31.0);
    float2 dir = p / max(rho, 1e-4);
    float rim = 0.3 + 0.1 * vnoise(dir * 1.9 + o, 0) + 0.05 * vnoise(dir * 4.3 + o * 1.7, 0);
    float a = 1.0 - smoothstep(rim - 0.1, rim + 0.01, rho);
    a *= mix(0.62 + 0.3 * vnoise(p * 11.0 - o, 0), 0.9, 1.0 - smoothstep(0.1, rim, rho));
    if (a < 1.0 / 255.0) return float4(0.0);
    float2 h = (local - data.xy) * float2(1.0, 1.15);
    float hd = length(h);
    float2 big = tribalVillageBlotches(p * 9.0 + seed * 37.0);
    float2 small = tribalVillageBlotches(p * 19.0 - seed * 23.0);
    float3 col = float3(0.64, 0.55, 0.41);
    col = mix(col, float3(0.5, 0.41, 0.3), max(big.x, 0.9 * small.x));
    col = mix(col, float3(0.74, 0.65, 0.5), max(big.y, 0.9 * small.y));
    col = mix(col, float3(0.79, 0.71, 0.56), 0.45 * (1.0 - smoothstep(0.04, 0.2, hd)));
    // Scuffs and pebbles, dark and pale.
    float2 g = p * 46.0 + seed * 13.0, cell = floor(g);
    int cx = int(cell.x), cy = int(cell.y);
    float roll = hash2(cx, cy);
    if (roll < 0.32) {
        float2 d = (g - cell - 0.25 - 0.5 * float2(hash2(cx + 5, cy), hash2(cx, cy + 9))) / float2(0.2 + 0.12 * roll, 0.14 + 0.08 * roll);
        float m = (1.0 - smoothstep(0.5, 1.0, dot(d, d))) * (0.3 + 0.15 * hash2(cx + 3, cy + 3));
        col = mix(col, hash2(cx - 7, cy) < 0.45 ? float3(0.74, 0.68, 0.58) : float3(0.36, 0.29, 0.21), m);
    }
    float4 c = float4(col * tint * a, a);
    // The hearth: a bed of ash with its embers, ringed with stones lit from the upper left.
    float ash = (1.0 - smoothstep(0.026, 0.038, hd)) * 0.92;
    c = unitOver(c, float4(float3(0.25, 0.23, 0.22) * ash, ash));
    if (!fogged) {
        float flicker = 0.7 + 0.3 * sin(unitPhase(time, 4680.0) + seed * 9.0);
        float ember = exp(-hd * hd / 0.00022) * flicker * 0.9;
        c = unitOver(c, float4(float3(1.0, 0.5, 0.14) * ember, ember));
    }
    for (int i = 0; i < 7; i++) {
        float angle = (float(i) + 0.35 * hash2(i, int(seed * 997.0))) * 0.8976 + seed * 6.2832;
        float2 d = (h - float2(cos(angle), sin(angle)) * 0.046) / float2(0.017, 0.0135);
        float stone = 1.0 - smoothstep(0.55, 1.0, dot(d, d));
        if (stone <= 0.0) continue;
        float lit = saturate(0.6 - 0.4 * d.x + 0.4 * d.y);
        c = unitOver(c, float4(float3(0.58, 0.56, 0.52) * tint * (0.62 + 0.5 * lit) * stone, stone));
    }
    return c;
}

// A city's token at strategic zoom (`cityToken`), premultiplied: a crenellated plate in the
// owner's color with a dark rim and a soft ink outline, lit from the upper left, carrying the
// owner's emblem (the emblem cell, `cell`). A capital's rim is gilt and its middle merlon
// taller. `local` is 0...1 across the quad (y up).
static float cityBox(float2 p, float2 c, float2 h) {
    float2 d = abs(p - c) - h;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
static float4 cityToken(float2 local, float4 cell, float3 team, float capital, texture2d<float> atlas, sampler smp) {
    float2 q = local * 2.0 - 1.0;   // y up
    float body = cityBox(q, float2(0.0, -0.18), float2(0.74, 0.52)) - 0.08;
    float merlons = min(cityBox(q, float2(-0.56, 0.44), float2(0.16, 0.16)), cityBox(q, float2(0.56, 0.44), float2(0.16, 0.16)));
    merlons = min(merlons, cityBox(q, float2(0.0, 0.44 + 0.08 * capital), float2(0.16, 0.16 + 0.08 * capital)));
    float d = min(body, merlons - 0.04);
    float aa = max(fwidth(d), 1e-4);
    if (d > 0.1 + aa) return float4(0.0);
    float light = saturate(0.55 - 0.35 * q.x + 0.3 * q.y);
    float outlineA = (1.0 - smoothstep(0.09 - aa, 0.09, d)) * 0.5;
    float4 c = float4(kUnitInk * outlineA, outlineA);
    float rimA = 1.0 - smoothstep(-aa, 0.0, d);
    float3 rim = mix(float3(0.27, 0.17, 0.10), float3(0.78, 0.6, 0.26), capital) * (0.8 + 0.4 * light);
    c = unitOver(c, float4(rim * rimA, rimA));
    float fillA = 1.0 - smoothstep(-0.12 - aa, -0.12, d);
    c = unitOver(c, float4(team * (0.78 + 0.36 * light) * fillA, fillA));
    // The emblem cell's emblem spans 0.8 of it; here it fills most of the plate's body.
    float2 at = 0.5 + (q - float2(0.0, -0.16)) * float2(0.5, -0.5) / 0.9;
    if (all(at > 0.0) && all(at < 1.0)) c = unitOver(c, atlas.sample(smp, cell.xy + at * cell.zw) * fillA);
    return c;
}

// An instance's color at a fragment, premultiplied, before atmosphere.
// A figure's data: x is team paint, y nearness to the silhouette (red and green, or blue and
// alpha in a cell shared by two M2 types).
static float2 unitData(UnitOut in, texture2d<float> atlas, sampler smp) {
    float4 d = atlas.sample(smp, in.maskUV);
    return in.maskHigh > 0.5 ? d.ba : d.rg;
}

static float4 unitColor(UnitOut in, constant Uniforms& u, texture2d<float> atlas, texture2d<float> town, sampler smp) {
    int kind = int(in.params.x + 0.5);
    float time = u.cameraUp.w;
    float4 c;
    if (kind == 0) {
        float4 body = atlas.sample(smp, in.uv);
        float2 data = unitData(in, atlas, smp);   // x: team paint, y: nearness to the silhouette
        c = unitFigure(body, data.x, in.tint.rgb, in.params.y) * in.tint.a;
        // The rim lies under the figure and fades out at the feet, so it stays planted.
        float4 rim = unitRim(1.0 - data.y, unitTexelsPerPixel(in.uv), in.cellLocal, kUnitAtlasTexels.x * in.cell.z, in.params.z, u)
                   * smoothstep(kUnitGroundLine + 0.005, kUnitGroundLine + 0.05, in.cellLocal.y);
        c = unitOver(rim * in.tint.a, c);
    } else if (kind == 1) {
        float3 w = unitStandardWarp(in.cellLocal, in.params.y, in.params.z, time);
        float2 uv = in.cell.xy + float2(w.x, 1.0 - w.y) * in.cell.zw;
        c = atlas.sample(smp, uv);
        c.rgb *= w.z;
        c = unitDimmed(c, in.params.y) * in.tint.a;
        float field = 1.0 - atlas.sample(smp, uv + in.tint.xy).g;
        c = unitOver(unitRim(field, unitTexelsPerPixel(uv), w.xy, kUnitAtlasTexels.x * in.cell.z, in.tint.z, u) * in.tint.a, c);
    } else if (kind == 2) {
        // Darkest at the feet, fading and softening (a blurrier mip) toward the tip.
        float t = saturate((in.local.y - in.params.z) / max(1.0 - in.params.z, 1e-3));
        float a = atlas.sample(smp, in.uv, bias(1.0 + 2.0 * t)).a;
        a *= in.tint.a * (1.0 - 0.65 * t);
        c = float4(kUnitCastTint * a, a);
    } else if (kind == 3 || kind == 8) {
        c = unitBase(in.local, float2(in.params.w, in.quadHeight), in.tint, in.params.z, in.params.y, time, kind == 8 ? 1 : 0, in.cell.xy);
    } else if (kind == 4) {
        // An emblem painted on a shield: shaded like the shield under it.
        c = atlas.sample(smp, in.uv);
        c.rgb *= 1.08 - 0.22 * saturate(in.local.x - in.local.y + 0.5);
        c = unitDimmed(c, in.params.y) * in.tint.a;
    } else if (kind == 6) {
        // Selected medallion: a cream ring between dark keylines with a breathing glow.
        float2 q = in.local * 2.0 - 1.0;
        float rho = length(q);
        float aa = max(fwidth(rho), 1e-4);
        float pulse = 0.5 + 0.5 * sin(unitPhase(time, 1375.0));
        float band = smoothstep(0.8 - aa, 0.8, rho) * (1.0 - smoothstep(0.87 - aa, 0.87, rho));
        float key = smoothstep(0.765 - aa, 0.765, rho) * (1.0 - smoothstep(0.905 - aa, 0.905, rho)) * 0.85;
        float glow = exp(-max(rho - 0.905, 0.0) * (22.0 - 8.0 * pulse)) * (0.45 + 0.3 * pulse) * step(0.765, rho)
                   * (1.0 - smoothstep(0.96, 1.0, rho));
        c = float4(kUnitSelectCream * glow, glow);
        c = unitOver(c, float4(kUnitInk * key, key));
        c = unitOver(c, float4(kUnitSelectCream * band, band)) * in.tint.a;
    } else if (kind == 7) {
        c = unitSelectionHex(in.local, in.params.w, in.params.z, time, in.params.y > 0.0 ? in.params.y : u.map.x) * in.tint.a;
    } else if (kind == 15) {
        c = unitThreatHex(in.local, in.params.w, in.params.z, time, in.params.y > 0.0 ? in.params.y : u.map.x) * in.tint.a;
    } else if (kind == 16) {
        c = unitWorkedHex(in.local, in.params.w, in.params.z, in.params.y > 0.0 ? in.params.y : u.map.x) * in.tint.a;
    } else if (kind == 22) {
        c = unitJobHex(in.local, in.params.w, in.params.z, in.params.y, in.tint.y, in.tint.x) * in.tint.a;
    } else if (kind == 23) {
        c = unitSiteHex(in.local, in.params.w, in.params.z, in.params.y, in.tint.y, in.tint.x) * in.tint.a;
    } else if (kind == 17) {
        c = unitHPBar(in.local, float2(in.params.w, in.quadHeight), in.params.y, in.params.z) * in.tint.a;
    } else if (kind == 18) {
        c = unitFortified(in.local) * in.tint.a;
    } else if (kind == 19) {
        c = unitArrow(in.local, float2(in.params.w, in.quadHeight)) * in.tint.a;
    } else if (kind == 20) {
        c = unitBurst(in.local, in.params.y) * in.tint.a;
    } else if (kind == 21) {
        // A hit flash: the figure's silhouette in warm white over it.
        float a = atlas.sample(smp, in.uv).a * in.tint.a;
        c = float4(in.tint.rgb * a, a);
    } else if (kind == 9) {
        c = unitDimmed(unitMedallion(in.local, in.cell, in.tint.rgb, int(in.params.z + 0.5), atlas, smp), in.params.y) * in.tint.a;
    } else if (kind == 10) {
        c = unitDimmed(unitEmblemBadge(in.local, in.cell, in.tint.rgb, atlas, smp), in.params.y) * in.tint.a;
    } else if (kind == 11) {
        // A city piece: the owner's color multiplied into its team paint, as on the figures.
        float4 piece = town.sample(smp, in.uv, bias(-0.25 * (1.0 - smoothstep(0.7, 1.0, u.eye.w))));
        float team = in.params.z > 0.5 ? town.sample(smp, in.maskUV).a : 0.0;
        c = unitFigure(piece, team, in.tint.rgb, 0.0) * in.tint.a;
        if (in.params.y > 0.5) c = applyExploredFog(c);
    } else if (kind == 12) {
        // A city's ground, flat: tinted toward the terrain it lies on. A tribal village's
        // (flags.w 1) is procedural, with no lanes.
        if (in.params.z > 0.5) {
            c = tribalVillageGround(in.local, in.cell, in.tint.rgb, in.params.y > 0.5, time);
        } else {
            c = town.sample(smp, in.uv);
            c.rgb *= in.tint.rgb;
        }
        c *= in.tint.a;
        if (in.params.y > 0.5) c = applyExploredFog(c);
    } else if (kind == 13) {
        c = citySmoke(in.local, in.params.w / max(in.quadHeight, 1e-4), in.params.z, time, in.params.y > 0.5) * in.tint.a;
    } else if (kind == 14) {
        c = cityToken(in.local, in.cell, in.tint.rgb, in.params.z, atlas, smp) * in.tint.a;
        if (in.params.y > 0.5) c = applyExploredFog(c);
    } else if (kind == 24) {
        // A tribal village's strategic token: its ivory badge cell, never a player's colour.
        c = atlas.sample(smp, in.uv) * in.tint.a;
        if (in.params.y > 0.5) c = applyExploredFog(c);
    } else {
        c = atlas.sample(smp, in.uv) * in.tint;
        if (in.params.y > 0.0) c = unitDimmed(c, in.params.y);
    }
    return c;
}

// How opaque an instance is at a fragment, for the stencil and tap passes: the painted art
// alone (no rim, no shading), so those passes stay cheap.
static float unitCoverage(UnitOut in, constant Uniforms& u, texture2d<float> atlas, texture2d<float> town, sampler smp) {
    int kind = int(in.params.x + 0.5);
    if (kind == 0 || kind == 4) return atlas.sample(smp, in.uv).a * in.tint.a;
    if (kind == 11) return town.sample(smp, in.uv).a * in.tint.a;
    if (kind == 1) {
        float3 w = unitStandardWarp(in.cellLocal, in.params.y, in.params.z, u.cameraUp.w);
        return atlas.sample(smp, in.cell.xy + float2(w.x, 1.0 - w.y) * in.cell.zw).a * in.tint.a;
    }
    if (kind == 5) return atlas.sample(smp, in.uv).a * in.tint.a;
    return unitColor(in, u, atlas, town, smp).a;
}

fragment float4 unit_fragment(UnitOut in [[stage_in]],
                              constant Uniforms& u [[buffer(1)]],
                              texture2d<float> atlas [[texture(0)]],
                              texture2d<float> town [[texture(1)]],
                              sampler smp [[sampler(0)]]) {
    if (int(in.params.x + 0.5) == 8) {
        // A base fill mixes two colors, whose atmosphere the corners worked out (`unit_vertex`).
        float4 w = unitBase(in.local, float2(in.params.w, in.quadHeight), in.tint, in.params.z, in.params.y, u.cameraUp.w, 2, in.cell.xy);
        if (w.z < 1.0 / 255.0) discard_fragment();
        return float4(in.shade * w.x + in.shade2 * w.y, w.z);
    }
    // A figure's quad is mostly empty: texels with no paint and beyond the rim's reach are
    // dropped before any shading.
    if (int(in.params.x + 0.5) == 0 && atlas.sample(smp, in.uv).a < 1.0 / 255.0
        && (1.0 - unitData(in, atlas, smp).y) * kUnitRimRange > in.reach) discard_fragment();
    float4 c = unitColor(in, u, atlas, town, smp);
    // Figures write their rank into the stencil wherever a fragment survives, so the empty
    // parts of their quads must not (`MapRenderer+Layering.swift`); nothing empty pays for the
    // atmosphere either.
    if (c.a < 1.0 / 255.0) discard_fragment();
    if (int(in.params.x + 0.5) == 2) return float4(in.shade * c.a, c.a);   // cast shadow (`unit_vertex`)
    return applyAtmosphere(c, in.world, in.position, u);
}

// A figure group's upper parts, stencil only (no color): they reset the stencil so trees in
// front are drawn over a figure's legs but never its body, shield or standard
// (`MapRenderer+Layering.swift`). `cut` is the leg height as a fraction of the figure's cell;
// the bodies' own legs end lower (`kUnitLegTop`), and trees stop there. City pieces keep
// their rank all over: a plant standing in front of a settlement covers whatever of it it
// overlaps, as it would a hill.
fragment float4 unit_upper_fragment(UnitOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]],
                                    constant float& cut [[buffer(3)]],
                                    texture2d<float> atlas [[texture(0)]],
                                    texture2d<float> town [[texture(1)]],
                                    sampler smp [[sampler(0)]]) {
    int kind = int(in.params.x + 0.5);
    if (kind == 11) discard_fragment();
    if (kind == 0 && in.rise < min(cut, kUnitLegTop) * in.quadHeight) discard_fragment();
    if (unitCoverage(in, u, atlas, town, smp) < 1.0 / 255.0) discard_fragment();
    return float4(0.0);
}

// Tap targets (`MapRenderer+Picking.swift`): the tile whose token covers this texel, as an
// index into the frame's tappable tiles plus one. Untappable instances (shadows, markers) and
// fragments under half coverage leave what is behind them.
fragment ushort unit_pick_fragment(UnitOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(1)]],
                                   const device ushort* owners [[buffer(2)]],
                                   texture2d<float> atlas [[texture(0)]],
                                   texture2d<float> town [[texture(1)]],
                                   sampler smp [[sampler(0)]]) {
    ushort owner = owners[in.instance];
    if (owner == 0 || unitCoverage(in, u, atlas, town, smp) < 0.5) discard_fragment();
    return owner;
}
"""#
}
