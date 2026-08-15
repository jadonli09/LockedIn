# OVERNIGHT AUTONOMOUS BUILD — LockedIn (macOS Focus Island)

> Companion file: `lockedin-build-spec.md` in this same folder. That file is the **binding product spec** — every feature, state, API choice, and aesthetic constraint. This file governs **process and autonomy**. Product conflict → spec wins. Process conflict → this file wins.

---

## INPUTS

### Core

- **`{{TIME_BUDGET}}`** → **4 hours maximum.** Check the clock with `date` at every phase boundary. At T-minus 30 minutes, stop all feature work and execute the Stabilize phase no matter what state you're in.

### Project specification

- **What to build** → LockedIn: a minimal Dynamic Island for the MacBook notch focused entirely on deep work. Native Swift/SwiftUI, built by stripping a fork of `boring.notch` down to its notch-window core and building focus features on top. Full detail: `lockedin-build-spec.md`.
- **Context & background** → The notch-app market (NotchNook, Alcove, Sapphire, MacNotch, Notchy) is media-first and feature-bloated. LockedIn wins on restraint + a real blocker. The spec's KEEP/DELETE lists were derived from the actual boring.notch file tree — trust them, but verify dependencies before deleting.
- **Design requirements** → Spec section "AESTHETIC CONSTRAINTS" is law and overrides every generic design default in this template. Pure #000 at rest, one accent (#E8A87C default), SF Pro Rounded, SF Symbols, springs only, no red, no badges.
- **Technical requirements** → Swift 5.10+, SwiftUI, macOS 14+, Apple Silicon. Build with `xcodebuild` CLI. Ad-hoc signing is fine for tonight. Reuse boring.notch's animation physics untouched.
- **Features (priority order)** →
  - **Must (tonight's definition of done):** spec Build Phases 1–4 — strip to clean empty island, idle glow states, Pomodoro engine + expanded UI + ⌥⌘L hotkey, invisible behaviors (keep-awake, idle auto-pause, Auto-DND code path).
  - **Should:** Phases 5–6 — focus sounds, app blocker + overlay + 2-min pass.
  - **Stretch (only if genuinely ahead):** Phases 7–9 — browser tab blocker, media row, settings window.
  - Never start a Should while a Must is broken. Never start a Stretch before all Shoulds are done or consciously skipped with a log entry.
- **Seed data / content** → None. If CC0 audio can't be sourced from allowed networks, synthesize: generate brown noise as a WAV programmatically (integrated white noise, normalized), a short sine-based chime for session end. Rain/Café become morning TODOs.
- **Deployment** → None. Deliverable is a locally built, launchable `LockedIn.app` + a green `xcodebuild` + committed repo.
- **Success criteria** →
  1. `xcodebuild -scheme <scheme> -configuration Debug build` exits 0 with no errors.
  2. App launches via `open`, runs 60+ seconds, no crash reports in `~/Library/Logs/DiagnosticReports`.
  3. Island renders at the notch; hover expand/collapse animates with original spring physics (verify visually — see Screenshot Verification below).
  4. A short test session (set a 1-min focus preset in code/UserDefaults for testing) runs end-to-end: accent arc drains, end pulse + chime fires, break auto-advances.
  5. `pmset -g assertions` shows the display-sleep assertion during focus and gone after.
  6. XCTest suite passes: timer state machine incl. persistence across relaunch, idle-pause accounting, blocklist matcher, 2-min pass expiry.
  7. Every phase = one git commit on branch `overnight-v1`. `FINAL_REPORT.md` and `MORNING_CHECKLIST.md` exist and are honest.

### Research targets

Not web research — **codebase archaeology** (first ~20 min):
- Map the dependency graph of every file on the spec's KEEP list: what do they import, what imports them. Produce `RESEARCH_NOTES.md` with the actual safe deletion order.
- Identify how the XPC media helper + `mediaremote-adapter` are wired into the build (targets, build phases, entitlements) so stripping doesn't orphan them.
- Note the exact spring/animation parameter values in `animations/` and `sizing/` that must survive.
- Confirm which SPM packages the project pulls (KeyboardShortcuts, Sparkle, Lottie?) and which can be dropped with the deleted features.

### Implementation phases (240 min total)

| # | Phase | Time | Covers |
|---|-------|------|--------|
| 0 | Preflight + archaeology | 20 | Verify `xcodebuild -version` works; clone repo if absent; branch `overnight-v1`; dependency mapping → `RESEARCH_NOTES.md` |
| 1 | Strip to empty island | 40 | Spec Phase 1. Delete in small batches, build between batches, commit each green state |
| 2 | Idle states | 25 | Spec Phase 2: ambient glow + session arc + optional minutes numeral |
| 3 | Pomodoro + expanded UI + hotkey | 50 | Spec Phase 3. Timestamp-based engine, persistence, pulse + chime, ⌥⌘L |
| 4 | Invisible behaviors | 30 | Spec Phase 4: keep-awake assertion, idle auto-pause, Auto-DND via `shortcuts` CLI (code path + graceful no-op) |
| 5 | Focus sounds | 20 | Spec Phase 5, synthesized audio fallback allowed |
| 6 | App blocker + 2-min pass | 30 | Spec Phase 6. Runtime needs Accessibility permission you cannot grant — build it, unit-test the logic, add a DEBUG simulation flag, defer live verify to morning |
| 7 | Stabilize + report | 30 | **Hard reserve, non-negotiable.** Full test pass, fix, re-test, `FINAL_REPORT.md`, `MORNING_CHECKLIST.md`, final commit |

Stretch phases (browser blocker, media row, settings) may only consume time left over after Phase 7's reserve is protected.

---

# STANDING INSTRUCTIONS

## SYSTEM DIRECTIVE

You are operating in **full autonomy mode** for 4 hours. The operator is asleep. These rules override defaults.

**Rule 1: Never ask for permission.** Every decision is yours within the spec's constraints. Undefined details → best judgment, log it, move on.

**Rule 2: Done = Musts complete + Phase 7 executed.** You are finished when Must phases work, tests pass, and the reports are written — not when all nine spec phases exist. A polished core beats nine half-features. Do not send partial updates.

**Rule 3: If blocked, pivot in under 5 minutes.** Use the Pivot Playbook below. The build matters more than any single tool or feature.

**Rule 4: Phases are atomic; git is your safety net.** Complete each phase, run the build, commit with a descriptive message, append a timestamped entry to `BUILD_LOG.md` (what was done, decisions, pivots, known issues). If a phase goes sideways, `git checkout` back to the last green commit and take a smaller bite.

**Rule 5: Time-box honestly.** Check `date` at every phase boundary. A phase at 2x its budget → ship the 80% version, log the remainder, move on.

**Rule 6: Test before declaring done.** The web checklist doesn't apply. This one does:
- [ ] Clean `xcodebuild` (Debug) exits 0
- [ ] App launches, survives 60s, zero new crash reports in `~/Library/Logs/DiagnosticReports`
- [ ] Idle CPU < 2% (`top -l 3 -pid <pid>` after the island settles)
- [ ] Full XCTest suite green (`xcodebuild test` on the test scheme)
- [ ] `pmset -g assertions` clean after session ends (no leaked assertions)
- [ ] Screenshot Verification: capture the notch region with `screencapture -x -R<x,y,w,h> shot.png` (top-center of the main display) in idle, session-running, and hovered states — hover can be induced by scripting the cursor with `cliclick` if installed, otherwise CGEvent-post a mouse-move in a tiny debug utility — then **look at the images** and judge them against the spec's states. If it doesn't look like the spec, it isn't done.
- [ ] Every file compiles with zero warnings introduced by new code

**Rule 7: One final message, plus two files.** Communicate nothing until complete. The final message and `FINAL_REPORT.md` contain: status (Complete / Complete with limitations), what was built per phase, what was cut and why, architecture of the new code, test results verbatim, known issues, and exact commands to build + run. `MORNING_CHECKLIST.md` is the operator's 10-minute wake-up script: permissions to grant (Accessibility, per-browser Automation), the Shortcuts to install for Auto-DND, features to verify by hand (hover feel, blocker overlay, pass flow), and any decisions awaiting a human.

## PIVOT PLAYBOOK (macOS edition)

| Blocker | Pivot |
|---------|-------|
| Stripping breaks the build in tangled ways | Revert to last green commit; delete in smaller batches; if a KEEP file depends on a DELETE file, extract the needed piece into a new small file rather than keeping the whole feature |
| `mediaremote-adapter` / XPC helper won't build or run | Put Now Playing behind a protocol, ship a stub implementation, log as limitation (media is a Stretch anyway) |
| SPM dependency resolution fails | Retry once with `-clonedSourcePackagesDirPath`; else vendor the package source into the repo; else drop the dependent feature |
| Code signing errors from `xcodebuild` | Ad-hoc sign: `CODE_SIGNING_ALLOWED=NO` for build checks or `codesign --force --deep -s - LockedIn.app` before launch |
| `shortcuts` CLI missing/denied | Auto-DND silently no-ops exactly as the spec prescribes; leave the code path + morning TODO |
| Can't source CC0 audio | Synthesize brown noise + chime programmatically; Rain/Café → morning TODO |
| Accessibility/Automation-gated behavior can't run live | Unit-test the pure logic; add `DEBUG_SIMULATE_BLOCK` flag that fakes a blocked-app activation so the overlay is screenshot-verifiable |
| A spec detail is ambiguous | Choose the more minimal interpretation, log it |
| Architecture realization mid-build | <30% into the phase: refactor. Otherwise: finish, note the debt |

## QUALITY STANDARDS

- Timer logic uses wall-clock timestamps, never accumulated `Timer` ticks (spec §Pomodoro 3) — it must survive app relaunch and system sleep.
- UI state on `@MainActor`; `[weak self]` in escaping closures; no new force-unwraps outside tests.
- No dead code, no commented-out corpses from the stripping phase — delete means delete.
- New files follow the existing project's folder conventions (`managers/`, `components/`, etc.).
- Spec aesthetic constraints are binding: if a template default here ever contradicts the spec (fonts, colors, dark mode), the spec wins.

## REMINDER

Four hours is enough for a beautiful core. Don't skip the archaeology — deleting blind is how the whole night dies in Phase 1. Don't skip Phase 7 — an untested app plus no morning checklist means the operator wakes up to a mystery, not a product. The only message you send is the final one. Make it count.

**Go.**
