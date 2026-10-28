// Instrument console from an old spacecraft: analog gauges, faders, knobs, levers and lamps,
// all driven by the music. Drawn with Cairo in y-down coordinates.

#pragma once

#include "audio.h"
#include "draw.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <string>
#include <vector>

/// The flight speed the loudest music reaches (the needles and readouts are scaled to it).
constexpr float maxSpeed = 1.65f;

/// Flight speed in multiples of light speed, as the readouts show it: about 1 c in silence, well past 10 c when the
/// music is loud, 99.99 c at most.
inline float lightSpeedsFor(float speed) { return std::min(0.7f * std::exp(3.1f * std::max(speed, 0.0f)), 99.99f); }

struct PanelInput {
    std::array<float, AudioFeatures::bandCount> bands{};
    float bass = 0;
    float mid = 0;
    float treble = 0;
    float level = 0;
    float beat = 0;
    float speed = 0;
    float hue = 0;
    float centroid = 0;
    float roll = 0;
    float alarm = 0; // tidal stress from a passing black hole: the instruments go haywire
};

class InstrumentPanel {
public:
    enum class Source { system, mic, file };

    /// Damped spring, so needles and faders move like real hardware (with a little overshoot).
    struct Spring {
        float pos = 0;
        float vel = 0;
        void step(float target, float dt, float stiffness = 140, float damping = 13) {
            vel += ((target - pos) * stiffness - vel * damping) * dt;
            pos += vel * dt;
        }
    };

    static constexpr int faderCount = 12;
    static constexpr int nixieCount = 4;

    InstrumentPanel() = default;
    ~InstrumentPanel();
    InstrumentPanel(const InstrumentPanel&) = delete;
    InstrumentPanel& operator=(const InstrumentPanel&) = delete;

    Source source = Source::system;

    void update(const PanelInput& i, float rawDt);
    /// What the neon dot-matrix panel above the console shows (scrolling when it doesn't fit).
    void setSong(const std::string& text);

    static double panelHeight(double width, double height);
    /// Height of the console strip (panel plus the shade it casts upward).
    static double stripHeight(double width, double height);

    /// Draws the console strip with its top at y = 0 (the caller positions it at the bottom of the view).
    void drawStrip(cairo_t* c, double width, double height);
    /// The master alarm banner, in view coordinates; only while `alarmActive`.
    void drawAlarm(cairo_t* c, double width, double height);
    /// Where the banner goes (including room for its glow).
    static Rect alarmRect(double width, double height);
    /// Both, as the macOS view draws them: console along the bottom, banner near the top.
    void draw(cairo_t* c, double width, double height);

    /// Whether the alarm banner (drawn outside the console strip) is showing.
    bool alarmActive() const { return chaos > 0.02f; }

private:
    struct Layout {
        double u, shadow, stripHeight, panelTop;
        Rect levers, gauges, dial, faders, scope, knobs, lamps;
        Rect tab, screen, dots; // the song display: its raised plate, the screen, and the field of dots
        double dotPitch;
    };

    Layout layout(double width, double height) const;
    static Rect content(Rect plate, double u);

    void drawStatic(cairo_t* c, const Layout& l, double width);
    void drawDynamic(cairo_t* c, const Layout& l);
    void drawFronts(cairo_t* c, const Layout& l);
    /// Makes a patch of the static panel over `r`, inside `shape`, with `effect` drawn on it.
    struct Patch;
    void makePatch(Patch& patch, Rect r, double scale, const std::function<void(cairo_t*)>& shape,
                   const std::function<void(cairo_t*)>& effect);
    /// Fades a patch in over the static panel: the glow at strength `alpha`.
    void paintPatch(cairo_t* c, const Patch& patch, double alpha);
    /// Paints the cached front layer (within the current clip).
    void paintFront(cairo_t* c);
    void plate(cairo_t* c, Rect r, double u, const char* title);
    void staticLevers(cairo_t* c, const Layout& l);
    void staticGauges(cairo_t* c, const Layout& l);
    void staticNixies(cairo_t* c, const Layout& l);
    void staticFaders(cairo_t* c, const Layout& l);
    void staticScope(cairo_t* c, const Layout& l);
    void staticKnobs(cairo_t* c, const Layout& l);
    void staticLamps(cairo_t* c, const Layout& l);
    void staticSongTab(cairo_t* c, const Layout& l);
    void renderSong(const Layout& l);

