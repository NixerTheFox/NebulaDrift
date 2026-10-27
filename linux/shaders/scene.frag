// Nebulae, gas clouds and galaxies (port of bgFragment in Sources/Shaders.metal).

in vec2 ndc;
out vec4 fragColor;

uniform vec4 nebulae[MAX_NEBULAE * 3];
uniform vec4 galaxies[MAX_GALAXIES * 3];

/// Sparse point stars on a grid in object space, drawn at a fixed on-screen size so that
/// they stay pin-pricks while the nebula or galaxy around them grows enormous.
/// Returns brightness. `density` is the fraction of grid cells holding a star.
float pointStars(vec2 p, float grid, float objectRadius, float seed, float density) {
    vec2 g = p * grid + seed * 7.0;
    vec2 cell = floor(g);
    float h = hash21(cell + seed);
    vec2 sc = cell + 0.5 + (vec2(hash21(cell + 3.1), hash21(cell + 7.7)) - 0.5) * 0.7;
    float sdUV = length(g - sc) * objectRadius / grid;   // distance in screen units
    float sharp = sdUV / 0.0032;
    float on = step(1.0 - density, h) * (0.35 + 0.65 * (h - (1.0 - density)) / density);
    return on * exp(-sharp * sharp);
}

/// Colours for gas clouds, from real narrow-band photos: crimson, magenta, violet, blue, teal, gold, green.
vec3 cloudPalette(float h) {
    const vec3 pal[7] = vec3[7](vec3(0.85, 0.18, 0.3), vec3(0.8, 0.25, 0.72), vec3(0.5, 0.35, 1.0),
                                vec3(0.28, 0.5, 1.0), vec3(0.15, 0.68, 0.75), vec3(0.95, 0.62, 0.25),
                                vec3(0.3, 0.82, 0.55));
    return pal[min(int(fract(h) * 7.0), 6)];
}

/// Soft beads on a grid in object space (star-forming knots, clusters). Returns brightness 0...1.
float beads(vec2 p, float grid, float seed, float density) {
    vec2 gp = p * grid + seed * 3.0;
    vec2 cell = floor(gp);
    float h = hash21(cell + seed * 1.7);
    vec2 c = cell + 0.5 + (vec2(hash21(cell + 2.1), hash21(cell + 6.3)) - 0.5) * 0.6;
    float r = length(gp - c);
    return step(1.0 - density, h) * exp(-r * r * 14.0) * (0.5 + 0.5 * hash21(cell + 9.9));
}

