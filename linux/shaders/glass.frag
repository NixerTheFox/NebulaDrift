// Cockpit glass pass: the canopy's scratches, smudges and specks. They are fixed to the ship, so this runs only
// when the frame size changes; the post pass reads the result and lights it with whatever lies behind.

in vec2 ndc;
out vec4 glass; // scratches and specks, smudge

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

void main() {
    vec2 size = u.resolution;
    vec2 px = vec2(gl_FragCoord.x, size.y - gl_FragCoord.y);
    vec2 g = vec2((px.x / size.x * 2.0 - 1.0) * u.aspect, 1.0 - px.y / size.y * 2.0);
    float scr = glassScratches(g, 2.0 / size.y);
    float smudge = smoothstep(0.42, 0.85, fbm(g * 1.6 + 3.0)) * 0.6 + fbm(g * 7.0) * 0.12;
    float specks = step(0.996, hash21(floor(px * 0.5)));
    glass = vec4(scr + specks * 0.3, smudge, 0.0, 1.0);
}
