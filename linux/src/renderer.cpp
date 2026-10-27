#include "renderer.h"

#include "draw.h"
#include "instruments.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>

static float clampf(float v, float lo, float hi) { return std::min(std::max(v, lo), hi); }

static bool coin() { return frand(0, 1) < 0.5f; }

template <class T>
static T pick(const std::vector<T>& v) {
    return v[std::min(size_t(frand(0, 1) * float(v.size())), v.size() - 1)];
}

const char* ditherLabel(DitherMode m) {
    switch (m) {
    case DitherMode::off: return "Dither: Off";
    case DitherMode::smooth: return "Dither: Smooth (removes banding)";
    case DitherMode::retro: return "Dither: Retro";
    }
    return "";
}

// MARK: - Object field

SpaceObject ObjectField::make(std::optional<float> z, std::optional<bool> through, std::optional<float> fixedSize) const {
    float angle = frand(0, 2 * float(M_PI));
    float size = fixedSize ? *fixedSize : frand(sizeLo, sizeHi);
    bool flyThrough = through ? *through : frand(0, 1) < throughChance;
    // Usually it sails past to one side; rarely we're headed straight into it.
    float dist = flyThrough ? size * frand(throughLo, throughHi) : size * extent + frand(0.2f, 0.9f);
    SpaceObject o;
    o.xy = V2(cosf(angle), sinf(angle)) * dist;
    o.z = z ? *z : spawnZ;
    o.size = size;
    o.seed = frand(0, 1);
    o.rotation = frand(0, 2 * float(M_PI));
    o.spin = frand(-0.03f, 0.03f);
    o.extra = extras(flyThrough);
    o.flyThrough = flyThrough;
    return o;
}

void ObjectField::spawnFlyThrough() {
    if (int(objects.size()) >= maxCount) objects.erase(objects.begin());
    objects.push_back(make({}, true));
}

void ObjectField::update(float dt, float speed, float screenRadius) {
    // Far away it zooms in steadily (exponential); once close it keeps coming at full speed, so it
    // looms ever faster and sweeps past us, out behind the camera, rather than easing to a stop.
    for (auto& o : objects) {
        o.z -= speed * approach * dt * std::max(o.z, o.size * nearFactor);
        o.rotation += o.spin * dt;
    }
    // Drop it only once it is entirely behind us, or entirely outside the view.
    objects.erase(std::remove_if(objects.begin(), objects.end(),
                                 [&](const SpaceObject& o) {
                                     float reach = disc ? o.size * 1.5f : 0;
                                     return o.z + reach < 0 ||
                                            (o.z + reach > 0 &&
                                             (length(o.xy) - o.size * extent) / (o.z + reach) > screenRadius);
                                 }),
                  objects.end());
}

float ObjectField::alpha(const SpaceObject& o) const {
    float t = clampf((spawnZ - o.z) / (spawnZ * 0.4f), 0, 1);
    return t * t * (3 - 2 * t);
}

std::vector<V4> ObjectField::packed() const {
    std::vector<V4> out(size_t(maxCount) * 3);
    for (int i = 0; i < std::min(int(objects.size()), maxCount); i++) {
        const SpaceObject& o = objects[i];
        out[i * 3] = {o.xy.x, o.xy.y, o.z, o.size};
        out[i * 3 + 1] = {o.seed, o.rotation, o.extra.x, alpha(o)};
        out[i * 3 + 2] = {o.size * depth, o.flyThrough ? 1.0f : 0.0f, o.extra.y, o.extra.z};
    }
    return out;
}

// MARK: - Black holes

Renderer::BlackHoleVariant::BlackHoleVariant(float seed) {
    auto f = [&](float k) {
        float x = seed * k;
        return x - floorf(x);
    };
    float k = f(3.7f);
    kind = k < 0.12f ? bare : (k < 0.37f ? quasar : (k < 0.52f ? torus : standard));
    innerEdge = 2.0f + 1.2f * f(1.9f);
    outerEdge = 9 + 13 * f(2.7f);
    thickness = kind == torus ? 0.22f + 0.1f * f(5.1f) : 0.02f + 0.09f * powf(f(5.1f), 1.5f);
    temperature = kind == quasar ? 1.4f + 0.3f * f(8.3f) : 0.6f + 0.8f * f(8.3f);
    spin = f(4.9f) > 0.5f ? 1 : -1;
}

