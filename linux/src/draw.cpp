#include "draw.h"

#include <algorithm>
#include <cairo-ft.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <random>

float frand(float a, float b) {
    static thread_local std::mt19937 rng{std::random_device{}()};
    return std::uniform_real_distribution<float>(a, b)(rng);
}

void addRoundedRect(cairo_t* c, Rect r, double radius) {
    radius = std::max(0.0, std::min({radius, r.w / 2, r.h / 2}));
    if (radius <= 0) {
        addRect(c, r);
        return;
    }
    cairo_new_sub_path(c);
    cairo_arc(c, r.maxX() - radius, r.minY() + radius, radius, -M_PI / 2, 0);
    cairo_arc(c, r.maxX() - radius, r.maxY() - radius, radius, 0, M_PI / 2);
    cairo_arc(c, r.minX() + radius, r.maxY() - radius, radius, M_PI / 2, M_PI);
    cairo_arc(c, r.minX() + radius, r.minY() + radius, radius, M_PI, 3 * M_PI / 2);
    cairo_close_path(c);
}

void addEllipse(cairo_t* c, Rect r) {
    if (r.w <= 0 || r.h <= 0) return;
    cairo_save(c);
    cairo_translate(c, r.midX(), r.midY());
    cairo_scale(c, r.w / 2, r.h / 2);
    cairo_new_sub_path(c);
    cairo_arc(c, 0, 0, 1, 0, 2 * M_PI);
    cairo_close_path(c);
    cairo_restore(c);
}

void arcTo(cairo_t* c, Pt p1, Pt p2, double radius) {
    double x0, y0;
    cairo_get_current_point(c, &x0, &y0);
    double ax = x0 - p1.x, ay = y0 - p1.y, bx = p2.x - p1.x, by = p2.y - p1.y;
    double la = std::hypot(ax, ay), lb = std::hypot(bx, by);
    if (la < 1e-9 || lb < 1e-9 || radius <= 0) {
        cairo_line_to(c, p1.x, p1.y);
        return;
    }
    ax /= la; ay /= la; bx /= lb; by /= lb;
    double cosT = std::clamp(ax * bx + ay * by, -1.0, 1.0);
    double theta = std::acos(cosT);
    if (theta < 1e-6 || std::fabs(theta - M_PI) < 1e-6) {
        cairo_line_to(c, p1.x, p1.y);
        return;
    }
    double dist = radius / std::tan(theta / 2); // from the corner to each tangent point
    Pt t1{p1.x + ax * dist, p1.y + ay * dist}, t2{p1.x + bx * dist, p1.y + by * dist};
    // Centre lies along the bisector.
    double mx = ax + bx, my = ay + by, ml = std::hypot(mx, my);
    double cd = radius / std::sin(theta / 2);
    Pt ctr{p1.x + mx / ml * cd, p1.y + my / ml * cd};
    double a1 = std::atan2(t1.y - ctr.y, t1.x - ctr.x), a2 = std::atan2(t2.y - ctr.y, t2.x - ctr.x);
    cairo_line_to(c, t1.x, t1.y);
    // Turn direction: cross product of the incoming and outgoing directions.
    double cross = (-ax) * by - (-ay) * bx;
    if (cross > 0) cairo_arc(c, ctr.x, ctr.y, radius, a1, a2);
    else cairo_arc_negative(c, ctr.x, ctr.y, radius, a1, a2);
}

static void addStops(cairo_pattern_t* p, const std::vector<RGBA>& colors, const std::vector<double>& locations) {
    for (size_t i = 0; i < colors.size(); i++) {
        double t = locations.size() == colors.size() ? locations[i]
                                                     : (colors.size() > 1 ? double(i) / double(colors.size() - 1) : 0);
        cairo_pattern_add_color_stop_rgba(p, t, colors[i].r, colors[i].g, colors[i].b, colors[i].a);
    }
}

void linearGradient(cairo_t* c, Rect r, const std::vector<RGBA>& colors, bool vertical, double endFraction) {
    double ex = vertical ? r.minX() : r.minX() + r.w * endFraction;
    double ey = r.minY() + r.h * endFraction;
    cairo_pattern_t* p = cairo_pattern_create_linear(r.minX(), r.minY(), ex, ey);
    addStops(p, colors, {});
    cairo_pattern_set_extend(p, CAIRO_EXTEND_PAD);
    cairo_save(c);
    addRect(c, r);
    cairo_set_source(c, p);
    cairo_fill(c);
    cairo_restore(c);
    cairo_pattern_destroy(p);
}

void radialGradient(cairo_t* c, Pt center, double radius, const std::vector<RGBA>& colors,
                    const std::vector<double>& locations) {
    cairo_pattern_t* p = cairo_pattern_create_radial(center.x, center.y, 0, center.x, center.y, radius);
    addStops(p, colors, locations);
    cairo_pattern_set_extend(p, CAIRO_EXTEND_NONE);
    cairo_save(c);
    cairo_set_source(c, p);
    cairo_paint(c);
    cairo_restore(c);
    cairo_pattern_destroy(p);
}

/// Three box blurs approximate a Gaussian of standard deviation `sigma`, in place on an A8 image.
static void blurA8(unsigned char* data, int w, int h, int stride, double sigma) {
    if (sigma < 0.3) return;
    int r = std::max(1, int(std::lround((std::sqrt(4 * sigma * sigma + 1) - 1) / 2)));
    std::vector<unsigned char> tmp(std::max(w, h));
    auto pass = [&](unsigned char* base, int count, int step) {
        int win = 2 * r + 1;
        int sum = 0;
        for (int i = -r; i <= r; i++) sum += base[std::clamp(i, 0, count - 1) * step];
        for (int i = 0; i < count; i++) {
            tmp[i] = (unsigned char)(sum / win);
            int add = std::min(i + r + 1, count - 1), sub = std::max(i - r, 0);
            sum += base[add * step] - base[sub * step];
        }
        for (int i = 0; i < count; i++) base[i * step] = tmp[i];
    };
    for (int k = 0; k < 3; k++) {
        for (int y = 0; y < h; y++) pass(data + y * stride, w, 1);
        for (int x = 0; x < w; x++) pass(data + x, h, stride);
    }
}

