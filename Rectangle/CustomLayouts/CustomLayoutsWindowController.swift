/// CustomLayoutsWindowController.swift
///
/// M3 Preferences UI: a programmatic standalone window to add/edit/delete custom
/// layouts (name, X/Y/W/H percent, hotkey via the real MASShortcutView) with live
/// re-registration. Single source of truth = CustomLayoutStore. See
/// docs/2026-06-23-Design-M3-Preferences-UI.md.

import Cocoa
import MASShortcut

final class CustomLayoutsWindowController: NSWindowController {

    private let store: CustomLayoutStore
    private let manager: CustomLayoutShortcutManager
    private let conflictDefaults: UserDefaults

    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No custom layouts yet. Click “+ Add Layout”.")
    private let bannerLabel = NSTextField(labelWithString: "")
    private var rowViews: [CustomLayoutRowView] = []
    private var observers: [NSObjectProtocol] = []
    /// Set by `addLayout`; consumed by the next `rebuildRows` to focus + reveal the new row.
    private var pendingFocusLayoutId: UUID?

    init(store: CustomLayoutStore, manager: CustomLayoutShortcutManager, conflictDefaults: UserDefaults = .standard) {
        self.store = store
        self.manager = manager
        self.conflictDefaults = conflictDefaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Custom Layouts"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        observers.append(NotificationCenter.default.addObserver(
            forName: .customLayoutsChanged, object: nil, queue: .main) { [weak self] _ in self?.storeChanged() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .customLayoutBindingsReconciled, object: nil, queue: .main) { [weak self] _ in self?.refreshStatuses() })
        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let addButton = NSButton(title: "+ Add Layout", target: self, action: #selector(addLayout))
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importLayouts))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportLayouts))
        let toolbar = NSStackView(views: [addButton, importButton, exportButton])
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        bannerLabel.textColor = .systemOrange
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.isHidden = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // FLIPPED document view: a non-flipped doc bottom-anchors content when it's shorter
        // than the clip view, which hid newly added rows (they piled up off the top). Flipped =
        // top-down, so rows lay out from the top and the list grows/scrolls downward normally.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        // The empty-state label lives INSIDE the stack so the document view's height always
        // tracks its content (an arranged subview), which is what makes newly added rows lay
        // out and scroll. NSStackView collapses hidden arranged subviews, so toggling
        // `emptyLabel.isHidden` swaps cleanly between the empty state and the rows.
        emptyLabel.textColor = .secondaryLabelColor
        rowsStack.addArrangedSubview(emptyLabel)
        scroll.documentView = doc

        content.addSubview(toolbar)
        content.addSubview(bannerLabel)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            bannerLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            bannerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            scroll.topAnchor.constraint(equalTo: bannerLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            // `==` (not `<=`) so the document view is exactly as tall as its rows → scrollable.
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }

    // MARK: Rows

    private func rebuildRows() {
        for v in rowViews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        rowViews.removeAll()
        let editable = !store.isReadOnlyFutureSchema
        bannerLabel.isHidden = editable
        bannerLabel.stringValue = editable ? "" : "Read-only: these layouts were written by a newer version."
        for layout in store.layouts {
            let row = CustomLayoutRowView(layoutId: layout.id, store: store, conflictDefaults: conflictDefaults,
                                          allLayouts: { [weak self] in self?.store.layouts ?? [] }, editable: editable)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            rowViews.append(row)
        }
        emptyLabel.isHidden = !store.layouts.isEmpty
        refreshStatuses()

        // Reveal a just-added row so "+ Add Layout" has a visible effect. Defer one tick and
        // force a layout pass first: the freshly created row has no real frame yet, so scrolling
        // to its bounds now would be unreliable for a row added below the fold. We deliberately
        // do NOT make the name field first responder here — an actively-edited field swallows
        // the next "+ Add Layout" click (the click just commits the field instead of adding),
        // which is the very "Add does nothing" symptom we're fixing.
        if let focusId = pendingFocusLayoutId {
            pendingFocusLayoutId = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, let row = self.rowViews.first(where: { $0.layoutId == focusId }) else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                row.scrollToVisible(row.bounds)
            }
        }
    }

    private func storeChanged() {
        // Only rebuild when the SET of layouts changed (add/delete); in-place edits keep focus.
        let current = Set(rowViews.map { $0.layoutId })
        let now = Set(store.layouts.map { $0.id })
        if current != now { rebuildRows() } else { refreshStatuses() }
    }

    private func refreshStatuses() {
        let nameForId: (UUID) -> String? = { [weak self] id in self?.store.layout(id: id)?.name }
        for row in rowViews {
            let outcome = manager.outcomes[row.layoutId] ?? .noHotkey
            row.setStatus(outcome.statusText(nameForId: nameForId))
        }
    }

    // MARK: Actions

    @objc private func addLayout() {
        guard !store.isReadOnlyFutureSchema else { NSSound.beep(); return }
        let layout = CustomLayout(name: "New Layout", rect: NormalizedRect(x: 0, y: 0, w: 0.5, h: 0.5))
        pendingFocusLayoutId = layout.id   // consumed by rebuildRows after .customLayoutsChanged
        store.add(layout)
    }

    @objc private func exportLayouts() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CustomLayouts.json"
        panel.allowedFileTypes = ["json"]   // 10.15-compatible
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            try? self.store.exportJSON().write(to: url)
        }
    }

    @objc private func importLayouts() {
        guard !store.isReadOnlyFutureSchema else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]   // 10.15-compatible
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            guard let data = try? Data(contentsOf: url) else { self.showImportError(.decode); return }
            if case .failure(let err) = self.store.importJSON(data) { self.showImportError(err) }
        }
    }

    private func showImportError(_ error: CustomLayoutImportError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import failed"
        switch error {
        case .decode: alert.informativeText = "The file is not a valid Custom Layouts export."
        case .unsupportedSchema: alert.informativeText = "The file was written by a newer version."
        case .invalidLayout: alert.informativeText = "The file contains an invalid layout. Nothing was changed."
        case .duplicateId: alert.informativeText = "The file contains duplicate layout ids. Nothing was changed."
        }
        alert.beginSheetModal(for: window!)
    }
}