SpaceObject Renderer::makeBlackHole(float z) { return makeBlackHole(z, frand(0, 1)); }

/// A black hole far ahead. `size` is its shadow radius (≈ 2.6 r_s) in world units; `extra.xyz` is the
/// disc's normal. Our path passes beside it, above or below the disc, never through the disc itself.
SpaceObject Renderer::makeBlackHole(float z, float seed) {
    float size = frand(0.1f, 0.22f);
    float rs = size / 2.6f;
    BlackHoleVariant v(seed);
    SpaceObject best;
    best.z = z;
    best.size = size;
    best.seed = seed;
    for (int attempt = 0; attempt < 24; attempt++) {
        // Disc orientation: mostly seen fairly edge-on, sometimes much more open.
        float open = frand(0, 1) < 0.2f ? frand(0.5f, 0.9f) : frand(0, 0.45f);
        float az = frand(0, 2 * float(M_PI));
        float sq = sqrtf(1 - open * open);
        V3 n{cosf(az) * sq, sinf(az) * sq, open};
        // Offset toward the disc's "up" side so we fly over it.
        V2 side(n.x, n.y);
        side = length(side) > 0.2f ? normalize(side) : V2(cosf(az + 1.3f), sinf(az + 1.3f));
        if (coin()) side = -side;
        float lateral = frand(13, 22) * rs;
        V2 xy = side * lateral;
        // Where (if anywhere) does our straight path cross the disc plane, and how far from the hole is that?
        float crossing = INFINITY;
        if (fabsf(n.z) > 1e-3f) {
            float zc = -(xy.x * n.x + xy.y * n.y) / n.z; // camera-relative z of the hole when we cross
            crossing = length(V3{xy.x, xy.y, zc}) / rs;
        }
        best.xy = xy;
        best.extra = {n.x, n.y, n.z, 0};
        if (crossing > v.outerEdge * 1.6f + 6) break;
    }
    return best;
}

void Renderer::updateBlackHole(float dt) {
    if (!blackHole) {
        tidalStress = std::max(tidalStress - dt * 0.5f, 0.0f);
        u.blackHole = {};
        u.blackHole2 = {};
        u.blackHole3 = {};
        return;
    }
    SpaceObject bh = *blackHole;
    // Zooms in from afar, then drifts past at a steady, unhurried pace.
    bh.z -= u.speed * 0.9f * dt * std::max(bh.z, bh.size * 5);
    // Tidal stress peaks as we pass closest, and lingers a moment after.
    float proximity = bh.size / length(V3{bh.xy.x, bh.xy.y, bh.z});
    float target = clampf((proximity - 0.05f) / 0.12f, 0, 1);
    tidalStress += (target - tidalStress) * (1 - expf(-dt * 3));
    if (bh.z < -length(bh.xy) * 3) blackHole.reset();
    else blackHole = bh;
    // Hand the shader its 3D position and disc orientation in the (roll-rotated) screen frame.
    float c = cosf(-u.roll), s = sinf(-u.roll);
    auto turn = [&](float x, float y) { return V2(c * x - s * y, s * x + c * y); };
    V2 p = turn(bh.xy.x, bh.xy.y), n = turn(bh.extra.x, bh.extra.y);
    float t = clampf((blackHoleSpawnZ - bh.z) / (blackHoleSpawnZ * 0.4f), 0, 1);
    BlackHoleVariant v(bh.seed);
    u.blackHole = {p.x, p.y, bh.z, bh.size / 2.6f};
    u.blackHole2 = {v.thickness, tidalStress, bh.seed, v.spin};
    u.blackHole3 = {n.x, n.y, bh.extra.z, std::max(t * t * (3 - 2 * t), 0.002f)};
    u.blackHole4 = {v.innerEdge, v.outerEdge, v.temperature, float(v.kind)};
}

