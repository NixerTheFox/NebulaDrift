// Shared by every Nebula Drift shader (GLSL port of Sources/Shaders.metal). Prepended to each stage.

// Must match `Uniforms` in renderer.h (std140).
layout(std140) uniform Uniforms {
    vec2 resolution;
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
    vec4 blackHole;        // centre x, y, z in camera space (screen frame), Schwarzschild radius r_s
    vec4 blackHole2;       // disc thickness (half-height / radius), tidal stress (0...1), seed, spin (+1/-1)
    vec4 glass;            // cockpit glass: on (0/1), unused...
    vec4 blackHole3;       // disc normal x, y, z, fade-in alpha
    vec4 blackHole4;       // inner edge, outer edge (r_s), temperature scale, kind (0 std, 1 quasar, 2 bare, 3 torus)
} u;

#define MAX_RINGS 10
#define MAX_NEBULAE 2
#define MAX_GALAXIES 2
#define NEBULA_LAYERS 4
#define GALAXY_LAYERS 7
#define STAR_FAR 6.0

#define saturate(x) clamp(x, 0.0, 1.0)

float sq(float x) { return x * x; }

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = vec2(1.6 * p.x + 1.2 * p.y, -1.2 * p.x + 1.6 * p.y) + 3.1;
        a *= 0.5;
    }
    return v;
}

vec3 palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

vec2 rot(vec2 p, float a) {
    float c = cos(a), s = sin(a);
    return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}
