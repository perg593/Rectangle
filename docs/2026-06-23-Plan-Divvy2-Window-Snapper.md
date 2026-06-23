# Plan: Divvy-2 — a keyboard-driven window snapper (Rectangle fork)

Status: **Reviewed — rev 3, Codex VERDICT: GREEN** (2026-06-23)
Workspace: `/Users/projas/divvy-2`

Changelog: rev1 → rev2 fixed the `WindowAction`-enum blocker + 12 findings
(parallel custom-layout subsystem). rev2 → rev3 hardened the M0.5 spike
(shortcut lifecycle, AppKit↔AX coordinate contract §3.8, stronger conflict
test). Inline `rev2 #n` / `rev3 #n` tags map each clause to the review round
that prompted it.

## 1. Goal

Replace Mizage Divvy (Intel-only, losing support) with a native, Apple
Silicon app. MVP interaction: **keyboard layouts** — global hotkeys that snap
the focused window to user-saved screen regions. Built by **forking Rectangle**
(`rxhanson/Rectangle`, MIT, Swift/AppKit) to inherit its window-manipulation,
hotkey, packaging, and onboarding machinery.

### Precise product gap (finding #4)
Stock Rectangle is NOT "presets only" — it ships many actions (halves, thirds,
quarters, sixths, eighths/ninths, `specified`, etc.), each bindable to a hotkey.
What it lacks, and what Divvy has, is: **an open-ended set of user-named,
arbitrary fractional rects, each with a GUI-bound hotkey, that the user can
add/edit/delete at runtime.** That single capability — "Custom Layouts" — is the
entire project.

