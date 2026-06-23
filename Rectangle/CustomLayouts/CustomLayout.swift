/// CustomLayout.swift
///
/// A user-named, arbitrary fractional screen rect with an optional GUI-bound hotkey —
/// the core Divvy-2 model. `id` is stable across edits (rename/rebind keep the same id).

import Foundation

struct CustomLayout: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String           // user label; duplicates allowed (id is the key)
    var rect: NormalizedRect
    var hotkey: HotkeyData?     // nil = defined but unbound

    init(id: UUID = UUID(), name: String, rect: NormalizedRect, hotkey: HotkeyData? = nil) {
        self.id = id
        self.name = name
        self.rect = rect
        self.hotkey = hotkey
    }
}
