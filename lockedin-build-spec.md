# LockedIn — macOS Focus Island (Build Spec for Claude Code)

## GOAL

Build a minimal, aesthetic Dynamic Island for the MacBook notch, focused entirely on deep work. Fork of boring.notch (GPL-3.0 — this project stays open source under GPL-3.0). Three capabilities only: Pomodoro focus sessions, app/website blocking during sessions, and ambient focus sounds. Everything else is deleted. The bar for every screen: it should feel like Apple shipped it.

Working title: **LockedIn** (rename is a find-replace later).

## SOURCE SKELETON

Start from a fork of `TheBoredTeam/boring.notch`. Do not build the notch window from scratch — it is already solved here.

### 1. KEEP (the hard-won parts)
- `boringNotchApp.swift`, `BoringViewCoordinator.swift`, `ContentView.swift` — app shell and state coordination (gut the tab content, keep the plumbing)
- `sizing/` and `animations/` — notch geometry and spring physics. Do not touch the animation curves; they are the product.
- `extensions/MouseTracker.swift`, `PanGesture.swift`, `Button+Bouncing.swift`, `KeyboardShortcutsHelper.swift` (global hotkey)
- `managers/NotchSpaceManager.swift`, `managers/MusicManager.swift`
- `MediaControllers/` + top-level `mediaremote-adapter/` + `BoringNotchXPCHelper` + `XPCHelperClient/` — Now Playing detection
- `observers/FullscreenMediaDetection.swift` — hide island during fullscreen video
- `helpers/AudioPlayer.swift` — reuse for focus sounds
- `components/Onboarding/PermissionsRequestView.swift` — adapt for our permissions
- `updater/` (Sparkle) — keep wired but dormant until v1 ships

### 2. DELETE (everything that competes for attention)
- `managers/`: CalendarManager, WebcamManager, BatteryActivityManager, BrightnessManager, VolumeManager
- `components/`: Calendar/, AnimatedFace, MusicVisualizer, LottieAnimationView, all mirror/webcam views
- `observers/`: DragDetector, MediaKeyInterceptor
- `helpers/`: Clipboard+Content
- `Shortcuts/`, `metal/`, file-shelf/tray UI, HUD replacement features, `boring.m4a`
- Any settings pane that configures a deleted feature

After stripping, the app must compile and show an empty functional island before any new feature work begins.

## THE THREE STATES

### 1. Idle (no session)
Pure black, flush with the hardware notch — indistinguishable from the bezel except for a faint 1px ambient glow along the bottom edge in the accent color, at ~15% opacity. Nothing else. No face, no icons, no text.

### 2. Idle (session running, not hovered)
The glow becomes a thin progress arc/underline that drains left-to-right as the session elapses. Optional (settings toggle, default on): remaining minutes as a small monospaced numeral tucked at the right edge of the notch, SF Pro Rounded, ~11pt, 60% white. Max two elements. No track titles, no album art in this state.

### 3. Hovered / expanded
Island grows with the existing spring physics into a single panel, one row deep:
- **Left:** play/pause circle for the session (start if none running)
- **Center:** time remaining, large, monospaced digits; session label under it ("Focus" / "Break") in 11pt caps, 40% white
- **Right:** sound toggle (SF Symbol wave) and a marquee track title with play/pause if system media is playing
- Long-press on center = end session early (see Blocker §3)

No second row. No tabs. If a feature needs a tab, it doesn't ship.

## FEATURES

### 1. Pomodoro engine
1. Presets: 25/5, 50/10, 90/15. Custom lengths live in Settings only, not in the island.
2. Cycle: focus → break → focus, auto-advance with a 3s grace animation; long break every 4th cycle (configurable off).
3. Session state persists across app restarts (UserDefaults + timestamps, not a live timer).
4. On session end: island pulses once in accent color + a single soft chime (bundled, ≤1s). No macOS notification banners. Ever.
5. Menu bar stays empty — the island is the only surface.

### 2. Blocker (the differentiator — no competitor has this)
1. **Blocklist model:** one list of app bundle IDs + one list of domains, editable in Settings with a native picker for apps and a plain text field for domains.
2. **App blocking:** subscribe to `NSWorkspace.didActivateApplicationNotification`. If the frontmost app's bundle ID is blocklisted during a focus session, present a full-screen borderless overlay: black, centered text "Locked in — 17:24 left", one quiet "Back to work" button that returns to the previous app. Do not force-quit anything.
3. **Ending early:** no hard lock (support nightmare) and no instant quit (too easy). Long-press to end shows a 5-second hold-to-confirm ring. Friction, not imprisonment.
4. **Website blocking v1:** poll the active tab URL every 2s via AppleScript/Automation for Safari, Chrome, Arc, and Edge. On domain match, redirect the tab to a bundled local `lockedin.html` (same black screen + time remaining). Requires per-browser Automation permission — request in onboarding with a plain-language explanation.
5. **Explicit non-approach:** no /etc/hosts editing, no privileged helper, no VPN/proxy in v1.
6. **Two-minute pass:** the block overlay carries a second, visually quiet button: "2-min pass". Tapping it grants exactly 120s of access to that one app or domain, then auto-relocks with a 3s fade warning. On the browser block page, the pass is a link using a custom URL scheme (`lockedin://pass?domain=x`) that the app registers and handles. Passes are per-item, don't stack, and aren't counted or logged anywhere (no stats in v1). This exists so people don't kill a whole session just to check one thing.

