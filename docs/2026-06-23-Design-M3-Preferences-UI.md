# Design: M3 — Custom Layouts Preferences UI

Status: **Proposed** (awaiting adversarial Codex review before implementation)
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
Override `isShortcutValid(_:)` to REJECT (return false) a chord that conflicts, mirroring Rectangle's
own validator usage. Conflict = the chord's `ShortcutCycle.ShortcutIdentity` matches (a) any live
`WindowAction` shortcut, or (b) another custom layout (excluding the row being edited). The check uses a
**shared helper** also used by the M2 manager so the two cannot diverge:
```
enum CustomLayoutConflict { 
  static func find(_ shortcut: MASShortcut, excluding id: UUID?, layouts: [CustomLayout],
                   conflictDefaults: UserDefaults) -> CustomLayoutShortcutManager.BindOutcome?
}
```
(M2's `reconcile()` is refactored to call this helper for its WindowAction/custom-dup classification — a
behavior-preserving extraction, re-verified by the existing M2 unit tests + spike Check 9.) The validator
shows the standard MASShortcut "already in use" feedback; record-time rejection is the primary UX, the
status label (§5) is the backstop for the residual `monitorRegistrationFailed`.

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
- **`CustomLayoutConflict.find`**: WindowAction match → `.conflictWindowAction(name)`; another custom
  layout (excluding self) → `.conflictCustomLayout(id)`; editing the SAME row's own chord → no conflict;
  free chord → nil. (Also assert the M2 manager still produces identical outcomes after the refactor.)
- **Default new layout** (`+ Add`) is valid (`isValid`, unique id, sensible default rect, no hotkey) and
  persists via the store.
- **Outcome → status string** mapping (each `BindOutcome` → its label).
- **Validator** wraps `CustomLayoutConflict.find` and returns false exactly when a conflict exists.

## 8. Risks / open questions
- **R-m3-1 MASShortcutView manual mode.** We use `shortcutValue` + `shortcutValueChange` (NOT
  `setAssociatedUserDefaultsKey`, since our hotkeys live in the model). Confirmed API at M0.5; the smoke
  test exercises a real recording. Guard against the callback firing during programmatic `shortcutValue`
  set (avoid a write-back loop by setting a `isPopulating` flag while loading rows).
- **R-m3-2 Table reuse / row identity.** Each row maps to a `CustomLayout.id`; cell views capture the id
  (not the row index) so reloads/reorders can't mis-route edits.
- **R-m3-3 Validator currency.** The validator reads the CURRENT store + WindowAction defaults at record
  time (not a stale snapshot), so it reflects live conflicts.
- **R-m3-4 Refactor safety.** Extracting `CustomLayoutConflict.find` from M2's reconcile is
  behavior-preserving; the M2 unit tests + spike Check 9 must still pass (re-run both).
- **R-m3-5 No new TCC/AX needs.** The window is ordinary AppKit; no new permissions. The app stays a
  menu-bar `LSUIElement` app; opening a window via `NSApp.activate` is fine.

## 9. Review gate
Adversarial Codex review before implementation; then build + test green + manual smoke test; then a Codex
checkpoint on the M3 result before M4. Target: zero BLOCKER/MAJOR.
