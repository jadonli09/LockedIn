# BUILD_LOG — LockedIn overnight-v1

## 2026-08-14 17:59 PDT — Phase 0: Preflight + archaeology (17:55–18:05)
- Baseline build of untouched main: green (exit 0, ~90s). Xcode 26.6, macOS 26.6.
- Project uses Xcode 16 filesystem-synced groups: disk deletion == build removal. Huge win for stripping.
- Dependency map in RESEARCH_NOTES.md. Media/XPC stack kept intact per spec KEEP list.
- Decision: ShortcutConstants.swift (KeyboardShortcuts names) folded into KeyboardShortcutsHelper.swift rather than kept as Shortcuts/ folder (spec DELETE list targets Apple-Shortcuts features; this file is the hotkey name table).
- Decision: bundle identifiers unchanged tonight (XPC helper service discovery depends on them); rename is display-name only.

## 2026-08-14 18:07 PDT — Phase 1: Strip to empty island (18:00–18:07)
- Deleted 70 files (120 → 50 Swift files): Shelf, Calendar, Webcam, Battery, Brightness, Volume, HUD/Live activities, Lottie, AnimatedFace, Tabs, Onboarding, Tips, WhatsNew, metal, DragDetector, MediaKeyInterceptor, Clipboard, boring.m4a.
- Surprise: most files were explicit pbxproj references, not synced groups (only private/ + XPC helper are synced). Wrote a script to purge dead PBXFileReference/PBXBuildFile entries; plutil-lint clean.
- Rewrote shell: App/AppDelegate (no MenuBarExtra by default, no onboarding/drag/welcome-sound), ContentView (hover/gesture/spring skeleton intact, placeholder open panel), Coordinator (screen mgmt + firstLaunch only), ViewModel (notch state + fullscreen detection only), Constants/generic trimmed, SettingsView minimal rewrite.
- MusicManager: removed sneak-peek coupling; that changed inferred isolation → wrapped playback sink in MainActor.assumeIsolated (already received on main queue).
- Build green. App launched, ran 15s+, no crash reports. Screenshot verified: island is pure black, flush with hardware notch, original corner radii. All compiler warnings remaining are pre-existing upstream Swift-6 concurrency warnings.
- Deferred: product/bundle rename stays boringNotch internally (XPC service discovery depends on bundle ids); "LockedIn" branding is display-level only for now.

