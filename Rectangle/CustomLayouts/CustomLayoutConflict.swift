/// CustomLayoutConflict.swift
///
/// Shared conflict primitives used by BOTH the M2 reconcile (first-wins) and the M3
/// record-time validator (reject any other layout), so the two cannot diverge — plus
/// the record-time validator, the binding-status text, and percent↔NormalizedRect helpers.

import Cocoa
import MASShortcut

enum CustomLayoutConflict {
    /// If `shortcut` matches a live Rectangle WindowAction shortcut, return that action's name.
    static func windowActionName(for shortcut: MASShortcut, in conflictDefaults: UserDefaults) -> String? {
        let identity = ShortcutCycle.ShortcutIdentity(shortcut)
        for (action, actionShortcut) in ShortcutCycle.shortcutsByAction(userDefaults: conflictDefaults) {
            if ShortcutCycle.ShortcutIdentity(actionShortcut) == identity { return action.name }
        }
        return nil
    }

    /// First layout IN THE GIVEN LIST whose hotkey matches `shortcut`. Callers pass
    /// different lists: the validator passes all-OTHER layouts; the manager passes the
    /// layouts kept so far this pass (preserving first-wins).
    static func customLayoutId(for shortcut: MASShortcut, in layouts: [CustomLayout]) -> UUID? {
        let identity = ShortcutCycle.ShortcutIdentity(shortcut)
        for layout in layouts {
            if let hotkey = layout.hotkey,
               ShortcutCycle.ShortcutIdentity(hotkey.toMASShortcut()) == identity {
                return layout.id
            }
        }
        return nil
    }
}

/// Record-time validator for the MASShortcutView recorder. Rejects a base-invalid chord
/// OR one that conflicts with a WindowAction or ANY other custom layout. On a *conflict*
/// rejection (not a base-invalid one) it fires `onConflict` with the conflicting target's
/// display name so the UI can surface an explicit alert; the recorder still beeps and the
/// per-row status label remains the passive explanation. UI stays out of this file — the
/// closure is the seam.
final class CustomLayoutShortcutValidator: MASShortcutValidator {
    private let conflictDefaults: UserDefaults
    private let otherLayouts: () -> [CustomLayout]

    /// Called with the conflicting WindowAction / custom-layout name when a base-valid chord
    /// is rejected for colliding with something else. Not called for base-invalid chords.
    var onConflict: ((String) -> Void)?

    init(conflictDefaults: UserDefaults = .standard, otherLayouts: @escaping () -> [CustomLayout]) {
        self.conflictDefaults = conflictDefaults
        self.otherLayouts = otherLayouts
        super.init()
    }

    override func isShortcutValid(_ shortcut: MASShortcut!) -> Bool {
        guard super.isShortcutValid(shortcut) else { return false }   // base rules first
        guard let shortcut else { return true }
        if let actionName = CustomLayoutConflict.windowActionName(for: shortcut, in: conflictDefaults) {
            onConflict?(actionName)
            return false
        }
        let others = otherLayouts()
        if let conflictId = CustomLayoutConflict.customLayoutId(for: shortcut, in: others) {
            onConflict?(others.first { $0.id == conflictId }?.name ?? "another layout")
            return false
        }
        return true
    }
}

extension CustomLayoutShortcutManager.BindOutcome {
    /// Human-readable per-row status. `nameForId` resolves a conflicting layout's display name.
    func statusText(nameForId: (UUID) -> String?) -> String {
        switch self {
        case .registered: return "Active"
        case .conflictWindowAction(let name): return "Conflicts with \(name)"
        case .conflictCustomLayout(let id): return "Conflicts with \(nameForId(id) ?? "another layout")"
        case .monitorRegistrationFailed: return "Registration failed"
        case .noHotkey: return "Unbound"
        case .suppressed: return "Paused"
        }
    }
}

extension NormalizedRect {
    /// Build from 0–100 percent inputs; nil if the resulting rect is invalid.
    static func fromPercents(x: Double, y: Double, w: Double, h: Double) -> NormalizedRect? {
        let r = NormalizedRect(x: CGFloat(x) / 100, y: CGFloat(y) / 100,
                               w: CGFloat(w) / 100, h: CGFloat(h) / 100)
        return r.isValid ? r : nil
    }

    var percents: (x: Double, y: Double, w: Double, h: Double) {
        (Double(x) * 100, Double(y) * 100, Double(w) * 100, Double(h) * 100)
    }
}
