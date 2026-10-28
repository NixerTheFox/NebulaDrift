// Post pass: black hole lensing (traced in hole.frag), chromatic aberration, shockwave rings, cockpit glass and dithering
// (port of postFragment in Sources/Shaders.metal). Works in y-down pixel coordinates like Metal does.

in vec2 ndc;
out vec4 fragColor;

uniform sampler2D scene;
uniform sampler2D glassTex;  // scratches and specks, smudge (see glass.frag)
uniform sampler2D holeDir;   // the black hole pass at half resolution (see hole.frag)
uniform sampler2D holeLight;
uniform float rings[MAX_RINGS];

struct HoleTrace {
    vec3 dir;     // direction the light finally came from (camera frame)
    vec3 light;   // disc and jet light picked up along the way
    float trans;  // how much of the background still shows through (0 = swallowed or fully blocked)
};

/// Samples the scene with Metal's top-left texture origin.
vec4 sceneAt(vec2 st) { return texture(scene, vec2(st.x, 1.0 - st.y)); }

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

    // Where this pixel's ray past the black hole really came from (traced at half resolution in hole.frag).
    vec2 qView = q + edgeQ;
    vec3 holeLightSum = vec3(0.0);
    float holeTrans = 1.0;
    if (hole) {
        vec2 sh = (mode == 2 ? cell * block + block * 0.5 : px) / size;
        sh.y = 1.0 - sh.y;
        vec4 hd = texture(holeDir, sh);
        HoleTrace ht;
        ht.dir = normalize(hd.xyz);
        ht.trans = hd.w;
        ht.light = texture(holeLight, sh).rgb;
        vec2 qs = ht.dir.xy / max(ht.dir.z, 0.05);
        holeTrans = mix(1.0, ht.trans * smoothstep(-0.1, 0.25, ht.dir.z), holeAlpha);
        holeLightSum = ht.light * holeAlpha;
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
        vec3 light = 1.0 - exp(-holeLightSum * 1.3);  // keep the hot disc from clipping
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
        vec2 scratched = texelFetch(glassTex, ivec2(gl_FragCoord.xy), 0).rg; // scratches + specks, smudge
        float smudge = scratched.y;
        c += vec3(0.85, 0.9, 1.0) * scratched.x * light * 1.15;
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
