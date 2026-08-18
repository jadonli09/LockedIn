> **Note (2026-08-17):** this document is the historical record from the overnight build. The project has since been fully re-identified as LockedIn — scheme `LockedIn`, product `LockedIn.app`, bundle id `com.jadonli.lockedin`. Where this file says `boringNotch` / `theboringteam.boringnotch`, read the new names; `./scripts/lockedin build|start|stop|restart` is the current way to run it.

# FINAL_REPORT — LockedIn overnight build

**Status: Complete with limitations.** All Must phases (1–4), all Should phases (5–6), and all three Stretch phases (7–9) are built, committed, and verified to the extent possible without human-grantable permissions. Total wall-clock: **17:55–18:45 PDT (~50 minutes)** against a 4-hour budget — fast incremental builds (~90s) and a fully scriptable verification loop made the difference.

Branch: `overnight-v1`, 11 commits, one per phase. Honest ledger: `BUILD_LOG.md`. Dependency archaeology: `RESEARCH_NOTES.md`. Wake-up script: `MORNING_CHECKLIST.md`.

## What was built, per phase

- **P0 Archaeology** — dependency map of the boring.notch tree; discovered most sources are *explicit* pbxproj references (not synced groups), which shaped the whole stripping strategy; baseline build verified green before touching anything.
- **P1 Strip** — 120 → 50 Swift files. Deleted shelf/calendar/webcam/battery/brightness/volume/HUD/Lottie/face/tabs/onboarding/clipboard/metal + boring.m4a; scripted pbxproj purge of 138 dead references; rewrote the six shell files (App, ContentView, Coordinator, ViewModel, Constants, generic) keeping every animation value byte-identical (`interactiveSpring 0.38/0.8`, open `0.42/0.8`, close `0.45/1.0`, `.bouncy(0.4)`). Media/XPC stack (MusicManager, MediaControllers, XPC helper, mediaremote-adapter, fullscreen detection) kept fully intact per spec.
- **P2 Idle states** — 1px accent glow at 15% along the island's bottom edge at rest; during a session it becomes a 2px arc, remaining-time anchored trailing so it drains left-to-right; optional minutes numeral (SF Pro Rounded 11pt monospaced digits, 60% white) tucked right of the notch with symmetric island widening to stay centered. Accent system: 5 curated colors, default #E8A87C amber, used only in glow/arc/pulse.
- **P3 Pomodoro + panel + hotkey** — timestamp-only engine (`FocusSessionState`: every function takes `now`; truth is wall-clock arithmetic, the 1s ticker only refreshes UI). Presets 25/5, 50/10, 90/15 (tap idle timer to cycle); focus → break auto-advance with 3s grace; long break (3× short) every 4th cycle, toggleable. Expanded panel: play/pause circle | large mono timer + FOCUS/BREAK/READY label + 5s hold-to-confirm white ring to end early | sound toggle + Now Playing marquee/play-pause. Synthesized 0.9s chime; single accent pulse on phase end; no notification banners anywhere. ⌥⌘L global hotkey (recordable in Settings) toggles the session and pulses the island.
- **P4 Invisible behaviors** — `NoDisplaySleep` assertion "LockedIn focus session" held only during running focus phases; idle auto-pause (30s poll, 5-min threshold) that **backdates** the pause by the idle interval so idle time never counts, auto-resuming within ~2s of the next input; Auto-DND via `shortcuts run "LockedIn Focus On/Off"` with the spec's silent no-op when the Shortcuts don't exist.
- **P5 Focus sounds** — synthesized seamless brown-noise loop (leaky integrator, equal-power crossfaded loop point); `LoopingSoundPlayer` with 400ms fades; auto-duck under system Now Playing with auto-resume; session-scoped fade-out on end; mini volume slider that exists only while a sound plays. Rain/Café deferred (no CC0 sourcing tonight).
- **P6 App blocker + 2-min pass** — `NSWorkspace.didActivateApplicationNotification` (turns out to need **no permissions**), full-screen black overlay at screen-saver level: "Locked in — MM:SS left" live, white "Back to work" pill returning to the previous app, quiet "2-min pass" granting exactly 120s (per-item, non-stacking, unlogged), auto-relock with 3s fade. `DEBUG_SIMULATE_BLOCK` defaults flag fakes a block for screenshotting.
- **P7 (stretch) Browser blocker** — 2s AppleScript poll of the frontmost browser only (Safari/Chrome/Arc/Edge), domain match (subdomain-aware, suffix-spoof-proof, unit-tested), redirect to bundled `lockedin.html` (black page, live remaining time, `lockedin://pass?domain=…&back=…` link); URL scheme registered and handled; pass returns the tab to the original URL; relock re-blocks with a 3s CSS fade.
- **P8 (stretch)** — the minimal media row was already delivered inside the panel (read-only marquee + play/pause, expanded state only).
- **P9 (stretch) Settings** — single grouped pane: launch-at-login, menu-bar icon (off by default; the island is the only surface), displays, hover/haptics, accent picker, custom focus/break steppers (Settings-only per spec), behavior toggles, hotkey recorder, blocked apps (native NSOpenPanel picker), blocked domains (normalized text entry), Shortcuts setup pointer, Sparkle update check. Display name → LockedIn.

