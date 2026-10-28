// Nebula Drift — an audio visualizer. Linux port: SDL2 window, OpenGL 3.3 renderer, Cairo instruments.
// Fly through space: stars stream past, nebula clouds take their colour from the music.

#include "audio.h"
#include "cockpit.h"
#include "draw.h"
#include "gl.h"
#include "instruments.h"
#include "renderer.h"

#include <SDL.h>
#include <sys/resource.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <glob.h>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

// MARK: - Files and settings

static std::string executableDir() {
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return ".";
    buf[n] = 0;
    std::string path(buf);
    return path.substr(0, path.find_last_of('/'));
}

static bool exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

/// Where the shaders and font live: next to the binary in a build tree, or in share/ when installed.
static std::string resourceDir() {
    std::string exe = executableDir();
    for (const std::string& dir : {exe + "/../share/nebuladrift", exe, std::string(NEBULADRIFT_SOURCE_DIR)}) {
        if (exists(dir + "/shaders/common.glsl")) return dir;
    }
    return exe;
}

/// Settings are remembered between launches in ~/.config/nebuladrift/settings.
class Settings {
public:
    Settings() {
        const char* xdg = std::getenv("XDG_CONFIG_HOME");
        const char* home = std::getenv("HOME");
        std::string base = xdg && *xdg ? xdg : std::string(home ? home : ".") + "/.config";
        dir = base + "/nebuladrift";
        path = dir + "/settings";
        std::ifstream in(path);
        std::string line;
        while (std::getline(in, line)) {
            size_t eq = line.find('=');
            if (eq != std::string::npos) values[line.substr(0, eq)] = line.substr(eq + 1);
        }
    }

    bool has(const std::string& key) const { return values.count(key) > 0; }
    int integer(const std::string& key, int fallback = 0) const {
        auto it = values.find(key);
        return it == values.end() ? fallback : std::atoi(it->second.c_str());
    }
    bool boolean(const std::string& key, bool fallback = false) const { return integer(key, fallback ? 1 : 0) != 0; }

    void set(const std::string& key, int value) {
        values[key] = std::to_string(value);
        save();
    }

private:
    void save() {
        mkdir((dir.substr(0, dir.find_last_of('/'))).c_str(), 0755);
        mkdir(dir.c_str(), 0755);
        std::ofstream out(path);
        for (auto& [k, v] : values) out << k << "=" << v << "\n";
    }

    std::string dir, path;
    std::map<std::string, std::string> values;
};

// MARK: - Performance numbers (P key)

/// CPU time (user + system) this process has used, in seconds.
static double processCPUTime() {
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    auto seconds = [](timeval t) { return double(t.tv_sec) + double(t.tv_usec) / 1e6; };
    return seconds(usage.ru_utime) + seconds(usage.ru_stime);
}

/// Whole-GPU utilization as reported by the kernel driver (amdgpu and some others), in percent.
static std::optional<int> gpuUtilization() {
    glob_t g{};
    std::optional<int> best;
    if (glob("/sys/class/drm/card*/device/gpu_busy_percent", 0, nullptr, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            std::ifstream in(g.gl_pathv[i]);
            int v;
            if (in >> v) best = std::max(best.value_or(0), v);
        }
    }
    globfree(&g);
    return best;
}

// MARK: - Overlays (Cairo drawings composited over the GL view)

static const char* overlayVert = R"(#version 330 core
uniform vec4 rect; // x, y, w, h in NDC (y up)
out vec2 st;
void main() {
    vec2 c = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    st = vec2(c.x, 1.0 - c.y);
    gl_Position = vec4(rect.xy + c * rect.zw, 0.0, 1.0);
}
)";

static const char* overlayFrag = R"(#version 330 core
uniform sampler2D tex;
uniform float alpha;
in vec2 st;
out vec4 fragColor;
void main() { fragColor = texture(tex, st) * alpha; }
)";

struct Overlay {
    cairo_surface_t* surface = nullptr;
    GLuint texture = 0;
    int width = 0, height = 0;
    int textureW = 0, textureH = 0; // size the texture was allocated at
    double x = 0, y = 0; // top-left, in drawable pixels
    bool hasContent = false;

    /// A cleared context for drawing `w` x `h` pixels, scaled so that one unit is one point.
    cairo_t* begin(int w, int h, double scale) {
        w = std::max(w, 1);
        h = std::max(h, 1);
        if (!surface || w != width || h != height) {
            if (surface) cairo_surface_destroy(surface);
            surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
            width = w;
            height = h;
        }
        cairo_t* c = cairo_create(surface);
        cairo_set_operator(c, CAIRO_OPERATOR_CLEAR);
        cairo_paint(c);
        cairo_set_operator(c, CAIRO_OPERATOR_OVER);
        cairo_scale(c, scale, scale);
        return c;
    }

