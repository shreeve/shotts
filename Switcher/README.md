# shotts-switcher

Switches macOS desktops at once, without the slide: a three-finger horizontal swipe or
Control-Left/Right moves one desktop, with no animation. macOS 26.6 or later.

It is Fast Desktop Switching in [Shotts](../README.md), which runs it from its app bundle while
the menu item is on. It is a Swift package of its own, with no dependency on Shotts, so it can
live on as a repository of its own too.

It comes from [noswoosh](https://github.com/mmathys/noswoosh) 1.7.8 by Max Mathys (MIT), whose
technique is from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT)
and whose macOS 27 payload layout is from [iss](https://github.com/joshuarli/iss) (ISC).

## How it works

A switch is a Dock swipe posted with almost no progress and a hard fling. The Dock's own
pipeline does the switch, so Mission Control, focus, and the wallpaper stay consistent, but the
slide has no distance to travel. macOS 27 checks such a swipe against a serialized IOHID payload
and wants it paired with a companion gesture event; on 26 neither is needed.

- **Control-Left/Right** are hot keys. macOS's own animated Control-arrow shortcuts are turned
  off while it runs, and put back as the user has them when it quits.
- **A three-finger swipe** is held back from the Dock by an event tap and replaced by the
  switch. Vertical swipes (Mission Control, App Exposé) pass.
- **The empty-desktop guard.** Landing on a desktop with no windows, macOS activates another
  app, which orders in a window from another desktop, and the Dock follows it there. The helper,
  having no windows, makes itself active the moment it lands, which leaves nothing to follow.
- **It switches only as far as there are desktops**, on the display under the pointer, where
  the Dock sends a swipe.

## Layout

```
Sources/SwitcherCore/DesktopSwitch.swift    the decisions and the numbers, with tests: which
                                            macOS, how far, the swipe's progress and velocity,
                                            the macOS 27 payload, and the swipe tracking
Sources/shotts-switcher/Switcher.swift      the program: SkyLight, events, the tap, the guard
Tests/SwitcherCoreTests/                    the tests
```

`SwitcherCore` has no AppKit and no events, so everything that decides something is tested. The
program finds SkyLight's private functions at run time (`dlopen`), so it links nothing private.

## Build, test, run

```bash
swift test
swift build -c release
.build/release/shotts-switcher
```

It needs Accessibility, which macOS checks for the app that started it: run from Terminal, that
is Terminal. Without it, it exits with status 3; before macOS 26.6, with status 4; on a macOS
without one of the SkyLight functions it uses, with status 5. It quits on a signal and when the
process that started it goes, so it never outlives its app; under launchd it runs on.
