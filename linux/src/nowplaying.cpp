#include "nowplaying.h"

#include <dlfcn.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <type_traits>
#include <vector>

// MARK: - MPRIS over D-Bus

// libdbus is loaded at run time (it is on every desktop), so neither building nor running needs it.
namespace {

struct DBusError {
    const char* name;
    const char* message;
    unsigned int bits;
    void* padding;
};

/// Larger than libdbus's own (opaque) iterator, which is all that matters: it is only passed by pointer.
struct DBusMessageIter {
    void* storage[16];
};

enum { busSession = 0, typeInvalid = 0, typeString = 's', typeArray = 'a', typeVariant = 'v', typeDictEntry = 'e' };

struct DBus {
    void* lib = nullptr;
    void (*errorInit)(DBusError*) = nullptr;
    void (*errorFree)(DBusError*) = nullptr;
    uint32_t (*errorIsSet)(const DBusError*) = nullptr;
    void* (*busGetPrivate)(int, DBusError*) = nullptr;
    void (*setExitOnDisconnect)(void*, uint32_t) = nullptr;
    uint32_t (*connected)(void*) = nullptr;
    void (*close)(void*) = nullptr;
    void (*unref)(void*) = nullptr;
    void* (*newMethodCall)(const char*, const char*, const char*, const char*) = nullptr;
    uint32_t (*appendArgs)(void*, int, ...) = nullptr;
    void* (*sendWithReplyAndBlock)(void*, void*, int, DBusError*) = nullptr;
    void (*messageUnref)(void*) = nullptr;
    uint32_t (*iterInit)(void*, DBusMessageIter*) = nullptr;
    int (*argType)(DBusMessageIter*) = nullptr;
    void (*recurse)(DBusMessageIter*, DBusMessageIter*) = nullptr;
    uint32_t (*next)(DBusMessageIter*) = nullptr;
    void (*getBasic)(DBusMessageIter*, void*) = nullptr;

    bool load() {
        lib = dlopen("libdbus-1.so.3", RTLD_NOW | RTLD_LOCAL);
        if (!lib) return false;
        auto sym = [&](auto& f, const char* name) {
            f = reinterpret_cast<std::remove_reference_t<decltype(f)>>(dlsym(lib, name));
            return f != nullptr;
        };
        return sym(errorInit, "dbus_error_init") && sym(errorFree, "dbus_error_free") &&
               sym(errorIsSet, "dbus_error_is_set") && sym(busGetPrivate, "dbus_bus_get_private") &&
               sym(setExitOnDisconnect, "dbus_connection_set_exit_on_disconnect") &&
               sym(connected, "dbus_connection_get_is_connected") && sym(close, "dbus_connection_close") &&
               sym(unref, "dbus_connection_unref") && sym(newMethodCall, "dbus_message_new_method_call") &&
               sym(appendArgs, "dbus_message_append_args") &&
               sym(sendWithReplyAndBlock, "dbus_connection_send_with_reply_and_block") &&
               sym(messageUnref, "dbus_message_unref") && sym(iterInit, "dbus_message_iter_init") &&
               sym(argType, "dbus_message_iter_get_arg_type") && sym(recurse, "dbus_message_iter_recurse") &&
               sym(next, "dbus_message_iter_next") && sym(getBasic, "dbus_message_iter_get_basic");
    }
};

std::string stringAt(DBus& d, DBusMessageIter* it) {
    const char* s = nullptr;
    d.getBasic(it, &s);
    return s ? s : "";
}

/// A variant's string, or the first string of a variant's string array.
std::string variantString(DBus& d, DBusMessageIter* variant) {
    DBusMessageIter v;
    d.recurse(variant, &v);
    if (d.argType(&v) == typeString) return stringAt(d, &v);
    if (d.argType(&v) == typeArray) {
        DBusMessageIter a;
        d.recurse(&v, &a);
        if (d.argType(&a) == typeString) return stringAt(d, &a);
    }
    return "";
}

class Session {
public:
    explicit Session(DBus& d) : d(d) {}
    ~Session() { disconnect(); }