    void end(cairo_t* c) {
        cairo_destroy(c);
        cairo_surface_flush(surface);
        if (!texture) glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, cairo_image_surface_get_stride(surface) / 4);
        if (width == textureW && height == textureH) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_BGRA, GL_UNSIGNED_BYTE,
                            cairo_image_surface_get_data(surface));
        } else {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_BGRA, GL_UNSIGNED_BYTE,
                         cairo_image_surface_get_data(surface));
            textureW = width;
            textureH = height;
        }
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        hasContent = true;
    }

    ~Overlay() {
        if (surface) cairo_surface_destroy(surface);
    }
};

class OverlayRenderer {
public:
    OverlayRenderer() {
        auto compile = [](GLenum type, const char* src) {
            GLuint s = glCreateShader(type);
            glShaderSource(s, 1, &src, nullptr);
            glCompileShader(s);
            return s;
        };
        GLuint vs = compile(GL_VERTEX_SHADER, overlayVert), fs = compile(GL_FRAGMENT_SHADER, overlayFrag);
        program = glCreateProgram();
        glAttachShader(program, vs);
        glAttachShader(program, fs);
        glLinkProgram(program);
        glDeleteShader(vs);
        glDeleteShader(fs);
        rectLoc = glGetUniformLocation(program, "rect");
        alphaLoc = glGetUniformLocation(program, "alpha");
        glGenVertexArrays(1, &vao);
    }

    void draw(const Overlay& o, int viewW, int viewH, float alpha = 1) {
        if (!o.hasContent || alpha <= 0.001f) return;
        glUseProgram(program);
        glUniform1i(glGetUniformLocation(program, "tex"), 0);
        glUniform1f(alphaLoc, alpha);
        float x = float(o.x / viewW * 2 - 1), y = float(1 - (o.y + o.height) / viewH * 2);
        glUniform4f(rectLoc, x, y, float(o.width) / viewW * 2, float(o.height) / viewH * 2);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, o.texture);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); // Cairo is premultiplied
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisable(GL_BLEND);
    }

private:
    GLuint program = 0, vao = 0;
    GLint rectLoc = -1, alphaLoc = -1;
};

/// Splits text into lines no wider than `maxWidth`, breaking at spaces (and at explicit newlines).
static std::vector<std::string> wrapText(cairo_t* c, const std::string& text, double maxWidth) {
    std::vector<std::string> out;
    std::stringstream paragraphs(text);
    std::string para;
    while (std::getline(paragraphs, para)) {
        std::string line;
        size_t i = 0;
        while (i < para.size()) {
            // Next word, with the spaces before it.
            size_t start = i;
            while (i < para.size() && para[i] == ' ') i++;
            while (i < para.size() && para[i] != ' ') i++;
            std::string piece = para.substr(start, i - start);
            std::string candidate = line + piece;
            cairo_text_extents_t e;
            cairo_text_extents(c, candidate.c_str(), &e);
            if (!line.empty() && e.x_advance > maxWidth) {
                out.push_back(line);
                size_t first = piece.find_first_not_of(' ');
                line = first == std::string::npos ? "" : piece.substr(first);
            } else {
                line = candidate;
            }
        }
        out.push_back(line);
    }
    return out;
}

// MARK: - File dialog

/// Asks zenity or kdialog (whichever is installed) for an audio file, off the main thread.
static bool hasProgram(const char* name) {
    const char* path = std::getenv("PATH");
    std::stringstream dirs(path ? path : "/usr/bin:/bin");
    std::string dir;
    while (std::getline(dirs, dir, ':')) {
        if (!dir.empty() && access((dir + "/" + name).c_str(), X_OK) == 0) return true;
    }
    return false;
}

static Uint32 fileChosenEvent = 0;

static bool openFileDialog() {
    std::string command;
    // The host's dialog tools must not pick up libraries bundled in the AppImage.
    if (hasProgram("zenity")) {
        command = "env -u LD_LIBRARY_PATH zenity --file-selection --title='Open Audio File' "
                  "--file-filter='Audio files | *.mp3 *.MP3 *.flac *.FLAC *.wav *.WAV *.ogg *.oga *.OGG' "
                  "--file-filter='All files | *' 2>/dev/null";
    } else if (hasProgram("kdialog")) {
        command = "env -u LD_LIBRARY_PATH kdialog --title 'Open Audio File' --getopenfilename \"$HOME\" "
                  "'Audio files (*.mp3 *.flac *.wav *.ogg *.oga)' 2>/dev/null";
    } else {
        return false;
    }
    std::thread([command] {
        std::string result;
        if (FILE* p = popen(command.c_str(), "r")) {
            char buf[4096];
            while (fgets(buf, sizeof(buf), p)) result += buf;
            pclose(p);
        }
        while (!result.empty() && (result.back() == '\n' || result.back() == '\r')) result.pop_back();
        if (result.empty()) return;
        SDL_Event e{};
        e.type = fileChosenEvent;
        e.user.data1 = new std::string(result);
        SDL_PushEvent(&e);
    }).detach();
    return true;
}

