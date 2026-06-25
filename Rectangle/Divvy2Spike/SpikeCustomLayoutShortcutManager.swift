/// SpikeCustomLayoutShortcutManager.swift
///
/// M0.5 spike-grade parallel hotkey manager (THROWAWAY; not the production M2
/// CustomLayoutShortcutManager). See docs/2026-06-23-Design-M0.5-Architecture-Spike.md §1.4.
///
/// Proves: register/unregister via MASShortcutMonitor directly (Bool return),
/// the §1.4 OWNERSHIP rule (chord-scoped unregister — never tear down a chord we
/// don't own), conflict rejection against live WindowAction shortcuts + our own
/// layouts, and lifecycle suppression (recording + ApplicationToggle.shortcutsDisabled).

import Cocoa
import MASShortcut

final class SpikeCustomLayoutShortcutManager {

    enum BindResult: Equatable {
        case registered
        case rejectedConflictWindowAction(String) // the colliding action name
        case rejectedConflictCustom
        case rejectedMonitorFailure
    }

    /// Only chords we successfully registered and OWN. Keyed by layout id.
    private(set) var owned: [UUID: MASShortcut] = [:]
    private var actions: [UUID: () -> Void] = [:]

    /// Instrumentation for the non-mutating ownership proof (check 1).
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    /// Lifecycle state.
    private(set) var suspendedForRecording = false
    private var recordingObserver: NSObjectProtocol?

    /// UserDefaults the conflict check consults for live WindowAction shortcuts.
    /// Injected (isolated suite) in tests so the spike never reads/writes real prefs.
    private let conflictDefaults: UserDefaults

    init(conflictDefaults: UserDefaults = .standard) {
        self.conflictDefaults = conflictDefaults
    }

    deinit {
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
        unregisterAllOwned()
    }

    // MARK: - Conflict check (mirrors TodoManager.conflict via ShortcutCycle.ShortcutIdentity)

    /// Returns a rejection reason if `shortcut` collides with a live WindowAction
    /// shortcut or an already-owned custom layout; nil if free.
    func conflictReason(for shortcut: MASShortcut) -> BindResult? {
        let identity = ShortcutCycle.ShortcutIdentity(shortcut)
        for (action, waShortcut) in ShortcutCycle.shortcutsByAction(userDefaults: conflictDefaults) {
            if ShortcutCycle.ShortcutIdentity(waShortcut) == identity {
                return .rejectedConflictWindowAction(action.name)
            }
        }
        for owned in owned.values {
            if ShortcutCycle.ShortcutIdentity(owned) == identity {
                return .rejectedConflictCustom
            }
        }
        return nil
    }

    // MARK: - Bind / unbind (ownership rule: conflict-check BEFORE any monitor call)

    @discardableResult
    func bind(layoutId: UUID, shortcut: MASShortcut, action: @escaping () -> Void) -> BindResult {
        if let reason = conflictReason(for: shortcut) {
            // Rejected: we make NO register/unregister monitor call for it.
            return reason
        }
        registerCalls += 1
        let registered = MASShortcutMonitor.shared().register(shortcut, withAction: { [weak self] in
            self?.fireFromMonitor(layoutId: layoutId)
        })
        guard registered else { return .rejectedMonitorFailure }
        owned[layoutId] = shortcut
        actions[layoutId] = action
        return .registered
    }

    /// Unregister ONLY a chord we own (chord-scoped unregister is global, so we
    /// must never call it for a non-owned chord — §1.4 ownership rule).
    func unbind(layoutId: UUID) {
        guard let shortcut = owned[layoutId] else { return }
        unregisterCalls += 1
        MASShortcutMonitor.shared().unregisterShortcut(shortcut)
        owned[layoutId] = nil
        actions[layoutId] = nil
    }

    func unregisterAllOwned() {
        for (id, _) in owned { unbind(layoutId: id) }
    }

    // MARK: - Firing (guarded by lifecycle state)

    private func shouldFire() -> Bool {
        !suspendedForRecording && !ApplicationToggle.shortcutsDisabled
    }

    /// Path taken by a real MASShortcutMonitor keypress.
    private func fireFromMonitor(layoutId: UUID) {
        guard shouldFire() else { return }
        actions[layoutId]?()
    }

    /// Direct, non-mutating invocation used by the spike checks (no synthesized
    /// keypress). Honors the same lifecycle guards as a real fire.
    @discardableResult
    func fireForTest(layoutId: UUID) -> Bool {
        guard shouldFire() else { return false }
        actions[layoutId]?()
        return true
    }

    // MARK: - Lifecycle: suspend while a shortcut is being recorded

    func startObservingRecording() {
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .shortcutRecording, object: nil, queue: .main
        ) { [weak self] note in
            self?.suspendedForRecording = (note.object as? Bool) ?? false
        }
    }
}