Non-goals for MVP (call-outs where these are actually load-bearing are noted):
drag-on-grid HUD, per-app rules, fancy animation. Window history/restore and
gaps are non-goals but are *load-bearing interactions* — handled explicitly in
§3.5 and §3.6 rather than ignored (findings #3, #10).

## 2. Why fork Rectangle

It already solves: the Accessibility move/resize path, global hotkey
registration (MASShortcut/MASShortcutMonitor), multi-display + multi-resolution
frame math, signed/notarized packaging, and first-run permission onboarding.

## 3. Architecture — a PARALLEL custom-layout system (finding #1, BLOCKER)

Codex confirmed: Rectangle's `WindowAction` is a **fixed enum with integer raw
values** and a static `WindowAction.active` list; `ShortcutManager` keys
`[WindowAction: MASShortcut]`; cycling and history are built on those fixed
cases. **We cannot add runtime user actions to that enum.** So we do NOT extend
it. Instead we add a self-contained subsystem that runs *alongside* it:

### 3.1 Model — `CustomLayout` (Codable)
```
struct CustomLayout: Codable, Identifiable {
  let id: UUID
  var name: String
  var rect: NormalizedRect      // x,y,w,h each in [0,1] of visibleFrame
  var hotkey: HotkeyData?       // MASShortcut's OWN canonical serialization (finding rev2 #3)
  var schemaVersion: Int        // start at 1
}
```

### 3.2 Store — `CustomLayoutStore` (finding #5)
Explicit storage contract, NOT "mirrors Defaults":
- Persist as a JSON array under our OWN UserDefaults key
  **`com.perg593.divvy2.customLayouts`** (rev2 #4 — concrete, not a
  placeholder), versioned by `schemaVersion`.
- **Hotkey serialization (rev2 #3):** do NOT assume `keyCode + carbonModifiers`
  is the app-level contract. `HotkeyData` stores MASShortcut's *own* canonical
  representation (its `data`/`dictionaryRepresentation` / `keyCode` +
  `modifierFlags` as Rectangle's recorder actually emits — confirmed at M0.5).
  Carbon flags are derived only at registration time if the monitor needs them.
- Provide `exportJSON()` / `importJSON()` so custom layouts can round-trip
  independently of Rectangle's own import/export (we do NOT rely on Rectangle's
  config import touching our key).
- Post a `customLayoutsChanged` notification on mutation so the shortcut
  manager re-registers (mirrors Rectangle's reload pattern, our own channel).

### 3.3 Hotkey registration — `CustomLayoutShortcutManager`
- Register each layout's hotkey directly via `MASShortcutMonitor.shared()`
  (the same dependency Rectangle already vendors), keyed by layout `UUID`.
- On trigger: compute target rect (§3.4) and apply it (§3.7). This **bypasses**
  `WindowAction`, action cycling, and `windowHistory` entirely — minimal
  upstream coupling (good for rebase, R2).
- **Lifecycle integration (rev3 #1):** bypassing the action system must NOT
  bypass `ShortcutManager`'s lifecycle. `CustomLayoutShortcutManager` must honor
  the same signals: **suspend custom hotkeys while a shortcut is being recorded**
  (so a chord-in-progress can't fire a layout), and respect Rectangle's
  **app-ignore / shortcuts-disabled** state (don't fire when the focused app is
  ignored or global shortcuts are off). Subscribe to the same notifications
  `ShortcutManager` uses; confirm their names at M0.5.
- **Conflict check (R3, rev3 #3):** on bind, reject a chord already used by a
  Rectangle `WindowAction` shortcut OR another custom layout, AND handle
  `MASShortcutMonitor`'s actual registration-failure return (don't assume
  success). Surface all three outcomes in the UI.

### 3.4 Target-screen selection (finding #11)
Reuse Rectangle's own screen-detection path (`ScreenDetection` /
`usableScreens(...)`) to pick the screen of the focused window — do not
hand-roll `NSScreen.main`. **Deterministic rule (rev2 #5):** target = the
screen with the **largest intersection** with the focused window's frame;
tie-break by Rectangle's existing screen ordering (adopt its real rule verbatim
if it differs, confirmed at M0.5). Test matrix: current display, secondary
display, window spanning two displays, notched/menu-bar display. Map
`NormalizedRect` onto that screen's `visibleFrame`.

### 3.5 Gaps (finding #3)
Custom layouts have **no shared-edge gap semantics** in the MVP. We do NOT touch
`gapSharedEdge`. Apply the rect to the raw `visibleFrame` (gap = 0). Documented
limitation; revisit post-MVP.

### 3.6 Window history / restore (finding #10, rev2 #2)
Custom layouts **opt out** of `windowHistory` by construction: the apply path
(§3.7) sets the AX frame **directly** and does NOT route through Rectangle's
`WindowAction` execution, so it cannot touch `lastRectangleActions`, cycling, or
restore state. This is a structural guarantee, not a verbal one — but it is
*proven* at M0.5 by moving a real window and asserting no writes to Rectangle's
history/restore occur. Test: repeated custom hotkey (idempotent, no drift) and
Rectangle's own restore unaffected after a custom snap.

### 3.7 Apply path (rev2 #2)
**Commit:** apply via a **direct AX frame-set** — read the focused window's
`AXUIElement` and set `kAXPositionAttribute`/`kAXSizeAttribute` (reusing
Rectangle's `AccessibilityElement` accessors as thin helpers), bypassing
`WindowAction`/`WindowCalculation` execution entirely. This is what makes the
§3.6 opt-out structural. M0.5 confirms the exact `AccessibilityElement` API
names against real source (finding #2 — no guessed classes); if a direct setter
isn't exposed, the spike adds a minimal one rather than calling action
execution.

### 3.8 Coordinate conversion contract (rev3 #2)
Bypassing `WindowCalculation` means THIS project now owns the coordinate math,
so it is specified, not assumed:
- **Orientation flip:** AppKit `NSScreen.visibleFrame` is **bottom-left
  origin**; the AX API (`kAXPositionAttribute`) is **top-left origin**,
  referenced to the **primary** display's top. The conversion must flip Y using
  the primary screen height, not the target screen's — a classic multi-display
  bug. Reuse Rectangle's existing flip helper (in `AccessibilityElement` /
  `ScreenDetection`) rather than re-deriving it.
- **Frame basis:** map `NormalizedRect` onto `visibleFrame` (excludes menu bar /
  Dock). Note whether Rectangle applies any adjusted-frame tweak and match it.
- **Rounding:** round to integer pixels after conversion; define rounding so
  adjacent layouts (e.g. left-60% / right-40%) tile without 1px gaps/overlaps.
- Proven at M0.5 with real-window assertions across the §3.4 display matrix.

## 4. Branding & identity — decided UP FRONT (findings #8, #9)
- **Bundle ID:** `com.perg593.divvy2` (stable; TCC/Accessibility identity is
  keyed on this — must not change later).
- **App name:** `Divvy2` (placeholder; confirm with user, but it is set before
  any AX/hotkey testing so permissions don't churn on a late rename).
- **Sparkle auto-update:** disabled for a personal fork (no update feed).
- **Login item / helper:** keep Rectangle's, re-pointed at our bundle ID.
- **Signing (finding #9):** `security find-identity` shows **0 valid signing
  identities**, so we use **ad-hoc (`-`) signing**. Ad-hoc is NOT a stable
  identity — Accessibility grants can drop on signature change. Mitigations:
  keep a stable bundle ID; add a dev helper `tccutil reset Accessibility
  com.perg593.divvy2` and re-grant; budget time for re-granting each rebuild.

## 5. Milestones (each is a Codex checkpoint)

- **M0 — Repo, branding, build green (finding #13).**
  - `gh repo fork rxhanson/Rectangle` → `perg593`; **pin a specific upstream
    tag/commit** (not a moving `main`).
  - Directory: `/Users/projas/divvy-2` already holds the workspace skeleton
    (`CLAUDE.md`, `.gitignore`, `docs/<this plan>`). `git clone` needs an empty
    dir, so M0 clones the fork to a temp dir, then **moves the clone's contents
    in and re-overlays the existing skeleton files** (CLAUDE.md, .gitignore,
    docs/) on top. Add upstream as a remote for rebasing. Per convention, do all
    work on a branch off `origin/main` — never commit to the fork's `main`.
  - `xcodebuild -resolvePackageDependencies`; build stock app; resolve the
    known Liquid Glass / asset-catalog build issue on macOS < 26 if hit
    (finding #12 — likely asset flags, not just deployment target).
  - Set bundle ID `com.perg593.divvy2`, app name, disable Sparkle.
  - Confirm: stock app launches, grants Accessibility, snaps windows.

- **M0.5 — Architecture spike (finding #6; de-risks BLOCKER + #2, #7, #10, #11
  and rev2 #1/#2/#3).** No model/UI. The spike must prove the WHOLE parallel
  path, not just "a shortcut fires." Concretely it must:
  1. Register **two** hardcoded custom shortcuts via `MASShortcutMonitor`, then
     **unregister + re-register one** from a simulated store change — proving
     reload/unregister and manager lifetime/retention (rev2 #1).
  2. **Conflict test (rev3 #3) — prove rejection, not just non-collision:**
     attempt to bind an exact duplicate of a **live Rectangle** shortcut → prove
     rejected; attempt a duplicate **custom-layout** chord → prove rejected;
     bind a non-conflicting chord → prove registered. Record
     `MASShortcutMonitor`'s actual success/failure return so failures are
     handled, not assumed.
  3. **Lifecycle (rev3 #1):** prove custom shortcuts do **not** fire while a
     shortcut is being recorded, and do not fire while the focused app is
     ignored / global shortcuts are disabled.
  4. **Move a real window** via the §3.7 direct AX frame-set and assert **no
     writes to Rectangle's history/restore state** occur (rev2 #2).
  5. **Coordinate contract (rev3 #2):** validate §3.8 conversion with
     real-window assertions for full-screen-ish, **top-half**, **bottom-half**
     (catches the Y-flip), and secondary display. **Notched-display fallback
     (rev3 #10):** if no notched display is attached, instead assert
     menu-bar/Dock `visibleFrame` behavior on the primary display and record the
     unavailable-hardware case in `SPIKE.md` — the gate still passes.
  6. Confirm Rectangle's **actual shortcut serialization + recorder output** and
     **commit ONE concrete Codable `HotkeyData` representation + migration**
     into `SPIKE.md` before M1 (rev2 #3 / rev3 #4).
  7. Read `WindowAction.swift`, `WindowCalculation*`, `ScreenDetection`,
     `AccessibilityElement`, `ShortcutManager`, `PrefsWindow`, and the real
     MASShortcut recorder view to confirm names/APIs (finding #7 — no guessed
     classes like `RecorderTableCellView`).

  Output: `SPIKE.md` recording every confirmed API, the canonical hotkey
  serialization, and the coordinate-conversion helper used. **Gate: all seven
  must pass before M1.**

- **M1 — Model + store + tests.** `CustomLayout`, `CustomLayoutStore` with
  versioned JSON persistence + export/import; unit tests for fraction→pixel
  mapping across the §3.4 display matrix.

- **M2 — Multi-layout hotkeys.** `CustomLayoutShortcutManager` registering real
  hotkeys from the store; conflict detection; multi-display + repeated-trigger
  + history-non-interference tests (§3.6).

- **M3 — Preferences UI.** Add/edit/delete custom layouts using the ACTUAL
  MASShortcut recorder view confirmed at M0.5; live re-registration on change.

- **M4 — Package.** Ad-hoc sign as `com.perg593.divvy2`, run as a real `.app`,
  document the TCC re-grant dev loop.

## 6. Risks / open questions
- **R1 License/branding** — MIT; personal renamed fork fine; keep LICENSE +
  attribution; reconfirm before any public distribution.
- **R2 Upstream drift** — changes isolated to NEW files + a few minimal hooks;
  upstream tracked as a remote; pinned base tag.
- **R3 Hotkey conflicts** — validated at bind time against Rectangle actions,
  custom layouts, and (best-effort) OS shortcuts.
- **R4 Build on Xcode 26.5** — resolve SPM + asset-catalog issue at M0.
- **R5 Permission churn** — ad-hoc signing; stable bundle ID + `tccutil` helper.

## 7. Review gate
This rev-2 plan goes to Codex adversarial review before M0; each milestone is
re-reviewed. Target: zero BLOCKER/MAJOR findings before any code.
