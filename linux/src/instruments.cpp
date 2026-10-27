#include "instruments.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

static double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }

static double contextScale(cairo_t* c) {
    cairo_matrix_t m;
    cairo_get_matrix(c, &m);
    return std::sqrt(std::fabs(m.xx * m.yy - m.xy * m.yx));
}

static void stroke(cairo_t* c, RGBA color, double width) {
    setColor(c, color);
    cairo_set_line_width(c, width);
    cairo_stroke(c);
}

static void line(cairo_t* c, Pt a, Pt b) {
    cairo_move_to(c, a.x, a.y);
    cairo_line_to(c, b.x, b.y);
}

InstrumentPanel::~InstrumentPanel() {
    if (cache) cairo_surface_destroy(cache);
}

// MARK: Update

void InstrumentPanel::update(const PanelInput& i, float rawDt) {
    float dt = std::min(rawDt, 1.0f / 30);
    time += dt;
    chaos = std::max(i.alarm - 0.1f, 0.0f) / 0.9f; // ignore the faint pull while it's still far off
    // Under tidal stress every instrument chases new random readings several times a second.
    if (chaos > 0.02f) {
        chaosClock -= dt;
        if (chaosClock <= 0) {
            chaosClock = frand(0.04f, 0.14f) / std::max(chaos, 0.3f);
            for (auto& t : chaosTargets) t = frand(-0.1f, 1.15f);
        }
    }
    auto mixed = [&](float normal, int k) { return normal + (chaosTargets[k] - normal) * chaos; };
    float hard = 1 + 2 * chaos; // stiffer springs: needles slam about
    gauges[0].step(mixed(i.bass, 0), dt, 140 * hard);
    gauges[1].step(mixed(i.mid, 1), dt, 140 * hard);
    gauges[2].step(mixed(i.treble, 2), dt, 140 * hard);
    velocity.step(mixed(std::min(i.speed / 1.2f, 1.0f), 3), dt, 40 * hard * hard, 9);
    const int n = int(i.bands.size());
    for (int k = 0; k < faderCount; k++) {
        int lo = k * n / faderCount, hi = std::max((k + 1) * n / faderCount, lo + 1);
        float v = 0;
        for (int b = lo; b < hi; b++) v += i.bands[b];
        v /= float(hi - lo);
        faders[k].step(mixed(v, 4 + k), dt, 260, 24);
    }
    levers[0].step(mixed(i.level, 16), dt, 50 * hard, 10);
    levers[1].step(mixed(i.beat, 17), dt, 220, 14);
    for (int k = 0; k < 3; k++) {
        knobSpin[k] += chaos * (chaosTargets[18 + k] - 0.5f) * 40 * dt;
        knobSpin[k] *= expf(-dt * (chaos > 0.02f ? 0 : 0.8f));
    }
    knobAngles[0] = i.hue * 2 * M_PI + knobSpin[0];
    knobAngles[1] = (i.centroid - 0.5f) * 2 * M_PI * 0.75 + knobSpin[1];
    knobAngles[2] = i.roll * 3 + knobSpin[2];
    beatLamp = std::max(beatLamp * expf(-dt * 7), i.beat);

    // Filament lamps glow up quickly and fade out slowly.
    std::array<float, 4> lit{beatLamp, source == Source::system ? 1.0f : 0.0f, source == Source::mic ? 1.0f : 0.0f,
                             source == Source::file ? 1.0f : 0.0f};
    if (chaos > 0.02f) {
        for (int k = 0; k < 4; k++) lit[k] = chaosTargets[20 + k] > 0.5f ? 1 : lit[k] * (1 - chaos);
    }
    for (int k = 0; k < 4; k++) {
        float rate = lit[k] > lampGlow[k] ? 14 : 4;
        lampGlow[k] += (lit[k] - lampGlow[k]) * (1 - expf(-dt * rate));
    }
    // Meter bulbs warm up at power-on, hum faintly, and stutter under tidal stress.
    float bulbTarget = (chaos > 0.02f && frand(0, 1) < chaos * 0.25f) ? 0.25f : 1;
    bulb += (bulbTarget - bulb) * (1 - expf(-dt * 3));

    // Nixie readout, 00.00 c ... 10.00 c: when a digit changes, the new cathode ignites and the old one
    // leaves an afterglow.
    float value = std::min(std::max(velocity.pos, 0.0f), 1.0f) * 10;
    char text[16];
    std::snprintf(text, sizeof(text), "%04d", int(std::floor(value * 100)));
    std::array<int, nixieCount> digits{};
    for (int k = 0; k < nixieCount; k++) digits[k] = text[k] >= '0' && text[k] <= '9' ? text[k] - '0' : 0;
    if (chaos > 0.02f) {
        for (int k = 0; k < nixieCount; k++) {
            if (chaosTargets[21 + k] < chaos) digits[k] = std::min(int(frand(0, 10)), 9);
        }
    }
    for (int k = 0; k < nixieCount; k++) {
        nixieAge[k] += dt;
        if (digits[k] != nixieDigits[k]) {
            nixiePrevious[k] = nixieDigits[k];
            nixieDigits[k] = digits[k];
            nixieAge[k] = 0;
        }
    }
    distance += double(i.speed * dt) * 2.5;
    bands = i.bands;
    bass = i.bass;
    centroid = i.centroid;
}

// MARK: Layout

double InstrumentPanel::panelHeight(double width, double height) {
    return std::max(std::min({height * 0.26, width / 10.9, 200.0}), 40.0);
}

double InstrumentPanel::stripHeight(double width, double height) { return panelHeight(width, height) * 1.15; }

InstrumentPanel::Layout InstrumentPanel::layout(double width, double height) const {
    double u = panelHeight(width, height);
    double shadow = u * 0.15;
    Layout l{u, shadow, u + shadow, shadow, {}, {}, {}, {}, {}, {}, {}};
    const double widths[7] = {0.8 * u, 2.34 * u, 1.5 * u, 1.68 * u, 1.4 * u, 1.46 * u, 0.6 * u};
    double gap = 0.12 * u;
    double total = gap * 6;
    for (double w : widths) total += w;
    double x = (width - total) / 2;
    double y = shadow + 0.13 * u;
    double h = 0.74 * u;
    Rect rects[7];
    for (int i = 0; i < 7; i++) {
        rects[i] = {x, y, widths[i], h};
        x += widths[i] + gap;
    }
    l.levers = rects[0];
    l.gauges = rects[1];
    l.dial = rects[2];
    l.faders = rects[3];
    l.scope = rects[4];
    l.knobs = rects[5];
    l.lamps = rects[6];
    return l;
}

Rect InstrumentPanel::content(Rect plate, double u) {
    return {plate.minX() + 0.06 * u, plate.minY() + 0.13 * u, plate.w - 0.12 * u, plate.h - 0.17 * u};
}

