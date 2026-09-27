# LockedIn

A minimal Dynamic Island for the MacBook notch, focused entirely on deep work.

Three capabilities, nothing else:

- **Pomodoro focus sessions** — 25/5, 50/10, 90/15 presets, wall-clock timestamp engine that survives relaunch and sleep, auto-advancing breaks, a long break every 4th cycle, ⌥⌘L from anywhere.
- **Blocking** — blocklisted apps get a full-screen black overlay during focus periods ("Locked in — 17:24 left"), with a quiet 2-minute pass so you never have to kill a session just to check one thing. Website blocking redirects blocked domains to a local block page in Safari, Chrome, Arc, and Edge.
- **Focus sounds** — seamless ambient loops with 400 ms fades, auto-ducked under whatever you're actually listening to.

At rest, the island is invisible: pure `#000`, flush with the hardware notch, nothing else. During a session a small remaining-minutes numeral sits at its edge. Hover to expand into a single one-row panel. No tabs, no badges, no streaks, no red.

Invisible session behaviors: display keep-awake during focus periods, idle auto-pause (idle time never counts — 25 minutes means 25 attended minutes), and optional Auto-DND via two Shortcuts.

**Face ID (opt-in, off by default)** — on-device face recognition ported from [Glance](https://github.com/jonnyoo/glance) (MIT): unlock the Mac from the lock screen with a scan in the notch (the unsandboxed helper types your stored password), auto-pause a session when you leave the desk and resume when you're back, and require your face to end a session early. Needs Camera access, Accessibility for `LockedInHelper`, an enrolled face, and your Mac password entered once in Settings → Face ID. A green dot in the island means the camera is on. Not as secure as Touch ID: a photo or phone held up is rejected, a replayed video may not be.

## Building

```sh
xcodebuild -scheme LockedIn -configuration Debug build
xcodebuild -scheme LockedInTests test
```

Or `./scripts/lockedin build` to build, sign, and (re)launch in one step. Requires macOS 15+, Xcode 16+, Apple Silicon.

Bundle id `com.jadonli.lockedin`; the Now Playing helper is `com.jadonli.lockedin.helper`.

## Credit & license

LockedIn is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam — the notch window management, spring physics, and Now Playing stack are their hard-won work, gratefully reused. Licensed under GPL-3.0, same as upstream; see [LICENSE](LICENSE).
