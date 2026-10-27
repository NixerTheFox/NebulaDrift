#include "audio.h"

#include "miniaudio.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

double nowSeconds() {
    using namespace std::chrono;
    static const auto start = steady_clock::now();
    return duration<double>(steady_clock::now() - start).count();
}

// MARK: - Audio analysis

float AudioAnalyzer::bandFrequency(float i) {
    return minFreq * powf(maxFreq / minFreq, i / float(bandCount));
}

static int firstBand(float hz, int fallback) {
    for (int i = 0; i < AudioAnalyzer::bandCount; i++) {
        if (AudioAnalyzer::bandFrequency(float(i) + 0.5f) >= hz) return i;
    }
    return fallback;
}

int AudioAnalyzer::bassEnd = firstBand(160, 8);
int AudioAnalyzer::midEnd = firstBand(2500, 40);

AudioAnalyzer::AudioAnalyzer() {
    const int n = fftSize;
    window.resize(n);
    // Hann window, as vDSP's .hanningDenormalized (full, periodic).
    for (int i = 0; i < n; i++) window[i] = 0.5f * (1 - cosf(2 * float(M_PI) * float(i) / float(n)));
    buf.resize(n);
    twiddle.resize(n / 2);
    for (int k = 0; k < n / 2; k++) twiddle[k] = std::polar(1.0f, -2 * float(M_PI) * float(k) / float(n));
    bitrev.resize(n);
    int bits = 0;
    while ((1 << bits) < n) bits++;
    for (int i = 0; i < n; i++) {
        int r = 0;
        for (int b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
        bitrev[i] = r;
    }
}

/// In-place iterative radix-2 forward DFT of `buf` (unscaled, like vDSP's complex DFT).
void AudioAnalyzer::fft() {
    const int n = fftSize;
    for (int i = 0; i < n; i++) {
        if (i < bitrev[i]) std::swap(buf[i], buf[bitrev[i]]);
    }
    for (int len = 2; len <= n; len <<= 1) {
        int half = len / 2, step = n / len;
        for (int i = 0; i < n; i += len) {
            for (int j = 0; j < half; j++) {
                std::complex<float> t = twiddle[j * step] * buf[i + j + half];
                buf[i + j + half] = buf[i + j] - t;
                buf[i + j] += t;
            }
        }
    }
}

void AudioAnalyzer::push(const float* samples, int count, float rate) {
    std::lock_guard<std::mutex> guard(lock);
    sampleRate = rate;
    const int mask = int(ring.size()) - 1;
    int w = writeIndex;
    for (int i = 0; i < count; i++) {
        ring[w] = samples[i];
        w = (w + 1) & mask;
    }
    writeIndex = w;
    lastPush = nowSeconds();
    if (!heardSound) {
        for (int i = 0; i < count; i++) {
            if (fabsf(samples[i]) > 1e-4f) {
                heardSound = true;
                break;
            }
        }
    }
}

bool AudioAnalyzer::hasHeardSound() {
    std::lock_guard<std::mutex> guard(lock);
    return heardSound;
}

AudioFeatures AudioAnalyzer::analyze(float dt) {
    const int n = fftSize;
    std::vector<float> samples(n, 0.0f);
    lock.lock();
    bool live = lastPush >= 0 && nowSeconds() - lastPush < 0.35;
    float rate = sampleRate;
    if (live) {
        const int mask = int(ring.size()) - 1;
        int r = (writeIndex - n + int(ring.size())) & mask;
        for (int i = 0; i < n; i++) {
            samples[i] = ring[r];
            r = (r + 1) & mask;
        }
    }
    lock.unlock();

    std::array<float, bandCount> raw{};
    if (live) {
        if (rate != rangesRate) buildRanges(rate);
        for (int i = 0; i < n; i++) buf[i] = {samples[i] * window[i], 0.0f};
        fft();
        const float scale = 4 / float(n);
        for (int b = 0; b < bandCount; b++) {
            const Range& range = bandRanges[b];
            float m = 0;
            for (int k = range.lo; k <= range.hi; k++) m = std::max(m, std::abs(buf[k]));
            // dB with a gentle tilt so highs aren't drowned out by the bass.
            float db = 20 * log10f(m * scale + 1e-7f) + 3 * log2f(range.freq / 1000);
            raw[b] = std::clamp((db + 72) / 60, 0.0f, 1.0f);
        }
    }

    float attack = 1 - expf(-dt * 30);
    float release = 1 - expf(-dt * 6);
    for (int b = 0; b < bandCount; b++) {
        float v = raw[b], o = state.bands[b];
        state.bands[b] = o + (v - o) * (v > o ? attack : release);
    }

    auto mean = [](const std::array<float, bandCount>& a, int lo, int hi) {
        float s = 0;
        for (int i = lo; i < hi; i++) s += a[i];
        return s / float(std::max(hi - lo, 1));
    };

    // Beat detection: bass jumping above its recent average.
    float bassInst = mean(raw, 0, bassEnd);
    bassAvg += (bassInst - bassAvg) * (1 - expf(-dt * 2.5f));
    state.beatAge += dt;
    // One beat per hit: after firing, the bass must fall back toward its average before it can fire again,
    // so a long kick or a sustained bass note doesn't re-trigger (which made double rings).
    if (bassInst - bassAvg < 0.025f) beatArmed = true;
    if (live && beatArmed && bassInst - bassAvg > 0.07f && bassInst > 0.25f && state.beatAge > 0.3f) {
        beatArmed = false;
        state.beatAge = 0;
        state.beat = 1;
    }
    state.beat *= expf(-dt * 5);

    // Auto-gain so quiet and loud material both move the visuals.
    std::array<float, 4> v{mean(state.bands, 0, bassEnd), mean(state.bands, bassEnd, midEnd),
                           mean(state.bands, midEnd, bandCount), mean(state.bands, 0, bandCount)};
    std::array<float, 4> rel{}, shaped{};
    for (int i = 0; i < 4; i++) {
        peaks[i] = std::max(std::max(v[i], peaks[i] - dt * 0.05f), 0.2f);
        rel[i] = std::clamp(v[i] / peaks[i], 0.0f, 1.0f);
        shaped[i] = std::clamp((rel[i] - 0.3f) / 0.7f, 0.0f, 1.0f);
    }
    state.bass = shaped[0];
    state.mid = shaped[1];
    state.treble = shaped[2];
    state.level = rel[3] * rel[3];

    float weighted = 0, total = 1e-4f;
    for (int i = 0; i < bandCount; i++) {
        weighted += float(i) * state.bands[i];
        total += state.bands[i];
    }
    state.centroid += (weighted / total / float(bandCount) - state.centroid) * (1 - expf(-dt));
    return state;
}

void AudioAnalyzer::buildRanges(float rate) {
    const float n = float(fftSize);
    const int last = fftSize / 2 - 1;
    bandRanges.clear();
    for (int i = 0; i < bandCount; i++) {
        float lo = bandFrequency(float(i)), hi = bandFrequency(float(i + 1));
        int a = std::clamp(int(lo * n / rate), 1, last);
        int b = std::clamp(int(hi * n / rate), a, last);
        bandRanges.push_back({a, b, sqrtf(lo * hi)});
    }
    rangesRate = rate;
}

// MARK: - Audio sources

struct AudioSources::Impl {
    AudioAnalyzer* analyzer = nullptr;
    ma_context context{};
    bool contextReady = false;
    ma_device device{};
    bool deviceActive = false;
    ma_decoder decoder{};
    bool decoderActive = false;
    std::vector<float> mono = std::vector<float>(1 << 16);

    bool ensureContext() {
        if (!contextReady) contextReady = ma_context_init(nullptr, 0, nullptr, &context) == MA_SUCCESS;
        return contextReady;
    }

    void pushInterleaved(const float* data, ma_uint32 frames, ma_uint32 channels, float rate) {
        if (!data || frames == 0) return;
        if (channels <= 1) {
            analyzer->push(data, int(frames), rate);
            return;
        }
        ma_uint32 done = 0;
        while (done < frames) {
            ma_uint32 chunk = std::min<ma_uint32>(frames - done, ma_uint32(mono.size()));
            const float* src = data + size_t(done) * channels;
            for (ma_uint32 i = 0; i < chunk; i++) {
                float s = 0;
                for (ma_uint32 c = 0; c < channels; c++) s += src[i * channels + c];
                mono[i] = s / float(channels);
            }
            analyzer->push(mono.data(), int(chunk), rate);
            done += chunk;
        }
    }

    static void captureCallback(ma_device* d, void*, const void* input, ma_uint32 frames) {
        auto* self = static_cast<Impl*>(d->pUserData);
        self->pushInterleaved(static_cast<const float*>(input), frames, d->capture.channels, float(d->sampleRate));
    }

    static void playbackCallback(ma_device* d, void* output, const void*, ma_uint32 frames) {
        auto* self = static_cast<Impl*>(d->pUserData);
        auto* out = static_cast<float*>(output);
        ma_uint64 read = 0;
        ma_data_source_read_pcm_frames(&self->decoder, out, frames, &read);
        if (read < frames) {
            std::memset(out + read * d->playback.channels, 0,
                        size_t(frames - read) * d->playback.channels * sizeof(float));
        }
        self->pushInterleaved(out, frames, d->playback.channels, float(d->sampleRate));
    }

    bool openCapture(const ma_device_id* id) {
        ma_device_config config = ma_device_config_init(ma_device_type_capture);
        config.capture.pDeviceID = id;
        config.capture.format = ma_format_f32;
        config.capture.channels = 2;
        config.sampleRate = 0; // the device's own rate
        config.dataCallback = captureCallback;
        config.pUserData = this;
        if (ma_device_init(&context, &config, &device) != MA_SUCCESS) return false;
        if (ma_device_start(&device) != MA_SUCCESS) {
            ma_device_uninit(&device);
            return false;
        }
        deviceActive = true;
        return true;
    }

    /// The monitor of the default output: everything the computer is playing.
    bool openMonitor() {
        if (context.backend == ma_backend_pulseaudio) {
            ma_device_id id;
            std::memset(&id, 0, sizeof(id));
            std::strncpy(id.pulse, "@DEFAULT_MONITOR@", sizeof(id.pulse) - 1);
            if (openCapture(&id)) return true;
        }
        // Otherwise look for any capture device that is a monitor or loopback of an output.
        ma_device_info* captures = nullptr;
        ma_uint32 count = 0;
        if (ma_context_get_devices(&context, nullptr, nullptr, &captures, &count) != MA_SUCCESS) return false;
        for (ma_uint32 i = 0; i < count; i++) {
            std::string name = captures[i].name;
            std::string lower = name;
            std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
            if (lower.find("monitor") != std::string::npos || lower.find("loopback") != std::string::npos) {
                ma_device_id id = captures[i].id;
                if (openCapture(&id)) return true;
            }
        }
        return false;
    }

    void stop() {
        if (deviceActive) {
            ma_device_uninit(&device);
            deviceActive = false;
        }
        if (decoderActive) {
            ma_decoder_uninit(&decoder);
            decoderActive = false;
        }
    }
};

AudioSources::AudioSources(AudioAnalyzer& a) : analyzer(a), impl(std::make_unique<Impl>()) {
    impl->analyzer = &a;
}

AudioSources::~AudioSources() {
    stopAll();
    if (impl->contextReady) ma_context_uninit(&impl->context);
}

void AudioSources::stopAll() {
    generation += 1;
    impl->stop();
}

void AudioSources::startSystemAudio() {
    stopAll();
    if (!impl->ensureContext() || !impl->openMonitor()) {
        if (onStatus) {
            onStatus("Couldn't capture system audio (needs PulseAudio or PipeWire). Press M for the mic or O to open "
                     "a file.");
        }
        return;
    }
    if (onStatus) onStatus("System audio");
    // A missing or muted monitor doesn't raise an error, it just delivers silence.
    silenceCheckAt = nowSeconds() + 10;
    silenceGeneration = generation;
}

void AudioSources::startMicrophone() {
    stopAll();
    if (!impl->ensureContext() || !impl->openCapture(nullptr)) {
        if (onStatus) onStatus("No microphone input available");
        return;
    }
    if (onStatus) onStatus("Microphone");
}

static std::string baseName(const std::string& path, bool dropExtension) {
    size_t slash = path.find_last_of('/');
    std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
    if (dropExtension) {
        size_t dot = name.find_last_of('.');
        if (dot != std::string::npos && dot > 0) name = name.substr(0, dot);
    }
    return name;
}

void AudioSources::play(const std::string& path) {
    stopAll();
    auto fail = [&](const std::string& why) {
        impl->stop();
        if (onStatus) onStatus("Couldn't play " + baseName(path, false) + ": " + why);
    };
    if (!impl->ensureContext()) return fail("no audio output");
    ma_decoder_config dc = ma_decoder_config_init(ma_format_f32, 2, 48000);
    if (ma_decoder_init_file(path.c_str(), &dc, &impl->decoder) != MA_SUCCESS) {
        return fail("unsupported or unreadable file (MP3, FLAC, WAV and Ogg Vorbis work)");
    }
    impl->decoderActive = true;
    ma_data_source_set_looping(&impl->decoder, MA_TRUE);

    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = 48000;
    config.dataCallback = Impl::playbackCallback;
    config.pUserData = impl.get();
    if (ma_device_init(&impl->context, &config, &impl->device) != MA_SUCCESS) return fail("no audio output");
    impl->deviceActive = true;
    if (ma_device_start(&impl->device) != MA_SUCCESS) return fail("couldn't start the audio output");
    if (onStatus) onStatus("Playing " + baseName(path, true));
}

void AudioSources::poll() {
    if (silenceCheckAt < 0 || nowSeconds() < silenceCheckAt) return;
    silenceCheckAt = -1;
    if (silenceGeneration != generation || analyzer.hasHeardSound()) return;
    if (onStatus) {
        onStatus("Only silence so far. Play something, or check that your sound server records the monitor of your "
                 "output (pavucontrol › Recording).");
    }
}
