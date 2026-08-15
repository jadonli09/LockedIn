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
