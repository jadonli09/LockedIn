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

        // Sandbox: ~/Library/Containers/<legacy-id>/Data/Library/Preferences/<legacy-id>.plist
        // resolves relative to the *real* home even from inside our own container.
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.jadonli.lockedin/Data", with: "")
        let legacyPlist = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Containers/\(legacyBundleID)/Data/Library/Preferences/\(legacyBundleID).plist")

        guard let data = try? Data(contentsOf: legacyPlist),
              let legacy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }

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
