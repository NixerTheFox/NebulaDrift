// Audio analysis and sources: system audio (the default output's monitor), microphone, or a file.

#pragma once

#include <array>
#include <complex>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

double nowSeconds();

struct AudioFeatures {
    static constexpr int bandCount = 64;
    std::array<float, bandCount> bands{};
    float bass = 0;
    float mid = 0;
    float treble = 0;
    float level = 0;
    float beat = 0;
    float beatAge = 10;
    float centroid = 0.5f;
};

class AudioAnalyzer {
public:
    static constexpr int fftSize = 2048;
    static constexpr int bandCount = AudioFeatures::bandCount;
    static constexpr float minFreq = 30;
    static constexpr float maxFreq = 16000;

    static float bandFrequency(float i);

    AudioAnalyzer();

    /// Called from audio threads with mono samples.
    void push(const float* samples, int count, float sampleRate);
    AudioFeatures analyze(float dt);
    bool hasHeardSound();

private:
    struct Range {
        int lo, hi;
        float freq;
    };

    void buildRanges(float rate);
    void fft();

    static int bassEnd, midEnd;

    std::mutex lock;
    std::vector<float> ring = std::vector<float>(16384); // power of two
    int writeIndex = 0;
    double lastPush = -1;
    float sampleRate = 48000;
    bool heardSound = false;

    std::vector<float> window;
    std::vector<std::complex<float>> buf, twiddle;
    std::vector<int> bitrev;
    std::vector<Range> bandRanges;
    float rangesRate = 0;

    AudioFeatures state;
    std::array<float, 4> peaks{0.3f, 0.3f, 0.3f, 0.3f};
    float bassAvg = 0;
    bool beatArmed = true;
};

/// Owns whichever source is running. Status messages are delivered on the caller's thread from poll().
class AudioSources {
public:
    explicit AudioSources(AudioAnalyzer& analyzer);
    ~AudioSources();

    std::function<void(const std::string&)> onStatus;

    void stopAll();
    void startSystemAudio();
    void startMicrophone();
    void play(const std::string& path);
    /// Call once per frame: runs delayed checks (silence warnings).
    void poll();

    struct Impl;

private:
    AudioAnalyzer& analyzer;
    std::unique_ptr<Impl> impl;
    int generation = 0;
    double silenceCheckAt = -1;
    int silenceGeneration = -1;
};