// MARK: - App

class App {
public:
    App(SDL_Window* window, const std::string& resources, const std::string& file)
        : window(window), sources(analyzer) {
        renderer = std::make_unique<Renderer>(resources + "/shaders",
                                              [this](float dt) { return analyzer.analyze(dt); });
        if (settings.has("dither")) {
            renderer->ditherMode = DitherMode(std::clamp(settings.integer("dither"), 0, 2));
        }
        if (settings.has("ditherStrength")) {
            renderer->ditherStrength = std::clamp(settings.integer("ditherStrength"), 1, 4);
        }
        if (settings.has("aberration")) renderer->aberration = settings.boolean("aberration");
        renderer->cockpitGlass = settings.boolean("cockpit");
        instrumentsHidden = settings.boolean("instrumentsHidden");
        statsShown = settings.boolean("showStats");
        renderer->onFrame = [this](const PanelInput& in, float dt) {
            if (instrumentsHidden) return;
            panel.update(in, dt);
            // Redraw the console at about 60 Hz; the springs still integrate every frame.
            panelClock += dt;
            if (panelClock >= 1.0f / 62) {
                panelClock = 0;
                panelDirty = true;
            }
        };
        sources.onStatus = [this](const std::string& s) { showHUD(s); };
        if (file.empty()) sources.startSystemAudio();
        else playFile(file);
        lastCPU = processCPUTime();
        lastStatsWall = nowSeconds();
    }

    void run() {
        double last = nowSeconds();
        while (running) {
            SDL_Event e;
            while (SDL_PollEvent(&e)) handle(e);
            sources.poll();
            double now = nowSeconds();
            float dt = float(std::min(now - last, 0.1));
            last = now;
            frame(dt, now);
            SDL_GL_SwapWindow(window);
        }
        sources.stopAll();
    }

private:
    static constexpr const char* hints =
        "S  system audio    M  microphone    O  open file (or drop one)    F  full screen    I  instruments    "
        "P  stats    T  fly into the next one    B  black hole\n"
        "G  cockpit glass    D  dither style    Shift-D  dither strength    C  chromatic aberration    Q  quality    "
        "H  hints";

    void handle(const SDL_Event& e) {
        if (e.type == SDL_QUIT) running = false;
        else if (e.type == SDL_KEYDOWN && !e.key.repeat) handleKey(e.key.keysym);
        else if (e.type == SDL_DROPFILE) {
            playFile(e.drop.file);
            SDL_free(e.drop.file);
        } else if (e.type == SDL_MOUSEMOTION) {
            lastMouseMove = nowSeconds();
            if (cursorHidden) {
                SDL_ShowCursor(SDL_ENABLE);
                cursorHidden = false;
            }
        } else if (e.type == fileChosenEvent) {
            auto* path = static_cast<std::string*>(e.user.data1);
            playFile(*path);
            delete path;
        } else if (e.type == SDL_WINDOWEVENT && e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            panelDirty = hudDirty = statsDirty = cockpitDirty = true;
        }
    }

    bool fullscreen() const { return SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP; }

