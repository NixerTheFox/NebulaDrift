#include "dashboard.h"

#include "dotmatrix.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

// Vacuum-fluorescent green, the pink of the warning lamps, and the red of the peak lamp and redline.
static const RGBA vfd{0.36, 1.0, 0.52, 1};
static const RGBA pink{1.0, 0.32, 0.62, 1};
static const RGBA red{1.0, 0.33, 0.22, 1};

static double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }

static double contextScale(cairo_t* c) {
    cairo_matrix_t m;
    cairo_get_matrix(c, &m);
    return std::sqrt(std::fabs(m.xx * m.yy - m.xy * m.yx));
}

static RGBA alpha(RGBA k, double a) { return {k.r, k.g, k.b, k.a * a}; }

Dashboard::~Dashboard() {
    for (cairo_surface_t* s : {back, lit, songImage}) {
        if (s) cairo_surface_destroy(s);
    }
    for (auto& set : digitImages) {
        for (cairo_surface_t* s : set) {
            if (s) cairo_surface_destroy(s);
        }
    }
}

// MARK: Update

void Dashboard::update(const PanelInput& i, float rawDt) {
    float dt = std::min(rawDt, 1.0f / 30);
    time += dt;
    chaos = std::max(i.alarm - 0.1f, 0.0f) / 0.9f;
    if (chaos > 0.02f) {
        chaosClock -= dt;
        if (chaosClock <= 0) {
            chaosClock = frand(0.04f, 0.14f) / std::max(chaos, 0.3f);
            for (auto& t : chaosTargets) t = frand(-0.1f, 1.15f);
        }
    }
    auto mixed = [&](float normal, int k) { return normal + (chaosTargets[k] - normal) * chaos; };
    float hard = 1 + 2 * chaos;
    flux.step(mixed(i.level, 0), dt, 60 * hard, 11);
    float levels[3] = {i.bass, i.mid, i.treble};
    for (int k = 0; k < 3; k++) {
        bars[k].step(mixed(levels[k], 1 + k), dt, 220 * hard, 22);
        // Peak hold: the top segment stays lit a moment, then drops.
        peakAge[k] += dt;
        if (bars[k].pos >= peaks[k]) {
            peaks[k] = bars[k].pos;
            peakAge[k] = 0;
        } else if (peakAge[k] > 0.7f) {
            peaks[k] = std::max(peaks[k] - dt * 0.9f, bars[k].pos);
        }
    }
    // Engine revs (thousands): the music's energy, with a kick on every beat.
    float revs = 0.7f + 6.2f * std::min(0.6f * i.level + 0.5f * i.bass, 1.1f) + 0.5f * i.beat;
    rpm.step(mixed(revs / 7.5f, 4) * 7.5f, dt, 90 * hard, 12);
    speed.step(mixed(i.speed / maxSpeed, 5) * maxSpeed, dt, 40 * hard * hard, 9);
    lightSpeeds = lightSpeedsFor(speed.pos);
    distance += double(lightSpeeds) * dt * 0.1;

    beatLamp = std::max(beatLamp * expf(-dt * 7), i.beat);
    arrows = std::max(arrows * expf(-dt * 5), i.beat > 0.5f ? 1.0f : 0.0f); // the hazard arrows flash on the beat
    float peakLit = std::max({bars[0].pos, bars[1].pos, bars[2].pos}) > 0.93f ? 1 : 0;
    std::array<float, 7> on{lightSpeeds >= 10 ? 1.0f : 0.0f, chaos > 0.02f && std::sin(time * 11) > 0 ? 1.0f : 0.0f,
                            beatLamp, source == Source::system ? 1.0f : 0.0f, source == Source::mic ? 1.0f : 0.0f,
                            source == Source::file ? 1.0f : 0.0f, peakLit};
    if (chaos > 0.02f) {
        for (int k = 0; k < 7; k++) {
            if (k != 1) on[k] = chaosTargets[6 + k] > 0.5f ? 1 : on[k] * (1 - chaos);
        }
        arrows = std::sin(time * 17) > 0 ? 1.0f : 0.0f;
    }
    for (int k = 0; k < 7; k++) {
        // Fluorescent segments light almost at once and fade out quickly.
        float rate = on[k] > lampGlow[k] ? 30 : 12;
        lampGlow[k] += (on[k] - lampGlow[k]) * (1 - expf(-dt * rate));
    }

    if (songHold > 0) songHold -= dt;
    else songScroll += dt * 14; // dot columns a second
}

void Dashboard::setSong(const std::string& text) {
    if (text == song) return;
    song = text;
    songScroll = 0;
    songHold = 1.5;
}

// MARK: Layout

double Dashboard::unit(double width, double height) {
    return std::max(std::min({height * 0.2, width / 5.6, 200.0}), 44.0);
}

double Dashboard::stripHeight(double width, double height) { return unit(width, height) * 1.12; }