    bool connect() {
        if (conn && d.connected(conn)) return true;
        disconnect();
        DBusError err;
        d.errorInit(&err);
        conn = d.busGetPrivate(busSession, &err);
        if (d.errorIsSet(&err)) d.errorFree(&err);
        if (conn) d.setExitOnDisconnect(conn, 0);
        return conn != nullptr;
    }

    std::vector<std::string> players() {
        std::vector<std::string> out;
        void* reply = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames");
        if (!reply) return out;
        DBusMessageIter it, a;
        if (d.iterInit(reply, &it) && d.argType(&it) == typeArray) {
            d.recurse(&it, &a);
            while (d.argType(&a) == typeString) {
                std::string name = stringAt(d, &a);
                if (name.rfind("org.mpris.MediaPlayer2.", 0) == 0) out.push_back(name);
                d.next(&a);
            }
        }
        d.messageUnref(reply);
        std::sort(out.begin(), out.end());
        return out;
    }

    /// A player property, as a reply message holding one variant (to be released with messageUnref).
    void* property(const std::string& player, const char* name) {
        return call(player.c_str(), "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "Get",
                    "org.mpris.MediaPlayer2.Player", name);
    }

    std::string status(const std::string& player) {
        void* reply = property(player, "PlaybackStatus");
        if (!reply) return "";
        std::string s;
        DBusMessageIter it;
        if (d.iterInit(reply, &it) && d.argType(&it) == typeVariant) s = variantString(d, &it);
        d.messageUnref(reply);
        return s;
    }

    Track metadata(const std::string& player) {
        Track t;
        void* reply = property(player, "Metadata");
        if (!reply) return t;
        DBusMessageIter it, v, a, e;
        if (d.iterInit(reply, &it) && d.argType(&it) == typeVariant) {
            d.recurse(&it, &v);
            if (d.argType(&v) == typeArray) {
                d.recurse(&v, &a);
                while (d.argType(&a) == typeDictEntry) {
                    d.recurse(&a, &e);
                    std::string key = d.argType(&e) == typeString ? stringAt(d, &e) : "";
                    if (d.next(&e) && d.argType(&e) == typeVariant) {
                        if (key == "xesam:title") t.title = variantString(d, &e);
                        else if (key == "xesam:artist") t.artist = variantString(d, &e);
                    }
                    d.next(&a);
                }
            }
        }
        d.messageUnref(reply);
        return t;
    }

private:
    void* call(const char* dest, const char* path, const char* iface, const char* method, const char* arg1 = nullptr,
               const char* arg2 = nullptr) {
        void* msg = d.newMethodCall(dest, path, iface, method);
        if (!msg) return nullptr;
        if (arg1) d.appendArgs(msg, typeString, &arg1, typeString, &arg2, typeInvalid);
        DBusError err;
        d.errorInit(&err);
        void* reply = d.sendWithReplyAndBlock(conn, msg, 400, &err);
        if (d.errorIsSet(&err)) d.errorFree(&err);
        d.messageUnref(msg);
        return reply;
    }

    void disconnect() {
        if (!conn) return;
        d.close(conn);
        d.unref(conn);
        conn = nullptr;
    }

    DBus& d;
    void* conn = nullptr;
};

} // namespace

NowPlaying::~NowPlaying() {
    {
        std::lock_guard<std::mutex> lock(mutex);
        stopping = true;
    }
    wake.notify_all();
    if (thread.joinable()) thread.join();
}

void NowPlaying::start() {
    if (!thread.joinable()) thread = std::thread([this] { poll(); });
}

std::optional<Track> NowPlaying::current() {
    std::lock_guard<std::mutex> lock(mutex);
    return track;
}