    void toggleFullScreen() {
        SDL_SetWindowFullscreen(window, fullscreen() ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
        if (fullscreen()) hideCursor();
    }

    void hideCursor() {
        SDL_ShowCursor(SDL_DISABLE);
        cursorHidden = true;
    }

    void handleKey(const SDL_Keysym& key) {
        bool shift = key.mod & KMOD_SHIFT;
        if ((key.mod & KMOD_CTRL) && key.sym == SDLK_q) {
            running = false;
            return;
        }
        switch (key.sym) {
        case SDLK_ESCAPE:
            if (fullscreen()) toggleFullScreen();
            break;
        case SDLK_p:
            statsShown = !statsShown;
            settings.set("showStats", statsShown);
            if (statsShown) {
                renderer->takeStats();
                lastStatsWall = nowSeconds();
                lastCPU = processCPUTime();
                statsText = " measuring… ";
                statsDirty = true;
            }
            break;
        case SDLK_b:
            renderer->spawnBlackHole();
            showHUD("Gravitational anomaly detected ahead", 3);
            break;
        case SDLK_t:
            renderer->spawnFlyThrough();
            showHUD("Course set: straight into the next one", 2);
            break;
        case SDLK_i:
            instrumentsHidden = !instrumentsHidden;
            settings.set("instrumentsHidden", instrumentsHidden);
            panelDirty = true;
            break;
        case SDLK_s:
            panel.source = InstrumentPanel::Source::system;
            sources.startSystemAudio();
            break;
        case SDLK_m:
            panel.source = InstrumentPanel::Source::mic;
            sources.startMicrophone();
            break;
        case SDLK_o:
            if (!openFileDialog()) {
                showHUD("No file dialog available (install zenity or kdialog). Drag an audio file onto the window "
                        "instead.");
            }
            break;
        case SDLK_f:
        case SDLK_F11: toggleFullScreen(); break;
        case SDLK_d:
            if (shift) {
                renderer->ditherStrength = renderer->ditherStrength % 4 + 1;
                settings.set("ditherStrength", renderer->ditherStrength);
                const char* names[4] = {"Light", "Medium", "Strong", "Heavy"};
                showHUD(std::string("Dither strength: ") + names[renderer->ditherStrength - 1], 2);
            } else {
                auto next = DitherMode((int(renderer->ditherMode) + 1) % 3);
                renderer->ditherMode = next;
                settings.set("dither", int(next));
                showHUD(ditherLabel(next), 2);
            }
            break;
        case SDLK_g:
            renderer->cockpitGlass = !renderer->cockpitGlass;
            settings.set("cockpit", renderer->cockpitGlass);
            cockpitDirty = true;
            showHUD(renderer->cockpitGlass ? "Cockpit: canopy glass" : "Cockpit: open view", 2);
            break;
        case SDLK_c:
            renderer->aberration = !renderer->aberration;
            settings.set("aberration", renderer->aberration);
            showHUD(renderer->aberration ? "Chromatic aberration: On" : "Chromatic aberration: Off", 2);
            break;
        case SDLK_q:
            altQuality = !altQuality;
            if (pixelRatio() > 1.01) {
                showHUD(altQuality ? "Quality: HiDPI (full resolution)" : "Quality: Standard (smoother)", 2);
            } else {
                showHUD(altQuality ? "Quality: Half resolution (fastest)" : "Quality: Standard", 2);
            }
            break;
        case SDLK_h:
            if (hudAlpha(nowSeconds()) > 0.5f) hudHideAt = -100;
            else showHUD("Nebula Drift", 8);
            break;
        default: break;
        }
    }

    void playFile(const std::string& path) {
        panel.source = InstrumentPanel::Source::file;
        sources.play(path);
    }

    void showHUD(const std::string& message, double seconds = 6) {
        hudText = message + "\n" + hints;
        hudHideAt = nowSeconds() + seconds;
        hudDirty = true;
    }

    float hudAlpha(double now) const {
        if (now < hudHideAt) return 1;
        return float(std::max(0.0, 1 - (now - hudHideAt) / 1.2));
    }

    double pixelRatio() const {
        int ww, wh, dw, dh;
        SDL_GetWindowSize(window, &ww, &wh);
        SDL_GL_GetDrawableSize(window, &dw, &dh);
        return ww > 0 ? double(dw) / ww : 1;
    }

    void frame(float dt, double now) {
        int ww, wh, dw, dh;
        SDL_GetWindowSize(window, &ww, &wh);
        SDL_GL_GetDrawableSize(window, &dw, &dh);
        ww = std::max(ww, 1);
        wh = std::max(wh, 1);
        double ratio = double(dw) / ww;
        // Standard renders one pixel per point (smooth on HiDPI); the alternative is full HiDPI resolution,
        // or half resolution on a normal display.
        double renderScale = altQuality ? (ratio > 1.01 ? ratio : 0.5) : 1.0;
        int rw = std::max(int(ww * renderScale), 1), rh = std::max(int(wh * renderScale), 1);

        renderer->step(dt, rw, rh);
        GLuint fbo = renderer->render(rw, rh);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glBlitFramebuffer(0, 0, rw, rh, 0, 0, dw, dh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, dw, dh);

        // Cockpit frame, below the console, HUD and stats.
        if (renderer->cockpitGlass) {
            if (cockpitDirty || cockpit.width != dw || cockpit.height != dh) {
                cairo_t* c = cockpit.begin(dw, dh, ratio);
                drawCockpitFrame(c, ww, wh);
                cockpit.end(c);
                cockpitDirty = false;
            }
            overlays.draw(cockpit, dw, dh);
        }

        if (!instrumentsHidden) {
            double strip = InstrumentPanel::stripHeight(ww, wh);
            if (panelDirty || console.width != dw) {
                cairo_t* c = console.begin(dw, int(std::ceil(strip * ratio)), ratio);
                panel.drawStrip(c, ww, wh);
                console.end(c);
                console.y = dh - console.height;
                if (panel.alarmActive()) {
                    Rect r = InstrumentPanel::alarmRect(ww, wh);
                    double pad = 40;
                    cairo_t* a = alarm.begin(int((r.w + 2 * pad) * ratio), int((r.h + 2 * pad) * ratio), ratio);
                    cairo_translate(a, -(r.x - pad), -(r.y - pad));
                    panel.drawAlarm(a, ww, wh);
                    alarm.end(a);
                    alarm.x = (r.x - pad) * ratio;
                    alarm.y = (r.y - pad) * ratio;
                }
                panelDirty = false;
            }
            overlays.draw(console, dw, dh);
            if (panel.alarmActive()) overlays.draw(alarm, dw, dh);
        }

        float hudA = hudAlpha(now);
        if (hudA > 0) {
            if (hudDirty || hud.width != dw) {
                // White text with a soft black shadow, wrapped to the window.
                cairo_t* m = cairo_create(cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1));
                selectUIFont(m, UIFont::sans, 13);
                std::vector<std::string> lines = wrapText(m, hudText, ww - 44.0);
                cairo_surface_destroy(cairo_get_target(m));
                cairo_destroy(m);
                double lineH = 17;
                double h = 38 + lines.size() * lineH + 16;
                cairo_t* c = hud.begin(dw, int(h * ratio), ratio);
                withShadow(c, 0, 0, 6, rgb(0, 0, 0, 1), [&](cairo_t* c) {
                    selectUIFont(c, UIFont::sans, 13);
                    setColor(c, rgb(1, 1, 1, 0.85));
                    for (size_t i = 0; i < lines.size(); i++) {
                        cairo_move_to(c, 22, 38 + 13 + i * lineH);
                        cairo_show_text(c, lines[i].c_str());
                    }
                });
                hud.end(c);
                hudDirty = false;
            }
            overlays.draw(hud, dw, dh, hudA);
        }

        if (statsShown) {
            if (now - lastStatsWall >= 0.5) updateStats(now);
            if (statsDirty || stats.width == 0) {
                cairo_t* m = cairo_create(cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1));
                selectUIFont(m, UIFont::mono, 11.5);
                cairo_text_extents_t e;
                cairo_text_extents(m, statsText.c_str(), &e);
                cairo_surface_destroy(cairo_get_target(m));
                cairo_destroy(m);
                double w = e.x_advance + 4, h = 20;
                cairo_t* c = stats.begin(int(w * ratio), int(h * ratio), ratio);
                addRoundedRect(c, {0, 0, w, h}, 6);
                setColor(c, rgb(0, 0, 0, 0.5));
                cairo_fill(c);
                selectUIFont(c, UIFont::mono, 11.5);
                setColor(c, rgb(0.6, 1, 0.72, 0.95));
                cairo_move_to(c, 2, 14);
                cairo_show_text(c, statsText.c_str());
                stats.end(c);
                stats.x = (ww - 16 - w) * ratio;
                stats.y = 34 * ratio;
                statsDirty = false;
            }
            overlays.draw(stats, dw, dh);
        }

