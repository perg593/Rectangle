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
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        doc.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
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
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -4),
            emptyLabel.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            emptyLabel.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
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
        store.add(CustomLayout(name: "New Layout", rect: NormalizedRect(x: 0, y: 0, w: 0.5, h: 1)))
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

        shortcutView.shortcutValidator = CustomLayoutShortcutValidator(
            conflictDefaults: conflictDefaults,
            otherLayouts: { [layoutId, allLayouts] in allLayouts().filter { $0.id != layoutId } })
        shortcutView.isEnabled = editable
        shortcutView.widthAnchor.constraint(equalToConstant: 120).isActive = true

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

    // Commit name + rect on end-editing of any field.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isPopulating, var layout = store.layout(id: layoutId) else { return }
        if let rect = NormalizedRect.fromPercents(x: xField.doubleValue, y: yField.doubleValue,
                                                  w: wField.doubleValue, h: hField.doubleValue) {
            layout.name = nameField.stringValue
            layout.rect = rect
            store.update(layout)
        } else {
            NSSound.beep()
            populate()   // restore valid values
        }
    }

    @objc private func deleteLayout() { store.delete(id: layoutId) }
}
