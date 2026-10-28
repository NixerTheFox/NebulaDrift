// The flight through space: simulation of stars, nebulae, galaxies and black holes, drawn with OpenGL.

#pragma once

#include "audio.h"
#include "gl.h"
#include "vec.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

struct PanelInput;

/// Must match `Uniforms` in shaders/common.glsl (std140).
struct Uniforms {
    V2 resolution;
    float time = 0;
    float aspect = 1;
    float bass = 0;
    float mid = 0;
    float treble = 0;
    float level = 0;
    float beat = 0;
    float speed = 0;
    float hue = 0;
    float roll = 0;
    float travel = 0;
    float dither = 1;
    float ditherStrength = 2;
    float aberration = 1;
    V4 blackHole;  // screen centre x, y, z (camera space), r_s
    V4 blackHole2; // disc thickness, tidal stress (0...1), seed, spin
    V4 glass;      // cockpit glass: on (0/1)
    V4 blackHole3; // disc normal x, y, z (screen frame), fade-in alpha
    V4 blackHole4; // inner edge, outer edge (in r_s), temperature scale, kind
};
static_assert(sizeof(Uniforms) == 144, "Uniforms must match the std140 block in the shaders");

enum class DitherMode { off = 0, smooth = 1, retro = 2 };
const char* ditherLabel(DitherMode m);

struct Star {
    V4 a; // x, y, z, tail z
    V4 b; // size, seed, brightness, true depth
};

/// A nebula or galaxy far away that drifts toward the camera.
struct SpaceObject {
    V2 xy;
    float z = 0;    // nebula: depth of its farthest layer; galaxy: depth of its centre
    float size = 0;
    float seed = 0;
    float rotation = 0;
    float spin = 0;
    V4 extra;       // nebula: hue shift, kind, variation; galaxy: arm count, disc normal x, normal y
    bool flyThrough = false; // on a collision course: we'll fly right through it
};

/// Moves the nebulae or galaxies toward us and drops them once passed (the renderer decides when to spawn).
struct ObjectField {
    static constexpr float extent = 1.8f; // drawn size in radii (matches the shader's cut-off)

    int maxCount;
    float spawnZ;        // far away: starts as a speck near the centre
    float approach;      // how fast it zooms in, relative to the star speed
    /// Below this depth (in object sizes) it stops zooming and drifts at a constant, slow speed.
    float nearFactor;
    float sizeLo, sizeHi;
    float depth;         // front-to-back thickness, as a fraction of its size
    /// Galaxies are 3D discs we can fly all the way through and out the back.
    bool disc;
    float throughChance; // probability that a new one is on a collision course
    float throughLo, throughHi; // how far off-centre we cross it, in object radii
    std::function<V4(bool)> extras;
    std::vector<SpaceObject> objects;

    SpaceObject make(std::optional<float> z = {}, std::optional<bool> through = {},
                     std::optional<float> fixedSize = {}) const;
    void spawnFlyThrough();
    void update(float dt, float speed, float screenRadius);
    float alpha(const SpaceObject& o) const;
    std::vector<V4> packed() const;
};

class Renderer {
public:
    static constexpr float nearPlane = 0.004f;
    static constexpr int maxRings = 10; // must match MAX_RINGS in the shaders
    static constexpr float blackHoleChance = 0.008f;
    static constexpr float galaxyChance = 0.09f;
    static constexpr float nebulaChance = 0.30f;
    static constexpr float blackHoleSpawnZ = 200;
    static constexpr int starCount = 12000;
    static constexpr float starFar = 6; // matches STAR_FAR in the shaders
    static constexpr float ringLifetime = 2.6f;

    /// Compiles the shaders found in `shaderDir`; throws std::runtime_error on failure.
    Renderer(const std::string& shaderDir, std::function<AudioFeatures(float)> features);
    ~Renderer();

    DitherMode ditherMode = DitherMode::smooth;
    int ditherStrength = 2; // 1 light ... 4 heavy
    bool aberration = true;
    bool cockpitGlass = false;
    /// Called after every simulation step with what the instrument console shows.
    std::function<void(const PanelInput&, float)> onFrame;

    void step(float dt, int width, int height);
    /// Renders the current frame into an RGBA8 framebuffer of `width` x `height` and returns it (bound).
    GLuint render(int width, int height);
    /// Reads back the last rendered frame as cairo-compatible premultiplied BGRA, top row first.
    std::vector<unsigned char> readPixels(int width, int height);

    void spawnBlackHole();
    void spawnFlyThrough(std::optional<bool> galaxy = {});

    /// Frames drawn and GPU time spent since the last call.
    std::pair<int, double> takeStats();

    // For --snapshot.
    void placeGalaxyForTesting(float seed, float arms, float tilt);
    void placeNebulaForTesting(float kind, float variation = 0.5f);
    void placeBlackHoleForTesting(float zRs, float stress, float seed = 0.6f);
    void placeFlyThroughForTesting(bool galaxy, float radius);
    void startFlyTest(std::optional<float> cloudKind);
    void spawnFreshForTesting();
    void placeObjectsForTesting();
    std::optional<float> testObjectDepth() const;

private:
    struct BlackHoleVariant {
        enum Kind { standard = 0, quasar = 1, bare = 2, torus = 3 };
        Kind kind;
        float innerEdge, outerEdge, thickness, temperature, spin;
        explicit BlackHoleVariant(float seed);
    };

    static SpaceObject makeBlackHole(float z, float seed);
    static SpaceObject makeBlackHole(float z);
    static V4 galaxyExtras(bool flyThrough);
    static V2 galaxyNormal(float tiltDegrees, float azimuth);

    void updateBlackHole(float dt);
    SpaceObject makeCloud(bool gas, std::optional<float> z = {}, std::optional<bool> through = {},
                          std::optional<float> kind = {});
    void respawn(Star& s, float aspect, std::optional<float> z = {});
    void ensureTargets(int width, int height);
    /// Pixels per black hole ray along each axis: wider frames get coarser rays, so the cost stays about the
    /// same as at standard resolution.
    static int holeStep(int width) { return width > 2200 ? 3 : 2; }
    void collectTimings();

    std::function<AudioFeatures(float)> features;
    Uniforms u;
    std::vector<float> ringAges;
    float lastBeatAge = INFINITY;
    float spawnTimer;
    std::optional<SpaceObject> blackHole;
    float tidalStress = 0;
    ObjectField nebulae, galaxies;
    std::vector<Star> stars;
    float hueBase;

    GLuint sceneProgram = 0, postProgram = 0, starProgram = 0, glassProgram = 0, holeProgram = 0;
    GLuint emptyVAO = 0, starVAO = 0, starVBO = 0, ubo = 0;
    GLuint sceneFBO = 0, sceneTex = 0, outFBO = 0, outTex = 0;
    int targetW = 0, targetH = 0;
    GLuint glassFBO = 0, glassTex = 0;                       // canopy scratches and smudges (glass.frag)
    GLuint holeFBO = 0, holeDirTex = 0, holeLightTex = 0;    // black hole rays at half resolution (hole.frag)
    bool glassReady = false;
    GLint nebLoc = -1, galLoc = -1, ringLoc = -1, frameLoc = -1;
    GLint postInputLocs[4] = {-1, -1, -1, -1};

    static constexpr int queryCount = 4;
    GLuint queries[queryCount] = {};
    bool queryPending[queryCount] = {};
    int queryIndex = 0;
    std::mutex statsLock;
    int statFrames = 0;
    double statGPUTime = 0;
};