        // Hide the mouse pointer after it has been still for a couple of seconds; it returns when moved.
        if (!cursorHidden && now - lastMouseMove > 2 && (SDL_GetWindowFlags(window) & SDL_WINDOW_MOUSE_FOCUS)) {
            hideCursor();
        }
    }

    void updateStats(double now) {
        double cpu = processCPUTime();
        double wall = std::max(now - lastStatsWall, 1e-3);
        double cpuPercent = (cpu - lastCPU) / wall * 100;
        lastStatsWall = now;
        lastCPU = cpu;
        auto [frames, gpuSeconds] = renderer->takeStats();
        double fps = frames / wall;
        double gpuMs = frames > 0 ? gpuSeconds / frames * 1000 : 0;
        std::optional<int> util = gpuUtilization();
        char gpu[16];
        if (util) std::snprintf(gpu, sizeof(gpu), "%d%%", *util);
        else std::snprintf(gpu, sizeof(gpu), "n/a");
        char text[128];
        std::snprintf(text, sizeof(text), " FPS %3.0f   CPU %3.0f%%   GPU %s (%.1f ms/frame) ", fps, cpuPercent, gpu,
                      gpuMs);
        statsText = text;
        statsDirty = true;
    }

    SDL_Window* window;
    AudioAnalyzer analyzer;
    AudioSources sources;
    Settings settings;
    std::unique_ptr<Renderer> renderer;
    InstrumentPanel panel;
    OverlayRenderer overlays;
    Overlay cockpit, console, alarm, hud, stats;
    bool running = true;
    bool instrumentsHidden = false, statsShown = false, altQuality = false, cursorHidden = false;
    bool panelDirty = true, hudDirty = true, statsDirty = true, cockpitDirty = true;
    float panelClock = 0;
    std::string hudText, statsText = " measuring… ";
    double hudHideAt = -100;
    double lastMouseMove = 0;
    double lastCPU = 0, lastStatsWall = 0;
};

// MARK: - Snapshots

