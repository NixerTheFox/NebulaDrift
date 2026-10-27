#include <metal_stdlib>
using namespace metal;

// Must match `Uniforms` in main.swift.
struct Uniforms {
    float2 resolution;
    float time;
    float aspect;
    float bass;
    float mid;
    float treble;
    float level;
    float beat;
    float speed;
    float hue;
    float roll;
    float travel;
    float dither;          // 0 off, 1 smooth, 2 retro
    float ditherStrength;  // 1 light ... 4 heavy
    float aberration;      // 0 off, 1 on
    float4 blackHole;      // centre x, y, z in camera space (screen frame), Schwarzschild radius r_s
    float4 blackHole2;     // disc thickness (half-height / radius), tidal stress (0...1), seed, spin (+1/-1)
    float4 glass;          // cockpit glass: on (0/1), unused...
    float4 blackHole3;     // disc normal x, y, z, fade-in alpha
    float4 blackHole4;     // inner edge, outer edge (r_s), temperature scale, kind (0 std, 1 quasar, 2 bare, 3 torus)
};

#define MAX_RINGS 10
#define MAX_NEBULAE 2
#define MAX_GALAXIES 2
#define NEBULA_LAYERS 4
#define GALAXY_LAYERS 7
#define STAR_FAR 6.0

// MARK: - Helpers

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = float2(1.6 * p.x + 1.2 * p.y, -1.2 * p.x + 1.6 * p.y) + 3.1;
        a *= 0.5;
    }
    return v;
}

static float3 palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
}