void Renderer::spawnBlackHole() {
    nebulae.objects.clear();
    galaxies.objects.clear();
    blackHole = makeBlackHole(80);
}

// MARK: - Galaxies and clouds

/// Arm count and a random 3D orientation: anything from face-on to (sometimes) razor-thin edge-on.
/// Fly-through galaxies stay fairly open so our path actually crosses the disc.
V4 Renderer::galaxyExtras(bool flyThrough) {
    float arms = float(pick<int>({0, 2, 2, 2, 2, 3, 3, 4}));
    float maxTilt = flyThrough ? 55 : (frand(0, 1) < 0.15f ? 88 : 78);
    float tilt = frand(0, maxTilt) * float(M_PI) / 180;
    float azimuth = frand(0, 2 * float(M_PI));
    return {arms, sinf(tilt) * cosf(azimuth), sinf(tilt) * sinf(azimuth), 0};
}

V2 Renderer::galaxyNormal(float tiltDegrees, float azimuth) {
    float t = tiltDegrees * float(M_PI) / 180;
    return {sinf(t) * cosf(azimuth), sinf(t) * sinf(azimuth)};
}

/// A gas cloud (big, diffuse) or a nebula (more compact and structured), with its kind, a random
/// variation (texture scale, palette) and hue.
SpaceObject Renderer::makeCloud(bool gas, std::optional<float> z, std::optional<bool> through, std::optional<float> kind) {
    float size = gas ? frand(0.5f, 1.3f) : frand(0.3f, 0.75f);
    SpaceObject o = nebulae.make(z, through, size);
    // Cloud kinds (must match the shader): nebulae 0-6, gas clouds 7-12.
    o.extra.y = kind ? *kind : (gas ? pick<float>({7, 8, 9, 10, 11, 12}) : pick<float>({0, 1, 2, 3, 4, 5, 6}));
    o.extra.z = frand(0, 1);
    return o;
}

void Renderer::spawnFlyThrough(std::optional<bool> galaxy) {
    nebulae.objects.clear();
    galaxies.objects.clear();
    if (galaxy ? *galaxy : frand(0, 1) < 0.25f) {
        galaxies.spawnFlyThrough();
    } else {
        nebulae.objects = {makeCloud(frand(0, 1) < 0.66f, {}, true)};
    }
}

// MARK: - Setup

static std::string readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Can't read " + path);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

static GLuint compile(GLenum type, const std::string& source, const std::string& name) {
    GLuint s = glCreateShader(type);
    const char* src = source.c_str();
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[8192];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        throw std::runtime_error("Shader " + name + " failed to compile:\n" + log);
    }
    return s;
}

static GLuint link(const std::string& dir, const std::string& vert, const std::string& frag) {
    std::string header = "#version 330 core\n" + readFile(dir + "/common.glsl") + "\n";
    GLuint vs = compile(GL_VERTEX_SHADER, header + "#line 1 1\n" + readFile(dir + "/" + vert), vert);
    GLuint fs = compile(GL_FRAGMENT_SHADER, header + "#line 1 1\n" + readFile(dir + "/" + frag), frag);
    GLuint p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glLinkProgram(p);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[8192];
        glGetProgramInfoLog(p, sizeof(log), nullptr, log);
        throw std::runtime_error("Shaders " + vert + " + " + frag + " failed to link:\n" + log);
    }
    GLuint block = glGetUniformBlockIndex(p, "Uniforms");
    if (block != GL_INVALID_INDEX) glUniformBlockBinding(p, block, 0);
    return p;
}

