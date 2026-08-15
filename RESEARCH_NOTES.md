# RESEARCH_NOTES — boring.notch dependency archaeology (Phase 0)

Date: 2026-08-14 17:55–18:05 PDT. Baseline `xcodebuild -scheme boringNotch -configuration Debug` on untouched main: **exit 0, ~90s**.

## Project mechanics (important)

- **Xcode 16 filesystem-synchronized groups** (`PBXFileSystemSynchronized*` in pbxproj, only 8 refs, 138 PBXBuildFile entries are for frameworks/resources). Deleting a `.swift` file from disk removes it from the build automatically — no pbxproj surgery needed for source deletions.
- Two targets: `boringNotch` (app) and `BoringNotchXPCHelper` (XPC service, used for accessibility-privileged media-key + Now Playing via `mediaremote-adapter` framework, vendored at repo root). The XPC helper is embedded via explicit build phases — do not touch its target wiring.
- SPM packages: Defaults (everywhere — keep), KeyboardShortcuts (keep), Sparkle (keep dormant), SkyLightWindow (BoringNotchSkyLightWindow — keep), MacroVisionKit (FullscreenMediaDetection — keep), AsyncXPCConnection (XPCHelperClient — keep), swiftui-introspect (ContentView/Settings/Welcome imports — trivially removable imports; keep package, unused is fine), LaunchAtLogin (Settings; keep), **Lottie (only LottieView.swift + Music/LottieAnimationView.swift — orphaned after delete)**, Pow (imported only by deleted battery/shelf UI), swift-collections (transitive). Packages left resolved but unreferenced are harmless tonight.

## Animation values that must survive (the product)

- `ContentView.swift`: `animationSpring = .interactiveSpring(response: 0.38, dampingFraction: 0.8)` (hover/gesture); open: `.spring(response: 0.42, dampingFraction: 0.8)`; close: `.spring(response: 0.45, dampingFraction: 1.0)`; content transition `.scale(0.8, anchor: .top) + .opacity, .smooth(0.35)`.
- `animations/drop.swift` (`BoringAnimations.animation` = `.spring(.bouncy(duration: 0.4))`).
- `sizing/matters.swift`: `openNotchSize = 640×190`, `cornerRadiusInsets = (opened: (19, 24), closed: (6, 14))`, `getClosedNotchSize()` (notch-width from auxiliaryTopLeft/RightArea + 4).
- Hover mechanics: `minimumHoverDuration` default 0.3s, 100ms close debounce.

## Media/XPC stack — internal dependency chain (keep intact)

`MusicManager` → `MediaChecker`, `AppIcons(AppIconAsNSImage)`, controllers via `MediaControllerProtocol`/`PlaybackState`; `SpotifyController`/`YouTubeMusicController` → `ImageService`; `NowPlayingController` → `XPCHelperClient` → AsyncXPCConnection → `BoringNotchXPCHelper` target → `mediaremote-adapter/` framework. `FullscreenMediaDetector` (MacroVisionKit) → `BoringViewModel.hideOnClosed`. **Keep all of:** `MediaControllers/`, `XPCHelperClient/`, `managers/MusicManager.swift`, `models/PlaybackState.swift`, `helpers/{MediaChecker,AppIcons,AudioPlayer}.swift`, `managers/ImageService.swift`, `extensions/NSImage+Extensions.swift`, `observers/FullscreenMediaDetection.swift`, `BoringNotchXPCHelper/`, `mediaremote-adapter/`.

## Safe deletion order

Everything below is deletable in **one batch** provided the six shell files are rewritten in the same commit (they are the only kept files referencing them):

1. Self-contained feature trees: `components/Shelf/`, `components/Calendar/`, `components/Webcam/`, `components/Tips/`, `components/Live activities/`, `components/Music/`, `components/Onboarding/` (rebuild minimal later), `metal/`, `Providers/`, `menu/StatusBarMenu.swift` (already unreferenced).
2. Leaf components: `AnimatedFace.swift`, `EmptyState.swift`, `LottieView.swift`, `WhatsNewView.swift`, `TestView.swift`, `Notch/NotchHomeView.swift`, `Notch/BoringHeader.swift`, `Notch/BoringExtrasMenu.swift`, `Settings/{EditPanelView,MusicSlotConfigurationView,ListItemPopover}.swift`.
3. Managers/models/observers: `CalendarManager`, `WebcamManager`, `BatteryActivityManager`, `BrightnessManager`, `VolumeManager`, `CalendarModel`, `EventModel`, `BatteryStatusViewModel`, `SharingStateManager`, `MusicControlButton`, `DragDetector`, `MediaKeyInterceptor`.
4. Helpers/extensions orphaned by (1–3): `Clipboard+Content`, `AssociatedObject.swift`, `NSMenu+AssociatedObject`, `ActionBar`, `NSItemProvider+LoadHelpers`, `URL+SecurityScoped`.
5. `Shortcuts/ShortcutConstants.swift` — **not** Apple-Shortcuts intents; it's the KeyboardShortcuts.Name table. Needed names move into `extensions/KeyboardShortcutsHelper.swift`; rest (mic/backlight/clipboard) die with their features.
6. `boring.m4a` welcome sound.

## Shell files to rewrite in the same commit

`boringNotchApp.swift` (drop MenuBarExtra content → spec wants empty menu bar; drop onboarding/QuickShare/DragDetector/WhatsNew/welcome-sound), `ContentView.swift` (keep hover/gesture/shape/spring skeleton; content = hello anim / idle / LockedIn panel), `BoringViewCoordinator.swift` (keep screen UUID handling + firstLaunch; drop sneakPeek/expandingView/HUD/MediaKeyInterceptor/XPC-accessibility), `models/BoringViewModel.swift` (drop webcam/drop-zones/shelf/battery/calendar), `enums/generic.swift` (trim), `models/Constants.swift` (trim deleted-feature Defaults keys), `components/Settings/SettingsView.swift` (minimal rewrite; window controller + SoftwareUpdater kept).

## Watch-outs

- `BoringViewCoordinator.currentView: NotchViews` (home/shelf) is load-bearing in ContentView/AppDelegate — remove the concept entirely (single view).
- `Defaults[.showNotHumanFace]`, `.boringShelf`, `.hudReplacement` etc. referenced from shell files — remove key + usage together.
- `MusicManager.shared.forceUpdate()` called in `BoringViewModel.open()` — keep (media stack stays).
- `Constants.swift` `defaultMediaController` references `MusicManager.shared` — keep.
- App bundle id / display name: rename to LockedIn is a Phase-1 nicety; product renaming kept minimal (display name only) to avoid breaking XPC helper bundle-id references. XPC mach service name is looked up by bundle id — **do not change bundle identifiers tonight.**
