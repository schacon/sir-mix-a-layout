# sir-mix-a-layout

A lightweight macOS window manager utility with animated slot mode.

## What it does

- `Ctrl + Cmd + P`: Toggle mode.
- `Ctrl + Cmd + I`: Toggle active window width between half and full (starts in half mode).
- Mode ON:
  - Only the first 4 visible windows are managed; all others are ignored.
  - Those 4 windows are assigned to fixed slot keys:
    - `Ctrl + Cmd + B` -> slot 1
    - `Ctrl + Cmd + N` -> slot 2
    - `Ctrl + Cmd + M` -> slot 3
    - `Ctrl + Cmd + ,` -> slot 4
    - `Ctrl + Cmd + H/J/K/L` target slots `1/2/3/4` for the right-side active pane
  - Pressing a slot key:
    - If that slot is inactive, it brings that window to the active area.
    - If that same slot is already active, it minimizes it back to its slot.
    - If a different slot is active, it switches the active window to the new slot.
  - Pressing `Ctrl + Cmd + H/J/K/L`:
    - Keeps the current active window in place (left pane in half mode).
    - Moves the selected slot window into the right pane.
    - If width mode is full, it automatically switches to half mode first.
  - Slots are `300x300`.
  - Slot 1 starts `50px` from the top, and each next slot is `400px` lower (`300 + 100 gap`).
  - Slot placement is top-right anchored, so windows that refuse to shrink overflow to the left.
  - On enable, the app prints which window was assigned to each slot key.
  - On enable, a floating "Window Slots" panel appears; each row has `Full`, `Left Half`, `Right Half` buttons to place that slot window directly into that target position.
  - In half mode, the two active panes are slightly narrower and keep a `20px` gap between them.
  - The panel also has `Minimize All` (send all actives back to slots) and `Swap` (active only when both left/right panes are populated).
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

## Customize layout and animation

Edit constants in:

`Sources/SirMixALayout/main.swift`

Look for `AppConfig`:

- `activeOffset`
- `activeSize`
- `slotSize`
- `slotStartX`
- `slotStartY`
- `slotVerticalGap`
- `animationDuration`
- `maxSlots`

## Notes

- This is implemented with Accessibility APIs (`AXUIElement`) and Carbon hotkeys.
- Behavior depends on target apps exposing standard accessibility window attributes.
- For login/startup usage, package this as an app or launch agent and grant that binary Accessibility access.
