# Plan — `nextDisplayMaxHeight` Window Action

Status: Reviewed (Codex green — rev 2)

## Goal

Add a new, **separate** `WindowAction` — `nextDisplayMaxHeight` — that in a single
keystroke moves the focused window to the next display **and** sets its height to
100% of that display's usable area (preserving width). This is additive: the
existing `nextDisplay` (move + center, no resize) is left untouched, so both
behaviors remain available and bindable independently.

Motivation: the stock `nextDisplay` action centers the window on the new display
without resizing (`resizes: false`, `NextPrevDisplayCalculation.calculateRect` →
`centerCalculation`). The config JSON maps one shortcut → one `WindowAction` enum
case; there is no field that composes two behaviors. The only way to get
"one press = switch display + full height" is a new enum case + calculation.

## Design decisions

1. **New enum case, not a mutation of `nextDisplay`.** Mutating `nextDisplay`'s
   calculation would change behavior for every existing `nextDisplay` binding and
   could not be expressed selectively in the config. A new case keeps both.

2. **Horizontal placement = centered on the new display, width-clamped.** After
   the display switch the window's `origin.x` is still in the *old* display's
   coordinate space; applying `MaximizeHeightCalculation` directly (it preserves
   `origin.x`) would leave the window horizontally mispositioned / off-screen on
   the new display. We therefore **clamp width to the destination, center it
   horizontally, and set full height**:
   `width = min(window.rect.width, visibleFrame.width)`,
   `x = visibleFrame.minX + (visibleFrame.width - width) / 2` (rounded),
   `y = visibleFrame.minY`, `height = visibleFrame.height`.
   The width-clamp mirrors `CenterCalculation` (which clamps over-wide windows to
   the destination width), so an over-wide window arriving on a narrower display
   stays fully on-screen.

3. **Bypass the `attemptMatchOnNextPrevDisplay` path.** That setting re-applies the
   *last* action on the new display. For `nextDisplayMaxHeight` we always force
   max-height regardless of the last action, so the new case must skip that branch
   in `NextPrevDisplayCalculation.calculate`. Concretely, extend the existing
   `if Defaults.attemptMatchOnNextPrevDisplay.userEnabled` guard (the block at
   `NextPrevDisplayCalculation.swift:23`) to `&& params.action != .nextDisplayMaxHeight`,
   so the early-return match path is skipped *before* it can run and the new case
   always falls through to `calculateRect`.

   **Known interaction (accepted):** because the new action is recorded as the
   window's last action, pressing plain `nextDisplay` afterward *with attempt-match
   enabled* will re-apply max-height on the next display (it looks the last action
   up in `calculationsByAction`). This is consistent with what attempt-match is for
   (carry the layout across displays); we accept it and call it out in QA rather
   than special-casing it.

4. **`resizes: true`** (it changes height) — unlike `nextDisplay`/`previousDisplay`
   which are `false`.

5. **`classification: .display`.** Keeps it grouped with the display actions and
   makes `ShortcutManager`'s `cycleMonitor` subsequent-execution guard treat it
   like the other display actions (the guard skips `.display` and `.size`).

6. **`gapsApplicable: .none`** for now (matches `nextDisplay`/`previousDisplay`).
   Full-height-to-edges with gaps is out of scope; revisit if desired.

7. **No default shortcut.** `spectacleDefault` / `alternateDefault` return `nil`
   (their `default` arm already covers it). The user assigns a shortcut.

8. **Assignment path = config import.** Since the M3 preferences recorder UI is not
   built yet, the user binds the action by adding an entry to their imported config
   JSON, keyed by the action name:
   `"nextDisplayMaxHeight": { "keyCode": <kc>, "modifierFlags": <mf> }`.
   `Config.load` / `Config.encoded` iterate `WindowAction.active` and round-trip by
   `action.name`, so adding the case to `active` is sufficient. It will also appear
   as a menu item (it has a non-nil `displayName`).

## Touch points (all in `Rectangle/`)

`WindowAction.swift` — the enum has many `switch self` properties. Some are
**exhaustive** (no `default` arm → the compiler forces the new case): `name`,
`displayName`, `image`, `gapsApplicable`. The rest have a `default` arm, so a clean
build does **not** prove behavioral completeness — each must be reviewed
explicitly. Every `switch self` over `WindowAction` and the chosen value for the
new case:

