# Design: M1 — CustomLayout model + store + tests

Status: **Proposed — rev 3** (addresses Codex round-2: 1 MAJOR + 1 MINOR)
Date: 2026-06-23
Branch: `feature/m0-fork-branding` (integration branch; M1 builds on M0 + M0.5)
Parent: [`2026-06-23-Plan-Divvy2-Window-Snapper.md`](2026-06-23-Plan-Divvy2-Window-Snapper.md) §3.1/§3.2/§5
Grounded by: [`SPIKE.md`](../SPIKE.md) (M0.5 proved the shapes below — HotkeyData ⇄ MASShortcut,
NormalizedRect→pixel, screen selection, no-history apply path).

## 0. Scope & gate
M1 delivers the PRODUCTION model + persistence + the fraction→pixel mapping, with unit tests —
**no hotkey registration (M2), no UI (M3), no apply path wiring (M2)**. The M0.5 spike already
proved the runtime path; M1 adds real, tested types under a new isolated subsystem
`Rectangle/CustomLayouts/` (minimal upstream coupling, R2).

**Mandatory pre-step (C1#collision): de-duplicate spike type names.** The spike files compile into
the SAME `Rectangle` module and Swift type names are module-scoped, so the spike's top-level
`HotkeyData` / `NormalizedRect` (`Rectangle/Divvy2Spike/Divvy2SpikeTypes.swift`) would COLLIDE with
the production types and fail to build. Before adding production types, **rename the spike's
duplicated types** `HotkeyData → SpikeHotkeyData` and `NormalizedRect → SpikeNormalizedRect` (and
update the declarations AND every use: `SpikeCustomLayout`'s `rect`/`hotkey` field types in
`Divvy2SpikeTypes.swift`, plus the runner/manager uses in `SpikeCustomLayoutShortcutManager.swift` /
`Divvy2SpikeRunner.swift`; `SpikeCustomLayout` itself is already prefixed). The spike stays runnable
behind `--divvy2-spike`;
production owns the clean `HotkeyData` / `NormalizedRect`. Verify a green build of the renamed spike
before writing production code. (Full spike removal remains a later/M4 cleanup.)

**Gate: `swift`/`xcodebuild` build + `xcodebuild test` (the new tests) green, then a Codex
checkpoint before M2.**

## 1. Model

### 1.1 `NormalizedRect` (Codable, Equatable)
Fractions of a screen's `visibleFrame`, **top-left origin** (x from left, y from TOP) — the
intuitive Divvy framing, matching the spike. All four in `[0, 1]`.
```
struct NormalizedRect: Codable, Equatable {
  var x, y, w, h: CGFloat   // x,y in [0,1]; w,h in (0,1]; x+w <= 1; y+h <= 1
}
```
- **Validation:** an `isValid` computed property (finite, non-NaN, `0<=x`, `0<=y`, `w>0`, `h>0`,
  `x+w<=1+ε`, `y+h<=1+ε`, ε=1e-6 for float slop). A `clamped()` that snaps into range. Persistence
  rejects/skips invalid rects on load (see §2.4) — never traps.

### 1.2 Pixel mapping (the load-bearing math) — §3.8
`func pixelRect(in visibleFrame: CGRect) -> CGRect` maps onto an AppKit `visibleFrame`
(bottom-left origin). **Edge-rounding (not per-dimension rounding)** so adjacent layouts tile with
NO 1px gap/overlap (plan §3.8 explicit requirement; the spike rounded each dimension independently,
which can leave seams — M1 fixes this):
```
let leftPx   = (visible.minX + x      * visible.width ).rounded()
let rightPx  = (visible.minX + (x+w)  * visible.width ).rounded()
let topY     = y * visible.height                      // from the TOP of the frame
let botY     = (y + h) * visible.height
// AppKit bottom-left: origin.y = visible.minY + (visible.height - botY)
let originYpx = (visible.minY + visible.height - botY).rounded()
let maxYpx    = (visible.minY + visible.height - topY).rounded()
return CGRect(x: leftPx, y: originYpx, width: rightPx - leftPx, height: maxYpx - originYpx)
```
Two adjacent rects sharing a fractional edge (e.g. left `w=0.6` and right `x=0.6`) round that edge
to the SAME integer, so `left.maxX == right.minX` exactly. **Conversion to AX top-left coords is NOT
done here** — that's the apply path's job (M2) via `CGRect.screenFlipped` (proven in the spike);
M1 stays in AppKit `visibleFrame` space and is unit-testable without real displays.

### 1.3 `HotkeyData` (Codable, Equatable)
The canonical serialization PROVEN in the spike to equal the `MASShortcutView`/
`MASDictionaryTransformer` on-disk dict:
```
struct HotkeyData: Codable, Equatable {
  let keyCode: Int
  let modifierFlags: UInt    // NSEvent.ModifierFlags.rawValue
}
init(_ MASShortcut) / func toMASShortcut() -> MASShortcut   // mirrors Rectangle's `Shortcut`
```
`schemaVersion` lives on `CustomLayout`/the store envelope (§2), NOT per-hotkey.

### 1.4 `CustomLayout` (Codable, Identifiable, Equatable)
```
struct CustomLayout: Codable, Identifiable, Equatable {
  let id: UUID
  var name: String           // user label; duplicates allowed (id is the key)
  var rect: NormalizedRect
  var hotkey: HotkeyData?     // nil = defined but unbound
}
```
- `id` is stable across edits (rename/rebind keep the same id). New layouts get a fresh UUID.

## 2. Store — `CustomLayoutStore` (§3.2)

### 2.1 Storage contract (explicit, NOT "mirrors Defaults")
- Persist a **versioned envelope** as JSON `Data` under our OWN UserDefaults key
  **`com.perg593.divvy2.customLayouts`**:
  ```
  struct CustomLayoutsEnvelope: Codable { var schemaVersion: Int; var layouts: [CustomLayout] }
  ```
  `schemaVersion` starts at **1**. Storing the version in the envelope (not just per-item) makes
  whole-file migration possible.
- The store is a small observable class with an in-memory `private(set) var layouts: [CustomLayout]`
  loaded at init and rewritten on every mutation.

### 2.2 API
```
final class CustomLayoutStore {
  static let defaultsKey = "com.perg593.divvy2.customLayouts"
  static let currentSchemaVersion = 1
  private(set) var layouts: [CustomLayout]
  /// True when the stored envelope's schemaVersion > currentSchemaVersion (a NEWER app wrote it).
  /// In this state `layouts` is exposed READ-ONLY and all mutators fail WITHOUT touching defaults,
  /// so we never downgrade/overwrite future data (C1#schema). Recovery: importJSON (explicit
  /// replace) or a future migration.
  private(set) var isReadOnlyFutureSchema: Bool
  init(userDefaults: UserDefaults = .standard)   // injectable for tests (isolated suite)

  func layout(id: UUID) -> CustomLayout?
  // Mutators return false (no-op) when read-only; true on success. All persist + notify on success.
  @discardableResult func add(_ layout: CustomLayout) -> Bool         // rejects duplicate id
  @discardableResult func update(_ layout: CustomLayout) -> Bool      // false if id absent or read-only
  @discardableResult func delete(id: UUID) -> Bool
  @discardableResult func setHotkey(_ hotkey: HotkeyData?, for id: UUID) -> Bool

  func exportJSON() -> Data                       // the envelope, pretty-printed
  @discardableResult func importJSON(_ data: Data) -> Result<Int, ImportError>  // STRICT atomic replace-all
  func reload()                                   // re-read from defaults (for external changes)
}
enum ImportError: Error { case decode, unsupportedSchema, invalidLayout, duplicateId }
```
- **Mutations run on the main thread** (assert `Thread.isMainThread` in DEBUG); the store is not
  thread-safe by design (UI + hotkey manager both touch it on main, like Rectangle's own state).
- `add` with an id already present returns `false` (use `update`). In read-only future-schema state
  every mutator returns `false` and does NOT write defaults.

### 2.3 Change notification
- On every successful mutation (add/update/delete/setHotkey/importJSON), post
  `Notification.Name.customLayoutsChanged` (defined in our own file, our own channel — mirrors
  Rectangle's reload pattern). M2's `CustomLayoutShortcutManager` subscribes to re-register.

### 2.4 Robustness / failure handling — load vs import are DIFFERENT contracts (C1#importVsLoad)
- **`loadFromDefaults` (tolerant; called at init/reload) — HEADER FIRST (C2#headerFirst).** Read the
  raw `Data`; missing key → empty store. **Step 1 — decode only the version header** with a minimal
  `struct EnvelopeHeader: Decodable { let schemaVersion: Int }`. If the header itself won't decode
  (truly corrupt/foreign JSON) → log, empty in-memory store, DO NOT overwrite the bad bytes. **Step 2
  — if `header.schemaVersion > currentSchemaVersion`** (a newer app wrote it): set
  `isReadOnlyFutureSchema = true`, leave defaults untouched, expose an empty (or best-effort decoded)
  `layouts`, and make ALL mutators no-op — this happens BEFORE attempting to decode `layouts`, so it
  holds even if the future `layouts` shape is undecodable by v1 (the exact gap Codex flagged). **Step
  3 — otherwise decode the full `CustomLayoutsEnvelope` tolerantly:** individually invalid layouts
  (`!rect.isValid`, or a duplicate id) are dropped-with-log and the valid remainder kept; the stored
  raw bytes are left intact until the next successful mutation.
- **Migration.** `migrate(envelope:)` switches on `schemaVersion` for KNOWN versions `<= current`;
  v1 is identity. Future versions are handled by the read-only path above (never downgraded).
  Recovery from read-only is an explicit `importJSON` (replace) or a future migration path.
- **`importJSON` (STRICT, atomic, all-or-nothing).** Decode the envelope → `.decode` on failure.
  Reject `schemaVersion > currentSchemaVersion` → `.unsupportedSchema`. Validate EVERY layout
  (`rect.isValid`) → `.invalidLayout` on any failure; reject any duplicate id → `.duplicateId`. Only
  if the ENTIRE payload decodes + validates does it commit (replace-all in memory + defaults + one
  notification) and return `.success(count)`. On ANY error the in-memory state AND defaults are left
  exactly as they were — import never partially succeeds or loses data. (This is the key difference
  from the tolerant load: load drops bad items to salvage data already on disk; import refuses bad
  input wholesale so the user's current set isn't silently altered.) `importJSON` also clears
  `isReadOnlyFutureSchema` on success (the user has explicitly chosen new content).
- Export/import round-trip independently of Rectangle's own config import/export (we do NOT rely on
  Rectangle's config touching our key).
- **Duplicate hotkeys are NOT validated here** — conflict detection is M2 (needs the live
  `MASShortcutMonitor` + `WindowAction` set). The store may hold two layouts with the same chord; M2
  rejects the bind. Documented boundary.

## 3. Tests (`RectangleTests/CustomLayoutTests.swift`, `@testable import Rectangle`)
All tests use an **isolated `UserDefaults(suiteName:)`** (removed in tearDown) — never `.standard`.

### 3.1 Pixel-mapping matrix (the §3.4 display matrix, as pure-function tests)
Synthetic `visibleFrame`s standing in for the real matrix (no real displays needed):
- **primary** `(0,0,1920,1080)`; **secondary with offset** `(1920,0,1440,900)` and a
  negative-origin secondary `(-1440,0,1440,900)`; **notched/menu-bar-reduced** `(0,25,1512,930)`;
  **non-zero Dock inset** `(0,70,1920,1010)`.
- Assert: full-screen `(0,0,1,1)` → exactly the visibleFrame; **left-half / right-half** abut
  (`left.maxX == right.minX`, no gap/overlap); **top-half vs bottom-half** Y placement (top half is
  the UPPER half in AppKit → larger origin.y); **left-60% / right-40% tile exactly** (sum of widths
  == frame width, shared edge); a **thirds** row tiles with no seams; off-origin frames preserve the
  offset.
- Round-trip invariants: `pixelRect` is idempotent; integer outputs; never exceeds the frame.

### 3.2 NormalizedRect validation
- `isValid` true/false table; `clamped()` brings out-of-range into range; NaN/inf rejected.

### 3.3 HotkeyData serialization
- `HotkeyData(MASShortcut).toMASShortcut()` preserves keyCode/modifierFlags; JSON round-trip; equals
  the `{keyCode, modifierFlags}` dict (re-asserting the spike result at the unit level).

### 3.4 Store CRUD + persistence + versioning
- add/update/delete/setHotkey return `true` and mutate in-memory AND survive a reload (new store
  instance on the same suite). `update`/`delete`/`setHotkey` of an absent id return `false` (no-op);
  `add` of an already-present id returns `false`. Envelope `schemaVersion == 1` persisted.
- Change notification fires exactly once per SUCCESSFUL mutation, and NOT on a failed/no-op mutation
  (XCTNSNotificationExpectation, isInverted for the no-op case).

### 3.5 Robustness — load tolerance vs import strictness + future schema
- **Load tolerance:** corrupt JSON → empty store, bad data NOT overwritten until next mutation; a
  blob with one invalid + one valid layout loads only the valid one (the raw blob stays until a
  mutation).
- **Future schema (two cases):** (a) a stored envelope with `schemaVersion = currentSchemaVersion+1`
  and otherwise-valid layouts → read-only (`isReadOnlyFutureSchema == true`), every mutator returns
  `false`, defaults byte-identical afterwards; (b) **a future-schema envelope whose `layouts` payload
  is NOT decodable by v1** (e.g. a renamed/retyped field) → STILL read-only and mutators still return
  `false` with defaults byte-identical (proves the header-first decode, not full-envelope decode,
  drives the read-only gate). A subsequent `importJSON` clears the flag.
- **Import strictness (atomic):** happy path returns `.success(count)` and replaces all; a payload
  with ANY invalid layout returns `.failure(.invalidLayout)` and leaves in-memory AND defaults
  unchanged; a duplicate id → `.failure(.duplicateId)`, unchanged; malformed bytes →
  `.failure(.decode)`, unchanged; `schemaVersion > current` → `.failure(.unsupportedSchema)`,
  unchanged. (Explicitly assert the store's `layouts` and the raw defaults are untouched on each
  failure — proving import never partially succeeds.)

## 4. Risks / open questions
- **R-m1-1 Rounding vs Rectangle's own math.** We deliberately own edge-rounding (§1.2). Rectangle's
  `visibleFrame`-based calculations may round differently; that's fine — custom layouts are a
  separate subsystem. Tests pin our behavior.
- **R-m1-2 `CGFloat` Codable.** `CGFloat` is Codable on macOS; tests cover encode/decode. If any
  platform quirk appears, store as `Double` and bridge.
- **R-m1-3 Spike/production name collision (RESOLVED in §0 pre-step).** Swift type names are
  module-scoped and the spike compiles into the same `Rectangle` target, so duplicate top-level
  `HotkeyData`/`NormalizedRect` would NOT compile. M1's mandatory pre-step renames the spike copies
  to `SpikeHotkeyData`/`SpikeNormalizedRect` (verified by a green build) before production types are
  added; production then owns the clean names. Production never imports/depends on spike code.
- **R-m1-4 Screen selection** is reused from Rectangle (`ScreenDetection`, proven in the spike) and
  is exercised in M2's apply path, not unit-tested here (needs real `NSScreen`s). M1 tests the pure
  mapping only; this boundary is explicit.

## 5. Review gate
Adversarial Codex review before implementation; then `xcodebuild build` + `xcodebuild test` green;
then a Codex checkpoint on the M1 result before M2. Target: zero BLOCKER/MAJOR.