void NowPlaying::poll() {
    DBus d;
    if (!d.load()) return;
    Session session(d);
    std::unique_lock<std::mutex> lock(mutex);
    while (!stopping) {
        lock.unlock();
        std::optional<Track> found;
        bool online = session.connect();
        if (online) {
            // The first player that is playing; failing that, the first paused one.
            std::string paused;
            for (const std::string& p : session.players()) {
                std::string s = session.status(p);
                if (s == "Playing") {
                    found = session.metadata(p);
                    break;
                }
                if (s == "Paused" && paused.empty()) paused = p;
            }
            if (!found && !paused.empty()) {
                found = session.metadata(paused);
                found->playing = false;
            }
            if (found && found->title.empty() && found->artist.empty()) found.reset();
        }
        lock.lock();
        track = found;
        wake.wait_for(lock, std::chrono::milliseconds(online ? 1500 : 6000), [this] { return stopping; });
    }
}

// MARK: - File tags

namespace {

void appendUTF8(std::string& out, uint32_t cp) {
    if (cp < 0x80) {
        out += char(cp);
    } else if (cp < 0x800) {
        out += char(0xC0 | (cp >> 6));
        out += char(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += char(0xE0 | (cp >> 12));
        out += char(0x80 | ((cp >> 6) & 0x3F));
        out += char(0x80 | (cp & 0x3F));
    } else {
        out += char(0xF0 | (cp >> 18));
        out += char(0x80 | ((cp >> 12) & 0x3F));
        out += char(0x80 | ((cp >> 6) & 0x3F));
        out += char(0x80 | (cp & 0x3F));
    }
}

/// An ID3v2 text frame's value (encoding byte, then the text) as UTF-8; the first of several values.
std::string id3Text(const uint8_t* p, size_t n) {
    if (n < 1) return "";
    uint8_t enc = p[0];
    p++;
    n--;
    std::string out;
    if (enc == 1 || enc == 2) {
        bool big = enc == 2;
        size_t i = 0;
        if (n >= 2 && ((p[0] == 0xFF && p[1] == 0xFE) || (p[0] == 0xFE && p[1] == 0xFF))) {
            big = p[0] == 0xFE;
            i = 2;
        }
        for (; i + 1 < n; i += 2) {
            uint32_t u = big ? (p[i] << 8 | p[i + 1]) : (p[i + 1] << 8 | p[i]);
            if (u == 0) break;
            if (u >= 0xD800 && u < 0xDC00 && i + 3 < n) {
                uint32_t lo = big ? (p[i + 2] << 8 | p[i + 3]) : (p[i + 3] << 8 | p[i + 2]);
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
            appendUTF8(out, u);
        }
    } else {
        for (size_t i = 0; i < n && p[i]; i++) {
            if (enc == 3) out += char(p[i]);
            else appendUTF8(out, p[i]); // ISO-8859-1
        }
    }
    return out;
}

void readID3(const std::vector<uint8_t>& b, Track& t) {
    if (b.size() < 10) return;
    int version = b[3];
    auto syncsafe = [&](size_t i) { return (b[i] & 0x7F) << 21 | (b[i + 1] & 0x7F) << 14 | (b[i + 2] & 0x7F) << 7 | (b[i + 3] & 0x7F); };
    size_t end = std::min(b.size(), size_t(10 + syncsafe(6)));
    size_t i = 10;
    if (b[5] & 0x40 && version >= 3 && i + 4 <= end) { // extended header
        i += version == 4 ? syncsafe(i) : (b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3]) + 4;
    }
    int idLen = version == 2 ? 3 : 4, header = version == 2 ? 6 : 10;
    while (i + header <= end && b[i] != 0) {
        std::string id(reinterpret_cast<const char*>(&b[i]), idLen);
        size_t size = version == 2   ? (b[i + 3] << 16 | b[i + 4] << 8 | b[i + 5])
                      : version == 4 ? syncsafe(i + 4)
                                     : size_t(b[i + 4]) << 24 | b[i + 5] << 16 | b[i + 6] << 8 | b[i + 7];
        i += header;
        if (size > end - i) break;
        if (id == "TIT2" || id == "TT2") t.title = id3Text(&b[i], size);
        if (id == "TPE1" || id == "TP1") t.artist = id3Text(&b[i], size);
        i += size;
    }
}

/// Vorbis comments (FLAC, Ogg Vorbis, Opus) starting at the vendor string's length.
void readVorbisComments(const std::vector<uint8_t>& b, size_t i, Track& t) {
    auto u32 = [&](size_t k) { return uint32_t(b[k]) | uint32_t(b[k + 1]) << 8 | uint32_t(b[k + 2]) << 16 | uint32_t(b[k + 3]) << 24; };
    if (i + 4 > b.size()) return;
    i += 4 + size_t(u32(i));
    if (i + 4 > b.size()) return;
    uint32_t count = u32(i);
    i += 4;
    for (uint32_t k = 0; k < count && i + 4 <= b.size(); k++) {
        size_t len = u32(i);
        i += 4;
        if (len > b.size() - i) break;
        std::string entry(reinterpret_cast<const char*>(&b[i]), len);
        i += len;
        size_t eq = entry.find('=');
        if (eq == std::string::npos) continue;
        std::string key = entry.substr(0, eq);
        std::transform(key.begin(), key.end(), key.begin(), ::toupper);
        if (key == "TITLE" && t.title.empty()) t.title = entry.substr(eq + 1);
        if (key == "ARTIST" && t.artist.empty()) t.artist = entry.substr(eq + 1);
    }
}

void readFLAC(const std::vector<uint8_t>& b, Track& t) {
    size_t i = 4;
    while (i + 4 <= b.size()) {
        bool last = b[i] & 0x80;
        int type = b[i] & 0x7F;
        size_t len = b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
        i += 4;
        if (type == 4) {
            readVorbisComments(b, i, t);
            return;
        }
        i += len;
        if (last) break;
    }
}

size_t find(const std::vector<uint8_t>& b, const char* needle, size_t n) {
    auto it = std::search(b.begin(), b.end(), needle, needle + n);
    return it == b.end() ? std::string::npos : size_t(it - b.begin());
}

} // namespace

Track NowPlaying::fromFile(const std::string& path) {
    Track t;
    std::ifstream in(path, std::ios::binary);
    std::vector<uint8_t> b(1 << 18);
    in.read(reinterpret_cast<char*>(b.data()), std::streamsize(b.size()));
    b.resize(size_t(std::max<std::streamsize>(in.gcount(), 0)));
    if (b.size() >= 10 && std::memcmp(b.data(), "ID3", 3) == 0) {
        size_t full = 10 + ((b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F));
        if (full > b.size() && full < (16u << 20)) { // big embedded cover art: read the whole tag
            in.clear();
            in.seekg(0);
            b.resize(full);
            in.read(reinterpret_cast<char*>(b.data()), std::streamsize(full));
            b.resize(size_t(std::max<std::streamsize>(in.gcount(), 0)));
        }
        readID3(b, t);
    } else if (b.size() >= 4 && std::memcmp(b.data(), "fLaC", 4) == 0) {
        readFLAC(b, t);
    } else if (b.size() >= 4 && std::memcmp(b.data(), "OggS", 4) == 0) {
        size_t at = find(b, "\x03vorbis", 7);
        if (at != std::string::npos) readVorbisComments(b, at + 7, t);
        else if ((at = find(b, "OpusTags", 8)) != std::string::npos) readVorbisComments(b, at + 8, t);
    }
    if (t.title.empty()) {
        // "Artist - Title.mp3", or just the name.
        std::string name = path.substr(path.find_last_of('/') + 1);
        size_t dot = name.find_last_of('.');
        if (dot != std::string::npos && dot > 0) name = name.substr(0, dot);
        size_t dash = name.find(" - ");
        if (dash != std::string::npos && t.artist.empty()) {
            t.artist = name.substr(0, dash);
            t.title = name.substr(dash + 3);
        } else {
            t.title = name;
        }
    }
    return t;
}