Renderer::Renderer(const std::string& shaderDir, std::function<AudioFeatures(float)> f)
    : features(std::move(f)),
      spawnTimer(frand(15, 35)),
      // Slot counts must match MAX_NEBULAE / MAX_GALAXIES in the shaders.
      nebulae{2, 200, 0.6f, 0.45f, 0.4f, 0.65f, 1.0f, false, 0.05f, 0, 0.35f,
              [](bool) { return V4{frand(-0.15f, 0.25f), 0, 0, 0}; }, {}},
      // Galaxies are much farther away: they approach slower and show up less often.
      galaxies{2, 200, 0.5f, 0.35f, 0.35f, 1.1f, 0.22f, true, 0.05f,
               0.35f, 0.65f, // through the arms, not the blinding core
               [](bool through) { return Renderer::galaxyExtras(through); }, {}},
      hueBase(frand(0, 1)) {
    sceneProgram = link(shaderDir, "fullscreen.vert", "scene.frag");
    postProgram = link(shaderDir, "fullscreen.vert", "post.frag");
    starProgram = link(shaderDir, "star.vert", "star.frag");
    nebLoc = glGetUniformLocation(sceneProgram, "nebulae");
    galLoc = glGetUniformLocation(sceneProgram, "galaxies");
    ringLoc = glGetUniformLocation(postProgram, "rings");
    sceneLoc = glGetUniformLocation(postProgram, "scene");

    glGenVertexArrays(1, &emptyVAO);
    glGenVertexArrays(1, &starVAO);
    glGenBuffers(1, &starVBO);
    glBindVertexArray(starVAO);
    glBindBuffer(GL_ARRAY_BUFFER, starVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Star) * starCount, nullptr, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, sizeof(Star), (void*)0);
    glVertexAttribDivisor(0, 1);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(Star), (void*)sizeof(V4));
    glVertexAttribDivisor(1, 1);
    glBindVertexArray(0);

    glGenBuffers(1, &ubo);
    glBindBuffer(GL_UNIFORM_BUFFER, ubo);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(Uniforms), nullptr, GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
    glGenQueries(queryCount, queries);

    nebulae.objects = {makeCloud(true, 8.0f, false)};
    stars.resize(starCount);
    for (auto& s : stars) respawn(s, 16.0f / 9.0f, frand(0.03f, starFar));
}

Renderer::~Renderer() {
    glDeleteProgram(sceneProgram);
    glDeleteProgram(postProgram);
    glDeleteProgram(starProgram);
    glDeleteVertexArrays(1, &emptyVAO);
    glDeleteVertexArrays(1, &starVAO);
    glDeleteBuffers(1, &starVBO);
    glDeleteBuffers(1, &ubo);
    glDeleteQueries(queryCount, queries);
    if (sceneFBO) glDeleteFramebuffers(1, &sceneFBO);
    if (outFBO) glDeleteFramebuffers(1, &outFBO);
    if (sceneTex) glDeleteTextures(1, &sceneTex);
    if (outTex) glDeleteTextures(1, &outTex);
}

/// b.w holds the star's true depth; a.z / a.w are the head and tail depths actually drawn.
/// Stars fill a deep box of space ahead of us: far ones start as faint specks near the centre.
void Renderer::respawn(Star& s, float aspect, std::optional<float> z) {
    float depth = z ? *z : frand(starFar * 0.85f, starFar);
    V2 xy;
    do {
        xy = V2(frand(-aspect, aspect), frand(-1, 1)) * 1.15f;
    } while (length(xy) < nearPlane * 6); // dead-centre stars would never leave the screen
    float r = frand(0, 1);
    float big = frand(0, 1);
    // Mostly small and dim, a few big bright ones.
    s.a = {xy.x, xy.y, depth, depth};
    s.b = {0.5f + 2.2f * big * big * big, frand(0, 1), r * r * 0.9f + 0.1f, depth};
}

// MARK: - Simulation