## 2026-08-14 18:14 PDT — Phase 2: Idle states (18:07–18:14)
- New: FocusAccent (5 curated colors, default #E8A87C amber), FocusModels (timestamp-based state machine, fully unit-testable — every function takes `now`), FocusSessionManager (ticker, 3s grace, persistence, pulse+chime hooks), FocusIdleView (glow + draining arc + minutes numeral).
- Built engine one phase early since idle states render session progress; Phase 3 only needs UI + hotkey on top.
- Wrote scripts/add_source_file.py to register new files in the pbxproj (groups are explicit, not synced).
- Decisions: arc "drains left-to-right" = remaining time anchored trailing, empties from the left; long break = 3× short break; island widens symmetrically by 26pt/side for the numeral (left side stays black) so it remains centered on the hardware notch.
- Pulse: accent stroke flash on the island shape, 0.5s ease-out, triggered by endPulse counter.
- Build green; glow verified by pixel inspection: bottom-edge pixels (33,26,20) = amber@15% over black.

## 2026-08-14 18:17 PDT — Phase 3: Pomodoro + expanded UI + hotkey (18:11–18:17)
- FocusPanelView: play/pause circle (left), large rounded-mono timer + phase label (center), Now Playing marquee + play/pause (right, only when media active). 5s hold-to-confirm white ring on center ends session early. Tap center while idle cycles the three presets (25/5 → 50/10 → 90/15) — decision: presets picked by tapping the idle time display, keeps island at ≤5 interactive elements.
- MarqueeText rewritten minimal (upstream one died with Live activities).
- openNotchSize 640×190 → 520×124: single-row panel. Spring curves untouched.
- chime.wav synthesized (880/1320/1760 Hz partials, exp decay, 0.9s, −6 dBFS) and registered as bundle resource.
- ⌥⌘L via KeyboardShortcuts (.toggleFocusSession) → toggle + island pulse. Verified live: synthetic ⌥⌘L started a session.
- Verified end-to-end: injected 60s session with 5s left via defaults → app restored it on relaunch (persistence ✓), expired → advanced to shortBreak 300s, completedFocusCount=1 (auto-advance + grace ✓). chime.wav present in bundle.
- Screenshots: expanded panel (25:00/READY), closed running state (amber arc draining + "25" numeral @60% white right of notch).
- Known: synthetic CGEvent hover doesn't trigger onHover open (tap + hotkey verified instead); hover-by-hand is a morning-checklist item. A synthetic click on the open panel's play button was swallowed by an overlapping window — hotkey path used for automation instead.

## 2026-08-14 18:22 PDT — Phase 4: Invisible behaviors (18:17–18:22)
- FocusBehaviors.swift: FocusBehaviorCoordinator (notification-driven), KeepAwakeManager (IOPMAssertion NoDisplaySleep "LockedIn focus session", focus periods only, never breaks), IdleAutoPauseMonitor (30s poll → 5min idle threshold; pause is BACKDATED by the idle interval so idle time never counts; 2s poll while auto-paused so next input resumes), FocusModeController (`shortcuts run "LockedIn Focus On"/"Off"`, silent no-op if missing).
- Engine additions: autoPause(idleFor:) with backdated pausedAt; pausedAutomatically flag gates auto-resume.
- Decisions: idle query uses min(secondsSinceLastEventType) over six concrete event types instead of the undocumented any-event sentinel (CGEventType(rawValue: ~0) is a failable-init crash risk); Auto-DND active only while a focus phase is actively running (off during breaks/pause — spec was ambiguous, chose minimal).
- Live-verified with pmset -g assertions: assertion present during focus ("LockedIn focus session"), gone after ⌥⌘L pause.
- shortcuts CLI present at /usr/bin/shortcuts; the two named Shortcuts must be created by hand (morning checklist) — runtime no-ops until then, as spec prescribes.

## 2026-08-14 18:26 PDT — Phase 5: Focus sounds (18:22–18:26)
- brownnoise.wav synthesized: leaky-integrated white noise, 11.5s, 0.5s equal-power crossfade tail→head for a seamless loop, normalized. CC0-equivalent (self-generated). Rain + Café: morning TODO (no network sourcing tonight).
- helpers/AudioPlayer.swift repurposed into LoopingSoundPlayer (AVAudioPlayer, infinite loop, 400ms fades). FocusSoundManager: toggle/start/stop, volume via Defaults, auto-duck under MusicManager.$isPlaying with resume when media stops, fade-out on session end.
- Panel right column: wave toggle (white 0.9 active / 0.4 idle, variableColor symbol effect while playing) + mini volume slider that appears only while a sound is active.
- Decision: "starting a session offers the last-used sound" implemented as one-tap toggle preloaded with last-used sound — no auto-play (minimal interpretation).
- Verified by click automation: toggle on → slider appears (screenshot), audio audible; toggle off → slider region reads pure black pixels.

## 2026-08-14 18:31 PDT — Phase 6: App blocker + 2-min pass (18:22–18:31)
- BlockOverlayView + BlockOverlayController: full-screen black NSPanel at .screenSaver level, "Locked in — MM:SS left" (live), white "Back to work" pill, quiet gray "2-min pass". The 3s fade-in IS the relock warning.
- AppBlocker: NSWorkspace.didActivateApplicationNotification (no permissions needed — Accessibility turned out unnecessary for app-level blocking); tracks last non-blocked app for "Back to work"; passes are per-item/non-stacking/unlogged; blocklist reacts live to Defaults changes; DEBUG_SIMULATE_BLOCK defaults flag for permission-free overlay simulation. BlocklistMatcher extracted to models/ (pure Foundation) for unit tests, incl. domain matcher for the browser stretch.
- Settings: Focus section (accent picker, toggles, hotkey recorder), Blocked apps (NSOpenPanel native picker), Blocked websites (text field, normalized).
- Fixed after live test: seed previousApp with frontmost at start; re-check frontmost when a session starts (blocked app already frontmost).
- LIVE VERIFIED full loop with TextEdit blocklisted: overlay appears on activation (screenshot), Back to work returns to Finder, 2-min pass lifts overlay, auto-relock kicks in ~120s later (pixel-verified black overlay).

## 2026-08-14 18:31 PDT — Test infrastructure (part of Phase 7 reserve, done early)
- Project had NO test target. Created LockedInTests unit-test bundle by hand in pbxproj (synced folder group + compiles FocusModels.swift/BlocklistMatcher.swift directly, no app host, no SPM deps) + shared scheme.
- Refactor for testability: FocusModels stripped of Defaults dependency (keys+Serializable moved to models/FocusDefaults.swift); BlocklistMatcher moved out of AppBlocker.
- 20 tests: state machine (start/elapse/expiry/pause/resume/no-op double transitions), backdated idle-pause accounting incl. clamp, phase advancement + every-4th long break + disable, Codable persistence round-trip + relaunch-by-timestamps, matcher (case-insensitivity, 120s pass, non-stacking, per-item, clear, domain matching incl. subdomains and suffix-spoof rejection).
- `xcodebuild -scheme LockedInTests test` → TEST SUCCEEDED, 20/20 passed.

## 2026-08-14 18:38 PDT — Phase 7 (stretch): Browser tab blocker + lockedin:// pass (18:31–18:38)
- BrowserBlocker: 2s poll of the FRONTMOST app only; if it's Safari/Chrome/Arc/Edge, reads the active tab URL via AppleScript (AppleScriptHelper), matches with BlocklistMatcher.domainMatches (already unit-tested), redirects the tab to bundled lockedin.html with ?left/domain/back/relock params. Never touches file:// URLs (no redirect loop). Domain passes: 120s, per-item, non-stacking; relock re-presents the page with a 3s CSS fade (?relock=1).
- lockedin:// URL scheme registered in Info.plist (+ NSAppleEventsUsageDescription for the Automation prompt); AppDelegate application(_:open:) routes to handlePassURL, which grants the pass and AppleScripts the tab back to the original URL.
- Block page visually verified in a browser (fallback rendering without params confirmed — `open` strips queries).
- LIMITATION: live redirect flow needs per-browser Automation permission → morning checklist. Code is inert without it (try? everywhere), exactly as spec prescribes.
