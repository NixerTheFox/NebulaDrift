// Post pass: black hole lensing, chromatic aberration, shockwave rings, cockpit glass and dithering
// (port of postFragment in Sources/Shaders.metal). Works in y-down pixel coordinates like Metal does.

in vec2 ndc;
out vec4 fragColor;

uniform sampler2D scene;
uniform float rings[MAX_RINGS];

/// Samples the scene with Metal's top-left texture origin.
vec4 sceneAt(vec2 st) { return texture(scene, vec2(st.x, 1.0 - st.y)); }

// MARK: - Black hole (drawn in the post pass so it can bend the light of everything behind it)

/// Approximate blackbody colour for a normalised temperature (0 = dull red ... 1 = white ... 1.4 = blue-white).
vec3 blackbody(float t) {
    vec3 c = mix(vec3(0.5, 0.06, 0.01), vec3(1.0, 0.38, 0.08), saturate(t * 2.2));
    c = mix(c, vec3(1.0, 0.78, 0.5), saturate(t * 2.2 - 0.9));
    c = mix(c, vec3(1.0, 0.96, 0.9), saturate(t * 2.0 - 1.4));
    return mix(c, vec3(0.78, 0.86, 1.0), saturate(t * 2.5 - 2.6));
}

struct HoleTrace {
    vec3 dir;     // direction the light finally came from (camera frame)
    vec3 light;   // disc and jet light picked up along the way
    float trans;  // how much of the background still shows through (0 = swallowed or fully blocked)
};

/// Disc gas density and turbulence at a point in the hole's frame (lengths in r_s).
float discDensity(vec3 pos, vec3 N, vec3 e1, vec3 e2, float rIn, float rOut, float thick,
                  float spin, float time, out float rho, out float hgt) {
    hgt = dot(pos, N);
    vec3 inPlane = pos - N * hgt;
    rho = length(inPlane);
    if (rho < rIn * 0.85 || rho > rOut * 1.1) return 0.0;
    float H = thick * rho + 0.05;
    float vert = exp(-0.5 * (hgt / H) * (hgt / H));
    if (vert < 0.01) return 0.0;
    float radial = smoothstep(rIn * 0.9, rIn * 1.25, rho) * pow(smoothstep(rOut, rOut * 0.3, rho), 1.5);
    float ang = atan(dot(inPlane, e2), dot(inPlane, e1));
    // Keplerian shear winds the gas into spiral streamers. Two phases cross-fade so it never winds up forever.
    float omega = spin * 2.2 / pow(rho, 1.5);
    float lr = log(rho);
    float n = 0.0;
    for (int k = 0; k < 2; k++) {
        float ph = fract(time / 24.0 + float(k) * 0.5);
        float wgt = 1.0 - abs(ph * 2.0 - 1.0);
        float a = ang - omega * ph * 24.0 + float(k) * 2.1;
        vec2 orbit = vec2(cos(a), sin(a));
        float warp = fbm(orbit * 2.0 + vec2(lr * 3.0, hgt / H * 0.35 + float(k) * 3.0));
        float g = fbm(orbit * 3.5 + vec2(lr * 12.0 + warp * 2.0, hgt / H * 0.6));
        n += wgt * g;
    }
    return vert * radial * (0.2 + 1.5 * n * n);
}

