# sir-mix-a-layout

A lightweight macOS window manager utility with animated layout, minimize, and app-switch behavior.

## What it does

- `Ctrl + Option + Cmd + W`: Move the focused window to a fixed offset/size with animation.
- `Ctrl + Option + Cmd + M`: Animate the focused window smaller, then minimize it.
- `Ctrl + Option + Cmd + Tab`: Animate current app window out, minimize it, activate next app, and slide its window into place.

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

## Customize layout and animation

Edit constants in:

`Sources/SirMixALayout/main.swift`

Look for `AppConfig`:

- `targetOffset`
- `targetSize`
- `animationDuration`
- `slideDistance`
- `activationDelay`

## Notes

- This is implemented with Accessibility APIs (`AXUIElement`) and Carbon hotkeys.
- Behavior depends on target apps exposing standard accessibility window attributes.
- For login/startup usage, package this as an app or launch agent and grant that binary Accessibility access.
