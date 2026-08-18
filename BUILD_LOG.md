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

## 2026-08-14 18:40 PDT — Phases 8+9 (stretch) (18:34–18:40)
- Phase 8 (media row) was already delivered inside the expanded panel in Phases 3/5: read-only marquee title + play/pause, right side, expanded state only. Nothing more to build.
- Phase 9: Settings gains custom Focus/Break length steppers (Settings-only, per spec), Shortcuts setup note + "Open Shortcuts" button; window retitled "LockedIn Settings"; CFBundleDisplayName = LockedIn (bundle id intentionally unchanged — XPC service discovery).
- Verified visually: island context menu (Settings ⌘, / Quit LockedIn) and the full Settings window render correctly.
- Permissions onboarding UI deliberately NOT built: every permission (Automation per-browser, Shortcuts) must be granted by a human anyway → MORNING_CHECKLIST covers it. Logged as conscious scope decision, not an omission.

## 2026-08-14 18:45 PDT — Phase 7 (reserve): Stabilize + report (18:35–18:45)
- Clean-room rebuild (deleted DerivedData): BUILD SUCCEEDED. Full test suite: 20/20 TEST SUCCEEDED.
- 65s soak: process alive, idle CPU 0.0% over 3 top samples, zero new crash reports.
- Warnings audit: touched every new/rewritten file, rebuilt, grepped — zero warnings introduced by new code.
- Hold-to-end verified live (5.6s synthetic press ends session); pmset assertion present during focus, 0 after end — no leaks.
- End-of-session pulse captured on screen (amber outline around island) + auto-advance to a fresh full break arc.
- README rewritten for LockedIn (GPL-3.0 preserved, upstream credited). FINAL_REPORT.md + MORNING_CHECKLIST.md written.
- Total elapsed 17:55 → 18:45 (~50 min of the 240-min budget). All Musts, all Shoulds, all Stretches shipped.

## 2026-08-15 — Iteration 2 (operator feedback round)
- Numeral clipped by hardware notch: closed-state center spacer now covers notchWidth+8 so both side slots sit fully outside the physical notch; side slots widened to 38pt.
- Glow aesthetics: span widened to notchWidth−8 (was inset 28pt total), soft blur bloom added under both the rest glow and the session arc so it reads as light, not a hairline.
- Hello animation now sized like the open panel (openNotchSize.width−96 × 96) instead of a square blob.
- ⌥⌘L feedback: transient chip pops from the left of the notch for 1.8s on every state change (▶ Focus / ⏸ Paused / ▶ Resumed / ✓ Ended), springs in/out; island renders closed content whenever a chip or pass is active.
- Blocker hardening: "Back to work" now HIDES the blocked app (never quits) before returning to the previous app; a 1.5s watchdog re-presents the overlay any time a blocked app is frontmost without a pass — perpetual enforcement, incl. pass expiry (with the 3s fade) and the dismissed-overlay-in-place case the operator hit with RStudio.
- Pass visibility: new PassCenter (shared observable ledger over pure PassBook; matcher pass logic refactored out, tests updated → 21/21 green). Closed island shows the pass countdown in place of the minutes numeral; expanded panel shows a cancellable pass chip; both blockers grant/read through PassCenter.
- Island blocklist controls: shield button in the panel opens a compact popover — active passes w/ cancel, blocked apps (native picker), blocked websites (add/remove) — no Settings window needed. PanelInteractionState.holdOpen keeps the island from auto-closing while the popover or app picker is up.
- Sounds: synthesized Rain (hiss + droplet pings) and Ocean (LFO-swelled brown noise + crest hiss) loops added alongside Brown Noise; right-click the wave icon to pick; selection crossfades if already playing.
- Spotify: Media section in Settings exposes the existing controller stack (Now Playing / Apple Music / Spotify / YouTube Music) with live switching via .mediaControllerChanged.
- Verification note: operator now active on the machine (clamshell, 2 external QHD displays) — no synthetic input posted this round; build clean, 21/21 tests, new build left running for hands-on check.