void Renderer::step(float dt, int width, int height) {
    AudioFeatures f = features(dt);
    float aspect = float(width) / float(std::max(height, 1));
    u.resolution = V2(float(width), float(height));
    u.aspect = aspect;
    u.time += dt;

    float target = 0.10f + f.level * 0.5f + f.bass * 0.35f + f.beat * 0.7f;
    u.speed += (target - u.speed) * (1 - expf(-dt * 2.5f));
    u.travel += u.speed * dt;
    u.bass = f.bass;
    u.mid = f.mid;
    u.treble = f.treble;
    u.level = f.level;
    u.beat = f.beat;
    u.dither = float(int(ditherMode));
    u.ditherStrength = float(ditherStrength);
    u.aberration = aberration ? 1 : 0;
    u.glass = {cockpitGlass ? 1.0f : 0.0f, 0, 0, 0};

    // Each beat launches its own ring; older rings keep expanding until they fade out.
    for (auto& a : ringAges) a += dt;
    ringAges.erase(std::remove_if(ringAges.begin(), ringAges.end(), [](float a) { return a >= ringLifetime; }),
                   ringAges.end());
    if (f.beatAge < lastBeatAge && (ringAges.empty() || ringAges.back() > 0.25f)) {
        ringAges.push_back(f.beatAge);
        if (int(ringAges.size()) > maxRings) ringAges.erase(ringAges.begin());
    }
    lastBeatAge = f.beatAge;

    // Nebulae and galaxies: one or two of each at a time, drifting toward us slower than the stars.
    float screenR = sqrtf(aspect * aspect + 1);
    bool hadObject = !nebulae.objects.empty() || !galaxies.objects.empty() || blackHole;
    nebulae.update(dt, u.speed, screenR);
    galaxies.update(dt, u.speed, screenR);
    updateBlackHole(dt);
    // Only one nebula, galaxy or (very rarely) black hole at a time, with a long, quiet gap in between.
    if (nebulae.objects.empty() && galaxies.objects.empty() && !blackHole) {
        if (hadObject) spawnTimer = frand(15, 35); // seconds of empty space between nebulae/galaxies
        spawnTimer -= dt;
        if (spawnTimer <= 0) {
            // Share of spawns: gas clouds 60%, nebulae 30%, galaxies 9%, black holes under 1%.
            float roll = frand(0, 1);
            if (roll < blackHoleChance) {
                blackHole = makeBlackHole(blackHoleSpawnZ);
            } else if (roll < blackHoleChance + galaxyChance) {
                galaxies.objects = {galaxies.make()};
            } else if (roll < blackHoleChance + galaxyChance + nebulaChance) {
                nebulae.objects = {makeCloud(false)};
            } else {
                nebulae.objects = {makeCloud(true)};
            }
        }
    }
    hueBase = fmodf(hueBase + dt * (0.006f + f.treble * 0.02f + f.beat * 0.03f), 1);
    u.hue = hueBase + f.centroid * 0.35f;
    u.roll = u.time * 0.02f + sinf(u.time * 0.13f) * 0.25f + f.bass * 0.03f * sinf(u.time * 2);
    if (onFrame) {
        PanelInput in;
        in.bands = f.bands;
        in.bass = f.bass;
        in.mid = f.mid;
        in.treble = f.treble;
        in.level = f.level;
        in.beat = f.beat;
        in.speed = u.speed;
        in.hue = u.hue;
        in.centroid = f.centroid;
        in.roll = u.roll;
        in.alarm = u.blackHole2.y;
        onFrame(in, dt);
    }

    float maxR = sqrtf(aspect * aspect + 1) + 0.15f;
    float tail = std::max(std::min(u.speed * 0.18f, 0.5f), 0.0005f);
    for (auto& s : stars) {
        s.b.w -= u.speed * dt;
        // The head stops at the near plane (already far off-screen); the tail keeps sweeping outward.
        float tailZ = std::max(s.b.w + tail, nearPlane);
        if (tailZ <= nearPlane || length(V2(s.a.x, s.a.y)) / tailZ > maxR) {
            respawn(s, aspect);
            continue;
        }
        s.a.z = std::max(s.b.w, nearPlane);
        s.a.w = tailZ;
    }
}