## Architecture of the new code

```
models/FocusModels.swift        pure state machine (no deps, fully tested)
models/BlocklistMatcher.swift   pure matching + pass bookkeeping (no deps, tested)
models/FocusDefaults.swift      Defaults keys + Serializable conformances
managers/FocusSessionManager.swift  runtime driver: ticker, grace, persistence, chime/pulse
managers/FocusBehaviors.swift   keep-awake, idle auto-pause, Auto-DND (notification-driven)
managers/FocusSoundManager.swift + helpers/AudioPlayer.swift  loops, fades, auto-duck
managers/AppBlocker.swift       activation watcher + overlay orchestration + passes
managers/BrowserBlocker.swift   AppleScript tab poll + redirect + lockedin:// passes
components/FocusIdleView.swift  glow / draining arc / minutes numeral
components/FocusPanelView.swift expanded one-row panel
components/BlockOverlayView.swift  overlay view + borderless panel controller
components/MarqueeText.swift    minimal overflow-only marquee
LockedInTests/                  unit test bundle (target hand-built in pbxproj)
scripts/add_source_file.py      registers new sources with the explicit-reference pbxproj
```

Everything session-driven hangs off two notifications (`focusPhaseDidChange`, `focusSessionDidEnd`) posted by the manager — blockers and behaviors never poll session state.

## Test results (verbatim)

```
Test Suite 'All tests' passed at 2026-08-14 18:30:54.211.
	 Executed 20 tests, with 0 failures (0 unexpected) in 0.016 (0.033) seconds
** TEST SUCCEEDED **
```

Runtime verification (all machine-driven, evidence in BUILD_LOG + scratchpad screenshots):

| Check | Result |
|---|---|
| Clean-room build (fresh DerivedData) | `** BUILD SUCCEEDED **` |
| Launch + 65s soak | alive, **0.0% CPU** across 3 top samples, `no new crash reports` |
| Island vs hardware notch | screenshot: pure black, flush, original silhouette |
| Idle glow | pixel-verified amber@15% at bottom edge (33,26,20) |
| Session arc + numeral | screenshot: draining amber arc + "25" @60% white |
| Expanded panel | screenshot: play circle / 25:00 READY / wave toggle |
| End-to-end session | injected 60s session → restored after relaunch → expired → pulse (screenshot of amber outline) + chime + auto-advance to 300s shortBreak, count=1 |
| Keep-awake | `pmset -g assertions`: present during focus, **0 after pause and after end** — no leaks |
| Hold-to-end | 5.6s synthetic press ended the session; <5s release does not |
| App blocker | live with TextEdit: overlay screenshot, Back-to-work → Finder, 2-min pass lifted overlay, auto-relock pixel-verified ~120s later |
| Block page | rendered in browser, param fallback confirmed |
| Warnings from new code | **zero** (all remaining warnings are pre-existing upstream Swift-6 concurrency noise) |

## Known issues / limitations

1. **Hover-to-open is verified by tap, not hover** — synthetic CGEvent mouse moves never trigger SwiftUI `onHover`; the handler is upstream's untouched code, but feel it by hand (morning item #1).
2. **Browser blocker is unexercised live** — needs per-browser Automation permission a human must grant. Logic is unit-tested; runtime is `try?`-inert without permission.
3. **Auto-DND no-ops** until the two Shortcuts are created (60s by hand — bundled .shortcut files were skipped because valid ones must be signed by Shortcuts itself).
4. **Rain + Café sounds missing**; brown noise ships.
5. **Bundle id still `theboringteam.boringnotch`** (XPC service discovery + Sparkle feed depend on it); all visible branding says LockedIn. Sparkle still points at upstream's appcast.
6. Idle auto-pause's 5-minute threshold is untested against a real 5-minute idle (poller + threshold logic unit-tested; cadence switching verified by code review only).
7. `swiftui-introspect`, `Lottie`, `Pow`, `swift-collections` SPM packages are resolved but unreferenced — dead weight in Package.resolved only; safe to drop from the project later.

## Build & run

```sh
cd ~/Downloads/LockedIn.notch   # branch overnight-v1
xcodebuild -scheme boringNotch -configuration Debug build -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
codesign --force --deep -s - build/DerivedData/Build/Products/Debug/boringNotch.app
open build/DerivedData/Build/Products/Debug/boringNotch.app
xcodebuild -scheme LockedInTests test -derivedDataPath build/DerivedData   # 20/20
```

⌥⌘L starts a session. Right-click the island for Settings/Quit. `defaults write theboringteam.boringnotch focusSessionState -string '{"completedFocusCount":0,"phase":"focus","phaseDuration":60,"phaseStart":<ref-epoch>,"preset":{"breakMinutes":5,"focusMinutes":25}}'` injects a short test session (ref-epoch = unix − 978307200).
