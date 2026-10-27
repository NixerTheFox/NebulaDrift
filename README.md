# Nebula Drift

An audio visualizer for macOS. You fly through space while the music drives everything you see: stars stream past, nebulae, gas clouds and galaxies grow from distant specks into vast clouds you fly through, beats send shockwaves across the view, and on very rare occasions you pass a black hole that bends light around it. A retro spacecraft console with Nixie tubes, VU meters and sliders reacts to the sound below the view.

Written in Swift with Metal shaders. No Xcode project, no dependencies.

## Requirements

- macOS 14.2 or later (system audio capture uses Core Audio process taps)
- Apple's command line tools (`xcode-select --install`) for `swiftc`

## Build and run

```bash
./build.sh
open "build/Nebula Drift.app"
```

On first launch macOS asks for **System Audio Recording** permission so the app can hear what your Mac is playing. You can also use the microphone or open an audio file instead.

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

Settings are remembered between launches.

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

## Test renders

Renders a set of test frames (every nebula, galaxy and black hole type, fly-throughs, the console) without opening a window:

```bash
"build/Nebula Drift.app/Contents/MacOS/NebulaDrift" --snapshot /path/to/output-folder
```