// MARK: - Drawing

void Renderer::ensureTargets(int width, int height) {
    if (width == targetW && height == targetH && sceneFBO) return;
    auto makeTarget = [&](GLuint& fbo, GLuint& tex, GLint internal, GLenum type) {
        if (!fbo) glGenFramebuffers(1, &fbo);
        if (!tex) glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, internal, width, height, 0, GL_RGBA, type, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    };
    makeTarget(sceneFBO, sceneTex, GL_RGBA16F, GL_HALF_FLOAT);
    makeTarget(outFBO, outTex, GL_RGBA8, GL_UNSIGNED_BYTE);
    glBindTexture(GL_TEXTURE_2D, 0);
    targetW = width;
    targetH = height;
}

void Renderer::collectTimings() {
    for (int i = 0; i < queryCount; i++) {
        if (!queryPending[i]) continue;
        GLint ready = 0;
        glGetQueryObjectiv(queries[i], GL_QUERY_RESULT_AVAILABLE, &ready);
        if (!ready) continue;
        GLuint64 ns = 0;
        glGetQueryObjectui64v(queries[i], GL_QUERY_RESULT, &ns);
        queryPending[i] = false;
        std::lock_guard<std::mutex> guard(statsLock);
        statGPUTime += double(ns) * 1e-9;
    }
}

GLuint Renderer::render(int width, int height) {
    width = std::max(width, 1);
    height = std::max(height, 1);
    ensureTargets(width, height);
    collectTimings();
    bool timing = !queryPending[queryIndex];
    if (timing) glBeginQuery(GL_TIME_ELAPSED, queries[queryIndex]);

    glBindBuffer(GL_UNIFORM_BUFFER, ubo);
    glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(Uniforms), &u);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
    glBindBuffer(GL_ARRAY_BUFFER, starVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Star) * stars.size(), nullptr, GL_STREAM_DRAW); // orphan
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(Star) * stars.size(), stars.data());

    std::vector<float> rings(ringAges);
    rings.resize(maxRings, 100);

    // Scene pass: nebula + stars into a high-precision texture.
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFBO);
    glViewport(0, 0, width, height);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glUseProgram(sceneProgram);
    std::vector<V4> neb = nebulae.packed(), gal = galaxies.packed();
    glUniform4fv(nebLoc, GLsizei(neb.size()), &neb[0].x);
    glUniform4fv(galLoc, GLsizei(gal.size()), &gal[0].x);
    glBindVertexArray(emptyVAO);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glEnable(GL_BLEND);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ZERO, GL_ONE);
    glUseProgram(starProgram);
    glBindVertexArray(starVAO);
    glDrawArraysInstanced(GL_TRIANGLES, 0, 6, GLsizei(stars.size()));
    glDisable(GL_BLEND);

    // Post pass: lensing, colour split, glass and dithering down to 8 bits.
    glBindFramebuffer(GL_FRAMEBUFFER, outFBO);
    glUseProgram(postProgram);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, sceneTex);
    glUniform1i(sceneLoc, 0);
    glUniform1fv(ringLoc, maxRings, rings.data());
    glBindVertexArray(emptyVAO);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);

    if (timing) {
        glEndQuery(GL_TIME_ELAPSED);
        queryPending[queryIndex] = true;
        queryIndex = (queryIndex + 1) % queryCount;
    }
    {
        std::lock_guard<std::mutex> guard(statsLock);
        statFrames += 1;
    }
    return outFBO;
}

std::vector<unsigned char> Renderer::readPixels(int width, int height) {
    std::vector<unsigned char> raw(size_t(width) * height * 4), out(raw.size());
    glBindFramebuffer(GL_READ_FRAMEBUFFER, outFBO);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, width, height, GL_BGRA, GL_UNSIGNED_BYTE, raw.data());
    size_t row = size_t(width) * 4;
    for (int y = 0; y < height; y++) std::memcpy(&out[y * row], &raw[(height - 1 - y) * row], row);
    return out;
}

