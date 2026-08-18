//
//  LegacyPreferencesMigration.swift
//  LockedIn
//
//  One-time carry-over of settings written under the pre-rename bundle id
//  (theboringteam.boringnotch) into com.jadonli.lockedin. Sandboxed apps
//  keep their preferences in per-container plists, so this reads the old
//  container's plist directly and copies any key we don't already have.
//  Runs before any singleton touches Defaults; a marker key makes it a no-op
//  forever after.
//

import Foundation

enum LegacyPreferencesMigration {
    private static let legacyBundleID = "theboringteam.boringnotch"
    private static let markerKey = "didMigrateLegacyPreferences_v1"

    /// Only these keys carry over — the focus/blocker settings a user would
    /// miss. Upstream media/UI keys are left behind on purpose.
    private static let keysToCarry: [String] = [
        "focusAccent", "lastFocusPreset", "longBreaksEnabled", "showRemainingMinutes",
        "idleAutoPauseEnabled", "autoDNDEnabled", "blockedBundleIDs", "blockedDomains",
        "lastFocusSound", "focusSoundVolume", "showSoundControls",
        "focusSessionState", "firstLaunch", "preferred_screen_uuid",
        "menubarIcon", "showOnAllDisplays", "openNotchOnHover", "minimumHoverDuration",
        "enableHaptics", "mediaController",
        "KeyboardShortcuts_toggleFocusSession",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        defer { defaults.set(true, forKey: markerKey) }

        // Inside our sandbox, ~ resolves to our own container; the legacy
        // container lives under the real home. Try the real home first (via
        // the account's pw_dir), then fall back to whatever ~ resolves to.
        let realHome = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let candidates = [realHome, NSHomeDirectory()].map { home in
            URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Containers/\(legacyBundleID)/Data/Library/Preferences/\(legacyBundleID).plist")
        }
        guard let legacyPlist = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: legacyPlist),
              let legacy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            NSLog("LockedIn: no legacy preferences found to migrate")
            return
        }

        var carried = 0
        for key in keysToCarry where defaults.object(forKey: key) == nil {
            if let value = legacy[key] {
                defaults.set(value, forKey: key)
                carried += 1
            }
        }
        NSLog("LockedIn: migrated \(carried) legacy preference(s) from \(legacyBundleID)")
    }
}