Dashboard::Layout Dashboard::layout(double width, double height) const {
    Layout l{};
    double u = unit(width, height);
    l.u = u;
    l.width = width;
    l.strip = u * 1.12;
    Rect f{(width - 4.6 * u) / 2, 0.17 * u, 4.6 * u, 0.72 * u};
    l.face = f;
    l.hood = {f.x - 0.14 * u, 0.05 * u, f.w + 0.28 * u, f.maxY() - 0.05 * u};
    l.odometer = {f.x + 0.05 * u, 0.97 * u, 1.05 * u, 0.11 * u};
    l.song = {f.x + 1.25 * u, 0.97 * u, f.w - 1.3 * u, 0.11 * u};
    double p = l.song.h * 0.78 / dotmatrix::rows;
    l.dotPitch = p;
    double dotsX = l.song.x + 0.2 * u;
    l.dots = {dotsX, l.song.y + (l.song.h - 7 * p) / 2, std::floor((l.song.maxX() - 0.06 * u - dotsX) / p) * p, 7 * p};

    l.flux = {f.x + 0.2 * u, f.y + 0.23 * u, 0.1 * u, 0.36 * u};
    for (int k = 0; k < 3; k++) l.bars[k] = {f.x + (3.8 + 0.25 * k) * u, f.y + 0.2 * u, 0.08 * u, 0.4 * u};
    l.speedBox = {f.x + 1.4 * u, f.y + 0.14 * u, 0.95 * u, 0.22 * u};
    l.tach = {f.x + 1.0 * u, f.y + 0.34 * u, 2.35 * u, 0.28 * u};
    for (int k = 0; k < 3; k++) {
        l.speedDigits[k] = {l.speedBox.maxX() - 0.2 * u - (3 - k) * 0.125 * u + 0.015 * u, l.speedBox.y + 0.03 * u,
                            0.095 * u, 0.165 * u};
        l.warp[k] = {l.speedBox.x + (0.07 + 0.06 * k) * u, l.speedBox.y + (0.1 - 0.025 * k) * u, 0.035 * u,
                     (0.05 + 0.025 * k) * u};
    }
    for (int j = 0; j < 6; j++) {
        l.scaleDots[j] = {l.speedBox.x + 0.08 * u + j * (l.speedBox.w - 0.16 * u) / 5, l.speedBox.maxY() + 0.035 * u};
    }
    for (int k = 0; k < 2; k++) l.rpmDigits[k] = {f.x + (1.02 + 0.064 * k) * u, f.y + 0.42 * u, 0.05 * u, 0.085 * u};
    for (int k = 0; k < 7; k++) {
        l.odoDigits[k] = {l.odometer.x + (0.08 + 0.06 * k) * u, l.odometer.y + 0.0175 * u, 0.045 * u, 0.075 * u};
    }
    for (int k = 0; k < 2; k++) l.lamps[k] = {f.x + (1.62 + 0.23 * k) * u, f.y + 0.035 * u, 0.2 * u, 0.07 * u};
    for (int k = 0; k < 4; k++) l.lamps[2 + k] = {f.x + (2.4 + 0.23 * k) * u, f.y + 0.035 * u, 0.2 * u, 0.07 * u};
    l.peak = {f.x + 4.25 * u, f.y + 0.06 * u, 0.13 * u, 0.06 * u};
    l.arrowLeft = {f.x + 0.75 * u, f.y + 0.17 * u, 0.2 * u, 0.1 * u};
    l.arrowRight = {f.x + 3.35 * u, f.y + 0.17 * u, 0.2 * u, 0.1 * u};
    return l;
}

/// Column `i` of the tachometer: its outline and how many dashes it is made of. The columns grow taller
/// toward the top of the rev range, as on the real thing.
void Dashboard::tachColumn(const Layout& l, int i, Rect& r, int& dashes) const {
    double pitch = l.tach.w / tachColumns;
    double t = double(i) / (tachColumns - 1);
    double s = clampd((t - 0.12) / 0.83, 0, 1);
    double profile = 0.12 + 0.88 * s * s * (3 - 2 * s);
    if (t > 0.9) profile *= 1 - (t - 0.9) * 0.5;
    double dashPitch = 0.024 * l.u;
    dashes = std::max(2, int(std::lround(profile * l.tach.h / dashPitch)));
    double h = dashes * dashPitch;
    r = {l.tach.x + i * pitch + pitch * 0.19, l.tach.maxY() - h, pitch * 0.62, h};
}

// MARK: Shapes

