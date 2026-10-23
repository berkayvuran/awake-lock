# AwakeLock

A tiny macOS menu bar app that locks your screen with a retro CRT-style lock screen while keeping the Mac awake, so long-running work (AI agent sessions in your editor, SSH, builds) keeps going behind it.

- `⌃⌥⌘L` or the menu bar item locks every connected display
- Unlock with your Mac password (or Touch ID if enrolled)
- Kiosk mode while locked: no Dock, menu bar, Cmd+Tab or Force Quit
- Prevents idle sleep only while locked
- Animations run on the GPU via Core Animation

## Build & install

```sh
./build.sh
```

Builds with `swiftc` (Command Line Tools are enough) and installs to `~/Applications/AwakeLock.app`.

## Caveat

This is not the macOS system lock. If the app crashes or is killed, the overlay disappears. Use `⌃⌘Q` when you need the real lock. Keep the lid open; closing it still puts the Mac to sleep.