void withShadow(cairo_t* c, double dx, double dy, double blur, RGBA color, const std::function<void(cairo_t*)>& body) {
    cairo_matrix_t m;
    cairo_get_matrix(c, &m);
    double scale = std::sqrt(std::fabs(m.xx * m.yy - m.xy * m.yx));

    cairo_surface_t* rec = cairo_recording_surface_create(CAIRO_CONTENT_COLOR_ALPHA, nullptr);
    cairo_t* rc = cairo_create(rec);
    cairo_set_matrix(rc, &m);
    body(rc);
    cairo_destroy(rc);

    double ix, iy, iw, ih;
    cairo_recording_surface_ink_extents(rec, &ix, &iy, &iw, &ih);
    if (iw > 0 && ih > 0 && color.a > 0) {
        double sigma = blur * scale / 2;
        int pad = int(std::ceil(sigma * 3)) + 2;
        int x0 = int(std::floor(ix)) - pad, y0 = int(std::floor(iy)) - pad;
        int w = int(std::ceil(ix + iw)) + pad - x0, h = int(std::ceil(iy + ih)) + pad - y0;
        cairo_surface_t* mask = cairo_image_surface_create(CAIRO_FORMAT_A8, w, h);
        cairo_t* mc = cairo_create(mask);
        cairo_set_source_surface(mc, rec, -x0, -y0);
        cairo_paint(mc);
        cairo_destroy(mc);
        cairo_surface_flush(mask);
        blurA8(cairo_image_surface_get_data(mask), w, h, cairo_image_surface_get_stride(mask), sigma);
        cairo_surface_mark_dirty(mask);
        cairo_save(c);
        cairo_identity_matrix(c);
        setColor(c, color);
        cairo_mask_surface(c, mask, x0 + dx * scale, y0 + dy * scale);
        cairo_restore(c);
        cairo_surface_destroy(mask);
    }
    cairo_save(c);
    cairo_identity_matrix(c);
    cairo_set_source_surface(c, rec, 0, 0);
    cairo_paint(c);
    cairo_restore(c);
    cairo_surface_destroy(rec);
}

// MARK: - Text

static cairo_font_face_t* labelFace = nullptr;

void loadLabelFont(const std::string& path) {
    static FT_Library library = nullptr;
    if (!library && FT_Init_FreeType(&library) != 0) library = nullptr;
    FT_Face face = nullptr;
    if (library && FT_New_Face(library, path.c_str(), 0, &face) == 0) {
        labelFace = cairo_ft_font_face_create_for_ft_face(face, 0);
    } else {
        labelFace = cairo_toy_font_face_create("sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    }
}

static void selectLabelFont(cairo_t* c, double size) {
    if (!labelFace) loadLabelFont("");
    cairo_set_font_face(c, labelFace);
    cairo_set_font_size(c, size);
}

void selectUIFont(cairo_t* c, UIFont font, double size) {
    cairo_select_font_face(c, font == UIFont::mono ? "monospace" : "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                           font == UIFont::mono ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(c, size);
}

/// Glyphs of `s` laid out from x = 0 with extra tracking; returns the advance width.
static double layout(cairo_t* c, const std::string& s, double size, double tracking, std::vector<cairo_glyph_t>& out) {
    out.clear();
    cairo_scaled_font_t* sf = cairo_get_scaled_font(c);
    cairo_glyph_t* glyphs = nullptr;
    int count = 0;
    if (cairo_scaled_font_text_to_glyphs(sf, 0, 0, s.c_str(), int(s.size()), &glyphs, &count, nullptr, nullptr,
                                         nullptr) != CAIRO_STATUS_SUCCESS) {
        return 0;
    }
    double kern = size * tracking;
    out.assign(glyphs, glyphs + count);
    for (int i = 0; i < count; i++) out[i].x += kern * i;
    double width = 0;
    if (count > 0) {
        cairo_text_extents_t e;
        cairo_scaled_font_glyph_extents(sf, glyphs + count - 1, 1, &e);
        width = out[count - 1].x + e.x_advance + kern;
    }
    cairo_glyph_free(glyphs);
    return width;
}

double textWidth(cairo_t* c, const std::string& s, double size, double tracking) {
    cairo_save(c);
    selectLabelFont(c, size);
    std::vector<cairo_glyph_t> g;
    double w = layout(c, s, size, tracking, g);
    cairo_restore(c);
    return w;
}

void drawText(cairo_t* c, const std::string& s, Pt p, double size, RGBA color, bool alignLeft, double tracking,
              bool alignRight) {
    if (size <= 0.5) return;
    cairo_save(c);
    selectLabelFont(c, size);
    std::vector<cairo_glyph_t> g;
    double width = layout(c, s, size, tracking, g);
    cairo_text_extents_t cap;
    cairo_text_extents(c, "H", &cap);
    double x = alignLeft ? p.x : (alignRight ? p.x - width : p.x - width / 2);
    double y = p.y - cap.y_bearing / 2; // y_bearing is negative: the cap height
    for (auto& gl : g) {
        gl.x += x;
        gl.y += y;
    }
    setColor(c, color);
    cairo_show_glyphs(c, g.data(), int(g.size()));
    cairo_restore(c);
}