static float2 rot(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

/// Sparse point stars on a grid in object space, drawn at a fixed on-screen size so that
/// they stay pin-pricks while the nebula or galaxy around them grows enormous.
/// Returns brightness. `density` is the fraction of grid cells holding a star.
static float pointStars(float2 p, float grid, float objectRadius, float seed, float density) {
    float2 g = p * grid + seed * 7.0;
    float2 cell = floor(g);
    float h = hash21(cell + seed);
    float2 sc = cell + 0.5 + (float2(hash21(cell + 3.1), hash21(cell + 7.7)) - 0.5) * 0.7;
    float sdUV = length(g - sc) * objectRadius / grid;   // distance in screen units
    float sharp = sdUV / 0.0032;
    float on = step(1.0 - density, h) * (0.35 + 0.65 * (h - (1.0 - density)) / density);
    return on * exp(-sharp * sharp);
}

// MARK: - Cloud palette

/// Colours for gas clouds, from real narrow-band photos: crimson, magenta, violet, blue, teal, gold, green.
static float3 cloudPalette(float h) {
    const float3 pal[7] = { float3(0.85, 0.18, 0.3), float3(0.8, 0.25, 0.72), float3(0.5, 0.35, 1.0),
                            float3(0.28, 0.5, 1.0), float3(0.15, 0.68, 0.75), float3(0.95, 0.62, 0.25),
                            float3(0.3, 0.82, 0.55) };
    return pal[min(int(fract(h) * 7.0), 6)];
}

// MARK: - Galaxy structure

/// Soft beads on a grid in object space (star-forming knots, clusters). Returns brightness 0...1.
static float beads(float2 p, float grid, float seed, float density) {
    float2 gp = p * grid + seed * 3.0;
    float2 cell = floor(gp);
    float h = hash21(cell + seed * 1.7);
    float2 c = cell + 0.5 + (float2(hash21(cell + 2.1), hash21(cell + 6.3)) - 0.5) * 0.6;
    float r = length(gp - c);
    return step(1.0 - density, h) * exp(-r * r * 14.0) * (0.5 + 0.5 * hash21(cell + 9.9));
}

/// Light and dust of one layer of a galaxy disc at disc position `p` (in galaxy radii).
/// Types: 0 grand-design spiral, 1 flocculent spiral, 2 barred spiral, 3 irregular starburst,
///        4 lenticular with a dust ring, 5 elliptical, 6 ring galaxy.
static void galaxyLayer(float2 p, float d, int type, float arms, bool barred, float pitch, float seed, float detail,
                        float spin, float3 coreCol, float3 armCol, constant Uniforms& u,
                        thread float3& g, thread float& dust, thread float& armOut) {
    const float3 hii = float3(1.0, 0.32, 0.55); // hydrogen-alpha pink of star-forming regions
    float disc = exp(-d * 2.6);
    g = float3(0.0);
    dust = 0.0;
    armOut = 0.0;
    if (type <= 2) {
        float a = atan2(p.y, p.x) + spin;
        float wobble = (fbm(p * 2.2 + seed * 5.0) - 0.5) * 1.1; // real arms wander and branch
        float rIn = barred ? 0.24 : 0.05;
        float spiral = a - log(max(d, rIn)) * pitch + wobble;
        float armP = pow(0.5 + 0.5 * cos(arms * spiral), mix(1.6, 3.2, fract(seed * 9.7)));
        if (type == 1) {
            // Flocculent: many short, patchy arm segments instead of a few long arms.
            float s2 = a - log(max(d, 0.05)) * pitch + (fbm(p * 2.5 + seed) - 0.5) * 2.0;
            armP = pow(0.5 + 0.5 * cos(6.0 * s2), 1.8) * smoothstep(0.3, 0.75, fbm(p * 3.5 + seed * 3.0)) * 1.4;
        }
        float radial = smoothstep(rIn, rIn + 0.22, d) * smoothstep(1.4, 0.45, d);
        float clumps = mix(1.0, 0.35 + 1.1 * fbm(p * 9.0 + seed * 7.0), detail);
        float arm = armP * radial * clumps;
        float spur = pow(0.5 + 0.5 * cos(arms * spiral + (fbm(p * 6.0 + seed) - 0.5) * 4.0), 6.0) * radial * 0.25 * detail;
        armOut = arm;
        // Plenty of diffuse starlight between the arms, warm near the centre and bluer outward.
        g += mix(coreCol, armCol, smoothstep(0.1, 0.8, d)) * disc * 0.75;
        g += armCol * (arm + spur) * exp(-d * 1.4) * (1.5 + 1.3 * u.mid);
        if (barred) {
            float2 pb = rot(p, -seed * 6.28);
            g += coreCol * exp(-pb.x * pb.x * 7.0 - pb.y * pb.y * 150.0) * smoothstep(0.45, 0.2, abs(pb.x)) * 1.1;
        }
        // Dark dust lanes hugging the inner edge of each arm, threaded with fine filaments.
        float lane = pow(0.5 + 0.5 * cos(arms * spiral + 0.6), 8.0) * radial;
        float fil = smoothstep(0.45, 0.8, fbm(p * 22.0 + seed * 3.0)) * detail;
        dust = lane * (0.6 + 0.6 * fil) * exp(-d * 1.0) * 1.4 + fil * (arm + disc) * 0.35;
        // Pink star-forming knots strung along the arms.
        g += hii * beads(p, 45.0, seed, 0.45) * saturate(arm * 1.5) * detail * (0.8 + 1.6 * u.treble) * 2.2;
    } else if (type == 3) {
        // Irregular starburst: clumpy, lopsided, full of pink nurseries.
        float blob = fbm(p * 2.2 + seed * 5.0);
        float dens = pow(saturate(blob * 1.3 - 0.15), 2.0) * (0.5 + fbm(p * 5.0 + seed * 9.0)) * exp(-d * 1.8) * 2.2;
        armOut = dens;
        g += mix(armCol, float3(0.85, 0.85, 1.0), 0.3) * dens * (1.0 + u.mid) + coreCol * exp(-d * 4.0) * 0.2;
        g += hii * beads(p, 28.0, seed, 0.35) * dens * detail * (0.8 + 1.6 * u.treble) * 3.0;
        dust = smoothstep(0.55, 0.8, fbm(p * 7.0 + seed * 2.0)) * dens * 0.8 * detail;
    } else if (type == 4) {
        // Lenticular / Sombrero: smooth old disc crossed by a dark ring of dust.
        g += coreCol * (exp(-d * 3.0) * 0.6 + exp(-d * 1.4) * 0.12);
        float dr = mix(0.45, 0.75, fract(seed * 6.1));
        dust = exp(-pow((d - dr) / 0.07, 2.0)) * 1.3 * (0.7 + 0.5 * fbm(p * 12.0 + seed));
    } else if (type == 5) {
        g += coreCol * exp(-d * 3.5) * 0.35;
    } else {
        // Ring galaxy: a blue ring of young stars around an old core.
        float ringR = mix(0.55, 0.8, fract(seed * 4.3));
        float ring = exp(-pow((d - ringR - (fbm(p * 3.0 + seed) - 0.5) * 0.12) / 0.08, 2.0)) * (0.5 + 0.9 * fbm(p * 8.0 + seed));
        armOut = ring;
        g += armCol * ring * 1.6 * (1.0 + u.mid) + coreCol * disc * 0.15;
        g += hii * beads(p, 50.0, seed, 0.3) * ring * detail * (0.6 + 1.6 * u.treble) * 1.5;
        dust = ring * 0.25 * detail;
    }
}

// MARK: - Nebula background

struct BgOut {
    float4 position [[position]];
    float2 ndc;
};

vertex BgOut bgVertex(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    BgOut o;
    o.position = float4(p[vid], 0.0, 1.0);
    o.ndc = p[vid];
    return o;
}

fragment float4 bgFragment(BgOut in [[stage_in]],
                           constant Uniforms& u [[buffer(0)]],
                           constant float* spec [[buffer(1)]],
                           constant float* rings [[buffer(2)]],
                           constant float4* nebulae [[buffer(3)]],
                           constant float4* galaxies [[buffer(4)]]) {
    float2 uv = rot(float2(in.ndc.x * u.aspect, in.ndc.y), u.roll);

    // Colour the audio "is": bass = magenta/crimson, mids = cyan/blue, treble = gold.
    float3 audioTint = normalize(float3(0.06) +
                                 u.bass * float3(1.0, 0.12, 0.5) +
                                 u.mid * float3(0.12, 0.6, 1.0) +
                                 u.treble * float3(1.0, 0.78, 0.3));

    float3 col = float3(0.004, 0.003, 0.012);

    float r = length(uv);

    // Galaxies: real 3D discs at any tilt. Each pixel's view ray is intersected with several parallel
    // planes through a thick disc, so the near side looms larger than the far side, discs foreshorten and
    // turn edge-on, and flying through one takes a long time as its layers of stars and dust stream past.
    // Per galaxy (3 x float4): A = centre (camera space x, y, z), radius; B = seed, spin, arm count, alpha;
    // C = disc thickness, fly-through flag, disc normal x, normal y.
    // Bass pumps the bulge, mids light the arms, treble sparks the star-forming regions.
    float3 ray = float3(uv, 1.0);  // view ray, scaled so that its depth component is 1
    for (int k = 0; k < MAX_GALAXIES; k++) {
        float4 A = galaxies[k * 3];
        float4 B = galaxies[k * 3 + 1];
        float4 C = galaxies[k * 3 + 2];
        if (B.w <= 0.001) continue;
        float3 cen = A.xyz;
        float size = A.w;
        float3 N = float3(C.z, C.w, sqrt(saturate(1.0 - C.z * C.z - C.w * C.w)));
        float3 e1 = normalize(cross(N, abs(N.y) < 0.95 ? float3(0, 1, 0) : float3(1, 0, 0)));
        float3 e2 = cross(N, e1);
        float arms = B.z;
        // Galaxy type and look, from its seed (so every galaxy is different).
        float tr = fract(B.x * 11.3);
        int gtype = arms < 0.5 ? (tr < 0.5 ? 4 : 5)
                  : (tr < 0.34 ? 0 : (tr < 0.54 ? 1 : (tr < 0.74 ? 2 : (tr < 0.88 ? 3 : 6))));
        bool barred = gtype == 2 || (gtype == 0 && fract(B.x * 7.31) > 0.7);
        float pitch = mix(1.6, 3.6, fract(B.x * 13.7));      // loosely to tightly wound arms
        float pal = fract(B.x * 17.9);
        // Palettes from real photos: violet-blue arms with a pink-white core, blue-white with cream, or neutral.
        float3 coreCol = pal < 0.3 ? float3(1.0, 0.8, 0.86) : float3(1.0, 0.87, 0.66);
        float3 armCol = pal < 0.3 ? float3(0.52, 0.52, 1.0) : (pal < 0.65 ? float3(0.66, 0.77, 1.0) : float3(0.82, 0.84, 0.92));
        float bulgeSize = gtype == 3 ? 0.3 : (gtype == 6 ? 0.6 : (gtype == 4 ? 1.4 : mix(0.6, 1.5, fract(B.x * 5.3))));
        float bulgeGain = gtype == 3 ? 0.3 : 1.0;

        // Bulge: an oblate glow of old stars around the centre, measured along the ray in 3D.
        // (Closest point on the ray, clamped to in front of us so the glow stays continuous.)
        float tc = max(dot(cen, ray) / dot(ray, ray), 0.0);
        {
            float3 off = ray * tc - cen;
            float3 lo = float3(dot(off, e1), dot(off, e2), dot(off, N) * 2.4) / size;
            float bd2 = dot(lo, lo);
            float spread = gtype == 5 ? 0.25 : 1.0; // ellipticals are all bulge
            float bulge = exp(-bd2 * 45.0 * spread / (bulgeSize * bulgeSize)) + 0.22 * exp(-bd2 * 5.0 * spread / bulgeSize);
            col += coreCol * bulge * bulgeGain * (0.55 + 0.9 * u.bass + 0.5 * u.beat) * B.w * 1.15;
        }

        // From inside the disc, the thin layers would show hard horizons when seen edgewise; instead,
        // fade them at grazing angles and draw the disc as a smooth band of light across the sky.
        float cosV = abs(dot(normalize(ray), N));
        float camH = -dot(cen, N);                              // our height above the mid-plane
        float camLat = length(-cen - N * camH) / size;          // our distance from the axis, in radii
        float inside = saturate(1.0 - abs(camH) / (C.x * 3.0)) * smoothstep(1.7, 1.1, camLat);
        if (inside > 0.0) {
            float band = exp(-cosV * cosV / (0.012 + 0.3 * camH * camH / (size * size)));
            float glowCol = exp(-camLat * 1.6);
            col += mix(armCol, coreCol, glowCol) * band * inside * (0.12 + 0.35 * glowCol) * B.w * (0.7 + 0.6 * u.mid);
        }
        float layerFade = mix(1.0, smoothstep(0.04, 0.25, cosV), inside);

        float denom = dot(ray, N);
        if (abs(denom) < 1e-5) continue;
        // Edge-on, the line of sight runs through more of the disc, so it glows brighter.
        float pathGain = min(1.0 / max(cosV, 0.1), 5.0) * layerFade;
        for (int L = 0; L < GALAXY_LAYERS; L++) {
            // Visit the planes farthest-first (which end that is depends on which side we see the disc from),
            // but keep each plane's identity fixed so nothing jumps where the view crosses its horizon.
            int idx = denom > 0.0 ? GALAXY_LAYERS - 1 - L : L;
            // Each pixel samples the slab at slightly different heights, so the layers blend into one volume.
            float jitter = (hash21(in.position.xy + float(idx) * 17.0) - 0.5) / float(GALAXY_LAYERS - 1);
            float f = float(idx) / float(GALAXY_LAYERS - 1) - 0.5 + jitter; // across the thickness
            float h = f * C.x;
            float t = (dot(cen, N) + h) / denom;                   // depth where the ray meets this plane
            if (t <= 0.004) continue;                              // that plane is behind us
            float2 p = float2(dot(ray * t - cen, e1), dot(ray * t - cen, e2)) / size;
            float d = length(p);
            if (d > 1.5) continue;
            float R = size / t;                 // on-screen size of one galaxy radius at that depth
            float swell = smoothstep(26.0, 11.0, R); // fade planes about to sweep over the camera
            if (swell <= 0.001) continue;
            float mid = exp(-f * f * 10.0) * swell;  // light and dust concentrate in the mid-plane
            float layerSeed = B.x * 13.0 + float(idx) * 1.7;
            float halo = exp(-d * 3.2);
            float edge = smoothstep(1.45, 0.75, d);
            // Fine structure (clumps, filaments, knots) lives in the thin mid-plane; above and below is haze.
            float detail = smoothstep(0.3, 0.8, mid);
            float3 g;
            float dustAmt, arm;
            galaxyLayer(p, d, gtype, arms, barred, pitch, B.x * 13.0, detail, B.y, coreCol, armCol, u, g, dustAmt, arm);
            // Close up: the glow of countless unresolved stars fills in around the resolved ones.
            float deep = smoothstep(2.0, 6.0, R);
            g += mix(coreCol, armCol, saturate(arm * 1.5)) * (halo * 1.2 + arm * halo + 0.04) * deep;
            g *= edge;

            // Resolved stars at this layer's depth (they parallax against the other layers), densest in the arms:
            // the speckled look of a galaxy photographed up close.
            float resolved = smoothstep(0.25, 1.2, R);
            float stars = resolved * pointStars(p, 90.0, R, layerSeed, 0.05);
            stars += smoothstep(0.4, 1.0, R) * pointStars(p, 200.0, R, layerSeed + 7.0, 0.2) * saturate(arm * 1.4) * detail;
            float sDeep = smoothstep(2.0, 6.0, R), sDeeper = smoothstep(6.0, 15.0, R);
            if (sDeep > 0.0) {
                stars += sDeep * pointStars(p, 420.0, R, layerSeed + 2.0, 0.06)
                       + sDeeper * pointStars(p, 1500.0, R, layerSeed + 3.0, 0.05);
            }
            float3 tintS = mix(float3(1.0, 0.85, 0.7), float3(0.75, 0.85, 1.0), hash21(floor(p * 90.0) + layerSeed));
            g += stars * max(halo * 2.5 + arm, sDeep * 0.7) * edge * tintS * 1.2 * (0.35 + 0.65 * mid);

            // This layer's dust hides some of what lies behind it, then its own light is added.
            col *= 1.0 - saturate(dustAmt * mid * edge) * 0.7 * B.w * layerFade;
            col += g * mid * B.w * pathGain * 0.24;
        }
    }

    // Nebulae: drawn as stacks of layers at different depths (back to front). Each layer is projected from
    // its own distance, so near ones grow and slide outward faster than far ones: real parallax.
    // Per cloud (3 x float4): A = world x, y, back-layer depth, size; B = seed, rotation, hue shift, alpha;
    // C = depth thickness, fly-through flag, kind, variation (0...1: texture scale and palette).
    // Several cross-sections through the cloud. The middle ones are widest (an ellipsoid of gas),
    // each has its own structure and embedded stars, and nearer layers' dust dims what lies behind them.
    // Emission colours: hydrogen-alpha red (bass), oxygen-III teal (mids), sulphur gold (treble).
    // Kinds — nebulae: 0 emission, 1 reflection, 2 planetary shell, 3 supernova remnant, 4 dark, 5 bipolar,
    // 6 rosette; gas clouds: 7 veil filaments, 8 molecular cloud, 9 cirrus, 10 pillars, 11 bubble, 12 tendrils.
    float3 hAlpha = float3(0.85, 0.16, 0.3);
    float3 oIII = float3(0.12, 0.62, 0.75);
    float3 sII = float3(0.95, 0.58, 0.22);
    for (int k = 0; k < MAX_NEBULAE; k++) {
        float4 A = nebulae[k * 3];
        float4 B = nebulae[k * 3 + 1]; // B.z = hue shift
        float4 C = nebulae[k * 3 + 2];
        if (B.w <= 0.001) continue;
        int kind = int(C.z + 0.5);
        float variation = C.w;
        float stretch = mix(1.0, 2.3, fract(B.x * 3.71)); // elongated clouds and shells
        float3 gasA = cloudPalette(B.x * 5.3);
        float3 gasB = cloudPalette(B.x * 5.3 + 0.3 + variation * 0.4);
        for (int sl = 0; sl < NEBULA_LAYERS; sl++) {
            float t = float(sl) / float(NEBULA_LAYERS - 1); // 0 = back, 1 = front
            float z = A.z - t * C.x;
            if (z <= 0.02) continue;
            float R = A.w / z;
            // A layer thins out as it swells past a few screen-heights (before its gas magnifies into big, blurry,
            // hard-edged slabs) and is gone by the time it reaches us; the deeper layers then take over.
            float la = B.w * smoothstep(0.0, A.w * 0.12, z) * smoothstep(9.0, 3.5, R);
            if (la <= 0.001) continue;
            float girth = mix(0.62, 1.0, 1.0 - abs(t - 0.5) * 2.0);
            float2 p = rot((uv - A.xy / z) / (R * girth), B.y + t * 0.9);
            p.x /= stretch;
            float d = length(p);
            if (d > 1.8) continue;
            float seed = B.x + t * 3.17;
            float Rs = R * girth;

            float2 sp = p * mix(1.1, 2.6, variation) + seed * 31.0; // coarse billows ... fine texture
            float2 q = float2(fbm(sp + u.time * 0.01), fbm(sp + float2(5.2, 1.3)));
            float2 w = float2(fbm(sp + 3.0 * q + float2(1.7, 9.2)), fbm(sp + 3.0 * q + float2(8.3, 2.8)));
            float n = fbm(sp + 2.6 * w);

            // Irregular outline, wispy edges, dark dust lanes.
            float shape = smoothstep(1.15, 0.05, d + (n - 0.5) * 1.1 + (w.y - 0.5) * 0.4);
            float gas = n * n * shape * shape * 2.2; // smooth, never clipped into flat plateaus
            // When we're close, finer filaments show how vast the cloud really is.
            float near = smoothstep(0.4, 2.0, Rs);
            gas *= mix(1.0, 0.55 + 0.9 * fbm(sp * 7.0 + w * 3.0), near);

            // Flying through it: two more levels of ever finer (soft) gas structure.
            float deep = smoothstep(2.5, 7.0, Rs);
            float deeper = smoothstep(7.0, 16.0, Rs);
            if (deep > 0.0) {
                float f2 = fbm(sp * 22.0 + w * 5.0);
                gas *= mix(1.0, 0.5 + f2, deep);
                if (deeper > 0.0) gas *= mix(1.0, 0.6 + 0.8 * fbm(sp * 75.0 + f2 * 3.0), deeper);
            }
            float dust = smoothstep(0.3, 0.95, fbm(sp * 2.4 + w * 1.6 + 4.0)) * shape * 0.7;

            // Deeper layers glow redder (hydrogen), nearer ones bluer (oxygen), as in real emission nebulae.
            float3 rim = mix(hAlpha, sII, saturate(0.15 + u.treble * 0.6 + B.z));
            float3 inner = mix(oIII, float3(0.55, 0.75, 1.0), u.mid * 0.4);
            float3 c = mix(rim, inner, smoothstep(0.75, 0.05, d + (w.x - 0.5) * 0.5));
            c = mix(c, hAlpha * 1.2, u.bass * 0.35 * smoothstep(0.2, 0.9, d));
            c = mix(hAlpha * 1.15, c, 0.3 + 0.7 * t);

            if (kind == 1) {
                // Reflection nebula: starlight scattered off dust, soft and blue.
                c = mix(float3(0.28, 0.48, 1.0), float3(0.78, 0.87, 1.0), exp(-d * d * 4.0));
                gas *= 0.85;
            } else if (kind == 2) {
                // Planetary nebula: a glowing shell blown off a dying star, teal inside, red at the rim.
                float shell = exp(-pow((d - 0.55 - (n - 0.5) * 0.18) / 0.17, 2.0));
                gas = shell * (0.5 + 0.9 * n) * 1.7;
                c = mix(float3(0.15, 0.72, 0.82), hAlpha * 1.2, smoothstep(0.42, 0.78, d));
                dust = 0.0;
            } else if (kind == 3) {
                // Supernova remnant: a torn, filamentary blast shell.
                float r0 = 0.72 + (w.x - 0.5) * 0.3;
                float shell = exp(-pow((d - r0) / 0.08, 2.0)) * (0.35 + 1.2 * fbm(sp * 4.0 + w * 2.0));
                gas = shell * 1.5 + gas * 0.12;
                c = mix(oIII * 1.15, hAlpha * 1.25, saturate(n * 1.6 - 0.3));
                dust = 0.0;
            } else if (kind == 4) {
                // Dark nebula: a cold dust cloud, seen as a silhouette against the glow of the stars behind it.
                if (sl == 0) {
                    float backdrop = exp(-d * d * 1.6) * smoothstep(1.8, 1.0, d) * (0.55 + 0.6 * fbm(sp * 0.8 + 9.0));
                    col += float3(0.62, 0.5, 0.56) * backdrop * 0.5 * la;
                    col += pointStars(p, 160.0, Rs, seed + 21.0, 0.12) * backdrop * la;
                }
                dust = smoothstep(0.32, 0.68, n) * shape * 1.3;
                gas *= 0.12;
                c = float3(0.6, 0.32, 0.26);
            } else if (kind == 5) {
                // Bipolar nebula: two lobes blown out of a dying star, pinched at the waist (hourglass / butterfly).
                float ay = abs(p.y);
                float lobe = exp(-pow(p.x / (0.08 + 0.55 * ay), 2.0)) * smoothstep(1.05, 0.35, ay) * smoothstep(0.0, 0.12, ay);
                gas = lobe * (0.45 + 0.9 * n) * 1.8;
                c = mix(float3(0.2, 0.7, 0.85), hAlpha * 1.2, smoothstep(0.2, 0.8, ay + abs(p.x) * 0.5));
                dust = 0.0;
            } else if (kind == 6) {
                // Rosette: a thick glowing shell around a hollow blown out by the young cluster at its centre.
                float shell = smoothstep(0.18, 0.45, d) * smoothstep(1.15, 0.55, d);
                gas = shell * (0.35 + 1.1 * n * n) * 1.7;
                dust = smoothstep(0.55, 0.82, fbm(sp * 3.0 + 7.0)) * shell * 0.9; // dark globules
                c = mix(hAlpha * 1.1, sII, saturate(w.x * 0.8 - 0.1) * 0.5);
            } else if (kind == 7) {
                // Veil: delicate twisted filaments.
                float r1 = 1.0 - abs(fbm(sp * 1.2 + w * 1.6) * 2.0 - 1.0);
                float r2 = 1.0 - abs(fbm(sp * 2.6 + w * 2.4 + 3.0) * 2.0 - 1.0);
                gas = (pow(r1, 7.0) + 0.5 * pow(r2, 9.0)) * shape * 2.2;
                c = mix(gasA, gasB, saturate(r1 * 1.4 - 0.4));
                dust = 0.0;
            } else if (kind == 8) {
                // Molecular cloud: big, soft, multi-coloured billows.
                gas = n * n * shape * shape * 2.6;
                c = mix(gasA, gasB, smoothstep(0.3, 0.7, w.x));
                dust *= 0.8;
            } else if (kind == 9) {
                // Cirrus: faint grey-blue wisps of dust lit by starlight.
                gas = pow(fbm(sp * 0.8 + w * 2.0), 2.5) * shape * 1.5;
                c = mix(float3(0.55, 0.62, 0.78), gasA, 0.2);
                dust = 0.0;
            } else if (kind == 10) {
                // Pillars: towers of dark dust rising from below, their edges lit, against a glowing backdrop.
                if (sl == 0) {
                    float backdrop = exp(-d * d * 1.4) * smoothstep(1.8, 1.0, d) * (0.5 + 0.7 * fbm(sp * 0.7 + 3.0));
                    col += mix(float3(0.2, 0.55, 0.7), float3(0.85, 0.6, 0.3), fbm(sp * 0.5)) * backdrop * 0.55 * la;
                }
                float tip = mix(-0.2, 0.65, fbm(float2(p.x * 2.5, seed * 3.0)));
                float column = smoothstep(0.42, 0.72, fbm(float2(p.x * 3.2, p.y * 0.9) + seed * 4.0 + w * 0.6))
                             * smoothstep(tip, tip - 0.3, p.y);
                float rimLight = column * (1.0 - column) * 4.0;
                dust = column * 1.4 * shape;
                gas = rimLight * shape * 1.6;
                c = mix(float3(0.98, 0.72, 0.4), gasA, 0.3);
            } else if (kind == 11) {
                // Bubble: a vast, faint shell of hydrogen blown out by stellar winds.
                float shell = exp(-pow((d - 0.78 - (n - 0.5) * 0.12) / 0.11, 2.0));
                gas = (shell * (0.5 + 0.8 * n) + n * n * 0.25 * smoothstep(0.8, 0.2, d)) * 1.5;
                c = mix(hAlpha * 1.1, gasA, 0.35);
                dust = 0.0;
            } else if (kind == 12) {
                // Tendrils: streamers of gas radiating from a bright central cluster.
                float2 dirv = p / max(d, 1e-3);
                float streak = fbm(dirv * 5.5 + float2(d * 1.4, 0.0) + seed * 3.0);
                gas = pow(streak, 3.0) * exp(-d * 1.4) * smoothstep(0.02, 0.22, d) * shape * 3.0 + exp(-d * d * 12.0) * 0.7;
                c = mix(gasA, gasB, smoothstep(0.2, 0.8, d));
            }

            float core = exp(-d * d * 9.0);
            float3 neb = c * gas * 1.25 + float3(0.95, 0.97, 1.0) * core * gas * 0.3;
            neb *= 1.0 - dust * 0.8;
            // The star at the heart of a planetary or reflection nebula (in the middle layer).
            if ((kind == 1 || kind == 2 || kind == 5) && sl == NEBULA_LAYERS / 2) {
                float sd = d * Rs / 0.004;
                neb += float3(0.85, 0.92, 1.0) * (exp(-sd * sd) * 2.0 + exp(-d * d * 60.0) * 0.25);
            }
            // The young star cluster at the heart of a rosette or a tendril cloud.
            if ((kind == 6 || kind == 12) && sl == NEBULA_LAYERS / 2) {
                neb += float3(0.85, 0.92, 1.0) * pointStars(p, 60.0, Rs, seed + 31.0, 0.5) * exp(-d * d * 18.0) * 1.8;
            }

            // Young stars embedded in the gas, at this layer's depth (so they parallax against other layers).
            float embedded = pointStars(p, 40.0, Rs, seed, 0.04) + near * pointStars(p, 140.0, Rs, seed + 5.0, 0.05);
            if (deep > 0.0) {
                embedded += deep * pointStars(p, 520.0, Rs, seed + 9.0, 0.04)
                          + deeper * pointStars(p, 1700.0, Rs, seed + 13.0, 0.04);
            }
            float starShare = kind == 4 ? 0.15 : ((kind == 7 || kind == 9 || kind == 11) ? 0.5 : 1.3);
            neb += embedded * shape * float3(0.92, 0.96, 1.0) * starShare;

            // This layer's dust hides some of what is behind it, then its own light is added.
            col *= 1.0 - saturate((kind == 4 || kind == 10) ? dust * 0.7 : dust * 0.45 * shape * t) * la;
            float gain = kind == 9 ? 0.7 : (kind == 11 ? 0.8 : 1.0);
            col += neb * la * gain * mix(0.5, 0.65, t) * (0.45 + 0.55 * u.level + 0.35 * u.beat);
        }
    }

    // Vanishing-point glow, pumped by the bass.
    float core = 0.015 / (r * r + 0.02);
    col += mix(palette(u.hue + 0.5), float3(1.0), 0.4) * core * (0.06 + 0.45 * u.bass + 0.3 * u.beat);


    // Tone map and vignette (dithering happens in the post pass).
    col *= 1.0 + 0.25 * u.beat;
    col = 1.0 - exp(-col * 1.4);
    float vig = smoothstep(1.9, 0.5, length(in.ndc * float2(1.15, 1.0)));
    col *= mix(0.5, 1.0, vig);
    return float4(col, 1.0);
}

// MARK: - Black hole (drawn in the post pass so it can bend the light of everything behind it)

/// Approximate blackbody colour for a normalised temperature (0 = dull red ... 1 = white ... 1.4 = blue-white).
static float3 blackbody(float t) {
    float3 c = mix(float3(0.5, 0.06, 0.01), float3(1.0, 0.38, 0.08), saturate(t * 2.2));
    c = mix(c, float3(1.0, 0.78, 0.5), saturate(t * 2.2 - 0.9));
    c = mix(c, float3(1.0, 0.96, 0.9), saturate(t * 2.0 - 1.4));
    return mix(c, float3(0.78, 0.86, 1.0), saturate(t * 2.5 - 2.6));
}

struct HoleTrace {
    float3 dir;     // direction the light finally came from (camera frame)
    float3 light;   // disc and jet light picked up along the way
    float trans;    // how much of the background still shows through (0 = swallowed or fully blocked)
};

/// Disc gas density and turbulence at a point in the hole's frame (lengths in r_s).
static float discDensity(float3 pos, float3 N, float3 e1, float3 e2, float rIn, float rOut, float thick,
                         float spin, float time, thread float& rho, thread float& hgt) {
    hgt = dot(pos, N);
    float3 inPlane = pos - N * hgt;
    rho = length(inPlane);
    if (rho < rIn * 0.85 || rho > rOut * 1.1) return 0.0;
    float H = thick * rho + 0.05;
    float vert = exp(-0.5 * (hgt / H) * (hgt / H));
    if (vert < 0.01) return 0.0;
    float radial = smoothstep(rIn * 0.9, rIn * 1.25, rho) * pow(smoothstep(rOut, rOut * 0.3, rho), 1.5);
    float ang = atan2(dot(inPlane, e2), dot(inPlane, e1));
    // Keplerian shear winds the gas into spiral streamers. Two phases cross-fade so it never winds up forever.
    float omega = spin * 2.2 / pow(rho, 1.5);
    float lr = log(rho);
    float n = 0.0;
    for (int k = 0; k < 2; k++) {
        float ph = fract(time / 24.0 + float(k) * 0.5);
        float wgt = 1.0 - abs(ph * 2.0 - 1.0);
        float a = ang - omega * ph * 24.0 + float(k) * 2.1;
        float2 orbit = float2(cos(a), sin(a));
        float warp = fbm(orbit * 2.0 + float2(lr * 3.0, hgt / H * 0.35 + float(k) * 3.0));
        float g = fbm(orbit * 3.5 + float2(lr * 12.0 + warp * 2.0, hgt / H * 0.6));
        n += wgt * g;
    }
    return vert * radial * (0.2 + 1.5 * n * n);
}

/// Follow a light ray from the camera through the black hole's curved spacetime. The bending uses the
/// photon-orbit equation x'' = -1.5 h² x / r⁵ (Schwarzschild, r_s = 1), which by itself produces the
/// shadow, the photon ring and the lensed images of the far side of the disc and of the stars behind.
/// The disc is a real 3D volume with thickness that emits and absorbs light along the way.
static HoleTrace traceHole(float3 rd, constant Uniforms& u) {
    HoleTrace res;
    res.light = float3(0.0);
    res.trans = 1.0;
    float rsW = u.blackHole.w;
    float3 pos = -u.blackHole.xyz / rsW;          // camera position relative to the hole
    float3 dir = normalize(rd);
    float3 N = normalize(u.blackHole3.xyz);
    float3 e1 = normalize(cross(N, abs(N.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0)));
    float3 e2 = cross(N, e1);
    float thick = u.blackHole2.x, spin = u.blackHole2.w;
    float rIn = u.blackHole4.x, rOut = u.blackHole4.y, tempScale = u.blackHole4.z;
    int kind = int(u.blackHole4.w + 0.5);
    bool hasDisc = kind != 2;

    // Relativistic jets (quasars): glowing beams along the spin axis, integrated along the straight ray.
    if (kind == 1) {
        float b = dot(dir, N);
        float denom = max(1.0 - b * b, 1e-4);
        float tr = max((dot(-pos, dir) - b * dot(-pos, N)) / denom, 0.0);  // ray parameter nearest the axis
        float sAx = dot(pos + dir * tr, N);
        float dAx = length(pos + dir * tr - N * sAx);
        float width = 0.7 + abs(sAx) * 0.06;
        float aligned = smoothstep(0.97, 0.8, abs(b));   // looking straight down a jet: no knot rings
        float knots = 1.0 - 0.3 * aligned * (0.5 + 0.5 * sin(abs(sAx) * 0.12 - u.time * 2.5));
        float jet = exp(-pow(dAx / width, 2.0)) * smoothstep(3.0, 12.0, abs(sAx)) * exp(-abs(sAx) / 260.0) * knots;
        float glow = exp(-dAx / (width * 6.0)) * smoothstep(3.0, 20.0, abs(sAx)) * exp(-abs(sAx) / 160.0);
        res.light += (float3(0.55, 0.62, 1.0) * jet * 0.7 + float3(0.4, 0.35, 0.9) * glow * 0.03) * (0.7 + 0.6 * u.bass);
    }

    // Far from the hole the bending is weak: apply the deflection 2/b analytically.
    float tca = dot(-pos, dir);
    float3 closest = pos + dir * max(tca, 0.0);
    float bImpact = length(closest);
    float reach = hasDisc ? rOut * 1.3 + 6.0 : 14.0;
    if (bImpact > max(reach, 60.0)) {
        float along = tca > 0.0 ? 1.0 : 0.5 * exp(tca / bImpact);
        res.dir = normalize(dir - closest / bImpact * (2.0 / bImpact) * along);
        return res;
    }

    float3 vel = dir;
    float h2 = dot(cross(pos, vel), cross(pos, vel));
    bool captured = false;
    for (int i = 0; i < 260; i++) {
        float r = length(pos);
        if (r < 1.0) { captured = true; break; }
        if (r > 400.0 && dot(pos, vel) > 0.0) break;
        float dt = clamp(0.07 * r, 0.02, 60.0);
        float rho = 0.0, hgt = 0.0;
        float dens = 0.0;
        if (hasDisc) {
            float hgtNow = dot(pos, N);
            float rhoNow = length(pos - N * hgtNow);
            float H = thick * rhoNow + 0.05;
            if (rhoNow < rOut * 1.15 && rhoNow > rIn * 0.8 && abs(hgtNow) < 4.0 * H + dt) {
                dt = min(dt, max(H * 0.5, 0.04));
                dens = discDensity(pos, N, e1, e2, rIn, rOut, thick, spin, u.time, rho, hgt);
            }
        }
        if (dens > 0.0) {
            // Doppler beaming of the orbiting gas (bright and blue where it comes toward us) and
            // gravitational redshift deep in the well; hotter toward the inner edge.
            float3 inPlane = normalize(pos - N * hgt);
            float3 orbitDir = cross(N, inPlane) * spin;
            float beta = min(sqrt(0.5 / max(rho - 1.0, 0.5)), 0.75);
            float gamma = 1.0 / sqrt(1.0 - beta * beta);
            float cosT = dot(orbitDir, -normalize(vel));
            float D = 1.0 / (gamma * (1.0 - beta * cosT));
            float g = D * sqrt(saturate(1.0 - 1.0 / rho));
            float temp = pow(rIn / rho, 0.75) * tempScale;
            float3 emit = blackbody(temp * g) * min(pow(g, 3.5), 6.0) * dens * (0.6 + 0.6 * temp);
            res.light += res.trans * emit * dt * 3.2;
            res.trans *= exp(-dens * dt * (1.2 + 2.0 * thick));
            if (res.trans < 0.01) break;
        }
        // Integrate the bend (semi-implicit Euler).
        vel += -1.5 * h2 * pos / pow(r, 5.0) * dt;
        pos += vel * dt;
    }
    if (captured) res.trans = 0.0;
    res.dir = normalize(vel);
    return res;
}

// MARK: - Scratched cockpit glass

/// One size class of straight scratches: in each grid cell, maybe a thin tapered line at a random angle.
static float scratchLayer(float2 p, float cell, float seed, float width, float density, float maxLen) {
    float2 cp = p / cell;
    float2 base = floor(cp);
    float acc = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = base + float2(i, j);
            if (hash21(c + seed) > density) continue;
            // Mostly near-horizontal (wiping), some at any angle.
            float r = hash21(c + seed + 3.7);
            float ang = r < 0.6 ? (r - 0.3) * 0.9 : r * 6.2832;
            float len = mix(0.25, maxLen, hash21(c + seed + 9.1));
            float2 centre = c + float2(hash21(c + seed + 1.3), hash21(c + seed + 5.9));
            float2 dir = float2(cos(ang), sin(ang));
            float2 d = cp - centre;
            float t = clamp(dot(d, dir), -len * 0.5, len * 0.5);
            float dist = length(d - dir * t) * cell;
            float taper = 1.0 - pow(abs(t) / (len * 0.5), 2.0);
            acc = max(acc, smoothstep(width, 0.0, dist) * taper * (0.35 + 0.65 * hash21(c + seed + 7.3)));
        }
    }
    return acc;
}

