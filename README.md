# sir-mix-a-layout

A lightweight macOS window manager utility with animated slot mode.

## What it does

- `Shift + Cmd + P`: Toggle mode.
- Mode ON:
  - All currently visible windows are moved into 200x200 slots at the bottom of the screen.
  - `Cmd + 1..9` moves a slotted window into the active area.
  - `Shift + Cmd + O` moves the current active window back into an empty slot.
  - `Shift + Cmd + 1..9` swaps the active window with the chosen slot.
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
- `slotGap`
- `slotMargin`
- `animationDuration`
- `maxSlots`

## Notes

- This is implemented with Accessibility APIs (`AXUIElement`) and Carbon hotkeys.
- Behavior depends on target apps exposing standard accessibility window attributes.
- For login/startup usage, package this as an app or launch agent and grant that binary Accessibility access.
