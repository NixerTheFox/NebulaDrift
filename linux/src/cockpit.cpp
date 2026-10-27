#include "cockpit.h"

#include "draw.h"
#include "instruments.h"

#include <algorithm>
#include <cmath>
#include <vector>

/// Corner points of the window, clockwise from bottom-left. The bottom runs behind the console.
static std::vector<Pt> windowCorners(double w, double h) {
    double sideLow = w * 0.035, sideHigh = w * 0.075, top = h * 0.07;
    double chamfer = std::min(w, h) * 0.08;
    return {{sideLow, h + 20}, {sideLow, h * 0.5}, {sideHigh, top + chamfer}, {sideHigh + chamfer, top},
            {w - sideHigh - chamfer, top}, {w - sideHigh, top + chamfer}, {w - sideLow, h * 0.5}, {w - sideLow, h + 20}};
}

static void addWindowPath(cairo_t* c, const std::vector<Pt>& pts, double radius) {
    cairo_move_to(c, pts[0].x, pts[0].y);
    for (size_t i = 1; i + 1 < pts.size(); i++) arcTo(c, pts[i], pts[i + 1], radius);
    cairo_line_to(c, pts.back().x, pts.back().y);
    cairo_close_path(c);
}

static void rivet(cairo_t* c, Pt p, double r) {
    Rect rect{p.x - r, p.y - r, 2 * r, 2 * r};
    withShadow(c, 0, 1, 2, rgb(0, 0, 0, 0.8), [&](cairo_t* c) {
        addEllipse(c, rect);
        setColor(c, rgb(0.16, 0.16, 0.16));
        cairo_fill(c);
    });
    cairo_save(c);
    addEllipse(c, rect);
    cairo_clip(c);
    cairo_pattern_t* g = cairo_pattern_create_linear(rect.minX(), rect.minY(), rect.maxX(), rect.maxY());
    cairo_pattern_add_color_stop_rgb(g, 0, 0.36, 0.36, 0.35);
    cairo_pattern_add_color_stop_rgb(g, 1, 0.1, 0.1, 0.1);
    cairo_set_source(c, g);
    cairo_paint(c);
    cairo_pattern_destroy(g);
    cairo_restore(c);
}

static void stencil(cairo_t* c, const char* s, Pt p, double size, bool alignRight = false) {
    drawText(c, s, p, size, rgb(0.86, 0.83, 0.74, 0.26), !alignRight, 0.12, alignRight);
}

void drawCockpitFrame(cairo_t* c, double w, double h) {
    double u = InstrumentPanel::panelHeight(w, h);
    std::vector<Pt> pts = windowCorners(w, h);
    double radius = std::min(w, h) * 0.03;

    // Hull plating around the window.
    cairo_save(c);
    cairo_rectangle(c, 0, 0, w, h);
    addWindowPath(c, pts, radius);
    cairo_set_fill_rule(c, CAIRO_FILL_RULE_EVEN_ODD);
    cairo_clip(c);
    cairo_set_fill_rule(c, CAIRO_FILL_RULE_WINDING);
    cairo_pattern_t* hull = cairo_pattern_create_linear(0, 0, 0, h);
    cairo_pattern_add_color_stop_rgb(hull, 0, 0.075, 0.08, 0.075);
    cairo_pattern_add_color_stop_rgb(hull, 1, 0.03, 0.032, 0.03);
    cairo_set_source(c, hull);
    cairo_paint(c);
    cairo_pattern_destroy(hull);
    // Brushed grain and grime.
    unsigned long long seed = 99;
    auto rnd = [&] {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        return double(seed >> 40) / double(1 << 24);
    };
    cairo_set_line_width(c, 1);
    for (double y = 0; y < h; y += 1 + 2.5 * rnd()) {
        setColor(c, rgb(1, 1, 1, 0.004 + 0.012 * rnd()));
        cairo_move_to(c, 0, y);
        cairo_line_to(c, w, y);
        cairo_stroke(c);
    }
    // Panel seams.
    double seamY = pts[3].y * 0.45;
    cairo_move_to(c, 0, seamY);
    cairo_line_to(c, w, seamY);
    cairo_move_to(c, pts[1].x * 0.45, seamY);
    cairo_line_to(c, pts[1].x * 0.45, h);
    cairo_move_to(c, w - pts[1].x * 0.45, seamY);
    cairo_line_to(c, w - pts[1].x * 0.45, h);
    setColor(c, rgb(0, 0, 0, 0.6));
    cairo_set_line_width(c, 1.5);
    cairo_stroke(c);
    cairo_move_to(c, 0, seamY + 1.5);
    cairo_line_to(c, w, seamY + 1.5);
    setColor(c, rgb(1, 1, 1, 0.06));
    cairo_set_line_width(c, 1);
    cairo_stroke(c);

    // Rivets in a row just outside the seal, all the way round.
    double spacing = std::max(26.0, u * 0.2);
    for (size_t i = 1; i + 2 < pts.size(); i++) {
        Pt a = pts[i], z = pts[i + 1];
        double len = std::hypot(z.x - a.x, z.y - a.y);
        Pt n{-(z.y - a.y) / len, (z.x - a.x) / len};
        Pt mid{(a.x + z.x) / 2, (a.y + z.y) / 2};
        cairo_new_path(c);
        addWindowPath(c, pts, radius);
        if (cairo_in_fill(c, mid.x + n.x * 4, mid.y + n.y * 4)) n = {-n.x, -n.y};
        cairo_new_path(c);
        double off = std::max(12.0, u * 0.09);
        for (double t = spacing * 0.5; t < len - spacing * 0.3; t += spacing) {
            Pt p{a.x + (z.x - a.x) * t / len + n.x * off, a.y + (z.y - a.y) * t / len + n.y * off};
            rivet(c, p, std::max(2.5, u * 0.018));
        }
    }
    // Stencils.
    stencil(c, "CANOPY 2-A   ·   PRESSURE RATED 1.2 ATM", {pts[3].x + 10, seamY * 0.5}, std::max(9.0, u * 0.07));
    stencil(c, "DO NOT OPEN IN FLIGHT", {w - pts[3].x - 10, seamY * 0.5}, std::max(9.0, u * 0.07), true);
    cairo_restore(c);

    // Soft shading on the glass just inside the frame, for depth.
    cairo_save(c);
    addWindowPath(c, pts, radius);
    cairo_clip(c);
    withShadow(c, 0, 4, 28, rgb(0, 0, 0, 0.85), [&](cairo_t* c) {
        addWindowPath(c, pts, radius);
        setColor(c, rgb(0, 0, 0, 1));
        cairo_set_line_width(c, 10);
        cairo_stroke(c);
    });
    cairo_restore(c);

    // Rubber seal with a worn highlight.
    addWindowPath(c, pts, radius);
    setColor(c, rgb(0.025, 0.025, 0.025));
    cairo_set_line_width(c, std::max(7.0, u * 0.05));
    cairo_stroke(c);
    addWindowPath(c, pts, radius);
    setColor(c, rgb(0.4, 0.4, 0.38, 0.2));
    cairo_set_line_width(c, 1);
    cairo_stroke(c);
}