/// Light and dust of one layer of a galaxy disc at disc position `p` (in galaxy radii).
/// Types: 0 grand-design spiral, 1 flocculent spiral, 2 barred spiral, 3 irregular starburst,
///        4 lenticular with a dust ring, 5 elliptical, 6 ring galaxy.
void galaxyLayer(vec2 p, float d, int gtype, float arms, bool barred, float pitch, float seed, float detail,
                 float spin, vec3 coreCol, vec3 armCol, out vec3 g, out float dust, out float armOut) {
    const vec3 hii = vec3(1.0, 0.32, 0.55); // hydrogen-alpha pink of star-forming regions
    float disc = exp(-d * 2.6);
    g = vec3(0.0);
    dust = 0.0;
    armOut = 0.0;
    if (gtype <= 2) {
        float a = atan(p.y, p.x) + spin;
        float wobble = (fbm(p * 2.2 + seed * 5.0) - 0.5) * 1.1; // real arms wander and branch
        float rIn = barred ? 0.24 : 0.05;
        float spiral = a - log(max(d, rIn)) * pitch + wobble;
        float armP = pow(0.5 + 0.5 * cos(arms * spiral), mix(1.6, 3.2, fract(seed * 9.7)));
        if (gtype == 1) {
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
            vec2 pb = rot(p, -seed * 6.28);
            g += coreCol * exp(-pb.x * pb.x * 7.0 - pb.y * pb.y * 150.0) * smoothstep(0.45, 0.2, abs(pb.x)) * 1.1;
        }
        // Dark dust lanes hugging the inner edge of each arm, threaded with fine filaments.
        float lane = pow(0.5 + 0.5 * cos(arms * spiral + 0.6), 8.0) * radial;
        float fil = smoothstep(0.45, 0.8, fbm(p * 22.0 + seed * 3.0)) * detail;
        dust = lane * (0.6 + 0.6 * fil) * exp(-d * 1.0) * 1.4 + fil * (arm + disc) * 0.35;
        // Pink star-forming knots strung along the arms.
        g += hii * beads(p, 45.0, seed, 0.45) * saturate(arm * 1.5) * detail * (0.8 + 1.6 * u.treble) * 2.2;
    } else if (gtype == 3) {
        // Irregular starburst: clumpy, lopsided, full of pink nurseries.
        float blob = fbm(p * 2.2 + seed * 5.0);
        float dens = sq(saturate(blob * 1.3 - 0.15)) * (0.5 + fbm(p * 5.0 + seed * 9.0)) * exp(-d * 1.8) * 2.2;
        armOut = dens;
        g += mix(armCol, vec3(0.85, 0.85, 1.0), 0.3) * dens * (1.0 + u.mid) + coreCol * exp(-d * 4.0) * 0.2;
        g += hii * beads(p, 28.0, seed, 0.35) * dens * detail * (0.8 + 1.6 * u.treble) * 3.0;
        dust = smoothstep(0.55, 0.8, fbm(p * 7.0 + seed * 2.0)) * dens * 0.8 * detail;
    } else if (gtype == 4) {
        // Lenticular / Sombrero: smooth old disc crossed by a dark ring of dust.
        g += coreCol * (exp(-d * 3.0) * 0.6 + exp(-d * 1.4) * 0.12);
        float dr = mix(0.45, 0.75, fract(seed * 6.1));
        dust = exp(-sq((d - dr) / 0.07)) * 1.3 * (0.7 + 0.5 * fbm(p * 12.0 + seed));
    } else if (gtype == 5) {
        g += coreCol * exp(-d * 3.5) * 0.35;
    } else {
        // Ring galaxy: a blue ring of young stars around an old core.
        float ringR = mix(0.55, 0.8, fract(seed * 4.3));
        float ring = exp(-sq((d - ringR - (fbm(p * 3.0 + seed) - 0.5) * 0.12) / 0.08)) * (0.5 + 0.9 * fbm(p * 8.0 + seed));
        armOut = ring;
        g += armCol * ring * 1.6 * (1.0 + u.mid) + coreCol * disc * 0.15;
        g += hii * beads(p, 50.0, seed, 0.3) * ring * detail * (0.6 + 1.6 * u.treble) * 1.5;
        dust = ring * 0.25 * detail;
    }
}

