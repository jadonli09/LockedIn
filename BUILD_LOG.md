# BUILD_LOG — LockedIn overnight-v1

## 2026-08-14 17:59 PDT — Phase 0: Preflight + archaeology (17:55–18:05)
- Baseline build of untouched main: green (exit 0, ~90s). Xcode 26.6, macOS 26.6.
- Project uses Xcode 16 filesystem-synced groups: disk deletion == build removal. Huge win for stripping.
- Dependency map in RESEARCH_NOTES.md. Media/XPC stack kept intact per spec KEEP list.
- Decision: ShortcutConstants.swift (KeyboardShortcuts names) folded into KeyboardShortcutsHelper.swift rather than kept as Shortcuts/ folder (spec DELETE list targets Apple-Shortcuts features; this file is the hotkey name table).
- Decision: bundle identifiers unchanged tonight (XPC helper service discovery depends on them); rename is display-name only.