## 2026-08-15 — Iteration 3
- Session arc/glow now spans the island's actual rendered width via GeometryReader (was pinned to notch width, so it floated centered once the island widened for the numeral — operator screenshot confirmed).
- Browser table extended: Comet (ai.perplexity.comet), Opera, Brave, Vivaldi, Dia — all verified/known to ship the standard Chromium scripting dictionary (checked via sdef for the installed ones).
- scripts/lockedin CLI: start | stop | restart | build (build also re-signs and relaunches).

## 2026-08-15 — Iteration 4
- Removed the accent glow/arc from the collapsed island entirely (operator call — it fought the aesthetic on both displays). Idle island is now pure black; session state = numeral only. FocusIdleUnderlay deleted.
- Numeral clearance widened decisively: center cover = notchWidth+24 (12pt margin per side), side slots 44pt. Bottom-edge "not flush" report was most plausibly the glow bloom bleeding below the shape — gone with the glow.
- Hello plays every launch (previous iteration) — kept.
- Block overlay redesigned: covers ONLY the blocked app's windows (CGWindowList bounds by owner PID — no permissions), NSVisualEffectView behind-window blur + black 0.55 tint, app name in caps, live countdown, primary "Stay locked in" pill = graceful app.terminate() + return to previous app, quiet 2-min pass. Watchdog now repositions panels as windows move, hides the overlay when the blocked app loses frontmost, re-covers on reactivation. Compact layout for windows under 420pt tall. Full-screen fallback when no window bounds exist.
- Block page redesigned: live JS countdown from a deadline param (until, ms epoch), breathing amber halo, domain label in caps, primary "Stay locked in" button → lockedin://close which AppleScripts the tab closed; pass link unchanged. handlePassURL generalized to handleURL (pass|close).

## 2026-08-15 — Iteration 6: aurora block surfaces (Opal-inspired, operator request)
- Shared design system across both block surfaces: violet-ink ground #0A0812, aurora palette (violet #7C6CFF, teal #4ED8C3, peach #FFB38A, rose #E88CC4 — peach keeps kinship with the island's amber; still no red), SF Pro Rounded throughout.
- Signature: the session ring — full aurora spectrum revealed clockwise as the session elapses (celebrates progress rather than scolding), live countdown inside. Identical mechanics in SwiftUI (trim over AngularGradient) and CSS (conic reveal + near-ink cover that doubles as the track).
- Atmosphere: three drifting blurred aurora orbs (16–22s alternate loops; prefers-reduced-motion respected on web), app overlay keeps the behind-window blur beneath the ink tint.
- Actions: "Stay locked in" = violet→teal gradient pill with soft violet shadow; "2-min pass" stays a whisper.
- Verified via headless Chrome renders (entrance animation initially made captures look dim — re-rendered with virtual-time budget).

