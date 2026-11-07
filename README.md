# EdgePal

The edges of your Mac trackpad, put to work. A native Swift menu bar app for Apple silicon Macs on macOS 14 or later.

| Where | What |
|---|---|
| Right edge | Press until it clicks, slide up or down: volume, with the real macOS indicator |
| Left edge | Brightness of the built-in screen |
| Bottom edge | Scrub whatever is playing (YouTube in Safari or Chrome, Music, Spotify, QuickTime). A preview shows where it will land; let go to jump |
| Top corners | Click 1 to 4 times: mute, play/pause, open an app (click again to hide it), open a link, press a key combination, or run a Shortcut |

The middle of the trackpad works as before. A gesture only starts with **one finger, inside an edge strip, and a physical click**. Palms, two-finger clicks, typing and scrolling never count. Every step gives a haptic tick, and the pointer stays where it was. Hold ⇧⌥ while sliding for quarter steps and finer scrubbing.

Settings: edge width, slide distance per step, swapping sides, requiring a modifier key, haptic strength, apps where EdgePal steps aside, and open at login.

## Build

```bash
bash Scripts/build-app.sh --run
```

This builds `build/EdgePal.app`, installs it in `~/Applications`, and makes `dist/EdgePal-<version>.zip`. On first launch the welcome guide asks for Accessibility permission.

An ad-hoc signed build gets a new signature every time, so macOS forgets the Accessibility permission after each rebuild. To keep it, create a code-signing certificate named **EdgePal Dev** in Keychain Access (Certificate Assistant → Create a Certificate → Code Signing). The build script uses it when it exists.

To check the parts that need no finger or permission:

```bash
~/Applications/EdgePal.app/Contents/MacOS/EdgePal --selftest
```

## How it works

- **Touches**: `Sources/EdgeTouch` is a small C bridge to Apple's private MultitouchSupport framework. It reports each finger's position in millimetres and drives the trackpad's Taptic Engine.
- **Clicks**: `EdgeEngine` installs a CGEventTap. When a left click starts with exactly one finger in an edge strip, the click is kept from apps and the pointer is frozen (`CGAssociateMouseAndMouseCursorPosition`). A watchdog makes sure the pointer is never left frozen.
- **Volume and brightness**: posts the same system-defined media key events as the keyboard, so macOS shows its own indicator. If a Mac ignores app-sent brightness keys, EdgePal switches to DisplayServices automatically.
- **Timeline**: since macOS 15.4 only Apple-signed programs can read Now Playing info, so `/usr/bin/perl` loads `libEdgePalMedia.dylib`, which uses MediaRemote. The two sides talk in JSON lines.
- **Corners**: `CornerClicks` counts clicks within 0.32 s. It runs the action straight away when no action is set for more clicks.

Uses private frameworks, so it's for direct distribution, not the Mac App Store. Touch data never leaves the Mac, and EdgePal makes no network requests.
