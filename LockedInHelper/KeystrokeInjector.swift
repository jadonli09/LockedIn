//
//  KeystrokeInjector.swift
//  LockedInHelper
//
//  Synthesizes keystrokes via CGEvent, posted at the HID tap so they reach the
//  lock screen's secure password field. Lives in the unsandboxed helper: the
//  HID tap needs Accessibility trust, which the sandboxed app can't hold.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import os

let faceUnlockLog = Logger(subsystem: "com.jadonli.lockedin.helper", category: "FaceUnlock")

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed
    case screenNotLocked

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required for LockedInHelper (System Settings → Privacy & Security → Accessibility)."
        case .eventCreationFailed:
            return "Couldn't create the keyboard event."
        case .screenNotLocked:
            return "Refused: the screen is not locked."
        }
    }
}

enum KeystrokeInjector {
    /// Gap between synthesized key events. loginwindow keeps up at 5 ms; Glance's
    /// 12 ms made an 11-character password take ~0.5 s.
    private static let keyInterval: TimeInterval = 0.005

    /// Authoritative lock state from the CoreGraphics session server — not a
    /// spoofable notification. Fails closed if unavailable, so the password is
    /// never typed into a random text field on an unlocked desktop.
    ///
    /// The XPC service often isn't attached to the GUI session, so
    /// `CGSessionCopyCurrentDictionary()` returns nil here even while the app
    /// sees it fine. WindowServer mirrors the same flag into the I/O Registry's
    /// `IOConsoleUsers`, which any process can read — that's the fallback.
    static func isScreenActuallyLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
            faceUnlockLog.info("lock check (CGSession): \(locked, privacy: .public)")
            return locked
        }
        let locked = consoleUserScreenIsLocked()
        faceUnlockLog.info("lock check (IOConsoleUsers, no CGSession): \(String(describing: locked), privacy: .public)")
        return locked ?? false
    }

    /// nil if the registry has no console entry for this user.
    private static func consoleUserScreenIsLocked() -> Bool? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        let uid = getuid()
        guard let me = users.first(where: { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }) else {
            return nil
        }
        return (me["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses
    /// Return. Takes `Data` so the caller can hold the plaintext as a zero-able
    /// buffer; the brief internal `String` decode is scoped to this call. Blocking.
    static func typeAndReturn(_ passwordBytes: Data) throws {
        guard AXIsProcessTrusted() else { throw KeystrokeError.accessibilityNotGranted }
        guard isScreenActuallyLocked() else { throw KeystrokeError.screenNotLocked }
        guard let text = String(data: passwordBytes, encoding: .utf8) else {
            throw KeystrokeError.eventCreationFailed
        }
        let source = CGEventSource(stateID: .hidSystemState)
        try clearFocusedField(source: source)
        for char in text {
            try postUnicode(String(char), source: source)
        }
        try postReturn(source: source)
    }

    /// Wipes anything already typed into the focused field (a stray keypress on
    /// the lock screen) so it isn't prepended to the password: ⌘→ to the end,
    /// then ⌘⌫ back to the start. Positional keys, so layout-independent.
    private static func clearFocusedField(source: CGEventSource?) throws {
        let rightArrow: CGKeyCode = 0x7C
        let delete: CGKeyCode = 0x33
        try postKey(rightArrow, flags: .maskCommand, source: source)
        try postKey(delete, flags: .maskCommand, source: source)
    }

    /// Posts a virtual key down/up, wrapped in a real ⌘ down/up when `flags`
    /// includes `.maskCommand` — some text fields ignore a bare flag without it.
    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) throws {
        let command: CGKeyCode = 0x37
        let usesCommand = flags.contains(.maskCommand)
        if usesCommand {
            guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true) else {
                throw KeystrokeError.eventCreationFailed
            }
            commandDown.flags = .maskCommand
            commandDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: keyInterval)
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        if usesCommand {
            guard let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else {
                throw KeystrokeError.eventCreationFailed
            }
            commandUp.flags = []
            commandUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: keyInterval)
        }
    }

    /// Per-character Unicode injection — bypasses keyboard layout issues.
    private static func postUnicode(_ unicode: String, source: CGEventSource?) throws {
        let utf16 = Array(unicode.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        utf16.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            }
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
    }

    /// Physical Return key (virtual key 0x24).
    private static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        keyUp.post(tap: .cghidEventTap)
    }
}