// MARK: Draw

void InstrumentPanel::draw(cairo_t* c, double width, double height) {
    Layout l = layout(width, height);
    cairo_save(c);
    cairo_translate(c, 0, height - l.stripHeight);
    drawStrip(c, width, height);
    cairo_restore(c);
    if (alarmActive()) drawAlarm(c, width, height);
}

void InstrumentPanel::drawStrip(cairo_t* c, double width, double height) {
    Layout l = layout(width, height);
    double scale = contextScale(c);
    if (!cache || cacheW != width || cacheH != l.stripHeight || cacheScale != scale) {
        if (cache) cairo_surface_destroy(cache);
        cache = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, int(std::ceil(width * scale)),
                                           int(std::ceil(l.stripHeight * scale)));
        cairo_t* lc = cairo_create(cache);
        cairo_scale(lc, scale, scale);
        drawStatic(lc, l, width);
        cairo_destroy(lc);
        cacheW = width;
        cacheH = l.stripHeight;
        cacheScale = scale;
    }
    cairo_save(c);
    cairo_scale(c, 1 / scale, 1 / scale);
    cairo_set_source_surface(c, cache, 0, 0);
    cairo_paint(c);
    cairo_restore(c);
    drawDynamic(c, l);
}

Rect InstrumentPanel::alarmRect(double width, double height) {
    double w = std::min(width * 0.62, 760.0), h = std::max(44.0, std::min(height * 0.075, 70.0));
    return {(width - w) / 2, height * 0.09, w, h};
}

/// A hazard triangle with an exclamation mark (the ⚠ sign, which the label font doesn't have).
static void warningSign(cairo_t* c, Pt center, double size, RGBA color) {
    double h = size * 0.8, w = size * 0.92;
    cairo_move_to(c, center.x, center.y - h / 2);
    cairo_line_to(c, center.x + w / 2, center.y + h / 2);
    cairo_line_to(c, center.x - w / 2, center.y + h / 2);
    cairo_close_path(c);
    cairo_set_line_join(c, CAIRO_LINE_JOIN_ROUND);
    stroke(c, color, size * 0.09);
    cairo_set_line_join(c, CAIRO_LINE_JOIN_MITER);
    drawText(c, "!", {center.x, center.y + h * 0.1}, size * 0.62, color, false, 0);
}

/// Flashing master alarm across the top of the view while tidal forces grip the ship.
void InstrumentPanel::drawAlarm(cairo_t* c, double width, double height) {
    bool flash = std::sin(time * 11) > -0.1;
    Rect r = alarmRect(width, height);
    double h = r.h;
    double a = std::min(chaos * 2.0, 1.0);
    withShadow(c, 0, 0, flash ? 30 : 8, rgb(1, 0.1, 0.05, (flash ? 0.9 : 0.3) * a), [&](cairo_t* c) {
        addRoundedRect(c, r, 6);
        setColor(c, flash ? rgb(0.55, 0.02, 0.02, 0.85 * a) : rgb(0.12, 0.01, 0.01, 0.75 * a));
        cairo_fill(c);
    });
    // Hazard stripes along the top and bottom edges.
    cairo_save(c);
    addRoundedRect(c, r, 6);
    cairo_clip(c);
    setColor(c, rgb(1, 0.8, 0.1, 0.8 * a));
    for (double band : {r.minY(), r.maxY() - h * 0.12}) {
        double x = r.minX() - h;
        while (x < r.maxX()) {
            cairo_move_to(c, x, band + h * 0.12);
            cairo_line_to(c, x + h * 0.12, band);
            cairo_line_to(c, x + h * 0.24, band);
            cairo_line_to(c, x + h * 0.12, band + h * 0.12);
            cairo_fill(c);
            x += h * 0.24;
        }
    }
    cairo_restore(c);
    addRoundedRect(c, r, 6);
    stroke(c, rgb(1, 0.25, 0.2, a), 2);
    RGBA color{1, flash ? 0.92 : 0.35, flash ? 0.85 : 0.3, a};
    char label[96];
    std::snprintf(label, sizeof(label), "GRAVITATIONAL ANOMALY  —  TIDAL STRESS %d%%", int(chaos * 100));
    double size = h * 0.42;
    drawText(c, label, {r.midX(), r.midY()}, size, color);
    double half = textWidth(c, label, size) / 2 + size * 1.1;
    warningSign(c, {r.midX() - half, r.midY()}, size, color);
    warningSign(c, {r.midX() + half, r.midY()}, size, color);
}

// MARK: Static parts (cached)

void InstrumentPanel::drawStatic(cairo_t* c, const Layout& l, double width) {
    double u = l.u;
    Rect panel{0, l.panelTop, width, u};

    // Shade cast onto the space view above the console.
    linearGradient(c, {0, 0, width, l.shadow}, {rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.55)}, true);

    // Painted gunmetal with brushed grain.
    linearGradient(c, panel, {rgb(0.2, 0.215, 0.2), rgb(0.105, 0.115, 0.105)}, true);
    LCG rng(7);
    double y = panel.minY() + 1;
    while (y < panel.maxY()) {
        line(c, {0, y}, {width, y});
        stroke(c, rgb(1, 1, 1, 0.012 + 0.03 * rng.next()), 1);
        y += 1 + 2 * rng.next();
    }
    // Chrome trim along the top edge.
    fillRect(c, {0, panel.minY(), width, std::max(1.5, u * 0.012)}, rgb(0.55, 0.57, 0.55));
    fillRect(c, {0, panel.minY() + std::max(1.5, u * 0.012), width, 1}, rgb(0, 0, 0, 0.6));
    // Hazard stripes at both ends, where the console meets the hull.
    for (double side : {0.0, width - 0.18 * u}) {
        Rect r{side, panel.minY() + 0.06 * u, 0.18 * u, u * 0.88};
        cairo_save(c);
        clipRect(c, r);
        fillRect(c, r, rgb(0.1, 0.1, 0.09));
        setColor(c, rgb(0.78, 0.6, 0.12, 0.85));
        double sx = r.minX() - r.h;
        while (sx < r.maxX()) {
            cairo_move_to(c, sx, r.maxY());
            cairo_line_to(c, sx + 0.06 * u, r.maxY());
            cairo_line_to(c, sx + 0.06 * u + r.h, r.minY());
            cairo_line_to(c, sx + r.h, r.minY());
            cairo_fill(c);
            sx += 0.12 * u;
        }
        cairo_restore(c);
    }

    plate(c, l.levers, u, "THROTTLE");
    plate(c, l.gauges, u, "SPECTRAL LOAD");
    plate(c, l.dial, u, "VELOCITY  ·  c");
    plate(c, l.faders, u, "BAND EQUALIZER");
    plate(c, l.scope, u, "SCOPE");
    plate(c, l.knobs, u, "TRIM");
    plate(c, l.lamps, u, "STATUS");

    staticLevers(c, l);
    staticGauges(c, l);
    staticNixies(c, l);
    staticFaders(c, l);
    staticScope(c, l);
    staticKnobs(c, l);
    staticLamps(c, l);

    // A dim cabin: darken all the metalwork so only what's lit really glows.
    fillRect(c, panel, rgb(0, 0, 0, 0.42));
}

