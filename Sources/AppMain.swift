import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI

@main
struct VoiceSidecarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = SidecarAppDelegate()
        app.setActivationPolicy(.accessory) // menu-bar-only app; never steals focus when recording
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) { }
    }
}

final class SidecarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private let recorder = WAVRecorder()
    private let monitor = FnMonitor()
    private let watcher = TranscriptWatcher()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var activeID: UUID?
    private var activeSnapshot: EditableSnapshot?
    private var activeIsFn = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceSidecar")
        statusItem.button?.toolTip = "VoiceSidecar · hold Fn with Gemini"
        let menu = NSMenu(title: "VoiceSidecar")
        menu.delegate = self
        statusItem.menu = menu
        monitor.onChange = { [weak self] pressed in
            if pressed { self?.beginRecording(isFn: true) }
            else { self?.endRecording(onlyIfFn: true) }
        }
        store.status = "Ready — hold Fn to record with Gemini"
        refreshFnMonitor()
        updateMenu(menu)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording { endRecording(onlyIfFn: false) }
        monitor.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshFnMonitor()
        updateMenu(menu)
    }

    private func refreshFnMonitor() {
        if !monitor.inputMonitoringGranted {
            store.fnStatus = "Input Monitoring required — click Permissions, then restart if needed"
        } else if monitor.start() {
            store.fnStatus = monitor.keyboardCount > 0
                ? "Fn HID ready (\(monitor.keyboardCount) Apple keyboard(s))"
                : "No Apple Fn HID found — use Manual Record or a supported keyboard"
        } else {
            store.fnStatus = "Could not open keyboard HID — check Input Monitoring"
        }
    }

    private func updateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: store.isRecording ? "● RECORDING" : store.status,
                               action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let hid = NSMenuItem(title: store.fnStatus, action: nil, keyEquivalent: "")
        hid.isEnabled = false
        menu.addItem(hid)
        menu.addItem(.separator())
        menu.addItem(item("Open Review…", #selector(openReview)))
        menu.addItem(item(store.isRecording ? "Stop recording" : "Manual start recording",
                          #selector(toggleManualRecord)))
        menu.addItem(item("Request Permissions…", #selector(requestPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("Export reviewed dataset…", #selector(exportDataset)))
        menu.addItem(item("Open recordings folder", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit VoiceSidecar", #selector(quit)))
    }

    private func item(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: store.isRecording ? "record.circle.fill" : "waveform",
                                           accessibilityDescription: "VoiceSidecar")
        statusItem.button?.image?.isTemplate = true
    }

    private func beginRecording(isFn: Bool) {
        guard !recorder.isRecording else { return }
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        guard access == .authorized else {
            store.status = "Microphone permission needed — Request Permissions, then try again"
            if access == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            return
        }
        // Capture target BEFORE opening any app window. Snapshot text is held only in memory.
        let snapshot = EditableSnapshot.capture()
        do {
            let session = try store.prepareSession(sourceApp: snapshot?.appName ??
                                  NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown",
                               captureMethod: isFn ? "Fn hold" : "Manual")
            do {
                try recorder.start(url: store.audioURL(for: session))
                activeID = session.id
                activeIsFn = isFn
                activeSnapshot = snapshot
                store.isRecording = true
                store.status = "Recording lossless WAV (Fn release stops)"
                updateIcon()
            } catch {
                store.discard(session.id)
                throw error
            }
        } catch {
            store.status = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func endRecording(onlyIfFn: Bool) {
        guard let id = activeID, recorder.isRecording,
              !onlyIfFn || activeIsFn else { return }
        let snapshot = activeSnapshot
        activeID = nil
        activeSnapshot = nil
        store.isRecording = false
        updateIcon()
        do {
            let audio = try recorder.stop()
            let seconds = Double(audio.framesWritten) / Double(max(audio.sampleRate, 1))
            if seconds < 0.45 { // Ignore ordinary quick Fn taps; not useful TTS training.
                store.discard(id)
                store.status = "Short Fn tap ignored"
                return
            }
            store.complete(id, sampleRate: audio.sampleRate, frameCount: audio.framesWritten)
            store.status = "WAV saved · waiting up to 18 s for Gemini insertion"
            watcher.follow(snapshot: snapshot, sessionID: id) { [weak self] sessionID, text in
                self?.store.addGeminiResult(text, for: sessionID)
            }
            if snapshot == nil {
                store.status = "WAV saved · Gemini text unavailable; paste into Review"
            }
        } catch {
            store.status = "Could not finish WAV: \(error.localizedDescription)"
        }
    }

    @objc private func toggleManualRecord() {
        if recorder.isRecording { endRecording(onlyIfFn: false) }
        else { beginRecording(isFn: false) }
    }

    @objc private func requestPermissions() {
        // These permissions are granted by macOS. No keylogging or synthetic events.
        monitor.requestInputMonitoring()
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Any] = [key: kCFBooleanTrue as Any]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshFnMonitor() }
            }
        }
        store.status = "Enable Input Monitoring, Accessibility, Microphone in System Settings"
        showAlert(title: "Permissions for VoiceSidecar", message: "Enable VoiceSidecar under System Settings → Privacy & Security → Microphone, Input Monitoring, and Accessibility. You may need to quit and reopen after granting Input Monitoring.\n\nIf Fn still does not work, use Manual start recording as a fallback.")
    }

    @objc private func openFolder() { store.openDataFolder() }

    @objc private func openReview() {
        if window == nil {
            let root = Dashboard(store: store,
                                 onExport: { [weak self] in self?.exportDataset() },
                                 onPermissions: { [weak self] in self?.requestPermissions() },
                                 onManualToggle: { [weak self] in self?.toggleManualRecord() })
            let host = NSHostingView(rootView: root)
            let newWindow = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 1020, height: 700),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
            newWindow.title = "VoiceSidecar — TTS Dataset Review"
            newWindow.contentView = host
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func exportDataset() {
        let picker = NSOpenPanel()
        picker.prompt = "Export Here"
        picker.message = "Select a parent folder for the exported TTS dataset"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let parent = picker.url else { return }
        do {
            let report = try store.exportDataset(into: parent)
            showAlert(title: "Dataset exported", message:
                "Exported \(report.exported) reviewed clips. Excluded \(report.excluded) unreviewed, too short, or too long recordings.\nVoice reference clips: \(report.voiceReferences).\n\n\(report.url.path)")
            NSWorkspace.shared.open(report.url)
        } catch {
            showAlert(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