/// A seven-segment digit in `cell`, slanted like the real ones; `mask` bits are segments a-g.
static void addSevenSegment(cairo_t* c, Rect cell, unsigned mask) {
    double w = cell.w, h = cell.h, t = w * 0.18, g = t * 0.14, skew = 0.08;
    auto P = [&](double x, double y) {
        cairo_line_to(c, cell.x + x + (h / 2 - y) * skew, cell.y + y);
    };
    auto horizontal = [&](double y) {
        double x0 = t / 2, x1 = w - t / 2;
        cairo_new_sub_path(c);
        P(x0 + g, y), P(x0 + g + t / 2, y - t / 2), P(x1 - g - t / 2, y - t / 2), P(x1 - g, y);
        P(x1 - g - t / 2, y + t / 2), P(x0 + g + t / 2, y + t / 2);
        cairo_close_path(c);
    };
    auto vertical = [&](double x, double y0, double y1) {
        cairo_new_sub_path(c);
        P(x, y0 + g), P(x + t / 2, y0 + g + t / 2), P(x + t / 2, y1 - g - t / 2), P(x, y1 - g);
        P(x - t / 2, y1 - g - t / 2), P(x - t / 2, y0 + g + t / 2);
        cairo_close_path(c);
    };
    double top = t / 2, mid = h / 2, bottom = h - t / 2, left = t / 2, right = w - t / 2;
    if (mask & 1) horizontal(top);
    if (mask & 2) vertical(right, top, mid);
    if (mask & 4) vertical(right, mid, bottom);
    if (mask & 8) horizontal(bottom);
    if (mask & 16) vertical(left, mid, bottom);
    if (mask & 32) vertical(left, top, mid);
    if (mask & 64) horizontal(mid);
}

static const unsigned digitMasks[12] = {0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F, 0x00, 0x40};
enum { blank = 10, dash = 11 };

/// The decimal point after a digit cell.
static void addDecimalPoint(cairo_t* c, Rect cell) {
    double r = cell.w * 0.09;
    addEllipse(c, {cell.maxX() + cell.w * 0.06, cell.maxY() - 2 * r, 2 * r, 2 * r});
}

static void addArrow(cairo_t* c, Rect r, bool left) {
    double s = left ? -1 : 1, cx = r.midX(), cy = r.midY();
    auto P = [&](double x, double y) { cairo_line_to(c, cx + s * x * r.w / 2, cy + y * r.h / 2); };
    cairo_new_sub_path(c);
    P(-1, -0.32), P(0.15, -0.32), P(0.15, -1), P(1, 0), P(0.15, 1), P(0.15, 0.32), P(-1, 0.32);
    cairo_close_path(c);
}

/// Segment `k` (0 = bottom) of a vertical bar gauge.
static Rect barSegment(Rect bar, int k, int count) {
    double h = bar.h / count;
    return {bar.x, bar.maxY() - (k + 1) * h + h * 0.14, bar.w, h * 0.72};
}

/// Lit things glow: a soft halo, then the bright segment.
static void glowFill(cairo_t* c, RGBA color, double blur) {
    cairo_path_t* path = cairo_copy_path(c);
    cairo_new_path(c);
    withShadow(c, 0, 0, blur, alpha(color, 0.9), [&](cairo_t* c) {
        cairo_append_path(c, path);
        setColor(c, color);
        cairo_fill(c);
    });
    cairo_path_destroy(path);
}

static void glowText(cairo_t* c, const std::string& s, Pt p, double size, RGBA color, double blur, bool left = false,
                     bool right = false) {
    withShadow(c, 0, 0, blur, alpha(color, 0.8),
               [&](cairo_t* c) { drawText(c, s, p, size, color, left, 0.06, right); });
}

// MARK: Static parts

void Dashboard::drawSegments(cairo_t* c, const Layout& l, bool on) {
    double u = l.u;
    double blur = 0.022 * u;
    // Unlit phosphor shows faintly through the glass.
    auto fill = [&](RGBA color) {
        if (on) glowFill(c, color, blur);
        else {
            setColor(c, alpha(color, 0.075));
            cairo_fill(c);
        }
    };
    for (int k = 0; k < fluxSegments; k++) addRect(c, barSegment(l.flux, k, fluxSegments));
    for (const Rect& bar : l.bars) {
        for (int k = 0; k < barSegments; k++) addRect(c, barSegment(bar, k, barSegments));
    }
    for (int i = 0; i < tachColumns; i++) {
        Rect r;
        int dashes;
        tachColumn(l, i, r, dashes);
        double dp = r.h / dashes;
        for (int j = 0; j < dashes; j++) addRect(c, {r.x, r.maxY() - (j + 1) * dp + dp * 0.15, r.w, dp * 0.7});
    }
    for (const Rect& w : l.warp) addRect(c, w);
    for (const Pt& d : l.scaleDots) addEllipse(c, {d.x - 0.012 * u, d.y - 0.012 * u, 0.024 * u, 0.024 * u});
    addArrow(c, l.arrowLeft, true);
    addArrow(c, l.arrowRight, false);
    fill(vfd);

    // Warning lamps: coloured windows with their legend in black.
    const char* names[6] = {"WARP", "TIDAL", "BEAT", "SYS", "MIC", "FILE"};
    for (int k = 0; k < 7; k++) {
        Rect r = k < 6 ? l.lamps[k] : l.peak;
        RGBA color = k < 2 ? pink : (k == 6 ? red : vfd);
        addRoundedRect(c, r, 0.012 * u);
        fill(color);
        drawText(c, k < 6 ? names[k] : "PEAK", {r.midX(), r.midY()}, r.h * 0.62,
                 on ? rgb(0.02, 0.05, 0.03, 0.9) : alpha(color, 0.12));
    }
    if (!on) {
        // Ghost eights behind every digit.
        for (const Rect& d : l.speedDigits) addSevenSegment(c, d, 0x7F);
        for (const Rect& d : l.rpmDigits) addSevenSegment(c, d, 0x7F);
        for (const Rect& d : l.odoDigits) addSevenSegment(c, d, 0x7F);
        fill(vfd);
        // The song display's dot field.
        double p = l.dotPitch;
        for (double x = l.dots.x; x < l.dots.maxX() - p * 0.5; x += p) {
            for (int r = 0; r < dotmatrix::rows; r++) addRect(c, {x, l.dots.y + r * p, p * 0.78, p * 0.78});
        }
        setColor(c, alpha(vfd, 0.06));
        cairo_fill(c);
    }
}

