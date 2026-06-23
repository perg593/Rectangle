# Design: M2 — CustomLayoutShortcutManager + apply path

Status: **Proposed** (awaiting adversarial Codex review before implementation)
Date: 2026-06-23
Branch: `feature/m0-fork-branding` (integration branch; M2 builds on M0/M0.5/M1)
Parent: [`2026-06-23-Plan-Divvy2-Window-Snapper.md`](2026-06-23-Plan-Divvy2-Window-Snapper.md) §3.3–3.8/§5
Grounded by: [`SPIKE.md`](../SPIKE.md) (the M0.5 spike PROVED this exact runtime path with the throwaway
`SpikeCustomLayoutShortcutManager` + the `Divvy2SpikeHelper` window: register/unregister with
chord-scoped ownership, conflict rejection, lifecycle suppression, real cross-app move via direct AX
`setFrame` with **no `windowHistory` writes**, and the coordinate contract) and M1 (`CustomLayout`,
`CustomLayoutStore`, `NormalizedRect.pixelRect`).

## 0. Scope & gate
M2 ships the PRODUCTION `CustomLayoutShortcutManager`: it registers real global hotkeys from the
`CustomLayoutStore`, reloads on change, detects conflicts, honors the shortcut lifecycle, and applies
the focused window's frame via the direct-AX path (bypassing `WindowAction`/`WindowManager`, so
`windowHistory` is never touched). **No UI (M3), no packaging (M4).** The manager is wired into
`AppDelegate.accessibilityTrusted()`. **Gate: `xcodebuild build` + `xcodebuild test` green
(new unit tests), then a Codex checkpoint before M3.**

## 1. `CustomLayoutShortcutManager` (new, `Rectangle/CustomLayouts/`)

### 1.1 Responsibilities
- Own a `[UUID: MASShortcut]` of **successfully-registered** chords (the §3.3 ownership rule) plus
  per-layout trigger closures.
- `reloadFromStore()`: unregister all owned chords, then for each store layout that has a hotkey,
  conflict-check and (if free) register via `MASShortcutMonitor.shared()`; record the per-layout
  outcome. Idempotent.
- Subscribe to `Notification.Name.customLayoutsChanged` → `reloadFromStore()` (debounced to the next
  main-runloop tick to coalesce bursts).
- Lifecycle: subscribe to `Notification.Name.shortcutRecording` (suspend firing while recording) and
  gate every fire on `ApplicationToggle.shortcutsDisabled` — IDENTICAL signals to Rectangle's own
  `ShortcutManager` (proven in the spike).
- On trigger: apply the layout to the focused window (§1.4).

### 1.2 API (sketch)
```
final class CustomLayoutShortcutManager {
  enum BindOutcome: Equatable {
    case registered
    case conflictWindowAction(String)   // colliding WindowAction.name
    case conflictCustomLayout(UUID)      // colliding layout id
    case monitorRegistrationFailed
    case noHotkey                        // layout has no chord (not an error)
  }
  private(set) var outcomes: [UUID: BindOutcome]   // surfaced to M3 UI

  init(store: CustomLayoutStore,
       windowContext: CustomLayoutWindowContext = AXWindowContext(),
       conflictDefaults: UserDefaults = .standard,
       monitor: ShortcutMonitoring = MASShortcutMonitor.shared())
  func start()            // initial reloadFromStore + subscribe
  func reloadFromStore()
  func stop()             // unregister all owned + unsubscribe (teardown / tests)
}
```

### 1.3 Conflict detection (§3.3 / rev3 #3)
On each layout's hotkey, BEFORE any monitor call, reject if its `ShortcutCycle.ShortcutIdentity`
matches:
1. any live Rectangle `WindowAction` shortcut — `ShortcutCycle.shortcutsByAction(userDefaults:
   conflictDefaults)` (injectable; real = `.standard`), OR
2. any chord already registered by THIS manager in the current reload pass (first-wins; later
   duplicate → `conflictCustomLayout`).
Then attempt `monitor.register(shortcut, …)`; if it returns `false` → `monitorRegistrationFailed`
(never assume success). Rejected chords are NEVER registered/unregistered on the monitor (chord-scoped
unregister would clobber a real binding — the §3.3 ownership rule the spike proved). The
`outcomes` map records all of registered / conflict / failure / noHotkey for M3 to display.

### 1.4 Apply path (§3.4/§3.5/§3.7/§3.8) — direct AX, no history
On trigger of layout L: `guard shouldFire`, then via the injected `CustomLayoutWindowContext`:
- get the focused window's **target** (its screen's raw `visibleFrame`, gap=0 per §3.5, via
  `ScreenDetection().detectScreens(using:)` → `currentScreen.visibleFrame`);
- compute `appKitRect = L.rect.pixelRect(in: visibleFrame)` (M1, edge-rounded);
- `target.apply(appKitRect)` which performs `windowElement.setFrame(appKitRect.screenFlipped)`
  (proven primitive). This path NEVER calls `WindowManager.execute`/`WindowAction`, so
  `windowHistory.restoreRects`/`lastRectangleActions` are untouched — the §3.6 structural opt-out.

**Injectable seam (for unit-testability):**
```
protocol CustomLayoutWindowContext { func currentTarget() -> CustomLayoutTarget? }
protocol CustomLayoutTarget { var visibleFrame: CGRect { get }; func apply(_ appKitRect: CGRect) }
```
- `AXWindowContext` (real): `AccessibilityElement.getFrontWindowElement()` + `ScreenDetection`; its
  `apply` does the `setFrame(_.screenFlipped)`.
