# sir-mix-a-layout

A lightweight macOS window manager utility with animated slot mode.

## What it does

- `Ctrl + Cmd + P`: Toggle mode.
- `Ctrl + Cmd + I`: Toggle active window width between half and full (starts in half mode).
- `F1..F14`: Mirror the 14 helper panel buttons:
  - `F1/F2/F3`: Slot 1 `Full/Left Half/Right Half`
  - `F4/F5/F6`: Slot 2 `Full/Left Half/Right Half`
  - `F7/F8/F9`: Slot 3 `Full/Left Half/Right Half`
  - `F10/F11/F12`: Slot 4 `Full/Left Half/Right Half`
  - `F13`: `Minimize All`
  - `F14`: `Swap`
- Mode ON:
  - Only the first 4 visible windows are managed; all others are ignored.
  - F-key actions are equivalent to clicking the helper panel buttons.
  - Slots are `300x300`.
  - Slot 1 starts `50px` from the top, and each next slot is `400px` lower (`300 + 100 gap`).
  - Slot placement is top-right anchored, so windows that refuse to shrink overflow to the left.
  - On enable, the app prints which window was assigned to each slot key.
  - On enable, a floating "Window Slots" panel appears; each row shows the app dock icon and `Full`, `Left Half`, `Right Half` buttons to place that slot window directly into that target position.
  - The active placement button is highlighted per row; clicking that same highlighted button again minimizes that window back to its slot.
  - The panel includes a `Reorder` toggle. When enabled, each slot row shows `Up` and `Down` buttons to move that window assignment to the previous/next slot.
  - Reorder wraps around: `Up` on slot 1 moves to slot 4, and `Down` on slot 4 moves to slot 1.
  - In half mode, the two active panes are slightly narrower and keep a `20px` gap between them.
  - The panel also has `Minimize All` (send all actives back to slots) and `Swap` (works with one or two half panes active).
- Mode OFF:
  - All managed windows are restored to their original sizes/positions.

## Requirements

- macOS 13+
- Swift 6 (Xcode 16+ toolchain)
- Accessibility permission for the process that runs this app

## Run

```bash
swift run
```

Grant Accessibility access to the running binary (for example Terminal, or the built app binary) in:

`System Settings -> Privacy & Security -> Accessibility`

The app will try to prompt for access on startup and open the Accessibility settings page automatically.

## Customize layout via TOML

On first enable (`Ctrl + Cmd + P`), the app reads:

`~/.config/sir-mix-a-layout/config.toml`

If missing, it creates the file with defaults:

```toml
slot_vertical_gap = 100
slot_top_offset = 50
slot_left_offset = 50

active_left_offset = 500
active_top_offset = 120
active_area_width = 1320
active_area_height = 860
active_split_gap = 20

control_panel_left_offset = 50
control_panel_top_offset = 20

animation_duration = 0.29
```

These values are reloaded each time you enable mode.

Notes on current slot layout behavior:
- Slots are arranged in a horizontal row from left to right.
- `slot_vertical_gap` is used as spacing between slot windows in that row.
- Slot windows use `active_area_height` for their height.

## Notes

- This is implemented with Accessibility APIs (`AXUIElement`) and Carbon hotkeys.
- Behavior depends on target apps exposing standard accessibility window attributes.
- For login/startup usage, package this as an app or launch agent and grant that binary Accessibility access.