std::pair<int, double> Renderer::takeStats() {
    std::lock_guard<std::mutex> guard(statsLock);
    auto out = std::make_pair(statFrames, statGPUTime);
    statFrames = 0;
    statGPUTime = 0;
    return out;
}

// MARK: - Test placements (--snapshot)

void Renderer::placeGalaxyForTesting(float seed, float arms, float tilt) {
    SpaceObject g = galaxies.make(0.85f, false);
    g.xy = V2(0.05f, 0.0f);
    g.size = 0.6f;
    g.seed = seed;
    V2 n = galaxyNormal(tilt, 1.2f);
    g.extra = {arms, n.x, n.y, 0};
    galaxies.objects = {g};
    nebulae.objects.clear();
    blackHole.reset();
    spawnTimer = 1000;
}

void Renderer::placeNebulaForTesting(float kind, float variation) {
    SpaceObject n = makeCloud(kind >= 7, 0.7f, false, kind);
    n.xy = V2(0.12f, 0.05f);
    n.size = 0.5f;
    n.extra.z = variation;
    nebulae.objects = {n};
    galaxies.objects.clear();
    blackHole.reset();
    spawnTimer = 1000;
}

void Renderer::placeBlackHoleForTesting(float zRs, float stress, float seed) {
    nebulae.objects.clear();
    galaxies.objects.clear();
    SpaceObject bh = makeBlackHole(1, seed);
    bh.z = zRs * bh.size / 2.6f;
    blackHole = bh;
    tidalStress = stress;
    spawnTimer = 1000;
}

void Renderer::placeFlyThroughForTesting(bool galaxy, float radius) {
    ObjectField& field = galaxy ? galaxies : nebulae;
    SpaceObject o = field.make(1.0f, true);
    if (galaxy) {
        // Just above the disc, looking down through it at a slant.
        o.z = o.size / radius;
        V2 n = galaxyNormal(50, 1.1f);
        o.extra = {2, n.x, n.y, 0};
    } else {
        o.z = o.size / radius + o.size * field.depth * 0.5f; // `radius` is for the middle layer
    }
    field.objects = {o};
    (galaxy ? nebulae : galaxies).objects.clear();
}

void Renderer::startFlyTest(std::optional<float> cloudKind) {
    nebulae.objects.clear();
    galaxies.objects.clear();
    blackHole.reset();
    spawnTimer = 1000;
    if (cloudKind) {
        SpaceObject o = makeCloud(*cloudKind >= 7, 1.0f, true, *cloudKind);
        o.size = 0.8f;
        o.xy = V2(0.08f, 0.05f);
        o.z = o.size * 3.5f;
        nebulae.objects = {o};
    } else {
        SpaceObject o = galaxies.make(1.0f, true, 0.8f);
        o.xy = V2(0.35f, 0.2f);
        o.z = o.size * 3;
        V2 n = galaxyNormal(45, 0.8f);
        o.extra = {2, n.x, n.y, 0};
        galaxies.objects = {o};
    }
}

void Renderer::spawnFreshForTesting() {
    nebulae.objects = {makeCloud(false, {}, false)};
    galaxies.objects = {galaxies.make({}, false)};
}

void Renderer::placeObjectsForTesting() {
    SpaceObject n = nebulae.make(0.45f);
    n.xy = V2(0.32f, 0.16f);
    n.size = 0.36f;
    nebulae.objects = {n};
    SpaceObject g = galaxies.make(1.1f, false);
    g.xy = V2(-0.62f, -0.05f);
    g.size = 0.55f;
    V2 gn = galaxyNormal(58, 3.3f);
    g.extra = {2, gn.x, gn.y, 0};
    galaxies.objects = {g};
}

std::optional<float> Renderer::testObjectDepth() const {
    if (!nebulae.objects.empty()) return nebulae.objects.front().z;
    if (!galaxies.objects.empty()) return galaxies.objects.front().z;
    return {};
}
