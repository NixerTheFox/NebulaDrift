// A retro-futuristic digital dashboard (V key): a green vacuum-fluorescent instrument cluster under a smoked
// glass hood, like the dashboards of the mid-80s: segmented bar gauges, a bar-graph tachometer, seven-segment
// readouts, warning lamps and a dot-matrix display showing the song. Drawn with Cairo in y-down coordinates.

#pragma once

#include "instruments.h"

#include <array>
#include <string>
#include <vector>

class Dashboard {
public:
    using Source = InstrumentPanel::Source;

    Dashboard() = default;
    ~Dashboard();
    Dashboard(const Dashboard&) = delete;
    Dashboard& operator=(const Dashboard&) = delete;

    Source source = Source::system;

    void update(const PanelInput& i, float rawDt);
    /// What the dot-matrix display shows (scrolling when it doesn't fit).
    void setSong(const std::string& text);

    /// Height of the dashboard strip (with the shade it casts upward), along the bottom of a view.
    static double stripHeight(double width, double height);
    /// Draws the strip with its top at y = 0: everything but the glass.
    void drawStrip(cairo_t* c, double width, double height);
    /// The smoked glass over the displays, in the same coordinates. It never changes, so it is drawn once.
    void drawGlass(cairo_t* c, double width, double height);
    /// Both, along the bottom of a view (for test renders).
    void draw(cairo_t* c, double width, double height);

private:
    struct Layout {
        double u, width, strip;
        Rect hood, face, odometer, song, dots; // dots: the song display's dot field
        Rect flux, speedBox, tach, rpm;
        std::array<Rect, 3> bars;
        std::array<Rect, 6> lamps;
        std::array<Rect, 3> warp;
        std::array<Pt, 6> scaleDots;
        std::array<Rect, 3> speedDigits;
        std::array<Rect, 2> rpmDigits;
        std::array<Rect, 7> odoDigits;
        Rect peak;
        double dotPitch;
    };
    static constexpr int tachColumns = 46, barSegments = 12, fluxSegments = 12;

    static double unit(double width, double height);
    Layout layout(double width, double height) const;
    void makeCaches(const Layout& l, double scale);
    void drawStatic(cairo_t* c, const Layout& l);
    /// Every segment of the display: lit (with glow) or as the faint unlit phosphor.
    void drawSegments(cairo_t* c, const Layout& l, bool lit);
    void drawDynamic(cairo_t* c, const Layout& l);
    /// Paints the lit-segment layer inside `r`, at `alpha`.
    void paintLit(cairo_t* c, Rect r, double alpha = 1);
    void tachColumn(const Layout& l, int i, Rect& r, int& dashes) const;
    void renderSong(const Layout& l, double scale);

    float time = 0, chaos = 0, chaosClock = 0;
    std::array<float, 16> chaosTargets{};
    InstrumentPanel::Spring flux, rpm, speed;
    std::array<InstrumentPanel::Spring, 3> bars{};
    std::array<float, 3> peaks{}, peakAge{};
    std::array<float, 7> lampGlow{}; // WARP, TIDAL, BEAT, SYS, MIC, FILE, PEAK
    float beatLamp = 0;
    double distance = 0; // light-years, on the trip meter
    float lightSpeeds = 0;

    std::string song, alarmText;
    double songScroll = 0, songHold = 0;

    cairo_surface_t* back = nullptr;    // everything that never changes
    cairo_surface_t* lit = nullptr;     // every segment lit, with its glow
    cairo_surface_t* songImage = nullptr;
    int songColumns = 0;
    std::string songRendered;
    std::array<std::array<cairo_surface_t*, 12>, 3> digitImages{}; // 0-9, blank, '-' for each digit size
    double cacheW = 0, cacheH = 0, cacheScale = 0;
};
