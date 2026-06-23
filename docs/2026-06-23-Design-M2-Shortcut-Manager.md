# Design: M2 — CustomLayoutShortcutManager + apply path

Status: **Proposed — rev 2** (addresses Codex round-1: 3 MAJOR on shared-monitor coexistence)
Date: 2026-06-23
Branch: `feature/m0-fork-branding` (integration branch; M2 builds on M0/M0.5/M1)
Parent: [`2026-06-23-Plan-Divvy2-Window-Snapper.md`](2026-06-23-Plan-Divvy2-Window-Snapper.md) §3.3–3.8/§5
Grounded by: [`SPIKE.md`](../SPIKE.md) (M0.5 proved register/unregister with chord-scoped ownership,
conflict rejection, lifecycle suppression, direct-AX move with no `windowHistory` writes, coordinate
contract) and M1 (`CustomLayout`/`CustomLayoutStore`/`NormalizedRect.pixelRect`).

Changelog: rev1 → rev2 fixes the shared-`MASShortcutMonitor` coexistence with Rectangle's OWN
`ShortcutManager`: (1) react to Rectangle shortcut/defaults changes and YIELD chords Rectangle now
wants (rev1 only reloaded on `.customLayoutsChanged`); (2) mirror Rectangle's lifecycle at the
REGISTRATION level (unregister during recording / app-disable), not just suppress at fire-time;
(3) add real shared-monitor coexistence tests. `C1#n` tags map clauses to the round-1 finding.

## 0. Scope & gate
M2 ships the PRODUCTION `CustomLayoutShortcutManager`: register real global hotkeys from the
`CustomLayoutStore`, reconcile on every relevant change, detect conflicts (Rectangle WindowActions
always WIN), honor the shortcut lifecycle at registration level, and apply the focused window's frame
via the direct-AX path (bypassing `WindowAction`/`WindowManager`, so `windowHistory` is never
touched). **No UI (M3), no packaging (M4).** Wired into `AppDelegate.accessibilityTrusted()`.
**Gate: `xcodebuild build` + `xcodebuild test` green, then a Codex checkpoint before M3.**

## 1. Confirmed coexistence facts (from `Rectangle/ShortcutManager.swift`)
Rectangle's own `ShortcutManager` (which our manager must not disturb):
- Binds WindowAction shortcuts through `MASShortcutBinder.shared()` onto the SAME global
  `MASShortcutMonitor` we use. Registering a chord already held by another owner FAILS (the spike
  showed duplicate registration returns false while the first binding stays live).
- Reacts to `.changeDefaults` (`defaultShortcutsChanged`) and `UserDefaults.didChangeNotification`
  (`userDefaultsChanged` → `reloadShortcutBindingsIfNeeded`, which only rebinds when the WindowAction
  ShortcutIdentities actually changed and `!shortcutsSuspendedForRecording`/`!shortcutsDisabled`),
  and to `.shortcutRecording` (unbind on record-start, rebind on record-end if `!shortcutsDisabled`).