/// Follow a light ray from the camera through the black hole's curved spacetime. The bending uses the
/// photon-orbit equation x'' = -1.5 h² x / r⁵ (Schwarzschild, r_s = 1), which by itself produces the
/// shadow, the photon ring and the lensed images of the far side of the disc and of the stars behind.
/// The disc is a real 3D volume with thickness that emits and absorbs light along the way.
HoleTrace traceHole(vec3 rd) {
    HoleTrace res;
    res.light = vec3(0.0);
    res.trans = 1.0;
    float rsW = u.blackHole.w;
    vec3 pos = -u.blackHole.xyz / rsW;          // camera position relative to the hole
    vec3 dir = normalize(rd);
    vec3 N = normalize(u.blackHole3.xyz);
    vec3 e1 = normalize(cross(N, abs(N.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
    vec3 e2 = cross(N, e1);
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
        float jet = exp(-sq(dAx / width)) * smoothstep(3.0, 12.0, abs(sAx)) * exp(-abs(sAx) / 260.0) * knots;
        float glow = exp(-dAx / (width * 6.0)) * smoothstep(3.0, 20.0, abs(sAx)) * exp(-abs(sAx) / 160.0);
        res.light += (vec3(0.55, 0.62, 1.0) * jet * 0.7 + vec3(0.4, 0.35, 0.9) * glow * 0.03) * (0.7 + 0.6 * u.bass);
    }

    // Far from the hole the bending is weak: apply the deflection 2/b analytically.
    float tca = dot(-pos, dir);
    vec3 closest = pos + dir * max(tca, 0.0);
    float bImpact = length(closest);
    float reach = hasDisc ? rOut * 1.3 + 6.0 : 14.0;
    if (bImpact > max(reach, 60.0)) {
        float along = tca > 0.0 ? 1.0 : 0.5 * exp(tca / bImpact);
        res.dir = normalize(dir - closest / bImpact * (2.0 / bImpact) * along);
        return res;
    }

    vec3 vel = dir;
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
            vec3 inPlane = normalize(pos - N * hgt);
            vec3 orbitDir = cross(N, inPlane) * spin;
            float beta = min(sqrt(0.5 / max(rho - 1.0, 0.5)), 0.75);
            float gamma = 1.0 / sqrt(1.0 - beta * beta);
            float cosT = dot(orbitDir, -normalize(vel));
            float D = 1.0 / (gamma * (1.0 - beta * cosT));
            float g = D * sqrt(saturate(1.0 - 1.0 / rho));
            float temp = pow(rIn / rho, 0.75) * tempScale;
            vec3 emit = blackbody(temp * g) * min(pow(g, 3.5), 6.0) * dens * (0.6 + 0.6 * temp);
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
float scratchLayer(vec2 p, float cell, float seed, float width, float density, float maxLen) {
    vec2 cp = p / cell;
    vec2 base = floor(cp);
    float acc = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 c = base + vec2(float(i), float(j));
            if (hash21(c + seed) > density) continue;
            // Mostly near-horizontal (wiping), some at any angle.
            float r = hash21(c + seed + 3.7);
            float ang = r < 0.6 ? (r - 0.3) * 0.9 : r * 6.2832;
            float len = mix(0.25, maxLen, hash21(c + seed + 9.1));
            vec2 centre = c + vec2(hash21(c + seed + 1.3), hash21(c + seed + 5.9));
            vec2 dir = vec2(cos(ang), sin(ang));
            vec2 d = cp - centre;
            float t = clamp(dot(d, dir), -len * 0.5, len * 0.5);
            float dist = length(d - dir * t) * cell;
            float taper = 1.0 - sq(abs(t) / (len * 0.5));
            acc = max(acc, smoothstep(width, 0.0, dist) * taper * (0.35 + 0.65 * hash21(c + seed + 7.3)));
        }
    }
    return acc;
}

/// A very scratched canopy: long gouges, medium scratches, fine hairlines and curved wiper scuffs.
float glassScratches(vec2 g, float px) {
    float s = scratchLayer(g, 0.5, 1.0, px * 2.2, 0.6, 1.7);
    s = max(s, scratchLayer(g, 0.17, 7.0, px * 1.8, 0.5, 1.4) * 0.8);
    s = max(s, scratchLayer(g, 0.06, 13.0, px * 1.4, 0.4, 1.3) * 0.55);
    for (int i = 0; i < 3; i++) {
        vec2 centre = vec2(-1.3 + float(i) * 1.5, -2.3 - float(i) * 0.4);
        float R = length(g - centre);
        float ring = smoothstep(0.9, 1.0, fract(R * 36.0 + float(i) * 0.37));
        float patch = smoothstep(0.55, 0.75, fbm(g * 1.4 + float(i) * 5.0));
        s = max(s, ring * patch * 0.14);
    }
    return s;
}

/// Signed distance from a pixel to the canopy window's edge, in screen heights (negative inside), and the
/// outward normal of the nearest edge. Matches the window shape drawn by the cockpit frame overlay.
float windowEdge(vec2 px, vec2 size, out vec2 normal) {
    float w = size.x, h = size.y;
    float lo = w * 0.035, hi = w * 0.075, top = h * 0.07, ch = min(w, h) * 0.08;
    vec2 P[8] = vec2[8](vec2(lo, h + 20.0), vec2(lo, h * 0.5), vec2(hi, top + ch), vec2(hi + ch, top),
                        vec2(w - hi - ch, top), vec2(w - hi, top + ch), vec2(w - lo, h * 0.5), vec2(w - lo, h + 20.0));
    float best = -1e9;
    normal = vec2(0.0);
    for (int i = 0; i < 7; i++) {
        vec2 e = P[i + 1] - P[i];
        vec2 n = normalize(vec2(e.y, -e.x));
        float dist = dot(px - P[i], n);
        if (dist > best) { best = dist; normal = n; }
    }
    return best / h;
}

// MARK: - Post pass

const float bayer4[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);

void main() {
    vec2 size = vec2(textureSize(scene, 0));
    int mode = int(u.dither + 0.5);
    int strength = clamp(int(u.ditherStrength + 0.5), 1, 4);
    float stress = u.blackHole2.y;
    float holeAlpha = u.blackHole3.w; // fades in as it emerges from the distance
    bool hole = holeAlpha > 0.001;
    vec3 holePos = u.blackHole.xyz;
    vec2 centre = holePos.z > 0.01 ? holePos.xy / holePos.z : vec2(1e3);
    float Rs = 2.6 * u.blackHole.w / max(length(holePos), 1e-3); // shadow size on screen

    // Pixel position with a top-left origin, as in Metal.
    vec2 fragPx = vec2(gl_FragCoord.x, size.y - gl_FragCoord.y);

    // Retro snaps the sample position to chunky blocks (1-4 px depending on strength).
    vec2 px = fragPx;
    float block = mode == 2 ? float(strength) : 1.0;
    vec2 cell = floor(px / block);
    vec2 uvT = (mode == 2 ? cell * block + block * 0.5 : px) / size;

    // Tidal stress shakes the whole view.
    if (stress > 0.0) {
        vec2 jolt = vec2(fbm(vec2(u.time * 9.0, 1.3)), fbm(vec2(4.1, u.time * 9.0))) - 0.5;
        uvT += jolt * 0.03 * stress * stress;
    }
    // Screen point in aspect-scaled coordinates (the space the black hole lives in), and back.
    vec2 q = vec2((uvT.x * 2.0 - 1.0) * u.aspect, 1.0 - uvT.y * 2.0);

    // Chromatic aberration: red and blue drift apart toward the edges. Barely there when cruising,
    // intense at warp speed, with an extra kick on beats, and wild while tidal forces tear at the ship.
    vec2 fromCenter = uvT - 0.5;
    float warp = smoothstep(0.12, 0.6, u.speed);
    vec2 shift = fromCenter * (0.35 + dot(fromCenter, fromCenter)) * u.aberration
               * (0.006 + 0.05 * warp + 0.012 * u.beat) + fromCenter * 0.08 * stress;

    // Thick aluminium-oxide canopy: near the frame the glass is a wedge that bends the view, stretching the
    // image and splitting its colours, like looking through the edge of a heavy lens.
    vec2 edgeQ = vec2(0.0);
    float edgeK = 0.0, edgeIn = 1.0;
    if (u.glass.x > 0.5) {
        vec2 nrm;
        edgeIn = -windowEdge(fragPx, size, nrm);               // distance inside the window
        edgeK = pow(saturate(1.0 - edgeIn / 0.11), 2.2);
        vec2 shiftPx = -nrm * edgeK * 0.06 * size.y;           // pull the sample inward
        edgeQ = vec2(shiftPx.x / size.x * 2.0 * u.aspect, -shiftPx.y / size.y * 2.0);
    }

    // Trace this pixel's ray past the black hole (once), to find where its light really came from.
    vec2 qView = q + edgeQ;
    vec3 holeLight = vec3(0.0);
    float holeTrans = 1.0;
    if (hole) {
        HoleTrace ht = traceHole(vec3(qView, 1.0));
        vec2 qs = ht.dir.xy / max(ht.dir.z, 0.05);
        holeTrans = mix(1.0, ht.trans * smoothstep(-0.1, 0.25, ht.dir.z), holeAlpha);
        holeLight = ht.light * holeAlpha;
        qView = mix(qView, qs, holeAlpha);
    }

    // Each colour channel is sampled through the lens; near the hole (and while under stress) the image
    // is also smeared around it, as if space itself were being dragged in circles.
    int taps = stress > 0.03 ? 7 : 1;
    vec2 v0 = q - centre;
    vec2 tangent = normalize(vec2(-v0.y, v0.x) + 1e-5);
    float smear = stress * (0.05 + 0.25 * Rs / (length(v0) + Rs + 1e-3));
    vec3 c = vec3(0.0);
    for (int ch = 0; ch < 3; ch++) {
        vec2 off = (ch == 0 ? shift : (ch == 2 ? -shift : vec2(0.0))) * vec2(2.0 * u.aspect, -2.0);
        float acc = 0.0;
        for (int t = 0; t < taps; t++) {
            float k = taps > 1 ? float(t) / float(taps - 1) - 0.5 : 0.0;
            vec2 qs = qView + off + tangent * k * smear + edgeQ * 0.18 * (float(ch) - 1.0);
            vec2 st = vec2(qs.x / u.aspect * 0.5 + 0.5, 0.5 - qs.y * 0.5);
            vec4 sampled = sceneAt(st);
            acc += ch == 0 ? sampled.r : (ch == 1 ? sampled.g : sampled.b);
        }
        c[ch] = acc / float(taps);
    }

    // Beat shockwave rings: one thin, crisp wavefront per beat, drawn after the colour split so that
    // chromatic aberration never turns one ring into several.
    {
        float r = length(q); // q is the rotated view, so this matches the scene's radius
        vec3 tint = normalize(vec3(0.06) + u.bass * vec3(1.0, 0.12, 0.5) + u.mid * vec3(0.12, 0.6, 1.0)
                              + u.treble * vec3(1.0, 0.78, 0.3));
        vec3 ringCol = mix(tint, vec3(1.0), 0.35);
        float ringLight = 0.0;
        for (int i = 0; i < MAX_RINGS; i++) {
            float age = rings[i];
            if (age > 3.0) continue;
            ringLight += exp(-sq((r - age * 1.8) * 32.0)) * exp(-age * 2.2);
        }
        c += ringCol * ringLight * 0.45 * (1.0 - c);
    }

    if (hole) {
        c *= holeTrans;                               // the shadow, and the disc's gas in front of the stars
        vec3 light = 1.0 - exp(-holeLight * 1.3);     // keep the hot disc from clipping
        c = c + light * (1.0 - c);
    }
    if (stress > 0.0) {
        // Red alarm pulse creeping in from the edges.
        float pulse = 0.5 + 0.5 * sin(u.time * 9.0);
        float edge = smoothstep(0.35, 0.95, length(fromCenter * vec2(1.2, 1.6)));
        c = mix(c, vec3(0.75, 0.03, 0.02), edge * stress * (0.25 + 0.35 * pulse));
    }

    if (u.glass.x > 0.5) {
        // Scratched cockpit glass, fixed to the ship (it doesn't shake with the view). Scratches and smudges
        // catch the light of whatever bright thing is just behind them, the way real scratched glass does.
        vec2 g = vec2((px.x / size.x * 2.0 - 1.0) * u.aspect, 1.0 - px.y / size.y * 2.0);
        vec3 around = vec3(0.0);
        for (int i = 0; i < 6; i++) {
            float a = float(i) * 1.0472;
            around += sceneAt(uvT + vec2(cos(a) / u.aspect, sin(a)) * 0.04).rgb;
        }
        around /= 6.0;
        vec3 lum = vec3(0.3, 0.5, 0.2);
        float light = dot(around, lum) * 1.8 + dot(c, lum) * 0.7 + 0.02;
        float scr = glassScratches(g, 2.0 / size.y);
        float smudge = smoothstep(0.42, 0.85, fbm(g * 1.6 + 3.0)) * 0.6 + fbm(g * 7.0) * 0.12;
        float specks = step(0.996, hash21(floor(px * 0.5)));
        c += vec3(0.85, 0.9, 1.0) * (scr + specks * 0.3) * light * 1.15;
        c += around * smudge * 0.4;                     // haze scatters nearby light
        c *= vec3(0.94, 0.97, 1.0);                     // faint tint of the canopy
        c += vec3(0.3, 0.18, 0.08) * smoothstep(-0.2, -1.0, g.y) * 0.05; // console glow reflected low down
        // The thick edge: darker and faintly blue-green, with a thin bright inner rim catching the light.
        c *= mix(vec3(1.0), vec3(0.62, 0.72, 0.74), edgeK * 0.8);
        c += vec3(0.7, 0.85, 0.9) * exp(-edgeIn / 0.004) * (0.06 + light * 0.5);
    }

    if (mode == 2) {
        // Retro: ordered Bayer dither down to a few colour levels (fewer as strength rises).
        const float levelsFor[4] = float[4](10.0, 7.0, 5.0, 3.0);
        float levels = levelsFor[strength - 1];
        c = pow(saturate(c), vec3(0.8)); // lift shadows so dark nebula still gets dots
        ivec2 ci = ivec2(cell);
        float th = (bayer4[(ci.y % 4) * 4 + ci.x % 4] + 0.5) / 16.0 - 0.5;
        c = floor(c * (levels - 1.0) + 0.5 + th) / (levels - 1.0);
        fragColor = vec4(saturate(pow(max(c, 0.0), vec3(1.25))), 1.0);
        return;
    }
    if (mode == 1) {
        // Smooth: triangular noise, from barely-there anti-banding (light) to visible film grain (heavy).
        float n = hash21(px + fract(u.time) * 61.0) + hash21(px * 1.37 + fract(u.time * 1.3) * 47.0) - 1.0;
        c += n * exp2(float(strength) - 2.0) / 255.0;
    }
    fragColor = vec4(saturate(c), 1.0);
}