/// A very scratched canopy: long gouges, medium scratches, fine hairlines and curved wiper scuffs.
static float glassScratches(float2 g, float px) {
    float s = scratchLayer(g, 0.5, 1.0, px * 2.2, 0.6, 1.7);
    s = max(s, scratchLayer(g, 0.17, 7.0, px * 1.8, 0.5, 1.4) * 0.8);
    s = max(s, scratchLayer(g, 0.06, 13.0, px * 1.4, 0.4, 1.3) * 0.55);
    for (int i = 0; i < 3; i++) {
        float2 centre = float2(-1.3 + float(i) * 1.5, -2.3 - float(i) * 0.4);
        float R = length(g - centre);
        float ring = smoothstep(0.9, 1.0, fract(R * 36.0 + float(i) * 0.37));
        float patch = smoothstep(0.55, 0.75, fbm(g * 1.4 + float(i) * 5.0));
        s = max(s, ring * patch * 0.14);
    }
    return s;
}

/// Signed distance from a pixel to the canopy window's edge, in screen heights (negative inside), and the
/// outward normal of the nearest edge. Matches the window shape drawn by CockpitFrameView.
static float windowEdge(float2 px, float2 size, thread float2& normal) {
    float w = size.x, h = size.y;
    float lo = w * 0.035, hi = w * 0.075, top = h * 0.07, ch = min(w, h) * 0.08;
    float2 P[8] = { float2(lo, h + 20.0), float2(lo, h * 0.5), float2(hi, top + ch), float2(hi + ch, top),
                    float2(w - hi - ch, top), float2(w - hi, top + ch), float2(w - lo, h * 0.5), float2(w - lo, h + 20.0) };
    float best = -1e9;
    normal = float2(0.0);
    for (int i = 0; i < 7; i++) {
        float2 e = P[i + 1] - P[i];
        float2 n = normalize(float2(e.y, -e.x));
        float dist = dot(px - P[i], n);
        if (dist > best) { best = dist; normal = n; }
    }
    return best / h;
}

