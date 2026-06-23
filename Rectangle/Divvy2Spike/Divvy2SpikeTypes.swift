/// Divvy2SpikeTypes.swift
///
/// M0.5 architecture-spike, THROWAWAY types (not the production M1/M2 model).
/// See docs/2026-06-23-Design-M0.5-Architecture-Spike.md.
///
/// These prove the parallel custom-layout data path:
///   - `HotkeyData` mirrors Rectangle's own `Shortcut` Codable (WindowAction.swift),
///     which is the canonical on-disk MASShortcut representation
///     ({ keyCode: Int, modifierFlags: UInt }), so the spike commits ONE concrete
///     serialization (rev2 #3 / rev3 #4).
///   - `NormalizedRect` is top-left-origin fractions of a screen's visibleFrame.

import Cocoa
import MASShortcut

/// Canonical hotkey serialization for a custom layout. Mirrors Rectangle's
/// `Shortcut` (keyCode + modifierFlags) and round-trips through MASShortcut.
struct HotkeyData: Codable, Equatable {
    let keyCode: Int
    let modifierFlags: UInt
    var schemaVersion: Int = 1

    init(keyCode: Int, modifierFlags: UInt, schemaVersion: Int = 1) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.schemaVersion = schemaVersion
    }

    init(_ shortcut: MASShortcut) {
        self.keyCode = shortcut.keyCode
        self.modifierFlags = shortcut.modifierFlags.rawValue
        self.schemaVersion = 1
    }

    func toMASShortcut() -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
    }
}

/// A rectangle expressed as fractions of a screen's visibleFrame, **top-left
/// origin** (x from the left edge, y from the TOP edge) — the intuitive Divvy
/// framing. Converted to AppKit (bottom-left) coordinates at apply time.
struct NormalizedRect: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat

    /// Map onto an AppKit `visibleFrame` (bottom-left origin). The Y term flips
    /// the top-left fraction into AppKit space within the frame.
    func appKitRect(in visibleFrame: CGRect) -> CGRect {
        let width = w * visibleFrame.width
        let height = h * visibleFrame.height
        let originX = visibleFrame.minX + x * visibleFrame.width
        let originY = visibleFrame.minY + (1 - y - h) * visibleFrame.height
        return CGRect(x: originX.rounded(), y: originY.rounded(),
                      width: width.rounded(), height: height.rounded())
    }
}

/// Throwaway spike stand-in for the eventual `CustomLayout` model.
struct SpikeCustomLayout: Identifiable {
    let id: UUID
    var name: String
    var rect: NormalizedRect
    var hotkey: HotkeyData?
}