/// `--snapshot <dir>` renders test frames with synthetic audio, for testing without a visible window.
static void runSnapshot(const std::string& resources, const std::string& dir) {
    const std::string shaders = resources + "/shaders";
    seedRandom(1); // the same frames every run, so renders can be compared
    auto write = [&](Renderer& r, int w, int h, const std::string& name,
                     const std::function<void(cairo_t*)>& overlay = nullptr) {
        r.render(w, h);
        std::vector<unsigned char> px = r.readPixels(w, h);
        cairo_surface_t* s = cairo_image_surface_create_for_data(px.data(), CAIRO_FORMAT_ARGB32, w, h, w * 4);
        if (overlay) {
            cairo_t* c = cairo_create(s);
            overlay(c);
            cairo_destroy(c);
        }
        cairo_surface_write_to_png(s, (dir + "/" + name + ".png").c_str());
        cairo_surface_destroy(s);
    };
    auto quiet = [](float level, float bass = 0, float mid = 0, float treble = 0) {
        return [=](float) {
            AudioFeatures f;
            f.level = level;
            f.bass = bass;
            f.mid = mid;
            f.treble = treble;
            return f;
        };
    };

    struct Look {
        const char* name;
        float loud;
        DitherMode dither;
    };
    for (Look look : {Look{"calm", 0.1f, DitherMode::smooth}, Look{"loud", 1, DitherMode::smooth},
                      Look{"retro", 1, DitherMode::retro}}) {
        float t = 0, loud = look.loud;
        InstrumentPanel panel;
        Renderer r(shaders, [&](float dt) {
            t += dt;
            AudioFeatures f;
            for (int i = 0; i < AudioAnalyzer::bandCount; i++) {
                f.bands[i] = loud * (0.75f - float(i) / 140 + 0.2f * sinf(float(i) * 0.5f + t * 3));
            }
            f.bass = loud * 0.85f;
            f.mid = loud * 0.6f;
            f.treble = loud * 0.5f;
            f.level = loud * 0.7f;
            f.beat = loud * 0.6f;
            f.beatAge = loud > 0.5f ? fmodf(t, 0.5f) : 10;
            f.centroid = 0.4f;
            return f;
        });
        r.ditherMode = look.dither;
        r.onFrame = [&](const PanelInput& in, float dt) { panel.update(in, dt); };
        for (int i = 0; i < 180; i++) r.step(1.0f / 60, 1600, 900);
        if (std::string(look.name) != "calm") {
            r.placeObjectsForTesting();
            r.step(1.0f / 60, 1600, 900);
        }
        write(r, 1600, 900, look.name, [&](cairo_t* c) { panel.draw(c, 1600, 900); });
    }

    // Fly-throughs: deep inside a nebula and a galaxy.
    for (auto [name, galaxy, radius] : {std::tuple{"through_nebula", false, 12.0f}, std::tuple{"through_galaxy", true, 9.0f}}) {
        Renderer r(shaders, quiet(0.5f, 0, 0.5f, 0.4f));
        r.placeFlyThroughForTesting(galaxy, radius);
        r.step(1.0f / 60, 1600, 900);
        write(r, 1600, 900, name);
    }

    // Beat detector check: long, sustained kicks every 0.5 s for 10 s should give ~20 beats, not doubles.
    {
        AudioAnalyzer analyzer;
        const float rate = 48000;
        int beats = 0;
        float lastAge = INFINITY, t = 0;
        std::vector<float> buffer(800); // 1/60 s of audio
        for (int frame = 0; frame < 600; frame++) {
            for (size_t i = 0; i < buffer.size(); i++) {
                float time = t + float(i) / rate;
                float phase = fmodf(time, 0.5f);
                float env = phase < 0.4f ? expf(-phase * 2) : 0; // a long 0.4 s tail on each kick
                buffer[i] = sinf(2 * float(M_PI) * 60 * time) * 0.6f * env;
            }
            analyzer.push(buffer.data(), int(buffer.size()), rate);
            AudioFeatures f = analyzer.analyze(1.0f / 60);
            if (f.beatAge < lastAge) beats += 1;
            lastAge = f.beatAge;
            t += float(buffer.size()) / rate;
        }
        std::printf("beat check: %d beats from 20 kicks\n", beats);
    }

    // GPU cost of a frame with a black hole close by.
    {
        Renderer r(shaders, [](float) { return AudioFeatures(); });
        r.placeBlackHoleForTesting(30, 0, 0.8f / 3.7f);
        r.step(1.0f / 60, 1512, 900);
        write(r, 1512, 900, "bench");
        double t0 = nowSeconds();
        for (int i = 0; i < 10; i++) write(r, 1512, 900, "bench");
        double withHole = (nowSeconds() - t0) * 100;
        Renderer plain(shaders, [](float) { return AudioFeatures(); });
        plain.step(1.0f / 60, 1512, 900);
        write(plain, 1512, 900, "bench");
        double t1 = nowSeconds();
        for (int i = 0; i < 10; i++) write(plain, 1512, 900, "bench");
        double without = (nowSeconds() - t1) * 100;
        std::printf("frame with black hole %.1f ms, without %.1f ms (both incl. PNG write)\n", withHole, without);
        plain.cockpitGlass = true;
        plain.step(1.0f / 60, 1512, 900);
        write(plain, 1512, 900, "bench");
        double t2 = nowSeconds();
        for (int i = 0; i < 10; i++) write(plain, 1512, 900, "bench");
        std::printf("frame with cockpit glass %.1f ms (incl. PNG write)\n", (nowSeconds() - t2) * 100);
    }

    // Black hole variants: standard, quasar, bare, torus (seeds chosen so fract(seed * 3.7) picks each kind).
    for (auto [name, kindR] : {std::pair{"standard", 0.8f}, std::pair{"quasar", 0.25f}, std::pair{"bare", 0.05f},
                               std::pair{"torus", 0.45f}}) {
        Renderer r(shaders, [](float) { return AudioFeatures(); });
        for (int i = 0; i < 30; i++) r.step(1.0f / 60, 800, 450);
        r.placeBlackHoleForTesting(70, 0, kindR / 3.7f);
        r.step(1.0f / 60, 800, 450);
        write(r, 800, 450, std::string("bh_") + name);
    }

    // Fly-through artifact check: frames every 0.75 s while passing straight through clouds and a galaxy.
    for (auto [name, kind] : {std::pair{"emission", std::optional<float>(0)}, std::pair{"molecular", std::optional<float>(8)},
                              std::pair{"veil", std::optional<float>(7)}, std::pair{"galaxy", std::optional<float>()}}) {
        Renderer r(shaders, quiet(0.4f, 0.3f));
        r.startFlyTest(kind);
        for (int frame = 0; frame < 8; frame++) {
            for (int i = 0; i < 45; i++) r.step(1.0f / 60, 640, 360);
            write(r, 640, 360, std::string("fly_") + name + std::to_string(frame));
        }
    }

    // Galaxy gallery: one frame per type (seed chosen so that fract(seed * 11.3) picks it).
    struct GalaxyType {
        const char* name;
        float tr, arms, tilt;
    };
    for (GalaxyType g : {GalaxyType{"grand", 0.17f, 2, 35}, GalaxyType{"flocculent", 0.44f, 3, 30},
                         GalaxyType{"barred", 0.64f, 2, 25}, GalaxyType{"irregular", 0.81f, 2, 40},
                         GalaxyType{"ring", 0.94f, 2, 30}, GalaxyType{"lenticular", 0.25f, 0, 78},
                         GalaxyType{"elliptical", 0.75f, 0, 50}}) {
        Renderer r(shaders, quiet(0.3f));
        r.placeGalaxyForTesting(g.tr / 11.3f, g.arms, g.tilt);
        r.step(1.0f / 60, 800, 450);
        write(r, 800, 450, std::string("galaxy_") + g.name);
    }

    // One frame per cloud kind (nebulae 0-6, gas clouds 7-12).
    for (int k = 0; k <= 12; k++) {
        Renderer r(shaders, quiet(0.3f));
        r.placeNebulaForTesting(float(k));
        r.step(1.0f / 60, 800, 450);
        write(r, 800, 450, "kind" + std::to_string(k));
    }

    // Black hole: approaching, close, and the violent pass (with the console and its alarm).
    struct Pass {
        const char* name;
        float z, stress, seed;
    };
    for (Pass p : {Pass{"blackhole_far", 110, 0, 0.8f / 3.7f}, Pass{"blackhole_near", 45, 0.3f, 0.8f / 3.7f},
                   Pass{"blackhole_pass", 8, 0.9f, 0.8f / 3.7f}, Pass{"blackhole_torus_pass", 10, 0.6f, 0.45f / 3.7f}}) {
        InstrumentPanel panel;
        Renderer r(shaders, quiet(0.5f, 0.5f));
        r.onFrame = [&](const PanelInput& in, float dt) { panel.update(in, dt); };
        for (int i = 0; i < 60; i++) r.step(1.0f / 60, 1600, 900);
        r.placeBlackHoleForTesting(p.z, p.stress, p.seed);
        for (int i = 0; i < 12; i++) r.step(1.0f / 60, 1600, 900);
        write(r, 1600, 900, p.name, [&](cairo_t* c) { panel.draw(c, 1600, 900); });
    }

    // Cockpit canopy: scratched glass catching the light of a nebula, and of a black hole.
    for (auto [name, hole] : {std::pair{"cockpit_nebula", false}, std::pair{"cockpit_blackhole", true}}) {
        InstrumentPanel panel;
        Renderer r(shaders, quiet(0.5f, 0.4f));
        r.cockpitGlass = true;
        r.onFrame = [&](const PanelInput& in, float dt) { panel.update(in, dt); };
        for (int i = 0; i < 60; i++) r.step(1.0f / 60, 1600, 900);
        if (hole) r.placeBlackHoleForTesting(60, 0);
        else r.placeNebulaForTesting(0);
        r.step(1.0f / 60, 1600, 900);
        write(r, 1600, 900, name, [&](cairo_t* c) {
            drawCockpitFrame(c, 1600, 900);
            panel.draw(c, 1600, 900);
        });
    }

    // Fly-through sequence: one frame every 1.5 s while heading straight into a nebula.
    {
        Renderer pass(shaders, quiet(0.4f, 0.3f));
        pass.spawnFlyThrough(false);
        std::string trace;
        for (int frame = 0; frame < 10; frame++) {
            write(pass, 640, 360, "pass" + std::to_string(frame));
            char buf[32];
            if (auto d = pass.testObjectDepth()) std::snprintf(buf, sizeof(buf), "%.2f", *d);
            else std::snprintf(buf, sizeof(buf), "gone");
            trace += (frame ? " " : "") + std::string(buf);
            for (int i = 0; i < 90; i++) pass.step(1.0f / 60, 640, 360);
        }
        std::printf("fly-through depth every 1.5 s: %s\n", trace.c_str());
    }

    // Journey: follow a fresh nebula and galaxy from spawn until they leave the screen.
    {
        Renderer journey(shaders, quiet(0.4f, 0.3f));
        journey.spawnFreshForTesting();
        for (int frame = 0; frame < 5; frame++) {
            write(journey, 800, 450, "journey" + std::to_string(frame));
            for (int i = 0; i < 60 * 3; i++) journey.step(1.0f / 60, 800, 450);
        }
    }
    std::printf("Snapshots written to %s\n", dir.c_str());
}

