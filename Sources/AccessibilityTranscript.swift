import Foundation
import AppKit
import ApplicationServices

/// A snapshot of the *focused editable element* at the moment recording begins.
/// Only a text delta is saved, never the original document's contents.
final class EditableSnapshot {
    let appName: String
    private let element: AXUIElement
    private let before: String

    private init(element: AXUIElement, before: String, appName: String) {
        self.element = element
        self.before = before
        self.appName = appName
        AXUIElementSetMessagingTimeout(element, 0.6)
    }

    static func capture() -> EditableSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.6)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        let role = readString(focused, key: kAXRoleAttribute as CFString) ?? ""
        // Never inspect password fields. Only text-like roles; avoid whole-window captures.
        guard !role.localizedCaseInsensitiveContains("secure"),
              ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView"]
                .contains(role) else { return nil }
        guard let current = readString(focused, key: kAXValueAttribute as CFString),
              current.count <= 50_000 else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown app"
        return EditableSnapshot(element: focused, before: current, appName: appName)
    }

    func insertedText() -> String? {
        guard let after = Self.readString(element, key: kAXValueAttribute as CFString),
              after.count <= 50_000, after != before else { return nil }
        // Compute the changed text between the longest common prefix and suffix.
        // Swift Character preserves Thai combining marks better than splitting bytes.
        let old = Array(before)
        let new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard newEnd >= prefix else { return nil }
        let inserted = String(new[prefix..<newEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid accidentally treating a large manual document rewrite as speech.
        guard !inserted.isEmpty, inserted.count <= 10_000 else { return nil }
        return inserted
    }

    private static func readString(_ element: AXUIElement, key: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        return value as? String
    }
}

/// Polls briefly after Fn release, because Gemini inserts its result asynchronously.
final class TranscriptWatcher {
    func follow(snapshot: EditableSnapshot?, sessionID: UUID,
                result: @escaping (UUID, String) -> Void) {
        guard let snapshot else { return }
        var lastSeen = ""
        var stableTicks = 0
        let deadline = Date().addingTimeInterval(18)
        let timer = Timer(timeInterval: 0.6, repeats: true) { timer in
            if let text = snapshot.insertedText() {
                if text == lastSeen { stableTicks += 1 }
                else { lastSeen = text; stableTicks = 0 }
                if stableTicks >= 2 {
                    result(sessionID, text)
                    timer.invalidate()
                    return
                }
            }
            if Date() >= deadline {
                if !lastSeen.isEmpty { result(sessionID, lastSeen) }
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
