# Design: M3 — Custom Layouts Preferences UI

Status: **Reviewed — rev 2, Codex VERDICT: GREEN** (2026-06-23)
Date: 2026-06-23
Branch: `feature/m0-fork-branding` (integration branch; M3 builds on M0/M0.5/M1/M2)
Parent: [`2026-06-23-Plan-Divvy2-Window-Snapper.md`](2026-06-23-Plan-Divvy2-Window-Snapper.md) §5 (M3)
Grounded by: M1 (`CustomLayoutStore` add/update/delete/setHotkey/export/import + `.customLayoutsChanged`),
M2 (`CustomLayoutShortcutManager` reconciles on store changes + `outcomes`), M0.5 (`MASShortcutView` is
the real recorder; `MASShortcutValidator` subclassing is Rectangle's pattern).

## 0. Scope & gate
M3 adds a UI to **add / edit / delete** custom layouts with the real `MASShortcutView` recorder, with
**live re-registration** (mutations post `.customLayoutsChanged`; the M2 manager already reconciles).
No new model/manager logic beyond a small, additive notification + a shared conflict helper. **No
packaging (M4).** **Gate: `xcodebuild build` + `xcodebuild test` green (logic unit tests) + a manual
run smoke test (open the window, add a layout, bind a hotkey, snap), then a Codex checkpoint before M4.**

## 1. Surface & entry point
- **Programmatic, standalone window** `CustomLayoutsWindowController` (NO storyboard surgery — Rectangle's
  Prefs window is storyboard/tab-based; we stay isolated per R2). A single `NSWindow` with a titled,
  resizable content view built in code.
- **Entry point:** a menu item **"Custom Layouts…"** inserted PROGRAMMATICALLY into Rectangle's status
  menu (`mainStatusMenu`, an existing `@IBOutlet`) at app setup — near "Preferences" — whose action opens
  the window (lazily constructed, `NSApp.activate` + `showWindow`), mirroring `openPreferences`.

## 2. Layout of the window
A vertical layout:
- **Toolbar row:** `+ Add Layout`, `Import…`, `Export…` buttons (Import/Export call M1
  `CustomLayoutStore.importJSON`/`exportJSON` via `NSOpenPanel`/`NSSavePanel`; import shows the
  `CustomLayoutImportError` on failure, never partial).
- **List:** a view-based `NSTableView` (one row per layout, `layouts` order). Per-row cell view:
  - **Name** — `NSTextField` (editable); commit → `store.update`.
  - **Rect** — four `NSTextField`s **X% Y% W% H%** (0–100, `NumberFormatter`), representing the
    top-left-origin `NormalizedRect` ×100. Commit → build `NormalizedRect(x/100,…)`; if `!isValid`,
    reject the edit (restore prior value + red highlight) — never persist an invalid rect.
  - **Hotkey** — a `MASShortcutView` in **manual mode** (`shortcutValue` set from the layout's
    `HotkeyData`; `shortcutValueChange` callback → `store.setHotkey(view.shortcutValue.map(HotkeyData.init), for: id)`;
    clearing sets nil). Its `shortcutValidator` is a `CustomLayoutShortcutValidator` (§4).
  - **Status** — a label showing the M2 binding outcome for this layout (§5): "Active", "Conflicts with
    Left Half", "Conflicts with <layout>", "Unbound", or "Registration failed".
  - **Delete** — `NSButton` → `store.delete(id:)`.
- **Empty state:** a hint when there are no layouts.

## 3. Data flow (single source of truth = `CustomLayoutStore`)
- The window holds the SHARED `CustomLayoutStore` and `CustomLayoutShortcutManager` (passed from
  `AppDelegate`; the window does NOT own them). All edits go through the store's M1 API.
- The store posts `.customLayoutsChanged` on every mutation → (a) the M2 manager reconciles
  (re-registers hotkeys live) and (b) the window reloads its rows.
- **Read-only state:** if `store.isReadOnlyFutureSchema`, the window disables editing and shows a banner
  (a newer app wrote the data) — mutators would no-op anyway.

## 4. Record-time conflict rejection — `CustomLayoutShortcutValidator: MASShortcutValidator`
`CustomLayoutShortcutValidator.isShortcutValid(_:)` mirrors Rectangle's own validator
(`TodoShortcutValidator`): **call `super.isShortcutValid(shortcut)` FIRST** (so MASShortcut's base rules
— no-modifier/non-function keys, restricted option-only chords — still reject), THEN also reject on a
custom-layout conflict:
```
override func isShortcutValid(_ s: MASShortcut!) -> Bool {
  guard super.isShortcutValid(s) else { return false }
  return CustomLayoutConflict.windowActionName(for: s, in: conflictDefaults) == nil
      && CustomLayoutConflict.customLayoutId(for: s, in: otherLayouts()) == nil   // otherLayouts excludes the edited row
}
```
**Rejection is QUIET (a beep), like `TodoShortcutValidator`** — in this MASShortcut version returning
`false` from `isShortcutValid` only beeps; the alert/explanation path is the separate
`isShortcutAlreadyTaken(bySystem:explanation:)`, which we do NOT use for custom conflicts. The *human*
explanation ("Conflicts with Left Half / <layout>") is the per-row **Status label** (§5), not a recorder
alert. (The §2 hotkey row text is corrected accordingly — no "standard already-in-use" alert claim.)

**Two DISTINCT conflict queries (C1#splitHelper) — do NOT share one `excluding:` helper:**
```
enum CustomLayoutConflict {
  /// Identity matches a live WindowAction shortcut → its action name.
  static func windowActionName(for s: MASShortcut, in conflictDefaults: UserDefaults) -> String?
  /// Identity matches a layout in the GIVEN list → its id (first match in list order).
  static func customLayoutId(for s: MASShortcut, in layouts: [CustomLayout]) -> UUID?
}
```
- **Validator** (record-time): rejects if the chord matches a WindowAction OR ANY OTHER layout
  (`otherLayouts()` = all layouts except the edited id).
- **Manager** (reconcile-time, FIRST-WINS): keeps the first layout for a chord and only rejects LATER
  duplicates. M2's `reconcile()` is refactored to use `windowActionName(...)` for the (shared, identical)
  WindowAction check and `customLayoutId(for:, in: <layouts kept so far this pass>)` for the dup check —
  preserving the existing `keptIdByIdentity` store-order semantics. Behavior-preserving; re-verified by
  the M2 unit tests (incl. the first-registered/second-conflict dup test) + spike Check 9.

## 5. Surfacing binding outcomes (additive M2 change)
`CustomLayoutShortcutManager` posts a new `Notification.Name.customLayoutBindingsReconciled` at the END
of `reconcileNow()` (additive; does not change reconcile logic). The window observes it and refreshes
the per-row Status label from the manager's `outcomes` map. (Loop-safe: the window only READS the store
on this signal; it does not mutate.)

## 6. Wiring (`AppDelegate`)
- Hold `private var customLayoutsWindowController: CustomLayoutsWindowController?` (lazy).
- At menu setup, insert the "Custom Layouts…" `NSMenuItem` into `mainStatusMenu` with a target/action that
  lazily builds the controller with the shared `customLayoutStore` + `customLayoutShortcutManager` and
  shows it. Constructed only after `accessibilityTrusted()` (store/manager exist).

## 7. Tests
UI rendering is verified by the **manual run smoke test** (open window → add → set rect → record hotkey →
snap a window). The non-UI logic is extracted and UNIT-tested (`RectangleTests/CustomLayoutUITests.swift`,
isolated suites):
- **Percent ⇄ NormalizedRect** round-trip + rejection of out-of-range/invalid percents.
- **`CustomLayoutConflict.windowActionName`**: a chord equal to a live WindowAction shortcut → that
  action's name; a free chord → nil.
- **`CustomLayoutConflict.customLayoutId`**: returns the FIRST layout in the given list whose chord
  matches (and nil if none) — the primitive used by both call sites with different lists.
- **M2 refactor is behavior-preserving:** two layouts with the SAME chord still yield `.registered` for
  the first and `.conflictCustomLayout(first.id)` for the second (the existing M2 dup test), and the
  WindowAction-conflict + dynamic-yield tests + spike Check 9 still pass.
- **Default new layout** (`+ Add`) is valid (`isValid`, unique id, sensible default rect, no hotkey) and
  persists via the store.
- **Outcome → status string** mapping (each `BindOutcome` → its label).
- **Validator**: returns FALSE when (a) `super.isShortcutValid` is false (base-invalid chord still
  rejected), (b) the chord matches a WindowAction, or (c) it matches ANY OTHER layout; returns TRUE for a
  base-valid, non-conflicting chord, AND for re-recording the edited row's OWN current chord (excluded).

## 8. Risks / open questions
- **R-m3-1 MASShortcutView manual mode.** We use `shortcutValue` + `shortcutValueChange` (NOT
  `setAssociatedUserDefaultsKey`, since our hotkeys live in the model). Confirmed API at M0.5; the smoke
  test exercises a real recording. Guard against the callback firing during programmatic `shortcutValue`
  set (avoid a write-back loop by setting a `isPopulating` flag while loading rows).
- **R-m3-2 Table reuse / row identity.** Each row maps to a `CustomLayout.id`; cell views capture the id
  (not the row index) so reloads/reorders can't mis-route edits.
- **R-m3-3 Validator currency.** The validator reads the CURRENT store + WindowAction defaults at record
  time (not a stale snapshot), so it reflects live conflicts.
- **R-m3-4 Refactor safety.** Extracting `CustomLayoutConflict.windowActionName`/`customLayoutId` from M2's reconcile is
  behavior-preserving; the M2 unit tests + spike Check 9 must still pass (re-run both).
- **R-m3-5 No new TCC/AX needs.** The window is ordinary AppKit; no new permissions. The app stays a
  menu-bar `LSUIElement` app; opening a window via `NSApp.activate` is fine.

## 9. Review gate
Adversarial Codex review before implementation; then build + test green + manual smoke test; then a Codex
checkpoint on the M3 result before M4. Target: zero BLOCKER/MAJOR.