    Rect leverSlot(Rect r, int k, double u) const;
    Rect gaugeFace(const Layout& l, int k) const;
    std::pair<Pt, double> gaugeGeometry(Rect face) const;
    double gaugeAngle(double v) const { return (-48 + 96 * v) * M_PI / 180; }
    std::pair<Rect, Rect> nixieRows(const Layout& l) const;
    std::vector<Rect> nixieTubes(const Layout& l) const;
    Rect nixieGlass(Rect tube) const;
    void addNixieGlassPath(cairo_t* c, Rect g) const;
    Rect digitBox(Rect g) const;
    void addNixieDigit(cairo_t* c, int d, Rect box) const;
    void nixieMesh(cairo_t* c, Rect g, RGBA color) const;
    Rect counterWindow(const Layout& l) const;
    int counterDigits(Rect win) const;
    std::pair<Rect, double> faderColumns(const Layout& l) const;
    struct Track {
        double x, top, bottom;
    };
    Track faderTrack(const Layout& l, int k) const;
    Rect scopeScreen(const Layout& l) const;
    std::pair<Pt, double> knobGeometry(const Layout& l, int k) const;
    struct Lamp {
        Pt center;
        double radius;
        const char* name;
    };
    std::vector<Lamp> lampGeometry(const Layout& l) const;
    void bezelRect(cairo_t* c, Rect r, double u);
    void screw(cairo_t* c, Pt p, double r);

    std::array<Spring, 3> gauges{};
    Spring velocity;
    std::array<Spring, faderCount> faders{};
    std::array<Spring, 2> levers{};
    std::array<double, 3> knobAngles{};
    float beatLamp = 0;
    std::array<float, AudioFeatures::bandCount> bands{};
    float bass = 0;
    float centroid = 0.5f;
    float time = 0;
    // Haywire state while a black hole's tidal forces scramble the electronics.
    float chaos = 0;
    std::array<float, 28> chaosTargets{};
    // Warm-up/cool-down of everything that glows.
    std::array<float, 4> lampGlow{};
    float bulb = 0; // the little bulbs lighting the VU meters
    std::array<int, nixieCount> nixieDigits{};
    std::array<int, nixieCount> nixiePrevious{};
    std::array<float, nixieCount> nixieAge{1, 1, 1, 1};
    float chaosClock = 0;
    std::array<double, 3> knobSpin{};
    double distance = 0; // travelled, in "AU", shown on the drum counter
    std::string song, songRendered;
    double songScroll = 0, songHold = 0;
    int songColumns = 0;
    cairo_surface_t* songImage = nullptr; // the song in lit dots

    cairo_surface_t* cache = nullptr;      // everything that never moves
    cairo_surface_t* frontCache = nullptr; // the Nixie tubes' cage and glass, drawn over the lit digits
    /// A piece of the static panel with a glow applied at full strength, in device pixels.
    struct Patch {
        cairo_surface_t* image = nullptr;
        int x = 0, y = 0;
        void release() {
            if (image) cairo_surface_destroy(image);
            image = nullptr;
        }
    };
    std::array<Patch, 3> litFaces;            // meter faces lit by their bulbs
    std::array<Patch, nixieCount> hazedTubes; // tubes filled with neon haze
    cairo_surface_t* gripImage = nullptr;  // a throttle lever's grip
    cairo_surface_t* capImage = nullptr;   // a fader cap
    ShadowCache shadows;
    enum : long { shadowLever = 1, shadowBulb, shadowDot, shadowFader, shadowNixie = 100, shadowLamp = 200 };
    double cacheW = 0, cacheH = 0, cacheScale = 0;
};