### 3. Focus sounds
1. Bundle exactly three CC0/self-recorded loops: Rain, Brown Noise, Café. Verify license of every file before bundling.
2. Playback via the existing AudioPlayer helper, seamless loop, 400ms fade in/out, independent volume slider in the expanded island (appears only while a sound is active).
3. Auto-duck: if system Now Playing starts (Spotify/Apple Music), pause the focus sound; resume when their music stops.
4. Sounds are session-scoped by default: starting a focus session offers the last-used sound; ending the session fades it out.

### 4. Media (deliberately minimal)
1. Read-only from the Now Playing adapter: track title (marquee if long) + play/pause. No album art, no scrubber, no lyrics, no visualizer.
2. Visible only in the expanded state, right side. Never in idle states.

### 5. Invisible session behaviors (zero UI footprint)

These run automatically with a focus session. None of them add a single pixel to the island.

1. **Auto-DND:** starting a focus session enables a macOS Focus mode; ending or pausing disables it. There is no public API for this, so use the `shortcuts` CLI (`Process` running `shortcuts run "LockedIn Focus On"` / `"...Off"`). Onboarding includes a one-tap install of the two bundled Shortcuts (.shortcut files, opened via `shortcuts://`). If the Shortcuts are missing at runtime, the feature silently no-ops — never error, never nag. Settings toggle, default on.
2. **Keep-awake:** during focus periods (not breaks), hold a display-sleep assertion via `IOPMAssertionCreateWithName` (`kIOPMAssertionTypeNoDisplaySleep`, reason string "LockedIn focus session"). Release on pause, break, or end. Never leak an assertion — verify with `pmset -g assertions` during testing.
3. **Idle auto-pause:** poll `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)` every 30s. If no keyboard/mouse input for 5 minutes during a focus period, pause the timer; resume automatically on the next input event. Idle time never counts toward the session — 25 minutes means 25 attended minutes. No extra permissions required. Settings toggle, default on.
4. **Global hotkey:** ⌥⌘L toggles start/pause of a session from anywhere, using the KeyboardShortcuts package already in the codebase. Recordable/changeable in Settings. The hotkey triggers the same pulse animation on the island so there's physical feedback without opening it.

## AESTHETIC CONSTRAINTS (non-negotiable)

1. At rest the island must be visually indistinguishable from the hardware notch. Pure #000000, no border, no shadow bleed onto wallpaper.
2. Exactly one accent color, user-pickable from 5 curated options (default: warm amber #E8A87C). The accent appears only in the glow, the progress arc, and the end-of-session pulse. Nowhere else.
3. Typography: SF Pro Rounded only. Two weights (Medium, Semibold). Timer digits monospaced.
4. Icons: SF Symbols only, hierarchical rendering, no custom glyphs, no emoji.
5. Motion: springs only, reusing boring.notch's existing physics values. Nothing linear, nothing bouncy-cartoonish, nothing over 0.5s.
6. No red anywhere. No badges, counters, streaks, or notification dots.
7. Max two information elements in any collapsed state; max five interactive elements in the expanded state.
8. Every decision defaults to removal. If unsure whether something earns its place, it doesn't.

## NON-GOALS FOR V1

Stats/streaks, calendar, clipboard, file shelf, mirror, HUDs, AI features, multi-display support, iCloud sync, localization. Do not build scaffolding for them.

**Explicitly deferred to v2 (decided, not forgotten):** session intention line, breathing glow on breaks, calendar collision warning. Do not implement early.

## TECH & PERMISSIONS

- Swift 5.10+, SwiftUI, macOS 14.0+ minimum (matches upstream), Apple Silicon primary target.
- Permissions requested (onboarding, each with one-line human explanation): Accessibility (app detection + overlay), Automation per-browser (tab URLs). No screen recording, no camera, no mic.
- Unsigned dev builds for now; Developer ID signing + notarization is a later step, already budgeted.
- License: GPL-3.0, LICENSE file preserved, upstream credited in README.

## BUILD PHASES (stop after each; must compile and run before proceeding)

1. Fork, strip per KEEP/DELETE lists, rename bundle, empty island renders with correct hover physics.
2. Idle states: ambient glow + session accent arc.
3. Pomodoro engine + expanded island UI + end-of-session pulse and chime + global hotkey.
4. Invisible behaviors: keep-awake, idle auto-pause, then Auto-DND (Shortcuts CLI + bundled .shortcut files).
5. Focus sounds + auto-duck.
6. App blocker + overlay + hold-to-end friction + 2-min pass button.
7. Browser tab blocker (Safari + Chrome first, then Arc/Edge) + `lockedin://` URL scheme for the pass.
8. Minimal media row.
9. Settings window (single pane: presets, blocklists, accent, sound, toggles, hotkey recorder) + permissions onboarding incl. Shortcuts install.
