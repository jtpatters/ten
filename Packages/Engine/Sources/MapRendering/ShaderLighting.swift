extension Shaders {
    /// Lighting and atmosphere shared by every pass, so the ground, decorations and units
    /// agree on light direction, fog and haze. Signatures are a contract; bodies are free.
    static let lighting = #"""
// Direction toward the sun (west-north-west, high). Sprites are painted lit from the left.
static float3 sunDirection(constant Uniforms& u) { return u.sun.xyz; }

// Explored-but-not-visible look, for ground and sprites alike: desaturated, cooler and darker,
// but with enough value and hue left to read the terrain. Premultiplied color in and out (the
// cool lift scales with alpha, so sprite edges stay clean).
static float4 applyExploredFog(float4 c) {
    float lum = dot(c.rgb, float3(0.30, 0.59, 0.11));
    float3 cool = lum * float3(0.86, 0.93, 1.08);
    c.rgb = mix(c.rgb, cool, 0.62) * 0.66 + float3(0.012, 0.020, 0.040) * c.a;
    return c;
}

namespace atmo {
// Value noise that repeats with `period` lattice cells in both axes, so cloud shadows can drift
// diagonally and still come back exactly when the clock wraps (hourly) and at the map's seam.
// The lattice wraps with float math (`wrapIndex`): every fragment of every pass runs this, and
// integer `%` by a non-constant is a slow software routine on Apple GPUs.
static float pnoise(float2 p, int2 period) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 s = f * f * (3.0 - 2.0 * f);
    int2 c0 = int2(i), c1 = c0 + 1;
    c0 = int2(wrapIndex(c0.x, period.x), wrapIndex(c0.y, period.y));
    c1 = int2(wrapIndex(c1.x, period.x), wrapIndex(c1.y, period.y));
    float a = hash2(c0.x, c0.y), b = hash2(c1.x, c0.y), c = hash2(c0.x, c1.y), d = hash2(c1.x, c1.y);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}
} // namespace atmo

// Last step of every fragment shader: drifting cloud shadows (scaled by `shadows`), distance
// haze, a gentle grade and a soft vignette. `world` is the fragment's world position,
// `fragCoord` its [[position]]. Premultiplied color in and out. Everything stays subtle: units
// must keep their contrast.
static float4 applyAtmosphere(float4 c, float3 world, float4 fragCoord, constant Uniforms& u, float shadows = 1.0) {
    float tw = u.map.y, time = u.cameraUp.w;

    // Cloud shadows, cast along the sun onto the ground (sprites take the shadow of the point
    // they stand on). The lattice divides the map width so the pattern wraps seamlessly, and the
    // drift covers whole lattice periods per hour, so the hourly clock wrap is invisible too.
    float2 g = world.xy - world.z * u.sun.xy / max(u.sun.z, 0.2);
    bool wraps = u.dims.z > 0.5;
    int2 period = int2(wraps ? max(1, int(round(u.dims.x / 5.0))) : 64, 18);
    float freq = wraps ? float(period.x) / (u.dims.x * tw) : 1.0 / (5.0 * tw);
    float perHourX = max(1.0, round(43.0 / float(period.x))) * float(period.x);
    float2 cp = g * freq + float2(perHourX, 18.0) * (time / 3600.0);
    float n = atmo::pnoise(cp, period) * 0.65 + atmo::pnoise(cp * 2.0 + 3.7, period * 2) * 0.35;
    float shadow = smoothstep(0.56, 0.74, n) * 0.07 * shadows;
    c.rgb *= 1.0 - shadow * float3(1.0, 0.92, 0.76);

    // Haze toward the horizon in tilted views, only when zoomed out far enough that distance
    // reads as distance: farther than the look-at point fades toward a pale sky blue.
    float pitch = u.viewport.z;
    float ref = u.eye.z / max(cos(pitch), 0.2);
    float far = length(world - u.eye.xyz) / max(ref, 1.0);
    float haze = smoothstep(1.1, 1.45, far) * 0.18 * smoothstep(0.05, 0.4, pitch) * smoothstep(1.0, 2.5, u.eye.w);
    c.rgb = mix(c.rgb, float3(0.72, 0.80, 0.88) * c.a, haze);

    // Gentle grade toward warm afternoon light: shadows lean cool, lights lean warm.
    float lum = dot(c.rgb, float3(0.30, 0.59, 0.11)) / max(c.a, 1e-3);
    c.rgb *= mix(float3(0.98, 0.99, 1.03), float3(1.025, 1.0, 0.97), smoothstep(0.12, 0.7, lum));

    // Soft vignette.
    float2 sp = fragCoord.xy / max(u.viewport.xy, float2(1.0)) - 0.5;
    sp.x *= u.viewport.x / max(u.viewport.y, 1.0);
    float v = smoothstep(0.45, 1.05, length(sp));
    c.rgb *= 1.0 - v * 0.08;
    return c;
}
"""#
}