void InstrumentPanel::plate(cairo_t* c, Rect r, double u, const char* title) {
    double radius = 0.035 * u;
    withShadow(c, 0, 0.012 * u, 0.03 * u, rgb(0, 0, 0, 0.7), [&](cairo_t* c) {
        addRoundedRect(c, r, radius);
        setColor(c, rgb(0.15, 0.16, 0.15));
        cairo_fill(c);
    });
    cairo_save(c);
    addRoundedRect(c, r, radius);
    cairo_clip(c);
    linearGradient(c, r, {rgb(0.19, 0.2, 0.19), rgb(0.125, 0.135, 0.125)}, true);
    cairo_restore(c);
    addRoundedRect(c, r, radius);
    stroke(c, rgb(0, 0, 0, 0.7), 1);
    line(c, {r.minX() + 0.04 * u, r.maxY() - 0.5}, {r.maxX() - 0.04 * u, r.maxY() - 0.5});
    stroke(c, rgb(1, 1, 1, 0.07), 1);
    double inset = 0.04 * u;
    for (Pt p : {Pt{r.minX() + inset, r.minY() + inset}, Pt{r.maxX() - inset, r.minY() + inset},
                 Pt{r.minX() + inset, r.maxY() - inset}, Pt{r.maxX() - inset, r.maxY() - inset}}) {
        screw(c, p, 0.02 * u);
    }
    if (title) drawText(c, title, {r.midX(), r.minY() + 0.068 * u}, 0.06 * u, paint(0.75));
}

Rect InstrumentPanel::leverSlot(Rect r, int k, double u) const {
    double cx = r.minX() + r.w * (k + 0.5) / 2;
    return {cx - 0.022 * u, r.minY() + 0.05 * u, 0.044 * u, r.h - 0.17 * u};
}

void InstrumentPanel::staticLevers(cairo_t* c, const Layout& l) {
    double u = l.u;
    Rect r = content(l.levers, u);
    const char* names[2] = {"THRUST", "PULSE"};
    for (int k = 0; k < 2; k++) {
        Rect slot = leverSlot(r, k, u);
        addRoundedRect(c, slot, slot.w / 2);
        setColor(c, rgb(0.03, 0.03, 0.03));
        cairo_fill(c);
        addRoundedRect(c, slot, slot.w / 2);
        stroke(c, rgb(1, 1, 1, 0.12), 1);
        for (int i = 0; i <= 4; i++) {
            double y = slot.maxY() - slot.h * i / 4;
            line(c, {slot.maxX() + 0.015 * u, y}, {slot.maxX() + (i % 2 == 0 ? 0.05 : 0.03) * u, y});
            stroke(c, paint(0.5), 1);
        }
        drawText(c, names[k], {slot.midX(), r.maxY() - 0.035 * u}, 0.05 * u, paint(0.8));
    }
}

Rect InstrumentPanel::gaugeFace(const Layout& l, int k) const {
    double u = l.u;
    Rect r = content(l.gauges, u);
    double w = (r.w - 0.08 * u * 2) / 3;
    return {r.minX() + k * (w + 0.08 * u), r.minY() + 0.01 * u, w, r.h - 0.02 * u};
}

std::pair<Pt, double> InstrumentPanel::gaugeGeometry(Rect face) const {
    return {{face.midX(), face.maxY() + face.h * 0.2}, face.h * 0.95};
}

void InstrumentPanel::staticGauges(cairo_t* c, const Layout& l) {
    double u = l.u;
    const char* names[3] = {"BASS", "MID", "TREBLE"};
    const char* scale[5] = {"0", "25", "50", "75", "100"};
    RGBA ink = rgb(0.15, 0.12, 0.1);
    for (int k = 0; k < 3; k++) {
        Rect outer = gaugeFace(l, k);
        bezelRect(c, outer, u);
        Rect face = outer.inset(0.025 * u, 0.025 * u);
        cairo_save(c);
        addRoundedRect(c, face, 0.02 * u);
        cairo_clip(c);
        linearGradient(c, face, {rgb(0.42, 0.39, 0.32), rgb(0.5, 0.45, 0.35)}, true);
        auto [pivot, R] = gaugeGeometry(face);
        // Red overload zone.
        cairo_new_sub_path(c);
        cairo_arc(c, pivot.x, pivot.y, R * 0.84, gaugeAngle(0.75) - M_PI / 2, gaugeAngle(1) - M_PI / 2);
        stroke(c, rgb(0.75, 0.12, 0.08), 0.035 * u);
        cairo_new_sub_path(c);
        cairo_arc(c, pivot.x, pivot.y, R * 0.8, gaugeAngle(0) - M_PI / 2, gaugeAngle(1) - M_PI / 2);
        stroke(c, rgb(0.12, 0.1, 0.08), std::max(1.0, 0.006 * u));
        for (int i = 0; i <= 20; i++) {
            double v = i / 20.0;
            double a = gaugeAngle(v);
            bool major = i % 5 == 0;
            line(c, polar(pivot, R * 0.8, a), polar(pivot, R * (major ? 0.9 : 0.86), a));
            stroke(c, rgb(0.12, 0.1, 0.08), major ? std::max(1.2, 0.01 * u) : std::max(0.8, 0.005 * u));
            if (major) drawText(c, scale[i / 5], polar(pivot, R * 0.98, a), 0.05 * u, ink);
        }
        drawText(c, names[k], {face.midX(), face.maxY() - face.h * 0.2}, 0.065 * u, rgb(0.15, 0.12, 0.1, 0.9));
        drawText(c, "%", {face.midX(), face.maxY() - face.h * 0.42}, 0.045 * u, rgb(0.15, 0.12, 0.1, 0.6));
        cairo_restore(c);
    }
}

// MARK: Nixie tubes (velocity readout) and distance counter

static const RGBA neon{1.0, 0.4, 0.1, 1};

/// The tube row (upper part of the plate) and the drum counter row beneath it.
std::pair<Rect, Rect> InstrumentPanel::nixieRows(const Layout& l) const {
    Rect r = content(l.dial, l.u);
    double counterH = r.h * 0.27;
    return {{r.minX(), r.minY(), r.w, r.h - counterH - 0.02 * l.u}, {r.minX(), r.maxY() - counterH, r.w, counterH}};
}