// MARK: - Row

final class CustomLayoutRowView: NSView, NSTextFieldDelegate {

    let layoutId: UUID
    private let store: CustomLayoutStore
    private let allLayouts: () -> [CustomLayout]

    private let nameField = NSTextField()
    private let xField = NSTextField()
    private let yField = NSTextField()
    private let wField = NSTextField()
    private let hField = NSTextField()
    private let shortcutView = MASShortcutView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var isPopulating = false
    // Observes this row's recorder and posts `.shortcutRecording` so the shortcut manager
    // suspends global custom-layout hotkeys WHILE recording. Without this, an already-bound
    // chord (e.g. another layout's hotkey) is intercepted by its global hotkey instead of
    // being captured here — so it can't be recorded and its conflict alert never fires. Only
    // one recorder is active at a time, so a per-row observer is sufficient.
    private let recordingObserver = ShortcutRecordingObserver()
    private var isShowingConflictAlert = false

    init(layoutId: UUID, store: CustomLayoutStore, conflictDefaults: UserDefaults,
         allLayouts: @escaping () -> [CustomLayout], editable: Bool) {
        self.layoutId = layoutId
        self.store = store
        self.allLayouts = allLayouts
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let pct = NumberFormatter()
        pct.minimum = 0; pct.maximum = 100; pct.maximumFractionDigits = 1
        [xField, yField, wField, hField].forEach { f in
            f.formatter = pct
            f.alignment = .right
            f.delegate = self
            f.isEditable = editable
            f.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        nameField.delegate = self
        nameField.isEditable = editable
        nameField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let validator = CustomLayoutShortcutValidator(
            conflictDefaults: conflictDefaults,
            otherLayouts: { [layoutId, allLayouts] in allLayouts().filter { $0.id != layoutId } })
        validator.onConflict = { [weak self] name in
            // Dispatch async: this fires from inside the recorder's event handling, so present
            // the alert after the validator returns (avoids reentrancy with the field editor).
            // `isShortcutValid` may be invoked several times for one chord, so guard against
            // stacking duplicate sheets (an AppKit hazard when a sheet is already attached).
            DispatchQueue.main.async {
                guard let self, !self.isShowingConflictAlert else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Shortcut already in use"
                alert.informativeText = "That shortcut is already assigned to “\(name)”. Pick a different combination."
                if let window = self.window, window.attachedSheet == nil {
                    self.isShowingConflictAlert = true
                    alert.beginSheetModal(for: window) { [weak self] _ in self?.isShowingConflictAlert = false }
                } else if self.window == nil {
                    alert.runModal()
                }
            }
        }
        shortcutView.shortcutValidator = validator
        shortcutView.isEnabled = editable
        shortcutView.widthAnchor.constraint(equalToConstant: 120).isActive = true
        recordingObserver.observe([shortcutView])   // suspend global hotkeys while recording

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteLayout))
        deleteButton.isEnabled = editable