void Dashboard::drawStatic(cairo_t* c, const Layout& l) {
    double u = l.u, W = l.width;
    double top = 0.2 * u;
    linearGradient(c, {0, 0, W, top + 1}, {rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.6)}, true);

    // The dashboard: black textured plastic, with a soft highlight along its top edge.
    Rect body{0, top, W, l.strip - top};
    linearGradient(c, body, {rgb(0.095, 0.095, 0.1), rgb(0.03, 0.03, 0.034)}, true);
    LCG rng(23);
    for (int i = 0, n = int(W * body.h / 30); i < n; i++) {
        double x = rng.next() * W, y = top + rng.next() * body.h, s = 0.6 + rng.next();
        fillRect(c, {x, y, s, s}, rgb(1, 1, 1, 0.015 + 0.03 * rng.next()));
    }
    fillRect(c, {0, top, W, std::max(1.0, 0.008 * u)}, rgb(1, 1, 1, 0.1));
    fillRect(c, {0, top + std::max(1.0, 0.008 * u), W, 1}, rgb(0, 0, 0, 0.5));
    for (double x : {l.hood.minX() - 0.7 * u, l.hood.maxX() + 0.7 * u}) {
        fillRect(c, {x, top, 1, body.h}, rgb(0, 0, 0, 0.55));
        fillRect(c, {x + 1, top, 1, body.h}, rgb(1, 1, 1, 0.05));
    }

    // The hood over the cluster, casting its shadow onto the dash.
    Rect h = l.hood;
    auto hoodPath = [&](cairo_t* c) {
        cairo_new_path(c);
        cairo_move_to(c, h.minX(), h.maxY());
        cairo_line_to(c, h.minX() + 0.03 * u, h.minY() + 0.12 * u);
        cairo_curve_to(c, h.minX() + 0.06 * u, h.minY() + 0.01 * u, h.minX() + 0.4 * u, h.minY(), h.midX(), h.minY());
        cairo_curve_to(c, h.maxX() - 0.4 * u, h.minY(), h.maxX() - 0.06 * u, h.minY() + 0.01 * u, h.maxX() - 0.03 * u,
                       h.minY() + 0.12 * u);
        cairo_line_to(c, h.maxX(), h.maxY());
        cairo_close_path(c);
    };
    withShadow(c, 0, 0.025 * u, 0.07 * u, rgb(0, 0, 0, 0.9), [&](cairo_t* c) {
        hoodPath(c);
        setColor(c, rgb(0.04, 0.04, 0.045));
        cairo_fill(c);
    });
    cairo_save(c);
    hoodPath(c);
    cairo_clip(c);
    linearGradient(c, h, {rgb(0.12, 0.12, 0.13), rgb(0.05, 0.05, 0.055), rgb(0.025, 0.025, 0.03)}, true);
    cairo_restore(c);
    cairo_save(c);
    hoodPath(c);
    cairo_set_line_width(c, std::max(1.0, 0.006 * u));
    setColor(c, rgb(1, 1, 1, 0.09));
    cairo_stroke(c);
    cairo_restore(c);

    // Recesses: the cluster window and the two small displays below it.
    for (Rect r : {l.face, l.odometer, l.song}) {
        double radius = r.h > 0.3 * u ? 0.07 * u : 0.025 * u;
        addRoundedRect(c, r.inset(-0.012 * u, -0.012 * u), radius + 0.012 * u);
        setColor(c, rgb(0, 0, 0, 0.9));
        cairo_fill(c);
        addRoundedRect(c, r, radius);
        setColor(c, rgb(0.012, 0.02, 0.017));
        cairo_fill(c);
        // The fine grid of a fluorescent display, barely visible.
        cairo_save(c);
        addRoundedRect(c, r, radius);
        cairo_clip(c);
        double step = std::max(2.0, 0.012 * u);
        for (double x = r.x; x < r.maxX(); x += step) addRect(c, {x, r.y, 0.5, r.h});
        for (double y = r.y; y < r.maxY(); y += step) addRect(c, {r.x, y, r.w, 0.5});
        setColor(c, alpha(vfd, 0.02));
        cairo_fill(c);
        cairo_restore(c);
    }

    drawSegments(c, l, false);

    // Legends and frames, lit permanently.
    double blur = 0.02 * u;
    RGBA legend = alpha(vfd, 0.9);
    Rect f = l.face;
    glowText(c, "FLUX", {l.flux.midX() + 0.04 * u, l.flux.minY() - 0.055 * u}, 0.055 * u, legend, blur);
    glowText(c, "F", {l.flux.maxX() + 0.05 * u, l.flux.minY() + 0.015 * u}, 0.045 * u, legend, blur, true);
    glowText(c, "1/2", {l.flux.maxX() + 0.05 * u, l.flux.midY()}, 0.04 * u, legend, blur, true);
    glowText(c, "E", {l.flux.maxX() + 0.05 * u, l.flux.maxY() - 0.015 * u}, 0.045 * u, legend, blur, true);
    glowText(c, "REACTOR OUTPUT", {l.flux.midX() + 0.04 * u, f.y + 0.665 * u}, 0.035 * u, legend, blur);
    glowText(c, "SPEED", {l.speedBox.minX() - 0.05 * u, l.speedBox.maxY() - 0.04 * u}, 0.06 * u, legend, blur, false,
             true);
    withShadow(c, 0, 0, blur, alpha(vfd, 0.8), [&](cairo_t* c) {
        addRect(c, l.speedBox);
        setColor(c, legend);
        cairo_set_line_width(c, std::max(1.0, 0.007 * u));
        cairo_stroke(c);
        addDecimalPoint(c, l.speedDigits[1]);
        addDecimalPoint(c, l.odoDigits[5]);
        setColor(c, vfd);
        cairo_fill(c);
    });
    glowText(c, "c", {l.speedBox.maxX() - 0.09 * u, l.speedDigits[0].maxY() - 0.04 * u}, 0.08 * u, legend, blur);
    glowText(c, "WARP", {l.warp[1].midX(), l.speedBox.y + 0.18 * u}, 0.033 * u, legend, blur);
    const char* scale[6] = {"1", "2", "5", "10", "20", "50"};
    for (int j = 0; j < 6; j++) {
        glowText(c, scale[j], {l.scaleDots[j].x, l.scaleDots[j].y + 0.045 * u}, 0.035 * u, legend, blur);
    }
    glowText(c, "x100 r/min", {l.rpmDigits[1].maxX() + 0.025 * u, l.rpmDigits[1].maxY() - 0.02 * u}, 0.034 * u,
             legend, blur, true);
    glowText(c, "TACH", {l.tach.minX() - 0.04 * u, l.tach.maxY() - 0.03 * u}, 0.06 * u, legend, blur, false, true);
    double pitch = l.tach.w / tachColumns;
    auto tachX = [&](double v) { return l.tach.x + (v - 0.5) / 7 * (l.tach.w - pitch) + pitch / 2; };
    const char* revs[8] = {"0.5", "1", "2", "3", "4", "5", "6", "7"};
    for (int k = 0; k < 8; k++) {
        glowText(c, revs[k], {tachX(k == 0 ? 0.5 : k), l.tach.maxY() + 0.045 * u}, 0.04 * u, legend, blur);
    }
    glowText(c, "x1000 r/min", {l.tach.maxX() + 0.03 * u, l.tach.maxY() + 0.045 * u}, 0.032 * u, legend, blur, true);
    // Redline over the top of the rev range.
    Rect last;
    int dashes;
    tachColumn(l, tachColumns - 1, last, dashes);
    withShadow(c, 0, 0, blur, alpha(red, 0.8), [&](cairo_t* c) {
        addRect(c, {tachX(6.5), last.minY() - 0.03 * u, l.tach.maxX() - tachX(6.5), std::max(1.0, 0.008 * u)});
        setColor(c, alpha(red, 0.9));
        cairo_fill(c);
    });
    const char* barNames[3] = {"BASS", "MID", "TREB"};
    for (int k = 0; k < 3; k++) {
        Rect b = l.bars[k];
        withShadow(c, 0, 0, blur, alpha(vfd, 0.7), [&](cairo_t* c) {
            double m = 0.014 * u;
            cairo_move_to(c, b.minX() - m + 0.03 * u, b.minY() - m);
            cairo_line_to(c, b.minX() - m, b.minY() - m);
            cairo_line_to(c, b.minX() - m, b.maxY() + m);
            cairo_line_to(c, b.maxX() + m, b.maxY() + m);
            cairo_line_to(c, b.maxX() + m, b.minY() - m);
            cairo_line_to(c, b.maxX() + m - 0.03 * u, b.minY() - m);
            setColor(c, legend);
            cairo_set_line_width(c, std::max(1.0, 0.006 * u));
            cairo_stroke(c);
        });
        glowText(c, "10", {b.minX() - 0.03 * u, b.minY() + 0.01 * u}, 0.03 * u, legend, blur, false, true);
        glowText(c, "5", {b.minX() - 0.03 * u, b.midY()}, 0.03 * u, legend, blur, false, true);
        glowText(c, "0", {b.minX() - 0.03 * u, b.maxY() - 0.01 * u}, 0.03 * u, legend, blur, false, true);
        glowText(c, barNames[k], {b.midX(), f.y + 0.665 * u}, 0.04 * u, legend, blur);
    }
    glowText(c, "LY", {l.odometer.x + 0.55 * u, l.odometer.midY()}, 0.055 * u, legend, blur, true);
    glowText(c, "TRIP", {l.odometer.maxX() - 0.06 * u, l.odometer.midY()}, 0.035 * u, alpha(vfd, 0.6), blur, false,
             true);
    // A note symbol at the start of the song display.
    std::vector<uint8_t> note = dotmatrix::glyphColumns(dotmatrix::note);
    double p = l.dotPitch;
    for (size_t x = 0; x < note.size(); x++) {
        for (int r = 0; r < dotmatrix::rows; r++) {
            if (note[x] & (1 << r)) addRect(c, {l.song.x + 0.06 * u + x * p, l.dots.y + r * p, p * 0.78, p * 0.78});
        }
    }
    glowFill(c, legend, blur * 0.7);
    fillRect(c, {l.dots.x - 0.04 * u, l.song.y + 0.015 * u, 1, l.song.h - 0.03 * u}, alpha(vfd, 0.25));
}