/// Tall, narrow cylinders like real IN-14 style tubes, centred in the row.
std::vector<Rect> InstrumentPanel::nixieTubes(const Layout& l) const {
    Rect row = nixieRows(l).first;
    double gap = 0.035 * l.u;
    double w = std::min(row.h * 0.6, (row.w - gap * (nixieCount - 1)) / nixieCount);
    double total = w * nixieCount + gap * (nixieCount - 1);
    std::vector<Rect> out;
    for (int k = 0; k < nixieCount; k++) out.push_back({row.midX() - total / 2 + k * (w + gap), row.minY(), w, row.h});
    return out;
}

/// Glass envelope (above the black base).
Rect InstrumentPanel::nixieGlass(Rect tube) const {
    return {tube.minX(), tube.minY() + tube.w * 0.12, tube.w, tube.h * 0.9 - tube.w * 0.12};
}

void InstrumentPanel::addNixieGlassPath(cairo_t* c, Rect g) const {
    double dome = g.w * 0.42;
    cairo_move_to(c, g.minX(), g.maxY());
    cairo_line_to(c, g.minX(), g.minY() + dome);
    cairo_curve_to(c, g.minX(), g.minY() + dome * 0.2, g.minX() + g.w * 0.2, g.minY(), g.midX(), g.minY());
    cairo_curve_to(c, g.maxX() - g.w * 0.2, g.minY(), g.maxX(), g.minY() + dome * 0.2, g.maxX(), g.minY() + dome);
    cairo_line_to(c, g.maxX(), g.maxY());
    cairo_close_path(c);
}

/// Where the numerals sit inside a tube.
Rect InstrumentPanel::digitBox(Rect g) const {
    double h = g.h * 0.58;
    double w = std::min(h * 0.58, g.w * 0.72);
    return {g.midX() - w / 2, g.minY() + g.h * 0.24, w, h};
}

/// A Nixie numeral as bent wire: strokes in a unit box (x right, y down), then scaled into `box`.
void InstrumentPanel::addNixieDigit(cairo_t* c, int d, Rect box) const {
    auto X = [&](double x) { return box.minX() + x * box.w; };
    auto Y = [&](double y) { return box.minY() + y * box.h; };
    auto move = [&](double x, double y) { cairo_move_to(c, X(x), Y(y)); };
    auto to = [&](double x, double y) { cairo_line_to(c, X(x), Y(y)); };
    auto curve = [&](double x, double y, double x1, double y1, double x2, double y2) {
        cairo_curve_to(c, X(x1), Y(y1), X(x2), Y(y2), X(x), Y(y));
    };
    auto oval = [&](double x, double y, double w, double h) {
        addEllipse(c, {X(x), Y(y), w * box.w, h * box.h});
    };
    switch (d) {
    case 0: oval(0.06, 0.02, 0.88, 0.96); break;
    case 1:
        move(0.55, 0.98); to(0.55, 0.02); to(0.28, 0.2);
        break;
    case 2:
        move(0.1, 0.24);
        curve(0.5, 0.02, 0.1, 0.1, 0.28, 0.02);
        curve(0.9, 0.27, 0.74, 0.02, 0.9, 0.12);
        curve(0.08, 0.98, 0.9, 0.5, 0.3, 0.7);
        to(0.94, 0.98);
        break;
    case 3:
        move(0.08, 0.15);
        curve(0.5, 0.02, 0.2, 0.05, 0.34, 0.02);
        curve(0.86, 0.25, 0.74, 0.02, 0.86, 0.12);
        curve(0.4, 0.47, 0.86, 0.4, 0.62, 0.47);
        curve(0.92, 0.72, 0.7, 0.47, 0.92, 0.56);
        curve(0.5, 0.98, 0.92, 0.88, 0.74, 0.98);
        curve(0.06, 0.84, 0.3, 0.98, 0.14, 0.93);
        break;
    case 4:
        move(0.72, 0.98); to(0.72, 0.02); to(0.05, 0.7);
        to(0.95, 0.7);
        break;
    case 5:
        move(0.88, 0.02); to(0.2, 0.02); to(0.13, 0.46);
        curve(0.52, 0.36, 0.26, 0.39, 0.38, 0.36);
        curve(0.92, 0.67, 0.78, 0.36, 0.92, 0.5);
        curve(0.5, 0.98, 0.92, 0.86, 0.74, 0.98);
        curve(0.06, 0.84, 0.3, 0.98, 0.14, 0.93);
        break;
    case 6:
        move(0.82, 0.06);
        curve(0.1, 0.66, 0.4, 0.12, 0.1, 0.38);
        oval(0.1, 0.4, 0.82, 0.58);
        break;
    case 7:
        move(0.06, 0.02); to(0.94, 0.02); to(0.36, 0.98);
        break;
    case 8:
        oval(0.17, 0.02, 0.66, 0.43); oval(0.08, 0.45, 0.84, 0.53);
        break;
    default: // 9
        oval(0.08, 0.02, 0.82, 0.58);
        move(0.9, 0.34);
        curve(0.18, 0.94, 0.9, 0.62, 0.6, 0.88);
        break;
    }
}

void InstrumentPanel::nixieMesh(cairo_t* c, Rect g, RGBA color) const {
    double cell = std::max(2.5, g.w * 0.085);
    double top = g.minY() + g.h * 0.18, bottom = g.maxY() - g.h * 0.1;
    int row = 0;
    double y = top;
    while (y < bottom) {
        double x = g.minX() + (row % 2 == 0 ? 0 : cell * 0.5);
        while (x < g.maxX()) {
            for (int k = 0; k < 6; k++) {
                double a = k / 6.0 * 2 * M_PI + M_PI / 6;
                double qx = x + std::cos(a) * cell * 0.5, qy = y + std::sin(a) * cell * 0.5;
                if (k == 0) cairo_move_to(c, qx, qy);
                else cairo_line_to(c, qx, qy);
            }
            cairo_close_path(c);
            x += cell;
        }
        y += cell * 0.87;
        row += 1;
    }
    stroke(c, color, 0.5);
}