// MARK: - Entry point

static void fatal(const std::string& message) {
    std::fprintf(stderr, "Nebula Drift: %s\n", message.c_str());
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Nebula Drift", message.c_str(), nullptr);
    std::exit(1);
}

int main(int argc, char** argv) {
    std::string snapshotDir, file;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--snapshot" && i + 1 < argc) snapshotDir = argv[++i];
        else if (a == "--help" || a == "-h") {
            std::printf("Usage: nebuladrift [audio-file] [--snapshot <output-folder>]\n");
            return 0;
        } else if (a.rfind("file://", 0) == 0) {
            file = a.substr(7);
        } else if (!a.empty() && a[0] != '-') {
            file = a;
        }
    }

    // NVIDIA's driver spins a CPU core while waiting for vsync unless told to sleep (ignored by other drivers).
    setenv("__GL_YIELD", "USLEEP", 0);
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
#ifdef SDL_HINT_APP_NAME
    SDL_SetHint(SDL_HINT_APP_NAME, "Nebula Drift");
#endif
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) fatal(std::string("Couldn't start SDL: ") + SDL_GetError());
    fileChosenEvent = SDL_RegisterEvents(1);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0);

    Uint32 flags = SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
    if (!snapshotDir.empty()) flags |= SDL_WINDOW_HIDDEN;
    int width = 1280, height = 780;
    SDL_Rect usable;
    if (snapshotDir.empty() && SDL_GetDisplayUsableBounds(0, &usable) == 0 && usable.w > 0 && usable.h > 0) {
        // Shrink to fit small screens, keeping the shape.
        double fit = std::min({1.0, usable.w * 0.92 / width, usable.h * 0.92 / height});
        width = int(width * fit);
        height = int(height * fit);
    }
    SDL_Window* window =
        SDL_CreateWindow("Nebula Drift", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, flags);
    if (!window) fatal(std::string("Couldn't open a window: ") + SDL_GetError());
    SDL_GLContext gl = SDL_GL_CreateContext(window);
    if (!gl) fatal(std::string("OpenGL 3.3 isn't available: ") + SDL_GetError());
    if (SDL_GL_SetSwapInterval(-1) != 0) SDL_GL_SetSwapInterval(1); // adaptive vsync if the driver has it

    std::string resources = resourceDir();
    loadLabelFont(resources + "/assets/BarlowCondensed-SemiBold.ttf");

    int status = 0;
    try {
        if (!snapshotDir.empty()) {
            mkdir(snapshotDir.c_str(), 0755);
            runSnapshot(resources, snapshotDir);
        } else {
            App app(window, resources, file);
            app.run();
        }
    } catch (const std::exception& e) {
        if (!snapshotDir.empty()) {
            std::fprintf(stderr, "Snapshot failed: %s\n", e.what());
            status = 1;
        } else {
            fatal(e.what());
        }
    }
    SDL_GL_DeleteContext(gl);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return status;
}