// MARK: Caches

void Dashboard::makeCaches(const Layout& l, double scale) {
    int pw = int(std::ceil(l.width * scale)), ph = int(std::ceil(l.strip * scale));
    for (cairo_surface_t** s : {&back, &lit}) {
        if (*s) cairo_surface_destroy(*s);
        *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
        cairo_t* c = cairo_create(*s);
        cairo_scale(c, scale, scale);
        if (s == &back) drawStatic(c, l);
        else drawSegments(c, l, true);
        cairo_destroy(c);
    }
    // Lit digits for each of the three sizes (with room for their glow).
    const Rect cells[3] = {l.speedDigits[0], l.rpmDigits[0], l.odoDigits[0]};
    for (int s = 0; s < 3; s++) {
        double m = cells[s].h * 0.3;
        for (int d = 0; d < 12; d++) {
            cairo_surface_t*& img = digitImages[s][d];
            if (img) cairo_surface_destroy(img);
            img = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, int(std::ceil((cells[s].w + 2 * m) * scale)),
                                             int(std::ceil((cells[s].h + 2 * m) * scale)));
            cairo_t* c = cairo_create(img);
            cairo_scale(c, scale, scale);
            addSevenSegment(c, {m, m, cells[s].w, cells[s].h}, digitMasks[d]);
            glowFill(c, vfd, cells[s].h * 0.09);
            cairo_destroy(c);
        }
    }
    songRendered.clear();
    cacheW = l.width;
    cacheH = l.strip;
    cacheScale = scale;
}