// MARK: - Post pass: lensing, chromatic aberration and dithering

constant float bayer4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

fragment float4 postFragment(BgOut in [[stage_in]],
                             texture2d<float> scene [[texture(0)]],
                             constant Uniforms& u [[buffer(0)]],
                             constant float* rings [[buffer(2)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 size = float2(scene.get_width(), scene.get_height());
    int mode = int(u.dither + 0.5);
    int strength = clamp(int(u.ditherStrength + 0.5), 1, 4);
    float stress = u.blackHole2.y;
    float holeAlpha = u.blackHole3.w; // fades in as it emerges from the distance
    bool hole = holeAlpha > 0.001;
    float3 holePos = u.blackHole.xyz;
    float2 centre = holePos.z > 0.01 ? holePos.xy / holePos.z : float2(1e3);
    float Rs = 2.6 * u.blackHole.w / max(length(holePos), 1e-3); // shadow size on screen

    // Retro snaps the sample position to chunky blocks (1-4 px depending on strength).
    float2 px = in.position.xy;
    float block = mode == 2 ? float(strength) : 1.0;
    float2 cell = floor(px / block);
    float2 uvT = (mode == 2 ? cell * block + block * 0.5 : px) / size;

    // Tidal stress shakes the whole view.
    if (stress > 0.0) {
        float2 jolt = float2(fbm(float2(u.time * 9.0, 1.3)), fbm(float2(4.1, u.time * 9.0))) - 0.5;
        uvT += jolt * 0.03 * stress * stress;
    }
    // Screen point in aspect-scaled coordinates (the space the black hole lives in), and back.
    float2 q = float2((uvT.x * 2.0 - 1.0) * u.aspect, 1.0 - uvT.y * 2.0);

    // Chromatic aberration: red and blue drift apart toward the edges. Barely there when cruising,
    // intense at warp speed, with an extra kick on beats, and wild while tidal forces tear at the ship.
    float2 fromCenter = uvT - 0.5;
    float warp = smoothstep(0.12, 0.6, u.speed);
    float2 shift = fromCenter * (0.35 + dot(fromCenter, fromCenter)) * u.aberration
                 * (0.006 + 0.05 * warp + 0.012 * u.beat) + fromCenter * 0.08 * stress;

    // Each colour channel is sampled through the lens; near the hole (and while under stress) the image
    // is also smeared around it, as if space itself were being dragged in circles.
    // Thick aluminium-oxide canopy: near the frame the glass is a wedge that bends the view, stretching the
    // image and splitting its colours, like looking through the edge of a heavy lens.
    float2 edgeQ = float2(0.0);
    float edgeK = 0.0, edgeIn = 1.0;
    if (u.glass.x > 0.5) {
        float2 nrm;
        edgeIn = -windowEdge(in.position.xy, size, nrm);       // distance inside the window
        edgeK = pow(saturate(1.0 - edgeIn / 0.11), 2.2);
        float2 shiftPx = -nrm * edgeK * 0.06 * size.y;          // pull the sample inward
        edgeQ = float2(shiftPx.x / size.x * 2.0 * u.aspect, -shiftPx.y / size.y * 2.0);
    }

    // Trace this pixel's ray past the black hole (once), to find where its light really came from.
    float2 qView = q + edgeQ;
    float3 holeLight = float3(0.0);
    float holeTrans = 1.0;
    if (hole) {
        HoleTrace ht = traceHole(float3(qView, 1.0), u);
        float2 qs = ht.dir.xy / max(ht.dir.z, 0.05);
        holeTrans = mix(1.0, ht.trans * smoothstep(-0.1, 0.25, ht.dir.z), holeAlpha);
        holeLight = ht.light * holeAlpha;
        qView = mix(qView, qs, holeAlpha);
    }

    int taps = stress > 0.03 ? 7 : 1;
    float2 v0 = q - centre;
    float2 tangent = normalize(float2(-v0.y, v0.x) + 1e-5);
    float smear = stress * (0.05 + 0.25 * Rs / (length(v0) + Rs + 1e-3));
    float3 c = float3(0.0);
    for (int ch = 0; ch < 3; ch++) {
        float2 off = (ch == 0 ? shift : (ch == 2 ? -shift : float2(0.0))) * float2(2.0 * u.aspect, -2.0);
        float acc = 0.0;
        for (int t = 0; t < taps; t++) {
            float k = taps > 1 ? float(t) / float(taps - 1) - 0.5 : 0.0;
            float2 qs = qView + off + tangent * k * smear + edgeQ * 0.18 * (float(ch) - 1.0);
            float2 st = float2(qs.x / u.aspect * 0.5 + 0.5, 0.5 - qs.y * 0.5);
            float4 sampled = scene.sample(smp, st);
            acc += ch == 0 ? sampled.r : (ch == 1 ? sampled.g : sampled.b);
        }
        c[ch] = acc / float(taps);
    }

    // Beat shockwave rings: one thin, crisp wavefront per beat, drawn after the colour split so that
    // chromatic aberration never turns one ring into several.
    {
        float r = length(q); // q is the rotated view, so this matches the scene's radius
        float3 tint = normalize(float3(0.06) + u.bass * float3(1.0, 0.12, 0.5) + u.mid * float3(0.12, 0.6, 1.0)
                                + u.treble * float3(1.0, 0.78, 0.3));
        float3 ringCol = mix(tint, float3(1.0), 0.35);
        float ringLight = 0.0;
        for (int i = 0; i < MAX_RINGS; i++) {
            float age = rings[i];
            if (age > 3.0) continue;
            ringLight += exp(-pow((r - age * 1.8) * 32.0, 2.0)) * exp(-age * 2.2);
        }
        c += ringCol * ringLight * 0.45 * (1.0 - c);
    }

    if (hole) {
        c *= holeTrans;                                 // the shadow, and the disc's gas in front of the stars
        float3 light = 1.0 - exp(-holeLight * 1.3);     // keep the hot disc from clipping
        c = c + light * (1.0 - c);
    }
    if (stress > 0.0) {
        // Red alarm pulse creeping in from the edges.
        float pulse = 0.5 + 0.5 * sin(u.time * 9.0);
        float edge = smoothstep(0.35, 0.95, length(fromCenter * float2(1.2, 1.6)));
        c = mix(c, float3(0.75, 0.03, 0.02), edge * stress * (0.25 + 0.35 * pulse));
    }

    if (u.glass.x > 0.5) {
        // Scratched cockpit glass, fixed to the ship (it doesn't shake with the view). Scratches and smudges
        // catch the light of whatever bright thing is just behind them, the way real scratched glass does.
        float2 g = float2((px.x / size.x * 2.0 - 1.0) * u.aspect, 1.0 - px.y / size.y * 2.0);
        float3 around = float3(0.0);
        for (int i = 0; i < 6; i++) {
            float a = float(i) * 1.0472;
            around += scene.sample(smp, uvT + float2(cos(a) / u.aspect, sin(a)) * 0.04).rgb;
        }
        around /= 6.0;
        float3 lum = float3(0.3, 0.5, 0.2);
        float light = dot(around, lum) * 1.8 + dot(c, lum) * 0.7 + 0.02;
        float scr = glassScratches(g, 2.0 / size.y);
        float smudge = smoothstep(0.42, 0.85, fbm(g * 1.6 + 3.0)) * 0.6 + fbm(g * 7.0) * 0.12;
        float specks = step(0.996, hash21(floor(px * 0.5)));
        c += float3(0.85, 0.9, 1.0) * (scr + specks * 0.3) * light * 1.15;
        c += around * smudge * 0.4;                       // haze scatters nearby light
        c *= float3(0.94, 0.97, 1.0);                    // faint tint of the canopy
        c += float3(0.3, 0.18, 0.08) * smoothstep(-0.2, -1.0, g.y) * 0.05; // console glow reflected low down
        // The thick edge: darker and faintly blue-green, with a thin bright inner rim catching the light.
        c *= mix(float3(1.0), float3(0.62, 0.72, 0.74), edgeK * 0.8);
        c += float3(0.7, 0.85, 0.9) * exp(-edgeIn / 0.004) * (0.06 + light * 0.5);
    }

    if (mode == 2) {
        // Retro: ordered Bayer dither down to a few colour levels (fewer as strength rises).
        const float levelsFor[4] = { 10.0, 7.0, 5.0, 3.0 };
        float levels = levelsFor[strength - 1];
        c = pow(saturate(c), float3(0.8)); // lift shadows so dark nebula still gets dots
        uint2 ci = uint2(cell);
        float th = (bayer4[(ci.y % 4) * 4 + ci.x % 4] + 0.5) / 16.0 - 0.5;
        c = floor(c * (levels - 1.0) + 0.5 + th) / (levels - 1.0);
        return float4(saturate(pow(c, float3(1.25))), 1.0);
    }
    if (mode == 1) {
        // Smooth: triangular noise, from barely-there anti-banding (light) to visible film grain (heavy).
        float n = hash21(px + fract(u.time) * 61.0) + hash21(px * 1.37 + fract(u.time * 1.3) * 47.0) - 1.0;
        c += n * exp2(float(strength) - 2.0) / 255.0;
    }
    return float4(saturate(c), 1.0);
}

// MARK: - Stars

struct Star {
    float4 a; // x, y, z (head), z (tail)
    float4 b; // size, seed, brightness, unused
};

struct StarOut {
    float4 position [[position]];
    float3 local;   // along (in widths), across (-1...1), streak length (in widths)
    float3 color;   // head
    float3 tail;    // trail colour, more saturated the faster we go
};

static float2 projectStar(float2 xy, float z, constant Uniforms& u) {
    return rot(xy / z, -u.roll);
}

vertex StarOut starVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant Star* stars [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]]) {
    Star st = stars[iid];
    float z = st.a.z;
    float2 head = projectStar(st.a.xy, z, u);
    float2 tail = projectStar(st.a.xy, st.a.w, u);
    float2 d = head - tail;
    float len = length(d);
    float2 dir = len > 1e-5 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float w = clamp(st.b.x * 0.0035 / z, 0.0014, 0.035);

    const float2 corners[6] = { float2(0, -1), float2(1, -1), float2(1, 1),
                                float2(0, -1), float2(1, 1), float2(0, 1) };
    float2 c = corners[vid];
    float L = len / w;
    float along = mix(-1.0, L + 1.0, c.x);
    float2 p = tail + dir * along * w + nrm * c.y * w;

    StarOut o;
    o.position = float4(p.x / u.aspect, p.y, 0.0, 1.0);
    o.local = float3(along, c.y, L);

    float seed = st.b.y;
    float twinkle = 0.75 + 0.25 * sin(u.time * (2.0 + seed * 9.0) + seed * 80.0) * (0.4 + u.treble);
    float fadeIn = smoothstep(STAR_FAR, STAR_FAR * 0.75, z);
    float bright = st.b.z * twinkle * fadeIn * clamp(0.45 / z, 0.14, 2.5) *
                   (0.7 + 0.8 * u.level + 0.6 * u.beat);
    float3 tint = palette(u.hue + seed * 0.5 + 0.1);
    // Real stars range from blue-white to deep orange; most are close to white.
    float spectral = fract(seed * 7.13);
    float3 starCol = spectral < 0.12 ? float3(0.7, 0.8, 1.0)
                   : (spectral < 0.6 ? float3(0.97, 0.98, 1.0)
                   : (spectral < 0.8 ? float3(1.0, 0.94, 0.82)
                   : (spectral < 0.94 ? float3(1.0, 0.82, 0.62) : float3(1.0, 0.66, 0.5))));
    o.color = mix(starCol, tint, 0.05 + 0.1 * u.treble) * bright * 0.5;
    float vivid = smoothstep(0.1, 0.7, u.speed);
    o.tail = mix(o.color, palette(u.hue + seed * 0.35 + 0.15) * bright * 0.6, 0.35 + 0.55 * vivid);
    return o;
}

fragment float4 starFragment(StarOut in [[stage_in]]) {
    float t = in.local.x;
    float L = in.local.z;
    float da = max(max(-t, t - L), 0.0);
    float d2 = da * da + in.local.y * in.local.y;
    float core = exp(-d2 * 4.0);
    float along = L > 0.01 ? saturate(t / L) : 1.0;
    float trail = L > 0.01 ? mix(0.12, 1.0, along) / (1.0 + L * 0.02) : 1.0;
    float3 c = mix(in.tail, in.color, along * along);
    return float4(c * core * trail, 1.0);
}