- `public func reloadFromDefaults()` (`ShortcutManager.swift:30`) does unbind→register→bind→subscribe
  — callable by us as an explicit coordination point (C1#coordinate).
- App-ignore: `ApplicationToggle.disableShortcuts/enableShortcuts` call
  `shortcutManager.unbindShortcuts()/bindShortcuts()` and post `.frontAppChanged`; the static
  `ApplicationToggle.shortcutsDisabled` reflects the current state.

**Design consequence:** Rectangle WindowActions have PRIORITY on the shared monitor. Our manager must
(a) never hold a chord that is a current WindowAction shortcut, (b) yield such a chord the moment a
WindowAction changes onto it AND let Rectangle (re)claim it, and (c) free its chords during
recording / app-disable exactly like Rectangle does.

## 2. `CustomLayoutShortcutManager` (new, `Rectangle/CustomLayouts/`)

### 2.1 Construction & dependencies
```
init(store: CustomLayoutStore,
     rectangleShortcutManager: ShortcutManager?,        // for the re-claim coordination (weak)
     windowContext: CustomLayoutWindowContext = AXWindowContext(),
     conflictDefaults: UserDefaults = .standard,
     monitor: ShortcutMonitoring = MASShortcutMonitor.shared())
func start()   // initial reconcile + subscribe to the signals in §2.4
func stop()    // unregister all owned + unsubscribe (teardown/tests)
```
`ShortcutMonitoring` (= `register(_:withAction:) -> Bool`, `unregister(_:)`) and
`CustomLayoutWindowContext` (§2.5) are tiny protocols so unit tests inject fakes and assert exact
calls without touching the real global monitor or moving real windows.

### 2.2 The single source of truth: `reconcile()` (debounced)
All change handling funnels into ONE idempotent `reconcile()`, debounced to the next main-runloop tick
(coalesces bursts; `isReconciling` re-entrancy flag). `reconcile()`:
1. Compute **active** = `!suspendedForRecording && !ApplicationToggle.shortcutsDisabled`.
2. Compute the **desired** registration set from the store: for each layout WITH a hotkey, in store
   order, keep it iff `active` AND its `ShortcutCycle.ShortcutIdentity` does NOT match (a) any current
   WindowAction shortcut (`ShortcutCycle.shortcutsByAction(userDefaults: conflictDefaults)`) nor
   (b) an already-kept earlier custom layout (first-wins). Record a per-layout `BindOutcome` for every
   layout (registered / conflictWindowAction / conflictCustomLayout / monitorRegistrationFailed /
   noHotkey / suppressed).
3. **Yield first, then re-claim (C1#coordinate):** unregister every owned chord NOT in desired
   (this releases any chord a WindowAction just took). If any chord was yielded *because it now
   collides with a WindowAction*, call `rectangleShortcutManager?.reloadFromDefaults()` ONCE so
   Rectangle's binder claims the freed chord on the now-clear monitor.
4. Register each desired chord not already owned via `monitor.register`; on `false` →
   `monitorRegistrationFailed` (never assume success), and do NOT track it as owned.
- **Loop-safety:** our registrations go through `MASShortcutMonitor` DIRECTLY (not the binder), so they
  do NOT write UserDefaults and cannot retrigger `UserDefaults.didChangeNotification`. The single
  `reloadFromDefaults()` re-claim writes defaults via Rectangle's binder, but the resulting reconcile
  finds no NEW yield (the chord is already unowned) and does not call it again — bounded, like
  Rectangle's own `isUpdatingShortcutBindings` guard.

### 2.3 Ownership rule (C1#ownership, spike-proven)
Only chords we successfully registered are tracked as owned. Conflicting/failed chords are NEVER
registered or unregistered on the monitor (chord-scoped `unregister` would clobber Rectangle's
binding). `stop()` unregisters only owned chords.

### 2.4 Signals observed (drive a debounced `reconcile`)
- `.customLayoutsChanged` (M1 store mutated) — re-derive desired set.
- `.changeDefaults` and `UserDefaults.didChangeNotification` — a WindowAction shortcut may have
  changed; reconcile yields/claims accordingly (C1#dynamic). (Debounce + identity-compare keeps this
  cheap despite frequent `didChange`.)
- `.shortcutRecording` (Bool) — set `suspendedForRecording`; reconcile (→ unregister all while
  recording, re-register the still-free ones after) (C1#lifecycle).
- `.frontAppChanged` — app-ignore state may have flipped; reconcile reads `ApplicationToggle.shortcutsDisabled`.

### 2.5 Apply path (§3.4/§3.5/§3.7/§3.8) — direct AX, no history
On a fired trigger of layout L: `guard active` (belt-and-suspenders fire-time check in addition to the
registration-level gating), then via the injected context:
```
protocol CustomLayoutWindowContext { func currentTarget() -> CustomLayoutTarget? }
protocol CustomLayoutTarget { var visibleFrame: CGRect { get }; func apply(_ appKitRect: CGRect) }
```
- `AXWindowContext` (real): `AccessibilityElement.getFrontWindowElement()` →
  `ScreenDetection().detectScreens(using:)?.currentScreen.visibleFrame` (raw, gap=0 per §3.5);
  `apply(rect)` = `windowElement.setFrame(rect.screenFlipped)`. This NEVER calls
  `WindowManager.execute`/`WindowAction`, so none of the known `windowHistory` writers
  (`WindowManager`, `SnappingManager`) run — the §3.6 structural opt-out.
- Manager computes `appKitRect = L.rect.pixelRect(in: target.visibleFrame)` (M1) and calls
  `target.apply(appKitRect)`. The test double returns a known `visibleFrame` and CAPTURES the
  pre-flip AppKit rect (the flip itself is covered by `ScreenFlippedTests` + the spike).

## 3. Wiring (`AppDelegate.accessibilityTrusted()`)
After `shortcutManager` and `applicationToggle` exist, construct the shared `customLayoutStore` (if
not already) and `customLayoutShortcutManager = CustomLayoutShortcutManager(store:,
rectangleShortcutManager: shortcutManager)` then `.start()`. One small block; no edits to Rectangle's
`ShortcutManager`. The store is a single instance owned by `AppDelegate` (M3 UI mutates it; the
manager observes `.customLayoutsChanged`).

## 4. Tests
### 4.1 Unit (`RectangleTests/CustomLayoutShortcutManagerTests.swift`) — fakes, headless
Inject a fake `ShortcutMonitoring` (records register/unregister + lets register return false on
demand), a fake `CustomLayoutWindowContext`, a fake/spy `rectangleShortcutManager` seam, an isolated
`conflictDefaults` suite, and an isolated-suite `CustomLayoutStore`.
- **Register from store / noHotkey / monitor-failure / custom-dup** outcomes (as rev1).
- **WindowAction conflict (static):** a WindowAction chord injected into `conflictDefaults`; a layout
  with that chord → `conflictWindowAction`, NO monitor register/unregister call for it.
- **Dynamic yield + re-claim (C1#dynamic):** register a custom chord X (free); then write a
  WindowAction shortcut == X into `conflictDefaults` and post `.changeDefaults`; assert the manager
  UNREGISTERS X (fake monitor saw the unregister of the owned chord), marks
  `conflictWindowAction`, and calls the `rectangleShortcutManager` re-claim hook EXACTLY once. Then
  remove the WindowAction chord + post change → X is registrable again.
- **Recording lifecycle at registration level (C1#lifecycle):** `.shortcutRecording(true)` →
  all owned chords UNREGISTERED (not merely fire-suppressed); `(false)` → re-registered (only the
  still-free ones). Assert via the fake monitor call log.
- **App-disable lifecycle:** set `ApplicationToggle.shortcutsDisabled` (via the real public
  `disableApp/enableApp`) + post `.frontAppChanged` → owned chords unregistered; re-enable → restored.
- **Apply computation:** trigger a layout → captured AppKit rect ==
  `layout.rect.pixelRect(in: fakeVisibleFrame)` (offset/secondary frame); repeated trigger idempotent.
- **Fire-time belt-and-suspenders:** even if a chord were somehow registered while disabled, a fired
  trigger does not apply.

### 4.2 Integration on the REAL shared monitor — spike checks (C1#integrationTest)
The fakes can't prove real `MASShortcutMonitor`/`MASShortcutBinder` coexistence, so extend the
existing `--divvy2-spike` harness (real monitor, real `ShortcutManager`, `Divvy2SpikeHelper` window):
- **Check 8 — production apply + no history:** drive the PRODUCTION
  `CustomLayoutShortcutManager.trigger(...)` against the helper window; assert it lands on the
  layout's `pixelRect`, repeated triggers are idempotent, and `AppDelegate.windowHistory` is
  byte-unchanged (closes §3.6 for the production type).
- **Check 9 — shared-monitor coexistence:** register a custom chord via the real monitor; inject a
  real WindowAction shortcut == that chord into standard defaults and post `.changeDefaults`; assert
  after reconcile that (a) the custom manager yielded the chord (outcome `conflictWindowAction`),
  (b) Rectangle's binding for that WindowAction is now live (its chord registered), and (c) a
  separate non-conflicting custom chord is still owned. Also assert recording-suspend unregisters and
  resume re-registers on the real monitor. Snapshot/restore the touched standard-defaults keys.

## 5. Risks / open questions
- **R-m2-1 Re-claim loop safety (C1#coordinate).** Our direct-monitor registrations don't write
  defaults; the one `reloadFromDefaults()` re-claim is gated on an actual WindowAction-yield and not
  repeated — bounded. Verified by Check 9 + the unit re-claim-once assertion.
- **R-m2-2 Observer ordering.** Because reconcile yields-then-reclaims explicitly, correctness does
  NOT depend on whether our observer fires before/after Rectangle's — we force Rectangle's rebind
  after freeing the chord.
- **R-m2-3 ShortcutIdentity normalization** (spike-confirmed) so a recorder-equal duplicate can't slip
  the conflict check.
- **R-m2-4 Focused-window edge cases** (no window / fullscreen / non-resizable): `currentTarget()`
  returns nil → trigger no-ops (logged); no force-unwraps.
- **R-m2-5 Debounce visibility.** A just-bound hotkey goes live on the next runloop tick; tests pump
  the runloop. Acceptable.

## 6. Review gate
Adversarial Codex review before implementation; then build + test green; then a Codex checkpoint on
the M2 result before M3. Target: zero BLOCKER/MAJOR.
