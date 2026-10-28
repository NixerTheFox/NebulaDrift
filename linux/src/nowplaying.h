// What's playing: the system's media players over MPRIS (D-Bus), or the tags of an opened file.

#pragma once

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

struct Track {
    std::string title, artist;
    bool playing = true;
};

class NowPlaying {
public:
    NowPlaying() = default;
    ~NowPlaying();
    NowPlaying(const NowPlaying&) = delete;
    NowPlaying& operator=(const NowPlaying&) = delete;

    /// Starts asking the session's media players (in the background, every second or two).
    void start();
    /// The track a media player reports, preferring one that is playing over a paused one.
    std::optional<Track> current();

    /// Title and artist from a file's tags (ID3v2, FLAC, Ogg Vorbis or Opus comments), else from its name.
    static Track fromFile(const std::string& path);

private:
    void poll();

    std::thread thread;
    std::mutex mutex;
    std::condition_variable wake;
    bool stopping = false;
    std::optional<Track> track;
};