- A test double returns a known `visibleFrame` and CAPTURES the applied AppKit rect, so the manager's
  compute-and-apply is unit-tested deterministically (the screen-flip itself is already covered by
  `ScreenFlippedTests` + the M0.5 spike, so the unit test asserts the pre-flip pixel rect).
`ShortcutMonitoring` is a tiny protocol (`register(_:withAction:) -> Bool`, `unregister(_:)`) so tests
inject a fake monitor and assert exact register/unregister calls without touching the real global
monitor.

### 1.5 Lifecycle gating (rev3 #1)
`shouldFire == !suspendedForRecording && !ApplicationToggle.shortcutsDisabled`. The monitor action
closure and any test-fire path both consult `shouldFire`. `suspendedForRecording` toggles from the
`shortcutRecording` notification (Bool payload).

## 2. Wiring
- `AppDelegate.accessibilityTrusted()` constructs `customLayoutStore` (if not already) and
  `customLayoutShortcutManager = CustomLayoutShortcutManager(store:)` then `.start()` — alongside the
  existing managers, AFTER `applicationToggle` (so `shortcutsDisabled` is observable). One small block;
  no edits to Rectangle's own `ShortcutManager`.
- The store is a single shared instance owned by `AppDelegate` (the M3 UI will mutate it; the manager
  observes `.customLayoutsChanged`).
- Coexistence: both Rectangle's `MASShortcutBinder` and our manager drive the SAME
  `MASShortcutMonitor.shared()`; the ownership rule guarantees we never unregister Rectangle's chords
  (spike-proven).

## 3. Tests
### 3.1 Unit (`RectangleTests/CustomLayoutShortcutManagerTests.swift`) — fakes, headless, fast
Inject a fake `ShortcutMonitoring`, a fake `CustomLayoutWindowContext`, and an isolated
`conflictDefaults` suite + an isolated-suite `CustomLayoutStore`.
- **Register from store:** two layouts with distinct hotkeys → both `.registered`, fake monitor saw 2
  registers; a layout with no hotkey → `.noHotkey`, no register.
- **Conflict — WindowAction:** inject a `WindowAction` (e.g. `leftHalf`) chord into `conflictDefaults`;
  a layout with that chord → `.conflictWindowAction("leftHalf")`, NO monitor register/unregister call.
- **Conflict — custom dup:** two layouts with the same chord → first `.registered`, second
  `.conflictCustomLayout(firstId)`, exactly one register call.
- **Monitor failure:** fake monitor returns false → `.monitorRegistrationFailed`, chord not owned.
- **Reload on change:** mutate the store (add/delete/setHotkey) → `.customLayoutsChanged` triggers
  `reloadFromStore`; owned set + outcomes match the new store; deleting a layout unregisters its chord
  (fake monitor saw the unregister); ownership rule — a rejected chord is never unregistered.
- **Apply computation:** trigger a layout → fake context's captured AppKit rect ==
  `layout.rect.pixelRect(in: fakeVisibleFrame)` (covering an offset/secondary `visibleFrame`);
  repeated trigger is idempotent (same rect, no drift).
- **Lifecycle:** post `shortcutRecording(true)` → a fired trigger does NOT apply (context.apply not
  called); `(false)` resumes; set `ApplicationToggle.shortcutsDisabled` (via the real public
  `disableApp/enableApp` on a throwaway toggle, or a test seam) → suppressed, then resumes.

### 3.2 Integration (real window) — covered by the M0.5 spike, RE-ASSERTED for the production manager
The real-window move + **no `windowHistory` writes** + multi-display coordinate correctness were
proven in the spike with the same `setFrame`/`screenFlipped`/`ScreenDetection` primitives. M2 adds a
gated check to the existing `--divvy2-spike` harness (Check 8) that drives the PRODUCTION
`CustomLayoutShortcutManager.trigger(...)` against the `Divvy2SpikeHelper` window and asserts: the
window lands on the layout's `pixelRect`, repeated triggers are idempotent, and
`AppDelegate.windowHistory` is byte-unchanged — closing the §3.6 history-non-interference requirement
for the production type, not just the spike stub. (Unit tests can't move real windows; this reuses the
already-built helper + grant.)

## 4. Risks / open questions
- **R-m2-1 Debounce vs immediacy.** Coalescing `customLayoutsChanged` to the next runloop tick avoids
  thrashing on bursty edits but means a just-bound hotkey is live a tick later — acceptable; tests
  pump the runloop.
- **R-m2-2 ShortcutIdentity normalization.** Reuse `ShortcutCycle.ShortcutIdentity` (spike-confirmed
  it normalizes modifier masks) so a recorder-equal duplicate can't slip the conflict check.
- **R-m2-3 Re-entrancy.** `reloadFromStore` mutates `outcomes`/owned while iterating; it snapshots the
  store's `layouts` first and runs fully on the main thread (no re-entrant store mutation).
- **R-m2-4 Monitor coexistence.** Never call `unregister` for a non-owned chord; `stop()` unregisters
  only owned chords. Asserted in unit tests (fake monitor call log) and the spike (Rectangle bindings
  survive).
- **R-m2-5 Focused-window edge cases** (no window, fullscreen, non-resizable): `currentTarget()`
  returns nil → trigger is a no-op (logged); real-world robustness leans on Rectangle's own
  `AccessibilityElement` accessors (proven). Apply does not force-unwrap.

## 5. Review gate
Adversarial Codex review before implementation; then build + test green; then a Codex checkpoint on the
M2 result before M3. Target: zero BLOCKER/MAJOR.