| switch (line) | exhaustive? | new-case value | action |
|---|---|---|---|
| `firstInGroup` (194) | no (default false) | false | leave default — sits right after `nextDisplay`, no new separator |
| `name` (204) | yes | `"nextDisplayMaxHeight"` | **add** (config/defaults key, must be stable) |
| `displayIndex` (334) | no (default nil) | nil | **leave default** — must NOT get a display index (that's only displayOne…Nine) |
| `displayName` (349) | yes | "Next Display + Max Height" | **add** (non-nil → menu item appears) |
| `allowedToExtendOutsideCurrentScreenArea` (644) | no (default false) | false | leave default — must stay on-screen |
| `resizes` (634) | no (default true) | true | **leave default** — i.e. do NOT add to the `false` group |
| `isDragSnappable` (653) | no (default true) | false | **add** to the `false` group (display move, not snappable) |
| `spectacleDefault` (669) | no (default nil) | nil | leave default — no default shortcut |
| `alternateDefault` (691) | no (default nil) | nil | leave default — no default shortcut |
| `image` (725) | yes | `nextDisplayTemplate` | **add** (reuse) |
| `gapSharedEdge` (848) | no (default .none) | .none | leave default |
| `gapsApplicable` (867) | yes | `.none` | **add** alongside `nextDisplay`/`previousDisplay` |
| `positionCycles` (902) | no (default true) | false | **add** to the `false` group alongside display actions |
| `category` (923) | no (default nil) | nil | leave default (no submenu) |
| `classification` (938) | no (default nil) | `.display` | **add** to the `.display` group |

Required updates (enum + the switches marked **add**):

- `enum WindowAction` — add `case nextDisplayMaxHeight = 129` (next free raw value;
  current max is `displayNine = 128`). Raw value is persisted/serialized, so it
  must be new and stable.
- `static let active` — append `nextDisplayMaxHeight` (near `nextDisplay,
  previousDisplay`) so it shows in the menu, prefs, and config round-trip.
- `name` — `return "nextDisplayMaxHeight"` (this is the config JSON key + defaults
  key; must be stable).
- `displayName` — non-nil title, e.g. "Next Display + Max Height". Use a plain
  string `value` with a new localization key (e.g. `"nextDisplayMaxHeight.title"`).
  Non-nil is required for the menu item to appear.
- `resizes` — add to the `true` path (i.e. remove from the `false` group; default
  arm already returns `true`, so just **don't** add it to the `false` list).
- `isDragSnappable` — add to the `return false` group alongside `nextDisplay`
  (display moves are not drag-snappable).
- `gapsApplicable` — add alongside `nextDisplay`/`previousDisplay` → `.none`.
- `positionCycles` — add alongside `nextDisplay`/`previousDisplay` → `false`.
- `classification` — add to the `.display` group.
- `image` — reuse `nextDisplayTemplate` (group with the `displayOne…` arm or add
  its own case).
- `firstInGroup` — leave default `false` (it sits right after `nextDisplay`, no new
  separator needed).
- `category` — leave `nil` (default).

`WindowCalculation/WindowCalculation.swift` —
- `calculationsByAction` — add `.nextDisplayMaxHeight: nextPrevDisplayCalculation`.

`WindowCalculation/NextPrevDisplayCalculation.swift` —
- `calculate`: include `.nextDisplayMaxHeight` in the branch that selects the
  **next** screen (`usableScreens.adjacentScreens?.next`).
- `calculate`: skip the `attemptMatchOnNextPrevDisplay` early-return when
  `params.action == .nextDisplayMaxHeight`.
- `calculateRect`: when `params.action == .nextDisplayMaxHeight`, compute
  width-clamped center-horizontally + full-height directly (see decision #2:
  `width = min(window.rect.width, visibleFrame.width)`, centered x, `y = minY`,
  `height = visibleFrame.height`) rather than falling through to
  `centerCalculation`. `RectCalculationParameters` carries `action`
  (`WindowCalculation.swift:77`), so the rect method branches on it.

`AppDelegate.swift` —
- Menu visibility rule (`AppDelegate.swift:401`) currently hides only
  `.nextDisplay` / `.previousDisplay` when `screenCount == 1` or combined-display
  mode. Add `|| windowAction == .nextDisplayMaxHeight` so the new action hides on
  single-display setups too. (Deliberately an explicit case add, **not** a switch
  to `classification == .display`, to avoid changing the existing visibility of the
  `displayOne…displayNine` actions, which are intentionally not hidden by this rule.)

## Out of scope

- Preferences recorder UI row (deferred to M3; assignment via config import).
- A `previousDisplayMaxHeight` twin (can add later symmetrically if wanted).
- Gap support for the full-height result.

## QA gate

- `xcodebuild build` (or `swift build`) green. Note the exhaustive switches only
  force `name`/`displayName`/`image`/`gapsApplicable`; the `default`-armed switches
  (see table above) must be confirmed by code review, not the build alone.
- Manual smoke (multi-display): bind `nextDisplayMaxHeight` via an imported config,
  press it — window moves to the next display, full height, centered horizontally,
  width preserved (and width-clamped if the destination is narrower).
- Manual smoke: plain `nextDisplay` still only moves + centers **when attempt-match
  is off, or when the prior action was not `nextDisplayMaxHeight`**. With
  attempt-match on, a `nextDisplay` immediately following a `nextDisplayMaxHeight`
  is expected to carry max-height forward (accepted interaction, decision #3).
- Single-display: the new action's menu item is hidden (AppDelegate rule).
- Confirm config export then re-import round-trips the new binding.

## Rollout

- Branch: `feature/next-display-max-height` (off `origin/main`).
- Codex adversarial review of this plan (green-gate) before implementing.
- Conventional commit: `feat(actions): add nextDisplayMaxHeight window action`.