void InstrumentPanel::staticNixies(cairo_t* c, const Layout& l) {
    double u = l.u;
    for (Rect tube : nixieTubes(l)) {
        Rect g = nixieGlass(tube);
        // Black phenolic base with leads running down into the panel.
        Rect base{tube.minX() + tube.w * 0.04, g.maxY() - 0.004 * u, tube.w * 0.92, tube.maxY() - g.maxY()};
        for (int k = 0; k < 4; k++) {
            double x = base.minX() + base.w * (0.2 + 0.2 * k);
            line(c, {x, base.maxY() - 1}, {x, base.maxY() + 0.02 * u});
        }
        stroke(c, rgb(0.55, 0.5, 0.42), std::max(0.8, 0.004 * u));
        addRoundedRect(c, base, base.h * 0.3);
        setColor(c, rgb(0.06, 0.05, 0.05));
        cairo_fill(c);
        linearGradient(c, base, {rgb(1, 1, 1, 0.12), rgb(1, 1, 1, 0)}, true);

        withShadow(c, 0, 0.01 * u, 0.025 * u, rgb(0, 0, 0, 0.8), [&](cairo_t* c) {
            addNixieGlassPath(c, g);
            setColor(c, rgb(0.045, 0.035, 0.03));
            cairo_fill(c);
        });

        cairo_save(c);
        addNixieGlassPath(c, g);
        cairo_clip(c);
        // Mirror-like getter flash in the dome.
        linearGradient(c, {g.minX(), g.minY(), g.w, g.w * 0.5}, {rgb(0.42, 0.42, 0.45, 0.8), rgb(0.2, 0.2, 0.22, 0)},
                       true);
        // Back half of the anode cage.
        nixieMesh(c, g, rgb(0.45, 0.4, 0.34, 0.22));
        // Support rods and the two mica spacers.
        Rect box = digitBox(g);
        for (double x : {g.minX() + g.w * 0.1, g.maxX() - g.w * 0.1}) {
            line(c, {x, box.minY() - g.h * 0.08}, {x, g.maxY()});
        }
        stroke(c, rgb(0.5, 0.48, 0.45, 0.55), std::max(0.7, 0.004 * u));
        for (double y : {box.minY() - g.h * 0.08, box.maxY() + g.h * 0.07}) {
            Rect mica{g.minX() + g.w * 0.04, y - g.w * 0.06, g.w * 0.92, g.w * 0.12};
            addEllipse(c, mica);
            setColor(c, rgb(0.82, 0.76, 0.64, 0.28));
            cairo_fill(c);
            addEllipse(c, mica);
            stroke(c, rgb(0.9, 0.85, 0.75, 0.35), 0.6);
        }
        // The stack of unlit cathodes: every digit's wire, each a little deeper in the tube.
        cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
        cairo_set_line_join(c, CAIRO_LINE_JOIN_ROUND);
        const int order[10] = {1, 7, 4, 2, 5, 3, 9, 6, 0, 8};
        for (int depth = 0; depth < 10; depth++) {
            double k = depth * 0.012;
            Rect b = box.inset(box.w * k, box.h * k);
            addNixieDigit(c, order[depth], b);
            stroke(c, rgb(0.55, 0.5, 0.46, 0.22), std::max(0.6, box.h * 0.022));
        }
        cairo_restore(c);
        addNixieGlassPath(c, g);
        stroke(c, rgb(0.7, 0.66, 0.6, 0.45), 1);
        // Tip-off nub on top of the dome.
        Rect nub{g.midX() - g.w * 0.06, g.minY() - g.w * 0.1, g.w * 0.12, g.w * 0.13};
        addRoundedRect(c, nub, nub.w / 2);
        setColor(c, rgb(0.35, 0.33, 0.3, 0.8));
        cairo_fill(c);
    }

    // Drum counter window for the distance travelled.
    Rect row = nixieRows(l).second;
    drawText(c, "DIST", {row.minX() + 0.05 * u, row.midY() - row.h * 0.18}, row.h * 0.38, paint(0.75));
    drawText(c, "AU", {row.minX() + 0.05 * u, row.midY() + row.h * 0.24}, row.h * 0.32, paint(0.55));
    Rect win = counterWindow(l);
    bezelRect(c, win.inset(-0.012 * u, -0.012 * u), u);
    fillRect(c, win, rgb(0.02, 0.02, 0.02));
}

/// The counter window spans the whole row beneath the tubes (after the DIST/AU label).
Rect InstrumentPanel::counterWindow(const Layout& l) const {
    Rect row = nixieRows(l).second;
    double x = row.minX() + 0.12 * l.u;
    return {x, row.minY() + row.h * 0.04, row.maxX() - x, row.h * 0.92};
}

/// As many drums as fit at a natural drum shape.
int InstrumentPanel::counterDigits(Rect win) const {
    return std::min(std::max(int(win.w / (win.h * 0.66)), 6), 12);
}

std::pair<Rect, double> InstrumentPanel::faderColumns(const Layout& l) const {
    Rect r = content(l.faders, l.u);
    return {r, r.w / faderCount};
}

InstrumentPanel::Track InstrumentPanel::faderTrack(const Layout& l, int k) const {
    auto [r, cw] = faderColumns(l);
    return {r.minX() + cw * (k + 0.5), r.minY() + 0.04 * l.u, r.maxY() - 0.11 * l.u};
}

void InstrumentPanel::staticFaders(cairo_t* c, const Layout& l) {
    double u = l.u;
    auto [r, cw] = faderColumns(l);
    for (int k = 0; k < faderCount; k++) {
        Track t = faderTrack(l, k);
        for (int i = 0; i <= 8; i++) {
            double y = t.bottom - (t.bottom - t.top) * i / 8;
            line(c, {t.x - cw * 0.42, y}, {t.x - cw * 0.2, y});
            stroke(c, paint(i % 4 == 0 ? 0.55 : 0.3), 1);
        }
        Rect slot{t.x - 0.009 * u, t.top - 0.01 * u, 0.018 * u, t.bottom - t.top + 0.02 * u};
        addRoundedRect(c, slot, slot.w / 2);
        setColor(c, rgb(0.02, 0.02, 0.02));
        cairo_fill(c);
        float f = AudioAnalyzer::bandFrequency((float(k) + 0.5f) * float(AudioAnalyzer::bandCount) / float(faderCount));
        char label[16];
        if (f < 1000) std::snprintf(label, sizeof(label), "%d", int(std::lround(f)));
        else if (f < 10000) std::snprintf(label, sizeof(label), "%.1fK", f / 1000);
        else std::snprintf(label, sizeof(label), "%.0fK", f / 1000);
        drawText(c, label, {t.x, r.maxY() - 0.04 * u}, std::min(0.045 * u, cw * 0.5), paint(0.7));
    }
}

Rect InstrumentPanel::scopeScreen(const Layout& l) const {
    return content(l.scope, l.u).inset(0.01 * l.u, 0.005 * l.u);
}

void InstrumentPanel::staticScope(cairo_t* c, const Layout& l) {
    double u = l.u;
    Rect s = scopeScreen(l);
    bezelRect(c, s.inset(-0.025 * u, -0.025 * u), u);
    cairo_save(c);
    addRoundedRect(c, s, 0.05 * u);
    cairo_clip(c);
    radialGradient(c, {s.midX(), s.midY()}, s.w * 0.65, {rgb(0.04, 0.13, 0.07), rgb(0.01, 0.035, 0.02)});
    for (int i = 1; i < 8; i++) {
        double x = s.minX() + s.w * i / 8;
        line(c, {x, s.minY()}, {x, s.maxY()});
    }
    for (int i = 1; i < 4; i++) {
        double y = s.minY() + s.h * i / 4;
        line(c, {s.minX(), y}, {s.maxX(), y});
    }
    stroke(c, rgb(0.35, 1, 0.55, 0.12), 1);
    cairo_restore(c);
}