/// The message as lit dots, with room around them for the glow.
void Dashboard::renderSong(const Layout& l, double scale) {
    const std::string& text = chaos > 0.02f ? alarmText : song;
    std::vector<uint8_t> cols = dotmatrix::columns(text);
    if (!cols.empty()) cols.pop_back();
    double p = l.dotPitch, m = 2 * p;
    if (songImage) cairo_surface_destroy(songImage);
    songImage = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, int(std::ceil((cols.size() * p + 2 * m) * scale)) + 1,
                                           int(std::ceil((7 * p + 2 * m) * scale)) + 1);
    cairo_t* c = cairo_create(songImage);
    cairo_scale(c, scale, scale);
    for (size_t x = 0; x < cols.size(); x++) {
        for (int r = 0; r < dotmatrix::rows; r++) {
            if (cols[x] & (1 << r)) addRect(c, {m + x * p, m + r * p, p * 0.78, p * 0.78});
        }
    }
    glowFill(c, vfd, p * 0.9);
    cairo_destroy(c);
    songColumns = int(cols.size());
    songRendered = text;
}

// MARK: Draw

void Dashboard::draw(cairo_t* c, double width, double height) {
    cairo_save(c);
    cairo_translate(c, 0, height - stripHeight(width, height));
    drawStrip(c, width, height);
    drawGlass(c, width, height);
    cairo_restore(c);
}

void Dashboard::drawStrip(cairo_t* c, double width, double height) {
    Layout l = layout(width, height);
    double scale = contextScale(c);
    if (!back || cacheW != width || cacheH != l.strip || cacheScale != scale) makeCaches(l, scale);
    cairo_save(c);
    cairo_scale(c, 1 / scale, 1 / scale);
    cairo_set_source_surface(c, back, 0, 0);
    cairo_paint(c);
    cairo_restore(c);
    drawDynamic(c, l);
}

void Dashboard::paintLit(cairo_t* c, Rect r, double a) {
    if (a <= 0.01) return;
    cairo_save(c);
    addRect(c, r);
    cairo_clip(c);
    cairo_scale(c, 1 / cacheScale, 1 / cacheScale);
    cairo_set_source_surface(c, lit, 0, 0);
    cairo_paint_with_alpha(c, std::min(a, 1.0));
    cairo_restore(c);
}