## 2026-08-15 — Iteration 7: flat redesign + tracking regression fix
- BUG: window tracking dead after app relaunch with a restored session — AppBlocker.start() never evaluated session state, so the watchdog/tracker timers only armed on a *state change*. Now calls sessionStateChanged() on start (parity with the other two blockers). Also: window-count changes mid-block (new/closed windows) re-present the overlay instead of silently refusing to reposition.
- Aurora design retired (operator: "very AI-generated" — the frontend-design skill's own calibration flags exactly that near-black+gradient look). New direction grounded in LockedIn's own identity: pure near-black field, SF Pro Rounded, single user-chosen accent, zero gradients.
- Signature: the island itself — a notch silhouette at the page top with the amber minutes numeral tucked at its right edge, mirroring the real notch. Progress = attended-minute dots (one per phase minute, accent when attended, rows of 30) + "N OF M MINUTES ATTENDED" line — the product's core promise made visible.
- Accent follows the user's Settings choice on both surfaces (?accent= param on the web page; Defaults on the overlay).
- Verified via headless Chrome render.

## 2026-08-16 — Iteration 8: friction model + album art wash
- Interaction model per operator: pause = friction (5s hold on the play/pause circle, ring fills; unlocks blocked apps so it must cost), reset = easy (single-tap ↺ that only appears while paused; restarts the phase at full time — a reset only ever adds focus). Timer text is display-only during a session (still cycles presets when idle; still hold-5s-to-end). Center label shows PAUSED while paused.
- Engine: resetPhase() + .reset transient chip. ⌥⌘L now starts/resumes only — never pauses (would bypass the friction).
- Album art wash: blurred (r28), lightly saturated, 50% opacity art masked from the trailing edge into black — color bleeds into the panel without the picture landing in it. Plus a 26pt rounded art thumb next to the marquee title.

## 2026-08-17 — Iteration 9: album-art wash done properly
- Operator: wash "looks like a block with some fading". Confirmed by rendering: an offscreen ImageRenderer harness (scratchpad/wash_harness.swift) iterated 6 variants side-by-side. V1 (blur 28 + linear mask holding 35% across the block) = slab. Circle-based pools (V2–V4) either muddied to grey at heavy blur or leaked the circle's rim as a hard edge. Winner V6: full-panel layer of the art's dominant color (MusicManager.avgColor, now always computed) at 0.42 + blurred art at 0.35, masked by a long horizontal ease starting ~30% — no straight edge anywhere, controls stay crisp.
- Layout: timer moved LEFT beside the play/pause circle (operator allowed off-center); media cluster owns the right half; marquee widened to 96pt and keyed to the title so it restarts cleanly.
- DEBUG_SIMULATE_MEDIA harness (flag or `-DEBUG_SIMULATE_MEDIA YES` launch arg) fakes a playing track + vivid art and suppresses real controller updates while on.
- DISCOVERY: the app is sandboxed (upstream entitlement) → its prefs live in ~/Library/Containers/theboringteam.boringnotch/…, NOT ~/Library/Preferences. Every `defaults write theboringteam.boringnotch` used for testing so far hit the wrong plist. Test scripts now target the container path.

## 2026-08-17 — Iteration 10: media-in-the-middle layout + four-side art vignette
- Layout: no media → controls | timer centered | actions (as originally). Media → controls | media | timer | actions — music takes the middle and pushes the timer right, per operator.
- Art treatment replaced (operator's Cuesheet reference: crisp art dissolving over a long ramp, not a blurred smear): the album cover itself, at 42% opacity, masked horizontally (long ease in from ~0→62%, plateau, release before the timer) AND vertically (soft top/bottom) — dissolves on all four sides, no block anywhere. Thumb removed (the vignette IS the art); track title + artist stacked over it.
- Verified in the offscreen harness with both layouts. Live capture blocked this round by the operator's display arrangement changing mid-session (island on a non-main screen).

## 2026-08-17 — Iteration 11: timer left / media right, break screen, skip break
- Layout swap per operator: controls | timer | media | actions. Vignette re-anchored to the right-center (x≈66%), still dissolving on all four sides — art sits under the track info, releases before the action icons.
- Break screen: replaces the timer during breaks — a rotating quiet nudge ("Stand up. Look far away." etc., seeded by completed-focus count so it changes each break) over "BREAK · MM:SS", plus a "Skip break" capsule → FocusSessionManager.skipBreak() advances straight to the next focus phase (announces Focus chip). Album vignette suppressed during breaks — the break screen owns the panel.
- Verified all three modes (media / plain / break) in the offscreen harness.

## 2026-08-17 — Iteration 12: layout revert + Meet screen-share gap closed
- Reverted to music-left / timer-right (operator preference); vignette back to x≈36%.
- ROOT CAUSE of the Meet gap: the browser blocker only read the ACTIVE tab of the FRONTMOST app's front window. During a screen share the browser often isn't frontmost, and the blocked site can be in a background window or inactive tab → never polled.
- Fix: every 2s, for EVERY running browser (not just frontmost), one AppleScript walks every window × every tab and returns "win|tab|url" lines; each blocked tab is redirected by exact window/tab index. Passes and relock-fade preserved per domain.
- Gotcha found live: inside a browser `tell` block the bare word `tab` is the tab CLASS, so the delimiter must be a literal "|" — output initially came back as "1tab2tabhttps://…" and silently never parsed.
- VERIFIED end-to-end in Comet with the operator away: (1) youtube.com in an inactive tab of a background window while Finder frontmost → redirected within one poll; (2) two more youtube tabs added to a second window with Comet HIDDEN → all three redirected, zero youtube URLs remained. Test tabs cleaned up. 21/21 unit tests still green.
- Cost: one script per running browser per poll; with ~15 tabs it's well under 100ms. Comet's own scan needs no additional permission (same Automation grant).

## 2026-08-17 — Iteration 13: the uncatchable 2-min pass
- Operator: make the pass "impossible" — a liquid-glass button that flees the cursor and returns home when it backs off. Implemented on both surfaces with identical physics: trigger radius 140pt from the button's CURRENT center; each hop 190pt directly away along the cursor→button vector with ±0.35 sideways jitter; hops bounce back toward home at the arena bounds; cursor > 2.2× radius away → springs home.
- App overlay: RunawayPassButton (SwiftUI, onContinuousHover on the arena, position-driven, 0.2s bouncy spring), GlassCapsule (ultraThinMaterial + top-down sheen + luminous rim + specular top streak + soft shadow). Panel now acceptsMouseMovedEvents.
- Block page: .pass-arena + JS mousemove with the same math; glass via backdrop-filter + inset highlights; 0.18s overshoot cubic-bezier hop, 0.6s ease home.
- VERIFIED with a puppeteer synthetic chase (40 steps, cursor always steering at the button's live position): min cursor–button gap 51px (button ~32px tall) — never catchable; after retreat, distance from home = 0px. First tuning (110/150) got within 21px mid-hop → widened.
- DEBUG_SIMULATE_BLOCK now also honors the `-DEBUG_SIMULATE_BLOCK YES` launch arg (sandbox-proof).

## 2026-08-17 — Iteration 14: runaway pass, from hops to physics
- Operator: "erratic and glitchy". Root cause: discrete random hops. Replaced with continuous physics on both surfaces: a damped particle (velocity/position integrated per frame @60Hz — JS rAF on web, Timer.publish in SwiftUI) pushed by an inverse-distance repulsion field around the pointer (radius 240, push 16000, falloff-shaped so it ramps to zero at the edge), pulled home by a soft spring, damping 0.90, speed cap 1800px/s. No randomness anywhere.
- Adaptive speed is emergent from the field: it flees at roughly the hand's speed plus a margin. Measured: creep 8px/frame → button ~7px/frame; sprint 22px/frame → ~21px/frame.
- Cornering: near a side wall it blends in a tangential component pointing home (k up to 2.2 within 200px of the wall) so it curves around the cursor back to open space instead of getting pinned. Arena widened to 760px / 76px tall.
- Measured with a puppeteer chase steering at the LIVE button position at 60Hz: min gap 20px (moderate), 13px (fast), 28px (slow) — never caught; per-frame movement max ~45–49px (old hops were 150+); returns home to ≤2px. Trajectory dumps drove each tuning step (found the wall-pin, then found the "matching pace at constant 56px gap" plateau that motivated the stronger far-field).
- SwiftUI version uses identical constants/math; verified by construction (live display capture unreliable this session).

## 2026-08-17 — Iteration 15: island sound control hidden; block page given architecture
- New Defaults key showSoundControls (default OFF) hides the wave/slider from the island entirely; engine and Settings remain (Settings → Focus sounds toggle to bring it back). Operator asked to not see it.
- Block page redesign, still flat/no-gradient/island-language: (1) hairline 96px grid vignetted to the center so the black reads as a surface, not a void; (2) short plumb line dropping from the notch silhouette — the page hangs from the island; (3) countdown scaled to a monument (clamp 120–176px, tight tracking) with a "FOCUS · REMAINING" phase label; (4) attended-minute tally regrouped in fives with a highlighted "current minute" dot; (5) accent dot before the domain eyebrow; (6) primary action gains an ↩ glyph + "closes this tab" hint; runaway glass pass unchanged. Iterated three renders (plumb initially pierced the eyebrow/digits — shortened to a 120px gesture).

## 2026-08-17 — Re-identification (branch `reidentify`)
- Full identity pass: bundle ids → com.jadonli.lockedin / .helper / .tests; project, targets, schemes, folders (LockedIn/, LockedInHelper/), files (LockedInApp, IslandCoordinator, IslandViewModel, IslandWindow, IslandSkyLightWindow, IslandAnimations, LockedInHelper*), Swift types (Boring* → Island*/LockedIn*), XPC mach service com.jadonli.lockedin.helper, product LockedIn.app, display name LockedIn, version 0.1.0 (1). 54 file headers rewritten.
- Removed: Sparkle (framework, updater UI, feed URL + public key — no LockedIn appcast exists yet), upstream imagesets (theboringteam/logo/etc.), Localizable.xcstrings (74 upstream strings), .github workflows/templates, crowdin.yml, CONTRIBUTING.md, SECURITY.md, Configuration/dmg, updater/appcast.xml. Dropped unused SPM packages Lottie / swiftui-introspect / swift-collections / Pow (12 → 7 resolved packages).
- Entitlements trimmed to what LockedIn uses (sandbox, apple-events + Spotify/Music exceptions, user-selected files, network client) — dropped camera, calendars, bookmarks, network server, Sparkle mach lookups.
- Kept on purpose: LICENSE (GPL-3.0), README credit to boring.notch/TheBoredTeam, THIRD_PARTY_LICENSES, mediaremote-adapter, and a copyright string crediting upstream. YouTube Music companion auth id "boringNotch" → "LockedIn" (protocol id, not branding).
- LegacyPreferencesMigration: one-time carry-over of focus/blocker/hotkey settings from the theboringteam.boringnotch container into the new one (marker key; read-only sandbox exception scoped to that path). Verified: youtube.com + RStudio blocklist carried over.
- BUG FOUND & FIXED: scripts/lockedin's `codesign --force --deep -s "LockedIn Dev"` STRIPPED the entitlements Xcode applied, so the app had been running unsandboxed since the stable cert was introduced (the old container survived from earlier launches, masking it). Re-sign now extracts and re-applies the entitlements.
- Verified live under the new identity: clean build, 21/21 tests, built bundle contains zero "boring" strings, hotkey → session → keep-awake assertion, media adapter spawns, app block overlay covers a real TextEdit document window (blur/dots/glass pass — screenshot); dialog sheets (layer≠0) are intentionally not covered — pre-existing behavior.
- Operator action required: new bundle id = new identity to TCC → re-grant Automation for Comet/Safari/RStudio on first block; a fresh "LockedIn wants to control…" prompt will appear at session start.

## 2026-08-17 — Browser blocking dead after re-identification: sandbox Apple Events exception
- Operator: "blocking doesn't work, I have insta and youtube blocked." Defaults correct, session live, tab-listing AppleScript works from Terminal and lists a youtube.com tab in Comet — the LockedIn process itself was the failing layer.
- ROOT CAUSE: the app is App-Sandboxed and `com.apple.security.temporary-exception.apple-events` listed only Spotify and Music. The sandbox refuses outbound Apple Events to any unlisted target (errAEEventNotPermitted) *before* TCC is consulted, so the "LockedIn wants to control Comet" prompt promised in the previous entry could never appear, and every `try?` in BrowserBlocker swallowed the error silently.
- WHY IT WORKED BEFORE: the re-sign bug fixed above — `codesign --deep` had been stripping entitlements — meant every earlier live browser-blocking test (Comet/Meet screen-share fix included) ran UNSANDBOXED, where Apple Events only need TCC. Restoring the entitlements restored the sandbox and exposed that the exception list never covered browsers.
- FIX: added all nine BrowserBlocker targets to the apple-events exception (com.apple.Safari, com.google.Chrome, company.thebrowser.Browser, company.thebrowser.dia, com.microsoft.edgemac, ai.perplexity.comet, com.operasoftware.Opera, com.brave.Browser, com.vivaldi.Vivaldi — case-sensitive, matched to real bundle ids). Rebuilt via scripts/lockedin build (entitlements re-applied, sandbox still on).
- Verified live: opened youtube.com in a new Comet tab during the running focus session → redirected to lockedin.html within 2s.