std::pair<Pt, double> InstrumentPanel::knobGeometry(const Layout& l, int k) const {
    Rect r = content(l.knobs, l.u);
    double cw = r.w / 3;
    double radius = std::min(cw * 0.3, 0.12 * l.u);
    return {{r.minX() + cw * (k + 0.5), r.minY() + r.h * 0.42}, radius};
}

void InstrumentPanel::staticKnobs(cairo_t* c, const Layout& l) {
    double u = l.u;
    const char* names[3] = {"HUE", "TONE", "ROLL"};
    for (int k = 0; k < 3; k++) {
        auto [center, kr] = knobGeometry(l, k);
        for (int i = 0; i <= 10; i++) {
            double a = (-135 + 27 * i) * M_PI / 180;
            line(c, polar(center, kr * 1.22, a), polar(center, kr * (i % 5 == 0 ? 1.45 : 1.36), a));
            stroke(c, paint(0.6), i % 5 == 0 ? 1.6 : 1);
        }
        // Knurled body with a shadow.
        withShadow(c, 0, 0.015 * u, 0.03 * u, rgb(0, 0, 0, 0.8), [&](cairo_t* c) {
            addEllipse(c, {center.x - kr, center.y - kr, 2 * kr, 2 * kr});
            setColor(c, rgb(0.08, 0.08, 0.08));
            cairo_fill(c);
        });
        for (int i = 0; i < 40; i++) {
            double a = i / 40.0 * 2 * M_PI;
            line(c, polar(center, kr * 0.86, a), polar(center, kr, a));
        }
        stroke(c, rgb(0.3, 0.3, 0.3), 1);
        double cap = kr * 0.78;
        Rect capRect{center.x - cap, center.y - cap, 2 * cap, 2 * cap};
        cairo_save(c);
        addEllipse(c, capRect);
        cairo_clip(c);
        linearGradient(c, capRect, {rgb(0.42, 0.42, 0.41), rgb(0.14, 0.14, 0.14)}, true);
        cairo_restore(c);
        drawText(c, names[k], {center.x, center.y + kr * 1.45 + 0.06 * u}, 0.05 * u, paint(0.8));
    }
}

std::vector<InstrumentPanel::Lamp> InstrumentPanel::lampGeometry(const Layout& l) const {
    double u = l.u;
    Rect r = content(l.lamps, u);
    std::vector<Lamp> out{{{r.minX() + 0.08 * u, r.minY() + 0.09 * u}, 0.055 * u, "BEAT"}};
    double rowTop = r.minY() + 0.25 * u;
    const char* names[3] = {"SYS", "MIC", "FILE"};
    for (int i = 0; i < 3; i++) out.push_back({{r.minX() + 0.08 * u, rowTop + i * 0.11 * u}, 0.03 * u, names[i]});
    return out;
}

void InstrumentPanel::staticLamps(cairo_t* c, const Layout& l) {
    double u = l.u;
    for (const Lamp& lamp : lampGeometry(l)) {
        double br = lamp.radius * 1.35;
        Rect ring{lamp.center.x - br, lamp.center.y - br, 2 * br, 2 * br};
        addEllipse(c, ring);
        setColor(c, rgb(0.3, 0.31, 0.3));
        cairo_fill(c);
        addEllipse(c, ring);
        stroke(c, rgb(0, 0, 0, 0.8), 1);
        drawText(c, lamp.name, {lamp.center.x + br + 0.025 * u, lamp.center.y}, 0.05 * u, paint(0.8), true);
    }
}

// MARK: Moving parts (every frame)

