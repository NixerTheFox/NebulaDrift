# Nebula Drift

An audio visualizer for macOS and Linux. You fly through space while the music drives everything you see: stars stream past, nebulae, gas clouds and galaxies grow from distant specks into vast clouds you fly through, beats send shockwaves across the view, and on very rare occasions you pass a black hole that bends light around it. A retro spacecraft console with Nixie tubes, VU meters and sliders reacts to the sound below the view.

The macOS app is written in Swift with Metal shaders (no Xcode project, no dependencies). The Linux version in [`linux/`](linux) is a port to C++ with OpenGL, SDL2 and Cairo, packaged as an AppImage.

## macOS

Download `Nebula_Drift-macOS.zip` from the [latest release](https://github.com/NixerTheFox/NebulaDrift/releases/latest), or build it yourself. The app isn't notarized: the first time, right-click it and choose **Open**.

### Requirements

- macOS 14.2 or later (system audio capture uses Core Audio process taps)
- Apple's command line tools (`xcode-select --install`) for `swiftc`

### Build and run

```bash
./build.sh
open "build/Nebula Drift.app"
```

On first launch macOS asks for **System Audio Recording** permission so the app can hear what your Mac is playing. You can also use the microphone or open an audio file instead.

## Linux

### AppImage

Download `Nebula_Drift-x86_64.AppImage` from the [latest release](https://github.com/NixerTheFox/NebulaDrift/releases/latest) (every push that touches `linux/` also builds one in GitHub Actions, under the run's artifacts). Then:

```bash
chmod +x Nebula_Drift-x86_64.AppImage
./Nebula_Drift-x86_64.AppImage            # or pass an audio file to play it
```

It needs OpenGL 3.3 (any Mesa, NVIDIA or AMD driver from the last decade) and glibc 2.35 or later (Ubuntu 22.04, Debian 12, Fedora 36 and newer). If it can't start for lack of FUSE (some containers and minimal installs), run it with `--appimage-extract-and-run`.

- **System audio** is recorded from the monitor of your default output, so it needs PulseAudio or PipeWire (with `pipewire-pulse`, the default almost everywhere). No permission prompt is involved. If it stays silent, check in `pavucontrol` › Recording that Nebula Drift records a "Monitor of …" source.
- **Open file** (O) uses `zenity` or `kdialog` if installed; dragging a file onto the window always works. MP3, FLAC, WAV and Ogg Vorbis play.
- **Q** switches between standard and full HiDPI resolution on a scaled display, and between full and half resolution (faster on weak GPUs) on a normal one. **F11** also toggles full screen, **Ctrl-Q** quits.

### Build it yourself

```bash
sudo apt install cmake g++ libsdl2-dev libcairo2-dev libfreetype-dev libgl-dev   # Debian/Ubuntu
cd linux
cmake -S . -B build && cmake --build build -j
./build/nebuladrift

./build-appimage.sh   # packages build/Nebula_Drift-<arch>.AppImage (downloads linuxdeploy)
```

On Fedora the packages are `cmake gcc-c++ SDL2-devel cairo-devel freetype-devel mesa-libGL-devel`; on Arch `cmake sdl2 cairo freetype2 mesa`.

## Controls

| Key | Action |
| --- | --- |
| S | Listen to system audio |
| M | Listen to the microphone |
| O | Open an audio file (or drag one onto the window) |
| F | Full screen (Esc to leave) |
| I | Show or hide the instrument console |
| G | Cockpit canopy: scratched thick glass and a hull frame |
| P | Performance stats (FPS, CPU, GPU) |
| T | Fly straight into the next nebula, gas cloud or galaxy |
| B | Summon a black hole |
| D | Dither style: off, smooth, retro |
| Shift-D | Dither strength |
| C | Chromatic aberration on or off |
| Q | Render quality: standard or Retina |
| H | Show or hide the key hints |

Settings are remembered between launches (on Linux in `~/.config/nebuladrift/settings`).

## What's in the sky

- **Gas clouds** (60% of sightings): veil filaments, molecular clouds, cirrus, pillars, bubbles, tendrils
- **Nebulae** (30%): emission, reflection, planetary, supernova remnant, dark, bipolar, rosette
- **Galaxies** (9%): grand-design, flocculent, barred, irregular, ring, lenticular, elliptical, as tilted 3D discs
- **Black holes** (under 1%): ray-traced with gravitational lensing and a volumetric accretion disc, in standard, quasar (with jets), torus and bare variants. Passing one sends the instruments haywire.

## Project layout

| File | Contents |
| --- | --- |
| `Sources/main.swift` | App, audio capture and analysis, beat detection, simulation, renderer |
| `Sources/Shaders.metal` | Nebulae, galaxies, stars, black hole ray tracer, post effects (loaded at runtime) |
| `Sources/Instruments.swift` | The spacecraft console |
| `Sources/Cockpit.swift` | The canopy frame |
| `Sources/Stats.swift` | Performance overlay |
| `linux/src/main.cpp` | Linux app: SDL2 window, keys, HUD and stats overlays, settings, test renders |
| `linux/src/audio.cpp` | Audio analysis and beat detection; capture and playback through miniaudio |
| `linux/src/renderer.cpp` | Simulation and the OpenGL passes |
| `linux/shaders/` | GLSL port of `Shaders.metal` (loaded at runtime) |
| `linux/src/instruments.cpp`, `cockpit.cpp`, `draw.cpp` | The console and canopy frame, drawn with Cairo |
| `linux/third_party/` | [miniaudio](https://miniaud.io) and [stb_vorbis](https://github.com/nothings/stb) (public domain / MIT-0) |
| `linux/assets/` | Barlow Condensed, the console's label font (SIL Open Font License) |

## Test renders

Renders a set of test frames (every nebula, galaxy and black hole type, fly-throughs, the console) without opening a window:

```bash
"build/Nebula Drift.app/Contents/MacOS/NebulaDrift" --snapshot /path/to/output-folder   # macOS
linux/build/nebuladrift --snapshot /path/to/output-folder                              # Linux (xvfb-run works headless)
```