void Dashboard::drawDynamic(cairo_t* c, const Layout& l) {
    double u = l.u, g = 0.04 * u; // room for the glow around lit segments
    // Under tidal stress the whole display flickers.
    double flicker = chaos > 0.02f && frand(0, 1) < chaos * 0.3f ? 0.35 : 1;

    auto paintBar = [&](Rect bar, int count, float value, float peak) {
        double h = bar.h / count;
        int n = int(std::lround(clampd(value, 0, 1) * count));
        if (n > 0) paintLit(c, {bar.x - g, bar.maxY() - n * h, bar.w + 2 * g, n * h + g}, flicker);
        int p = int(std::lround(clampd(peak, 0, 1) * count));
        if (p > n) paintLit(c, {bar.x - g, bar.maxY() - p * h, bar.w + 2 * g, h}, flicker);
    };
    paintBar(l.flux, fluxSegments, flux.pos, 0);
    for (int k = 0; k < 3; k++) paintBar(l.bars[k], barSegments, bars[k].pos, peaks[k]);

    // Tachometer: every column up to the revs.
    double pitch = l.tach.w / tachColumns;
    int n = std::clamp(int(std::floor((rpm.pos - 0.5) / 7 * (tachColumns - 1))) + 1, 0, tachColumns);
    if (n > 0) paintLit(c, {l.tach.x - g, l.tach.y - g, n * pitch, l.tach.h + 2 * g}, flicker);

    int warp = lightSpeeds >= 40 ? 3 : lightSpeeds >= 20 ? 2 : lightSpeeds >= 10 ? 1 : 0;
    if (warp > 0) {
        paintLit(c, {l.warp[0].x - g, l.speedBox.y + 0.01 * u, l.warp[warp - 1].maxX() + 0.012 * u - l.warp[0].x + g,
                     0.14 * u},
                 flicker);
    }
    const float marks[6] = {1, 2, 5, 10, 20, 50};
    for (int j = 5; j >= 0; j--) {
        if (lightSpeeds >= marks[j]) {
            Pt d = l.scaleDots[j];
            paintLit(c, {d.x - 0.03 * u, d.y - 0.03 * u, 0.06 * u, 0.06 * u}, flicker);
            break;
        }
    }
    for (Rect r : {l.arrowLeft, l.arrowRight}) paintLit(c, r.inset(-g, -g), arrows * flicker);
    // (Lamps sit close together: only a little of the glow around each, so as not to light the next one.)
    for (int k = 0; k < 7; k++) {
        paintLit(c, (k < 6 ? l.lamps[k] : l.peak).inset(-0.012 * u, -g), lampGlow[k] * flicker);
    }

    // Seven-segment readouts.
    auto digit = [&](int size, Rect cell, int d) {
        if (chaos > 0.02f && frand(0, 1) < chaos * 0.3f) d = std::min(int(frand(0, 10)), 9);
        cairo_surface_t* img = digitImages[size][d];
        double m = cell.h * 0.3;
        cairo_save(c);
        cairo_translate(c, cell.x - m, cell.y - m);
        cairo_scale(c, 1 / cacheScale, 1 / cacheScale);
        cairo_set_source_surface(c, img, 0, 0);
        cairo_paint_with_alpha(c, flicker);
        cairo_restore(c);
    };
    int tenths = std::min(int(std::lround(lightSpeeds * 10)), 999);
    digit(0, l.speedDigits[0], tenths >= 100 ? tenths / 100 : blank);
    digit(0, l.speedDigits[1], tenths / 10 % 10);
    digit(0, l.speedDigits[2], tenths % 10);
    int hundreds = std::clamp(int(std::lround(rpm.pos * 10)), 0, 99);
    digit(1, l.rpmDigits[0], hundreds >= 10 ? hundreds / 10 : blank);
    digit(1, l.rpmDigits[1], hundreds % 10);
    long trip = long(distance * 10) % 10000000;
    for (int k = 6; k >= 0; k--, trip /= 10) digit(2, l.odoDigits[k], int(trip % 10));

    // The song, or the alarm while tidal forces scramble everything.
    if (chaos > 0.02f) {
        char text[48];
        std::snprintf(text, sizeof(text), "!! TIDAL STRESS %d%% !!", int(chaos * 100));
        alarmText = text;
    }
    const std::string& text = chaos > 0.02f ? alarmText : song;
    if (text != songRendered || !songImage) renderSong(l, cacheScale);
    double p = l.dotPitch, m = 2 * p;
    int visible = int(std::lround(l.dots.w / p));
    cairo_save(c);
    addRect(c, l.dots.inset(-p, -p));
    cairo_clip(c);
    auto paintSong = [&](double x) {
        cairo_save(c);
        cairo_translate(c, x - m, l.dots.y - m);
        cairo_scale(c, 1 / cacheScale, 1 / cacheScale);
        cairo_set_source_surface(c, songImage, 0, 0);
        cairo_paint_with_alpha(c, chaos > 0.02f ? (std::sin(time * 11) > -0.2 ? 1.0 : 0.15) : flicker);
        cairo_restore(c);
    };
    if (songColumns <= visible || chaos > 0.02f) {
        paintSong(l.dots.x + std::floor((visible - songColumns) / 2.0) * p);
    } else {
        // A marquee: steps one dot column at a time, then starts over after a gap.
        int loop = songColumns + 12;
        if (songScroll >= loop) {
            songScroll = 0;
            songHold = 1.5;
        }
        double x = l.dots.x - std::floor(songScroll) * p;
        paintSong(x);
        paintSong(x + loop * p);
    }
    cairo_restore(c);
}