void InstrumentPanel::drawDynamic(cairo_t* c, const Layout& l) {
    double u = l.u;

    // Throttle levers.
    for (int k = 0; k < 2; k++) {
        Rect slot = leverSlot(content(l.levers, u), k, u);
        double v = clampd(levers[k].pos, 0, 1.05);
        double y = slot.maxY() - slot.w / 2 - v * (slot.h - slot.w);
        Rect grip{slot.midX() - 0.11 * u, y - 0.035 * u, 0.22 * u, 0.07 * u};
        withShadow(c, 0, 0.02 * u, 0.035 * u, rgb(0, 0, 0, 0.8), [&](cairo_t* c) {
            fillRect(c, {slot.midX() - 0.012 * u, y - 0.02 * u, 0.024 * u, 0.04 * u}, rgb(0.25, 0.25, 0.25));
            addRoundedRect(c, grip, 0.03 * u);
            setColor(c, rgb(0.55, 0.08, 0.06));
            cairo_fill(c);
        });
        cairo_save(c);
        addRoundedRect(c, grip, 0.03 * u);
        cairo_clip(c);
        linearGradient(c, grip, {rgb(0.85, 0.22, 0.15), rgb(0.4, 0.05, 0.04)}, true);
        double gx = grip.minX() + 0.03 * u;
        while (gx < grip.maxX() - 0.02 * u) {
            line(c, {gx, grip.minY()}, {gx, grip.maxY()});
            gx += 0.025 * u;
        }
        stroke(c, rgb(0, 0, 0, 0.35), 1);
        cairo_restore(c);
    }

    // VU gauges.
    for (int k = 0; k < 3; k++) {
        Rect face = gaugeFace(l, k).inset(0.025 * u, 0.025 * u);
        auto [pivot, R] = gaugeGeometry(face);
        cairo_save(c);
        addRoundedRect(c, face, 0.02 * u);
        cairo_clip(c);
        // Light from one small warm bulb behind the bottom-centre of the face.
        double b = bulb * frand(0.97f, 1.0f);
        Pt bulbAt{face.midX(), face.maxY() - face.h * 0.04};
        cairo_save(c);
        cairo_set_operator(c, CAIRO_OPERATOR_SCREEN);
        radialGradient(c, bulbAt, face.h * 1.15,
                       {rgb(1, 0.78, 0.45, 0.55 * b), rgb(0.95, 0.6, 0.28, 0.3 * b), rgb(0.8, 0.45, 0.2, 0)},
                       {0, 0.45, 1});
        cairo_restore(c);
        double a = gaugeAngle(clampd(gauges[k].pos, -0.03, 1.06));
        // The needle casts a long shadow away from the bulb.
        withShadow(c, 0, -0.012 * u, 0.012 * u, rgb(0, 0, 0, 0.45), [&](cairo_t* c) {
            line(c, pivot, polar(pivot, R * 0.94, a));
            stroke(c, rgb(0.12, 0.08, 0.06), std::max(1.2, 0.009 * u));
        });
        // Shroud along the bottom hiding the bulb, which peeks over its edge.
        Rect shroud{face.minX(), face.maxY() - face.h * 0.1, face.w, face.h * 0.1};
        linearGradient(c, shroud, {rgb(0.1, 0.09, 0.08), rgb(0.03, 0.03, 0.03)}, true);
        withShadow(c, 0, 0, 0.03 * u, rgb(1, 0.7, 0.35, 0.8 * b), [&](cairo_t* c) {
            addEllipse(c, {bulbAt.x - 0.016 * u, shroud.minY() - 0.008 * u, 0.032 * u, 0.016 * u});
            setColor(c, rgb(1, 0.88, 0.65, b));
            cairo_fill(c);
        });
        linearGradient(c, face, {rgb(1, 1, 1, 0.1), rgb(1, 1, 1, 0)}, false, 0.55);
        cairo_restore(c);
    }

    // Velocity on the Nixie tubes, "00.00" to "10.00" (fractions of light speed). Under tidal stress they scramble.
    std::vector<Rect> tubes = nixieTubes(l);
    for (int k = 0; k < int(tubes.size()); k++) {
        Rect g = nixieGlass(tubes[k]);
        Rect box = digitBox(g);
        double lit = frand(0.92f, 1.0f) * (chaos > 0.02f && frand(0, 1) < chaos * 0.3f ? 0.2 : 1);
        cairo_save(c);
        addNixieGlassPath(c, g);
        cairo_clip(c);
        // Neon haze filling the glass around the glowing cathode.
        Pt center{box.midX(), box.midY()};
        radialGradient(c, center, box.h * 0.8,
                       {rgb(neon.r, neon.g, neon.b, 0.16 * lit), rgb(neon.r, neon.g * 0.8, neon.b, 0)});
        // The lit numeral: a wide soft bloom, the orange glow, then the hot core of the wire.
        // The previous cathode's afterglow, then the new one igniting.
        double age = nixieAge[k];
        double ignite = std::min(age / 0.06, 1.0) * lit;
        double after = std::max(1 - age / 0.18, 0.0) * 0.6 * lit;
        std::pair<int, double> layers[2] = {{nixiePrevious[k], after}, {nixieDigits[k], ignite}};
        for (auto [d, glow] : layers) {
            if (glow <= 0.01) continue;
            struct Pass {
                double width;
                RGBA color;
                double blur;
            };
            const Pass passes[3] = {{box.h * 0.1, rgb(neon.r, neon.g, neon.b, 0.16 * glow), box.h * 0.14},
                                    {box.h * 0.05, rgb(neon.r, neon.g + 0.05, neon.b, 0.9 * glow), box.h * 0.04},
                                    {box.h * 0.02, rgb(1, 0.8, 0.55, glow), 0}};
            for (const Pass& p : passes) {
                auto body = [&](cairo_t* c) {
                    cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
                    cairo_set_line_join(c, CAIRO_LINE_JOIN_ROUND);
                    addNixieDigit(c, d, box);
                    stroke(c, p.color, std::max(0.8, p.width));
                };
                if (p.blur > 0) withShadow(c, 0, 0, p.blur, rgb(neon.r, neon.g, neon.b, 0.7 * glow), body);
                else body(c);
            }
        }
        // Decimal point cathode after the second digit.
        if (k == 1) {
            double r = box.h * 0.045;
            Rect dot{g.maxX() - g.w * 0.13 - r, box.maxY() - r, 2 * r, 2 * r};
            withShadow(c, 0, 0, box.h * 0.08, rgb(neon.r, neon.g, neon.b, lit), [&](cairo_t* c) {
                addEllipse(c, dot);
                setColor(c, rgb(1, 0.7, 0.4, lit));
                cairo_fill(c);
            });
        }
        // Front of the anode cage, faintly lit by the glow behind it.
        nixieMesh(c, g, rgb(0.9, 0.55, 0.3, 0.13));
        // Reflections on the curved glass: a bright band on one side, a faint one on the other.
        linearGradient(c, {g.minX() + g.w * 0.08, g.minY(), g.w * 0.14, g.h}, {rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.02)},
                       false);
        linearGradient(c, {g.maxX() - g.w * 0.16, g.minY(), g.w * 0.08, g.h}, {rgb(1, 1, 1, 0.0), rgb(1, 1, 1, 0.1)},
                       false);
        cairo_restore(c);
    }

    // Distance drum counter: white figures on black drums; the last drum rolls continuously.
    Rect win = counterWindow(l);
    int n = counterDigits(win);
    double dw = win.w / n;
    long long whole = (long long)distance;
    double frac = distance - double(whole);
    cairo_save(c);
    clipRect(c, win);
    for (int i = 0; i < n; i++) {
        int place = n - 1 - i;
        long long power = 1;
        for (int p = 0; p < place; p++) power *= 10;
        int digit = int((whole / power) % 10);
        // Only the last drum rolls smoothly; the others flip when the one to their right wraps (like a real counter).
        double roll = place == 0 ? frac : 0;
        if (place > 0 && (whole % power) == power - 1) roll = frac;
        Rect cell{win.minX() + i * dw, win.minY(), dw, win.h};
        linearGradient(c, cell.inset(1, 0), {rgb(0.05, 0.05, 0.05), rgb(0.16, 0.16, 0.15), rgb(0.05, 0.05, 0.05)}, true);
        for (int offset = 0; offset <= 1; offset++) {
            int value = (digit + offset) % 10;
            double y = cell.midY() + (offset - roll) * cell.h;
            char s[4];
            std::snprintf(s, sizeof(s), "%d", value);
            drawText(c, s, {cell.midX(), y}, cell.h * 0.78, i == n - 1 ? rgb(0.95, 0.35, 0.25) : rgb(0.93, 0.91, 0.85));
        }
        fillRect(c, {cell.maxX() - 0.5, cell.minY(), 1, cell.h}, rgb(0, 0, 0, 0.6));
    }
    // Drum curvature: dark at the top and bottom of the window.
    linearGradient(c, win, {rgb(0, 0, 0, 0.75), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.75)}, true);
    cairo_restore(c);

    // Fader caps.
    double cw = faderColumns(l).second;
    for (int k = 0; k < faderCount; k++) {
        Track t = faderTrack(l, k);
        double v = clampd(faders[k].pos, 0, 1);
        double y = t.bottom - v * (t.bottom - t.top);
        double capW = std::min(cw * 0.72, 0.075 * u), capH = 0.05 * u;
        Rect cap{t.x - capW / 2, y - capH / 2, capW, capH};
        withShadow(c, 0, 0.012 * u, 0.02 * u, rgb(0, 0, 0, 0.8),
                   [&](cairo_t* c) { fillRect(c, cap, rgb(0.5, 0.5, 0.48)); });
        linearGradient(c, cap, {rgb(0.78, 0.78, 0.75), rgb(0.3, 0.3, 0.29)}, true);
        fillRect(c, {cap.minX() + 1, cap.midY() - 0.5, cap.w - 2, 1.2}, rgb(1, 1, 1, 0.9));
    }

    // Scope traces: spectrum, plus a bass-driven sine sweep.
    Rect s = scopeScreen(l);
    cairo_save(c);
    addRoundedRect(c, s, 0.05 * u);
    cairo_clip(c);
    std::vector<Pt> spectrum, wave, noise;
    for (int i = 0; i < int(bands.size()); i++) {
        spectrum.push_back({s.minX() + s.w * i / std::max(int(bands.size()) - 1, 1),
                            s.maxY() - s.h * (0.08 + 0.8 * bands[i])});
    }
    double cycles = 2 + double(centroid) * 6;
    for (int i = 0; i <= 80; i++) {
        double t = i / 80.0;
        double y = s.midY() - s.h * 0.32 * bass * std::sin(t * cycles * 2 * M_PI - double(time) * 6);
        wave.push_back({s.minX() + s.w * t, y});
    }
    if (chaos > 0.02f) {
        // Signal breaks up into noise.
        for (int i = 0; i <= 120; i++) {
            noise.push_back({s.minX() + s.w * i / 120, s.midY() + s.h * 0.45 * chaos * frand(-1, 1)});
        }
    }
    auto addPolyline = [&](const std::vector<Pt>& pts) {
        for (size_t i = 0; i < pts.size(); i++) {
            if (i == 0) cairo_move_to(c, pts[i].x, pts[i].y);
            else cairo_line_to(c, pts[i].x, pts[i].y);
        }
    };
    for (int pass = 0; pass < 2; pass++) {
        double alpha = pass == 0 ? 0.45 : 1;
        for (int layer = 0; layer < 2; layer++) {
            if (pass == 0) addPolyline(wave);
            else {
                addPolyline(spectrum);
                addPolyline(noise);
            }
            if (layer == 0) stroke(c, rgb(0.4, 1, 0.6, 0.18 * alpha), 0.03 * u);
            else stroke(c, rgb(0.6, 1, 0.72, 0.95 * alpha), std::max(1.0, 0.008 * u));
        }
    }
    setColor(c, rgb(0, 0, 0, 0.18));
    for (double sy = s.minY(); sy < s.maxY(); sy += 3) addRect(c, {s.minX(), sy, s.w, 1});
    cairo_fill(c);
    if (chaos > 0.02f && std::sin(time * 14) > -0.2) {
        fillRect(c, s, rgb(0.6, 0.02, 0.02, 0.45 * chaos));
        drawText(c, "WARNING", {s.midX(), s.midY() - s.h * 0.14}, s.h * 0.3, rgb(1, 0.25, 0.2));
        char label[32];
        std::snprintf(label, sizeof(label), "TIDAL STRESS %d%%", int(chaos * 100));
        drawText(c, label, {s.midX(), s.midY() + s.h * 0.22}, s.h * 0.16, rgb(1, 0.5, 0.4));
    }
    linearGradient(c, s, {rgb(1, 1, 1, 0.08), rgb(1, 1, 1, 0)}, true, 0.5);
    cairo_restore(c);

    // Knob pointers.
    cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
    for (int k = 0; k < 3; k++) {
        auto [center, kr] = knobGeometry(l, k);
        line(c, polar(center, kr * 0.25, knobAngles[k]), polar(center, kr * 0.72, knobAngles[k]));
        stroke(c, rgb(0.95, 0.93, 0.85), std::max(1.5, 0.012 * u));
    }
    cairo_set_line_cap(c, CAIRO_LINE_CAP_BUTT);

    // Lamps.
    const RGBA colors[4] = {rgb(1, 0.62, 0.15), rgb(0.35, 1, 0.45), rgb(0.35, 1, 0.45), rgb(0.35, 1, 0.45)};
    std::vector<Lamp> lamps = lampGeometry(l);
    for (int i = 0; i < int(lamps.size()); i++) {
        const Lamp& lamp = lamps[i];
        RGBA col = colors[i];
        double on = clampd(lampGlow[i], 0, 1);
        Rect rect{lamp.center.x - lamp.radius, lamp.center.y - lamp.radius, 2 * lamp.radius, 2 * lamp.radius};
        double k = 0.18 + 0.82 * on;
        auto body = [&](cairo_t* c) {
            addEllipse(c, rect);
            setColor(c, rgb(col.r * k, col.g * k, col.b * k));
            cairo_fill(c);
        };
        if (on > 0.05) withShadow(c, 0, 0, lamp.radius * 2.4 * on, rgb(col.r, col.g, col.b, 0.55 * on), body);
        else body(c);
        addEllipse(c, rect.inset(lamp.radius * 0.45, lamp.radius * 0.45).offset(-lamp.radius * 0.2, -lamp.radius * 0.25));
        setColor(c, rgb(1, 1, 1, 0.25 + 0.35 * on));
        cairo_fill(c);
    }
}

