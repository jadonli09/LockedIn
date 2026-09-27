> **Note (2026-08-17):** this document is the historical record from the overnight build. The project has since been fully re-identified as LockedIn — scheme `LockedIn`, product `LockedIn.app`, bundle id `com.jadonli.lockedin`. Where this file says `boringNotch` / `theboringteam.boringnotch`, read the new names; `./scripts/lockedin build|start|stop|restart` is the current way to run it.

# MORNING_CHECKLIST — 10 minutes to a fully live LockedIn

Everything below needs a human at the keyboard; the code paths are built, tested where possible, and silently no-op until you do these.

## 0. Build & launch (1 min)

```sh
cd ~/Downloads/LockedIn.notch
xcodebuild -scheme boringNotch -configuration Debug build -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
codesign --force --deep -s - build/DerivedData/Build/Products/Debug/boringNotch.app
open build/DerivedData/Build/Products/Debug/boringNotch.app
```

(Or open `boringNotch.xcodeproj` in Xcode and hit Run. Branch: `overnight-v1`.)

## 1. Feel the things automation couldn't (3 min)

- [ ] **Hover** over the notch → island should spring open (synthetic mouse events never trigger SwiftUI hover, so this is verified by tap only — the one untested interaction). Also check the hover-out close feel.
- [ ] **⌥⌘L** → island pulses amber + session starts. Check the closed state: thin amber arc draining along the bottom edge + small "25" numeral right of the notch.
- [ ] **Long-press the center timer for 5s** → white ring fills, session ends. (Ring logic is coded and gestures work, but a 5-second synthetic press wasn't automated.)
- [ ] Tap the timer while idle to cycle presets 25/5 → 50/10 → 90/15.
- [ ] Wave icon in the expanded panel → brown noise fades in; volume slider appears. Play Spotify → noise should duck; pause → it should return.

## 2. Auto-DND Shortcuts (2 min)

The `shortcuts` CLI path is wired and silently no-ops right now.

- [ ] Open Shortcuts.app → new shortcut → add **Set Focus** action → "Turn Do Not Disturb **On** until Turned Off" → name it exactly `LockedIn Focus On`.
- [ ] Duplicate → change to Turn DND **Off** → name it `LockedIn Focus Off`.
- [ ] Start a session; the macOS Focus moon should light up. Pause; it should clear.

## 3. Browser blocker — Automation permission (2 min)

- [ ] Settings (right-click the island) → Blocked websites → add `x.com` (or your poison).
- [ ] Start a session, switch to Safari/Chrome/Arc/Edge, open the domain. First poll will trigger the macOS **Automation** prompt ("LockedIn wants to control Safari") → allow per browser you use.
- [ ] Tab should redirect to the black "Locked in — MM:SS left" page. Click **2-min pass** → browser asks to open LockedIn → allow → tab returns to the original URL for 120s, then the block page fades back in over 3s.
- [ ] Note: the app must be launched at least once for `lockedin://` to register with LaunchServices (already true if you did step 0).

## 4. App blocker sanity (1 min — already machine-verified end-to-end)

- [ ] Settings → Blocked apps → Add app… → pick something distracting.
- [ ] Start a session, open the app → full-screen overlay. "Back to work" returns to the previous app; "2-min pass" gives 120s then auto-relocks (verified live with TextEdit last night, including the 120s relock).

## 5. Sounds still TODO

- [ ] Rain + Café loops: source CC0 files (freesound.org, CC0 filter), drop into `boringNotch/` as `rain.wav` / `cafe.wav`, add cases to `FocusSound` in `managers/FocusSoundManager.swift`, register with `python3 scripts/add_source_file.py` — resources need the Resources-phase variant used in git history (see Phase 5 commit). Brown noise ships already (synthesized, self-made, license-clean).

## Decisions awaiting you (nothing blocking)

- Rename: everything user-visible says LockedIn; bundle id is still `theboringteam.boringnotch` because the XPC helper + Sparkle feed reference it. A rename is a coordinated change across app + XPC helper + appcast (v1-ship task, not a morning task).
- Sparkle: still points at upstream's appcast (harmless; updates check will just find their releases — consider disabling the auto-check until you host your own feed).
- The menu bar icon is OFF by default per the "empty menu bar" law; Quit lives in the island's right-click menu. Toggle the icon in Settings if you want a visible escape hatch.
- The idle glow is 15% opacity per spec — it is *very* faint on a bright wallpaper. If you want it more present, it's one number in `FocusIdleView.swift`.


## Face ID (added 2026-09-26, ~5 min, all opt-in)

Nothing below runs until you flip the switches; the camera never starts on its own.

- [ ] Settings → **Face ID**: click **Allow…** next to Camera (system prompt). If it says Denied: System Settings › Privacy & Security › Camera → LockedIn.
- [ ] **Accessibility (helper)** → **Grant…** → enable *LockedInHelper* in System Settings › Privacy & Security › Accessibility. This is what types the password on the lock screen; the sandboxed app can't.
- [ ] **Face** → **Enroll…** → follow the ring: look at the camera, then the 8 directions it lights up (2 samples each, ~30 s). Good lighting, no hat.
- [ ] **Mac password** → type it in the field → **Save**. It's stored in the app's Keychain item and is never shown again; **Remove** clears it.
- [ ] **Face unlock** → turn on "Unlock the Mac with my face" (On wake + On lock are preselected). Leave Liveness on *Light* unless you want to require a blink/head turn (*Heavy*).
- [ ] Test: ⌃⌘Q to lock → the notch shows the face-id glyph with an orbiting arc ("Looking…"), then "Unlocked" and the password is typed. If it says "Not recognized", re-enroll in the lighting you actually sit in.
- [ ] **Presence** → "Pause the session when I leave the desk" (default: away after 1 min). Start a session, walk away for the threshold → island shows "Away", session pauses (backdated), sound fades; sit back down → "Welcome back", session resumes.
- [ ] Optional: "Require my face to end a session early" → the 5 s end-hold and blocklist removals first check it's you; if the camera can't see you, hold 15 s instead.
- Note: a re-signed dev build with a *different* identity will make the Keychain prompt for the password item and the face-data key; `./scripts/lockedin build` keeps the stable "LockedIn Dev" identity so this doesn't happen.
