// Streaking stars, one instanced quad each (port of starVertex in Sources/Shaders.metal).

layout(location = 0) in vec4 starA; // x, y, z (head), z (tail)
layout(location = 1) in vec4 starB; // size, seed, brightness, true depth

out vec3 local;   // along (in widths), across (-1...1), streak length (in widths)
out vec3 color;   // head
out vec3 tailCol; // trail colour, more saturated the faster we go

vec2 projectStar(vec2 xy, float z) {
    return rot(xy / z, -u.roll);
}

void main() {
    float z = starA.z;
    vec2 head = projectStar(starA.xy, z);
    vec2 tail = projectStar(starA.xy, starA.w);
    vec2 d = head - tail;
    float len = length(d);
    vec2 dir = len > 1e-5 ? d / len : vec2(1.0, 0.0);
    vec2 nrm = vec2(-dir.y, dir.x);
    float w = clamp(starB.x * 0.0035 / z, 0.0014, 0.035);

    const vec2 corners[6] = vec2[6](vec2(0.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
                                    vec2(0.0, -1.0), vec2(1.0, 1.0), vec2(0.0, 1.0));
    vec2 c = corners[gl_VertexID];
    float L = len / w;
    float along = mix(-1.0, L + 1.0, c.x);
    vec2 p = tail + dir * along * w + nrm * c.y * w;

    gl_Position = vec4(p.x / u.aspect, p.y, 0.0, 1.0);
    local = vec3(along, c.y, L);

    float seed = starB.y;
    float twinkle = 0.75 + 0.25 * sin(u.time * (2.0 + seed * 9.0) + seed * 80.0) * (0.4 + u.treble);
    float fadeIn = smoothstep(STAR_FAR, STAR_FAR * 0.75, z);
    float bright = starB.z * twinkle * fadeIn * clamp(0.45 / z, 0.14, 2.5) *
                   (0.7 + 0.8 * u.level + 0.6 * u.beat);
    vec3 tint = palette(u.hue + seed * 0.5 + 0.1);
    // Real stars range from blue-white to deep orange; most are close to white.
    float spectral = fract(seed * 7.13);
    vec3 starCol = spectral < 0.12 ? vec3(0.7, 0.8, 1.0)
                 : (spectral < 0.6 ? vec3(0.97, 0.98, 1.0)
                 : (spectral < 0.8 ? vec3(1.0, 0.94, 0.82)
                 : (spectral < 0.94 ? vec3(1.0, 0.82, 0.62) : vec3(1.0, 0.66, 0.5))));
    color = mix(starCol, tint, 0.05 + 0.1 * u.treble) * bright * 0.5;
    float vivid = smoothstep(0.1, 0.7, u.speed);
    tailCol = mix(color, palette(u.hue + seed * 0.35 + 0.15) * bright * 0.6, 0.35 + 0.55 * vivid);
}