// MARK: Helpers

void InstrumentPanel::bezelRect(cairo_t* c, Rect r, double u) {
    withShadow(c, 0, 0.01 * u, 0.025 * u, rgb(0, 0, 0, 0.8), [&](cairo_t* c) {
        addRoundedRect(c, r, 0.03 * u);
        setColor(c, rgb(0.3, 0.3, 0.3));
        cairo_fill(c);
    });
    cairo_save(c);
    addRoundedRect(c, r, 0.03 * u);
    cairo_clip(c);
    linearGradient(c, r, {rgb(0.62, 0.63, 0.61), rgb(0.18, 0.19, 0.18)}, true);
    cairo_restore(c);
}

void InstrumentPanel::screw(cairo_t* c, Pt p, double r) {
    Rect rect{p.x - r, p.y - r, 2 * r, 2 * r};
    cairo_save(c);
    addEllipse(c, rect);
    cairo_clip(c);
    linearGradient(c, rect, {rgb(0.7, 0.7, 0.68), rgb(0.22, 0.22, 0.22)}, true);
    cairo_restore(c);
    LCG rng((unsigned long long)std::fabs(p.x * 31 + p.y * 17));
    double a = rng.next() * M_PI;
    line(c, {p.x - std::cos(a) * r * 0.7, p.y - std::sin(a) * r * 0.7}, {p.x + std::cos(a) * r * 0.7, p.y + std::sin(a) * r * 0.7});
    stroke(c, rgb(0.08, 0.08, 0.08), std::max(1.0, r * 0.3));
}
