/// HotkeyData.swift
///
/// Canonical, Codable serialization of a custom-layout hotkey. Mirrors Rectangle's
/// own `Shortcut` (WindowAction.swift) and the MASDictionaryTransformer on-disk dict
/// `{ keyCode, modifierFlags }` — proven interchangeable in the M0.5 spike (SPIKE.md).

import Cocoa
import MASShortcut

struct HotkeyData: Codable, Equatable {
    let keyCode: Int
    let modifierFlags: UInt   // NSEvent.ModifierFlags.rawValue

    init(keyCode: Int, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init(_ shortcut: MASShortcut) {
        self.keyCode = shortcut.keyCode
        self.modifierFlags = shortcut.modifierFlags.rawValue
    }

    func toMASShortcut() -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
    }
}
