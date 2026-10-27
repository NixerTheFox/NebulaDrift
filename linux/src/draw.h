// Small Core Graphics–style helpers on top of Cairo, so the console and canopy code reads like the
// macOS version: rects, colours, gradients, blurred drop shadows and tracked label text. All y-down.

#pragma once

#include <cairo.h>
#include <cmath>
#include <functional>
#include <string>
#include <vector>

struct Pt {
    double x = 0, y = 0;
};

struct Rect {
    double x = 0, y = 0, w = 0, h = 0;

    double minX() const { return x; }
    double minY() const { return y; }
    double maxX() const { return x + w; }
    double maxY() const { return y + h; }
    double midX() const { return x + w / 2; }
    double midY() const { return y + h / 2; }
    Rect inset(double dx, double dy) const { return {x + dx, y + dy, w - 2 * dx, h - 2 * dy}; }
    Rect offset(double dx, double dy) const { return {x + dx, y + dy, w, h}; }
};

struct RGBA {
    double r = 0, g = 0, b = 0, a = 1;
};

inline RGBA rgb(double r, double g, double b, double a = 1) { return {r, g, b, a}; }

/// Off-white stencil paint used for labels.
inline RGBA paint(double a) { return {0.86, 0.83, 0.74, a}; }

inline void setColor(cairo_t* c, RGBA k) { cairo_set_source_rgba(c, k.r, k.g, k.b, k.a); }

inline void addRect(cairo_t* c, Rect r) { cairo_rectangle(c, r.x, r.y, r.w, r.h); }

inline void fillRect(cairo_t* c, Rect r, RGBA k) {
    addRect(c, r);
    setColor(c, k);
    cairo_fill(c);
}

inline void clipRect(cairo_t* c, Rect r) {
    addRect(c, r);
    cairo_clip(c);
}

void addRoundedRect(cairo_t* c, Rect r, double radius);
void addEllipse(cairo_t* c, Rect r);

/// Like CGPath.addArc(tangent1End:tangent2End:radius:): a line toward `p1` rounded into the line to `p2`.
void arcTo(cairo_t* c, Pt p1, Pt p2, double radius);

/// Fills `r` with a gradient running down (vertical) or across and down (diagonal) the rect, as in the
/// macOS helper; colours are spread evenly and the last one carries on past `endFraction`.
void linearGradient(cairo_t* c, Rect r, const std::vector<RGBA>& colors, bool vertical, double endFraction = 1);

/// Paints a radial gradient (inside the current clip) from `center` out to `radius`; nothing beyond it.
void radialGradient(cairo_t* c, Pt center, double radius, const std::vector<RGBA>& colors,
                    const std::vector<double>& locations = {});

/// Draws what `body` draws with a soft drop shadow underneath, like CGContext.setShadow. Offset and blur
/// are in points (scaled with the context), offset y positive is down.
void withShadow(cairo_t* c, double dx, double dy, double blur, RGBA color, const std::function<void(cairo_t*)>& body);

/// Label text in the console's condensed font. `p` is the centre (or left edge, with alignLeft) of the
/// text, vertically centred on its capitals. `tracking` is extra space after each character, in ems.
void drawText(cairo_t* c, const std::string& s, Pt p, double size, RGBA color, bool alignLeft = false,
              double tracking = 0.06, bool alignRight = false);

/// Width of `s` as drawText would set it.
double textWidth(cairo_t* c, const std::string& s, double size, double tracking = 0.06);

/// UI text (HUD, stats) in the system sans-serif or monospace font.
enum class UIFont { sans, mono };
void selectUIFont(cairo_t* c, UIFont font, double size);

/// Loads the bundled label font (falls back to the system's sans-serif if missing).
void loadLabelFont(const std::string& path);

/// Point at `angle` measured clockwise from straight up (y-down coordinates).
inline Pt polar(Pt c, double r, double angle) { return {c.x + r * std::sin(angle), c.y - r * std::cos(angle)}; }

/// Tiny deterministic generator (the same sequence as the macOS LCG).
struct LCG {
    unsigned long long state;
    explicit LCG(unsigned long long seed) : state(seed) {}
    double next() {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        return double(state >> 40) / double(1 << 24);
    }
};

/// A uniformly random float in [a, b].
float frand(float a, float b);
