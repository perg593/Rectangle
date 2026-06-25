/// Divvy2SpikeHelper — main.swift
///
/// THROWAWAY M0.5 spike helper app. A single resizable titled window with NO
/// document model and state restoration OFF, so the spike can launch/terminate it
/// as a controlled, disposable cross-app window-move target without any risk to
/// the user's real apps or documents.
/// See docs/2026-06-23-Design-M0.5-Architecture-Spike.md §3.

import Cocoa

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 200, y: 200, width: 600, height: 400)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Divvy2 Spike Helper"
        window.isRestorable = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = HelperAppDelegate()
app.delegate = delegate
app.run()