// MARK: Glass

void Dashboard::drawGlass(cairo_t* c, double width, double height) {
    Layout l = layout(width, height);
    double u = l.u;
    LCG rng(41);
    for (Rect r : {l.face, l.odometer, l.song}) {
        bool big = r.h > 0.3 * u;
        double radius = big ? 0.07 * u : 0.025 * u;
        cairo_save(c);
        addRoundedRect(c, r, radius);
        cairo_clip(c);
        // Smoked, faintly green-tinted acrylic.
        fillRect(c, r, rgb(0.0, 0.03, 0.02, 0.14));
        // The hood's shadow across the top of the glass.
        linearGradient(c, {r.x, r.y, r.w, (big ? 0.2 : 0.05) * u}, {rgb(0, 0, 0, 0.6), rgb(0, 0, 0, 0)}, true);
        // Broad slanted reflections of the cabin, as on curved glass.
        auto sheen = [&](double x0, double w, double a) {
            double slant = r.h * 0.6;
            cairo_pattern_t* pat = cairo_pattern_create_linear(x0, 0, x0 + w, 0);
            cairo_pattern_add_color_stop_rgba(pat, 0, 1, 1, 1, 0);
            cairo_pattern_add_color_stop_rgba(pat, 0.5, 1, 1, 1, a);
            cairo_pattern_add_color_stop_rgba(pat, 1, 1, 1, 1, 0);
            cairo_move_to(c, x0 + slant, r.y);
            cairo_line_to(c, x0 + slant + w, r.y);
            cairo_line_to(c, x0 + w, r.maxY());
            cairo_line_to(c, x0, r.maxY());
            cairo_close_path(c);
            cairo_set_source(c, pat);
            cairo_fill(c);
            cairo_pattern_destroy(pat);
        };
        sheen(r.x + r.w * 0.08, r.w * 0.16, 0.075);
        sheen(r.x + r.w * 0.27, r.w * 0.04, 0.05);
        sheen(r.x + r.w * 0.62, r.w * 0.22, 0.04);
        // A gloss along the upper edge, and the lower edge of the glass catching the light.
        linearGradient(c, {r.x, r.y + r.h * 0.04, r.w, r.h * 0.3}, {rgb(1, 1, 1, 0.06), rgb(1, 1, 1, 0)}, true);
        linearGradient(c, {r.x, r.maxY() - r.h * 0.12, r.w, r.h * 0.12}, {rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.06)}, true);
        // Dust and fine scratches.
        int specks = int(r.w * r.h / (0.02 * u * u));
        for (int i = 0; i < specks; i++) {
            double x = r.x + rng.next() * r.w, y = r.y + rng.next() * r.h, s = 0.4 + rng.next() * 0.9;
            addEllipse(c, {x, y, s, s});
            setColor(c, rgb(1, 1, 1, 0.04 + 0.08 * rng.next()));
            cairo_fill(c);
        }
        for (int i = 0; i < (big ? 9 : 2); i++) {
            double x = r.x + rng.next() * r.w, y = r.y + rng.next() * r.h, len = (0.05 + rng.next() * 0.25) * u;
            double a = (rng.next() - 0.5) * 0.8;
            cairo_move_to(c, x, y);
            cairo_curve_to(c, x + len * 0.3, y + len * a * 0.2, x + len * 0.7, y + len * a * 0.5, x + len, y + len * a);
            setColor(c, rgb(1, 1, 1, 0.05 + 0.04 * rng.next()));
            cairo_set_line_width(c, 0.5);
            cairo_stroke(c);
        }
        // Smudges.
        for (int i = 0; i < (big ? 3 : 1); i++) {
            Pt p{r.x + rng.next() * r.w, r.y + rng.next() * r.h};
            radialGradient(c, p, (0.08 + rng.next() * 0.12) * u, {rgb(1, 1, 1, 0.025), rgb(1, 1, 1, 0)});
        }
        cairo_restore(c);
        // A thin bevel where the glass meets its frame.
        addRoundedRect(c, r.inset(0.5, 0.5), radius);
        setColor(c, rgb(1, 1, 1, 0.07));
        cairo_set_line_width(c, 1);
        cairo_stroke(c);
    }
}
