**Nebula Drift 1.0 is the first release, for macOS and Linux.**

> This app is 100% made with AI: every line of code, the shaders and the instruments were written by AI. All the ideas behind it come directly from me.

An audio visualizer: you fly through space while the music drives everything you see. Stars stream past, nebulae, gas clouds and galaxies grow from distant specks into vast clouds you fly through, beats send shockwaves across the view, and on very rare occasions you pass a black hole that bends light around it. A retro spacecraft console reacts to the sound below the view.

## What's in it

- **Gas clouds**: veil filaments, molecular clouds, cirrus, pillars, bubbles, tendrils
- **Nebulae**: emission, reflection, planetary, supernova remnant, dark, bipolar, rosette
- **Galaxies**: grand-design, flocculent, barred, irregular, ring, lenticular and elliptical, as tilted 3D discs you can fly through
- **Black holes** (rare): ray-traced gravitational lensing and a glowing accretion disc, in standard, quasar (with jets), torus and bare variants. Passing one sends the instruments haywire.
- **Spacecraft console**: Nixie tubes, VU meters, faders, an oscilloscope, a distance counter, knobs and status lamps, all driven by the music
- **Cockpit canopy** (G): scratched thick glass that catches the light, in a riveted hull frame
- **Look**: smooth or retro dithering, chromatic aberration, and a beat-driven warp speed
- **Sound sources**: what your computer is playing, the microphone, or an audio file

Press **H** in the app to see all the keys.

## Download

**macOS** (14.2 or later, Apple silicon and Intel): download `Nebula_Drift-macOS.zip`, unzip it and move **Nebula Drift** to Applications. The app isn't notarized, so the first time right-click it and choose **Open** (or run `xattr -dr com.apple.quarantine "/Applications/Nebula Drift.app"`). Allow **System Audio Recording** when asked.

**Linux** (x86-64; Ubuntu 22.04, Debian 12, Fedora 36 or newer): download `Nebula_Drift-x86_64.AppImage`, run `chmod +x Nebula_Drift-x86_64.AppImage`, then start it. System audio is captured through PulseAudio or PipeWire. Opening files uses `zenity` or `kdialog` if installed; dragging a file onto the window always works. MP3, FLAC, WAV and Ogg Vorbis play.

## Known limitations

- The macOS app is ad-hoc signed, not notarized by Apple.
- The Linux AppImage is x86-64 only.