void main() {
    vec2 uv = rot(vec2(ndc.x * u.aspect, ndc.y), u.roll);

    vec3 col = vec3(0.004, 0.003, 0.012);

    float r = length(uv);

    // Galaxies: real 3D discs at any tilt. Each pixel's view ray is intersected with several parallel
    // planes through a thick disc, so the near side looms larger than the far side, discs foreshorten and
    // turn edge-on, and flying through one takes a long time as its layers of stars and dust stream past.
    // Per galaxy (3 x vec4): A = centre (camera space x, y, z), radius; B = seed, spin, arm count, alpha;
    // C = disc thickness, fly-through flag, disc normal x, normal y.
    // Bass pumps the bulge, mids light the arms, treble sparks the star-forming regions.
    vec3 ray = vec3(uv, 1.0);  // view ray, scaled so that its depth component is 1
    for (int k = 0; k < MAX_GALAXIES; k++) {
        vec4 A = galaxies[k * 3];
        vec4 B = galaxies[k * 3 + 1];
        vec4 C = galaxies[k * 3 + 2];
        if (B.w <= 0.001) continue;
        vec3 cen = A.xyz;
        float size = A.w;
        vec3 N = vec3(C.z, C.w, sqrt(saturate(1.0 - C.z * C.z - C.w * C.w)));
        vec3 e1 = normalize(cross(N, abs(N.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
        vec3 e2 = cross(N, e1);
        float arms = B.z;
        // Galaxy type and look, from its seed (so every galaxy is different).
        float tr = fract(B.x * 11.3);
        int gtype = arms < 0.5 ? (tr < 0.5 ? 4 : 5)
                  : (tr < 0.34 ? 0 : (tr < 0.54 ? 1 : (tr < 0.74 ? 2 : (tr < 0.88 ? 3 : 6))));
        bool barred = gtype == 2 || (gtype == 0 && fract(B.x * 7.31) > 0.7);
        float pitch = mix(1.6, 3.6, fract(B.x * 13.7));      // loosely to tightly wound arms
        float pal = fract(B.x * 17.9);
        // Palettes from real photos: violet-blue arms with a pink-white core, blue-white with cream, or neutral.
        vec3 coreCol = pal < 0.3 ? vec3(1.0, 0.8, 0.86) : vec3(1.0, 0.87, 0.66);
        vec3 armCol = pal < 0.3 ? vec3(0.52, 0.52, 1.0) : (pal < 0.65 ? vec3(0.66, 0.77, 1.0) : vec3(0.82, 0.84, 0.92));
        float bulgeSize = gtype == 3 ? 0.3 : (gtype == 6 ? 0.6 : (gtype == 4 ? 1.4 : mix(0.6, 1.5, fract(B.x * 5.3))));
        float bulgeGain = gtype == 3 ? 0.3 : 1.0;

        // Bulge: an oblate glow of old stars around the centre, measured along the ray in 3D.
        // (Closest point on the ray, clamped to in front of us so the glow stays continuous.)
        float tc = max(dot(cen, ray) / dot(ray, ray), 0.0);
        {
            vec3 off = ray * tc - cen;
            vec3 lo = vec3(dot(off, e1), dot(off, e2), dot(off, N) * 2.4) / size;
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
            float jitter = (hash21(gl_FragCoord.xy + float(idx) * 17.0) - 0.5) / float(GALAXY_LAYERS - 1);
            float f = float(idx) / float(GALAXY_LAYERS - 1) - 0.5 + jitter; // across the thickness
            float h = f * C.x;
            float t = (dot(cen, N) + h) / denom;                   // depth where the ray meets this plane
            if (t <= 0.004) continue;                              // that plane is behind us
            vec2 p = vec2(dot(ray * t - cen, e1), dot(ray * t - cen, e2)) / size;
            float d = length(p);
            if (d > 1.5) continue;
            float R = size / t;                 // on-screen size of one galaxy radius at that depth
            float swell = smoothstep(26.0, 11.0, R); // fade planes about to sweep over the camera
            if (swell <= 0.001) continue;
            float midW = exp(-f * f * 10.0) * swell;  // light and dust concentrate in the mid-plane
            float layerSeed = B.x * 13.0 + float(idx) * 1.7;
            float halo = exp(-d * 3.2);
            float edge = smoothstep(1.45, 0.75, d);
            // Fine structure (clumps, filaments, knots) lives in the thin mid-plane; above and below is haze.
            float detail = smoothstep(0.3, 0.8, midW);
            vec3 g;
            float dustAmt, arm;
            galaxyLayer(p, d, gtype, arms, barred, pitch, B.x * 13.0, detail, B.y, coreCol, armCol, g, dustAmt, arm);
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
            vec3 tintS = mix(vec3(1.0, 0.85, 0.7), vec3(0.75, 0.85, 1.0), hash21(floor(p * 90.0) + layerSeed));
            g += stars * max(halo * 2.5 + arm, sDeep * 0.7) * edge * tintS * 1.2 * (0.35 + 0.65 * midW);

            // This layer's dust hides some of what lies behind it, then its own light is added.
            col *= 1.0 - saturate(dustAmt * midW * edge) * 0.7 * B.w * layerFade;
            col += g * midW * B.w * pathGain * 0.24;
        }
    }

    // Nebulae: drawn as stacks of layers at different depths (back to front). Each layer is projected from
    // its own distance, so near ones grow and slide outward faster than far ones: real parallax.
    // Per cloud (3 x vec4): A = world x, y, back-layer depth, size; B = seed, rotation, hue shift, alpha;
    // C = depth thickness, fly-through flag, kind, variation (0...1: texture scale and palette).
    // Several cross-sections through the cloud. The middle ones are widest (an ellipsoid of gas),
    // each has its own structure and embedded stars, and nearer layers' dust dims what lies behind them.
    // Emission colours: hydrogen-alpha red (bass), oxygen-III teal (mids), sulphur gold (treble).
    // Kinds — nebulae: 0 emission, 1 reflection, 2 planetary shell, 3 supernova remnant, 4 dark, 5 bipolar,
    // 6 rosette; gas clouds: 7 veil filaments, 8 molecular cloud, 9 cirrus, 10 pillars, 11 bubble, 12 tendrils.
    vec3 hAlpha = vec3(0.85, 0.16, 0.3);
    vec3 oIII = vec3(0.12, 0.62, 0.75);
    vec3 sII = vec3(0.95, 0.58, 0.22);
    for (int k = 0; k < MAX_NEBULAE; k++) {
        vec4 A = nebulae[k * 3];
        vec4 B = nebulae[k * 3 + 1]; // B.z = hue shift
        vec4 C = nebulae[k * 3 + 2];
        if (B.w <= 0.001) continue;
        int kind = int(C.z + 0.5);
        float variation = C.w;
        float stretch = mix(1.0, 2.3, fract(B.x * 3.71)); // elongated clouds and shells
        vec3 gasA = cloudPalette(B.x * 5.3);
        vec3 gasB = cloudPalette(B.x * 5.3 + 0.3 + variation * 0.4);
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
            vec2 p = rot((uv - A.xy / z) / (R * girth), B.y + t * 0.9);
            p.x /= stretch;
            float d = length(p);
            if (d > 1.8) continue;
            float seed = B.x + t * 3.17;
            float Rs = R * girth;

            vec2 sp = p * mix(1.1, 2.6, variation) + seed * 31.0; // coarse billows ... fine texture
            vec2 q = vec2(fbm(sp + u.time * 0.01), fbm(sp + vec2(5.2, 1.3)));
            vec2 w = vec2(fbm(sp + 3.0 * q + vec2(1.7, 9.2)), fbm(sp + 3.0 * q + vec2(8.3, 2.8)));
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
            vec3 rim = mix(hAlpha, sII, saturate(0.15 + u.treble * 0.6 + B.z));
            vec3 inner = mix(oIII, vec3(0.55, 0.75, 1.0), u.mid * 0.4);
            vec3 c = mix(rim, inner, smoothstep(0.75, 0.05, d + (w.x - 0.5) * 0.5));
            c = mix(c, hAlpha * 1.2, u.bass * 0.35 * smoothstep(0.2, 0.9, d));
            c = mix(hAlpha * 1.15, c, 0.3 + 0.7 * t);

            if (kind == 1) {
                // Reflection nebula: starlight scattered off dust, soft and blue.
                c = mix(vec3(0.28, 0.48, 1.0), vec3(0.78, 0.87, 1.0), exp(-d * d * 4.0));
                gas *= 0.85;
            } else if (kind == 2) {
                // Planetary nebula: a glowing shell blown off a dying star, teal inside, red at the rim.
                float shell = exp(-sq((d - 0.55 - (n - 0.5) * 0.18) / 0.17));
                gas = shell * (0.5 + 0.9 * n) * 1.7;
                c = mix(vec3(0.15, 0.72, 0.82), hAlpha * 1.2, smoothstep(0.42, 0.78, d));
                dust = 0.0;
            } else if (kind == 3) {
                // Supernova remnant: a torn, filamentary blast shell.
                float r0 = 0.72 + (w.x - 0.5) * 0.3;
                float shell = exp(-sq((d - r0) / 0.08)) * (0.35 + 1.2 * fbm(sp * 4.0 + w * 2.0));
                gas = shell * 1.5 + gas * 0.12;
                c = mix(oIII * 1.15, hAlpha * 1.25, saturate(n * 1.6 - 0.3));
                dust = 0.0;
            } else if (kind == 4) {
                // Dark nebula: a cold dust cloud, seen as a silhouette against the glow of the stars behind it.
                if (sl == 0) {
                    float backdrop = exp(-d * d * 1.6) * smoothstep(1.8, 1.0, d) * (0.55 + 0.6 * fbm(sp * 0.8 + 9.0));
                    col += vec3(0.62, 0.5, 0.56) * backdrop * 0.5 * la;
                    col += pointStars(p, 160.0, Rs, seed + 21.0, 0.12) * backdrop * la;
                }
                dust = smoothstep(0.32, 0.68, n) * shape * 1.3;
                gas *= 0.12;
                c = vec3(0.6, 0.32, 0.26);
            } else if (kind == 5) {
                // Bipolar nebula: two lobes blown out of a dying star, pinched at the waist (hourglass / butterfly).
                float ay = abs(p.y);
                float lobe = exp(-sq(p.x / (0.08 + 0.55 * ay))) * smoothstep(1.05, 0.35, ay) * smoothstep(0.0, 0.12, ay);
                gas = lobe * (0.45 + 0.9 * n) * 1.8;
                c = mix(vec3(0.2, 0.7, 0.85), hAlpha * 1.2, smoothstep(0.2, 0.8, ay + abs(p.x) * 0.5));
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
                gas = (pow(max(r1, 0.0), 7.0) + 0.5 * pow(max(r2, 0.0), 9.0)) * shape * 2.2;
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
                c = mix(vec3(0.55, 0.62, 0.78), gasA, 0.2);
                dust = 0.0;
            } else if (kind == 10) {
                // Pillars: towers of dark dust rising from below, their edges lit, against a glowing backdrop.
                if (sl == 0) {
                    float backdrop = exp(-d * d * 1.4) * smoothstep(1.8, 1.0, d) * (0.5 + 0.7 * fbm(sp * 0.7 + 3.0));
                    col += mix(vec3(0.2, 0.55, 0.7), vec3(0.85, 0.6, 0.3), fbm(sp * 0.5)) * backdrop * 0.55 * la;
                }
                float tip = mix(-0.2, 0.65, fbm(vec2(p.x * 2.5, seed * 3.0)));
                float column = smoothstep(0.42, 0.72, fbm(vec2(p.x * 3.2, p.y * 0.9) + seed * 4.0 + w * 0.6))
                             * smoothstep(tip, tip - 0.3, p.y);
                float rimLight = column * (1.0 - column) * 4.0;
                dust = column * 1.4 * shape;
                gas = rimLight * shape * 1.6;
                c = mix(vec3(0.98, 0.72, 0.4), gasA, 0.3);
            } else if (kind == 11) {
                // Bubble: a vast, faint shell of hydrogen blown out by stellar winds.
                float shell = exp(-sq((d - 0.78 - (n - 0.5) * 0.12) / 0.11));
                gas = (shell * (0.5 + 0.8 * n) + n * n * 0.25 * smoothstep(0.8, 0.2, d)) * 1.5;
                c = mix(hAlpha * 1.1, gasA, 0.35);
                dust = 0.0;
            } else if (kind == 12) {
                // Tendrils: streamers of gas radiating from a bright central cluster.
                vec2 dirv = p / max(d, 1e-3);
                float streak = fbm(dirv * 5.5 + vec2(d * 1.4, 0.0) + seed * 3.0);
                gas = pow(streak, 3.0) * exp(-d * 1.4) * smoothstep(0.02, 0.22, d) * shape * 3.0 + exp(-d * d * 12.0) * 0.7;
                c = mix(gasA, gasB, smoothstep(0.2, 0.8, d));
            }

            float core = exp(-d * d * 9.0);
            vec3 neb = c * gas * 1.25 + vec3(0.95, 0.97, 1.0) * core * gas * 0.3;
            neb *= 1.0 - dust * 0.8;
            // The star at the heart of a planetary or reflection nebula (in the middle layer).
            if ((kind == 1 || kind == 2 || kind == 5) && sl == NEBULA_LAYERS / 2) {
                float sd = d * Rs / 0.004;
                neb += vec3(0.85, 0.92, 1.0) * (exp(-sd * sd) * 2.0 + exp(-d * d * 60.0) * 0.25);
            }
            // The young star cluster at the heart of a rosette or a tendril cloud.
            if ((kind == 6 || kind == 12) && sl == NEBULA_LAYERS / 2) {
                neb += vec3(0.85, 0.92, 1.0) * pointStars(p, 60.0, Rs, seed + 31.0, 0.5) * exp(-d * d * 18.0) * 1.8;
            }

            // Young stars embedded in the gas, at this layer's depth (so they parallax against other layers).
            float embedded = pointStars(p, 40.0, Rs, seed, 0.04) + near * pointStars(p, 140.0, Rs, seed + 5.0, 0.05);
            if (deep > 0.0) {
                embedded += deep * pointStars(p, 520.0, Rs, seed + 9.0, 0.04)
                          + deeper * pointStars(p, 1700.0, Rs, seed + 13.0, 0.04);
            }
            float starShare = kind == 4 ? 0.15 : ((kind == 7 || kind == 9 || kind == 11) ? 0.5 : 1.3);
            neb += embedded * shape * vec3(0.92, 0.96, 1.0) * starShare;

            // This layer's dust hides some of what is behind it, then its own light is added.
            col *= 1.0 - saturate((kind == 4 || kind == 10) ? dust * 0.7 : dust * 0.45 * shape * t) * la;
            float gain = kind == 9 ? 0.7 : (kind == 11 ? 0.8 : 1.0);
            col += neb * la * gain * mix(0.5, 0.65, t) * (0.45 + 0.55 * u.level + 0.35 * u.beat);
        }
    }

    // Vanishing-point glow, pumped by the bass.
    float core = 0.015 / (r * r + 0.02);
    col += mix(palette(u.hue + 0.5), vec3(1.0), 0.4) * core * (0.06 + 0.45 * u.bass + 0.3 * u.beat);

    // Tone map and vignette (dithering happens in the post pass).
    col *= 1.0 + 0.25 * u.beat;
    col = 1.0 - exp(-col * 1.4);
    float vig = smoothstep(1.9, 0.5, length(ndc * vec2(1.15, 1.0)));
    col *= mix(0.5, 1.0, vig);
    fragColor = vec4(col, 1.0);
}
