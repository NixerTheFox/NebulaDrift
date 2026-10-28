// Black hole pass: traces each pixel's light ray past the black hole (port of traceHole in
// Sources/Shaders.metal). By far the most expensive part of a frame, so it runs at half resolution: the bending
// varies smoothly across the screen, and the post pass upsamples the result.

in vec2 ndc;
layout(location = 0) out vec4 holeDir;   // direction the light finally came from (camera frame), transmittance
layout(location = 1) out vec4 holeLight; // disc and jet light picked up along the way

uniform vec2 fullSize; // the full-resolution frame, in pixels

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

void main() {
    vec2 size = fullSize;
    // The full-resolution point at the centre of this texel's 2 x 2 pixels, y-down as in the post pass.
    vec2 halfSize = ceil(size * 0.5);
    vec2 px = vec2(gl_FragCoord.x, halfSize.y - gl_FragCoord.y) * 2.0;

    // The same ray the post pass would trace for this pixel: shaken by tidal stress, bent by the canopy's edge.
    vec2 uvT = px / size;
    float stress = u.blackHole2.y;
    if (stress > 0.0) {
        vec2 jolt = vec2(fbm(vec2(u.time * 9.0, 1.3)), fbm(vec2(4.1, u.time * 9.0))) - 0.5;
        uvT += jolt * 0.03 * stress * stress;
    }
    vec2 q = vec2((uvT.x * 2.0 - 1.0) * u.aspect, 1.0 - uvT.y * 2.0);
    if (u.glass.x > 0.5) {
        vec2 nrm;
        float edgeIn = -windowEdge(px, size, nrm);
        float edgeK = pow(saturate(1.0 - edgeIn / 0.11), 2.2);
        vec2 shiftPx = -nrm * edgeK * 0.06 * size.y;
        q += vec2(shiftPx.x / size.x * 2.0 * u.aspect, -shiftPx.y / size.y * 2.0);
    }
    HoleTrace ht = traceHole(vec3(q, 1.0));
    holeDir = vec4(ht.dir, ht.trans);
    holeLight = vec4(ht.light, 1.0);
}