        func cap(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.textColor = .tertiaryLabelColor; return l }
        let stack = NSStackView(views: [nameField, cap("X%"), xField, cap("Y%"), yField,
                                        cap("W%"), wField, cap("H%"), hField,
                                        shortcutView, statusLabel, deleteButton])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])

        populate()
        // Assign the change callback AFTER populating shortcutValue so the programmatic set
        // doesn't write back.
        shortcutView.shortcutValueChange = { [weak self] view in
            guard let self, !self.isPopulating else { return }
            self.store.setHotkey(view.shortcutValue.map(HotkeyData.init), for: self.layoutId)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // If this row is removed while its recorder is active (delete/rebuild during
        // recording), stop recording so MASShortcut tears down its event monitor and the
        // observer posts the "recording ended" resume before everything deallocates.
        if shortcutView.isRecording { shortcutView.isRecording = false }
    }

    private func populate() {
        isPopulating = true
        defer { isPopulating = false }
        guard let layout = store.layout(id: layoutId) else { return }
        nameField.stringValue = layout.name
        let p = layout.rect.percents
        xField.doubleValue = p.x; yField.doubleValue = p.y; wField.doubleValue = p.w; hField.doubleValue = p.h
        shortcutView.shortcutValue = layout.hotkey?.toMASShortcut()
    }

    func setStatus(_ text: String) { statusLabel.stringValue = text }

    // Commit name + rect on end-editing of any field. Rather than rejecting an
    // out-of-bounds combination wholesale (which made X/Y feel un-editable when the
    // default w/h left no room), CLAMP into the nearest valid rect — keeping the typed
    // x/y position and shrinking w/h to fit — then repopulate so the fields show what
    // was actually stored.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isPopulating, var layout = store.layout(id: layoutId) else { return }
        let raw = NormalizedRect(x: CGFloat(xField.doubleValue) / 100, y: CGFloat(yField.doubleValue) / 100,
                                 w: CGFloat(wField.doubleValue) / 100, h: CGFloat(hField.doubleValue) / 100)
        let rect = raw.isValid ? raw : raw.clamped()
        layout.name = nameField.stringValue
        layout.rect = rect
        store.update(layout)
        if rect != raw { populate() }   // reflect any clamping back into the fields
    }

    @objc private func deleteLayout() { store.delete(id: layoutId) }
}

// MARK: - Flipped container

/// A top-left-origin container used as the scroll view's document view so list rows lay out
/// from the top and the list grows/scrolls downward (a non-flipped doc bottom-anchors short
/// content, which hid newly added rows).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
