# Agent rules

Shotts is a native Mac screenshot tool that feels like a small utility Apple shipped next to the
Screenshot app: F10, select an area, annotate, copy. It lives in the menu bar, targets macOS 27
on Apple silicon only, and stays small in code and in memory. It never loses a capture the user
is editing, and it never captures anything the user did not ask for; every rule below serves
that, the native feel, or the memory budget.

`docs/SPEC.md` is what the product does. `HANDOFF.md` is how the code does it, with the Traps:
read it before changing capture, the selection overlay, the editor, or export.

## Shape

- `ShottsCore`: values and decisions. The annotation model, styles and their pixel metrics,
  geometry, hit testing, the selection rules, the editor's sizing rules, and undo. No AppKit, no
  CoreGraphics drawing, no `FileManager`. Anything with a decision in it belongs here, with a
  test.
- `ShottsUI`: AppKit. The selection overlay, the editor window and its canvas, the renderer that
  draws a document into a `CGContext`, and export to the pasteboard, a drag, or a file.
- `Shotts`: `@main`, the menu bar item, the hot key, and capture through ScreenCaptureKit. The
  only target that touches the screen.

## Rules

- One renderer. The editor's canvas and every exported image are drawn by the same code
  (`Renderer`) from the same `Document`, so what the user sees is what they paste.
- One source image per capture. Undo records annotation changes, never a copy of the pixels.
  Nothing caches a second full-size bitmap; obscure effects render from the source on demand.
- Capture is frozen: every display is pictured once when the user presses the hot key, with
  Shotts' own windows excluded. The picker shows that picture, the magnifier reads it, and an
  area is cut from it into a bitmap of its own; the pictures are released the moment the picker
  closes, and only the cut-out survives. A clicked window is the one exception: the user picked
  that window, so it is captured on its own as it is then. The picker itself is never in a
  capture.
- Coordinates: `Document` and every annotation live in image pixels. Screen points, backing
  scale, and display origins are converted at the edges (capture, overlay, canvas) and nowhere
  else. Style lengths are points; `Style`'s pixel metrics are the one place they become pixels.
- Escape cancels the current thing and nothing more. In the editor: typing, then a drag, then
  the selection, then the editor, asking only when there are annotations. In the picker it
  cancels the capture, as the Screenshot app's does.
- After a copy, save, or drag out that ends the edit, focus returns to the app that was frontmost
  when the hot key fired.
- The hot key is a Carbon hot key, which needs no Accessibility permission. Screen Recording is
  the only permission Shotts asks for, and only when the first capture needs it.
- Developer switches (`--edit`, `--render`, …) exist only in debug builds. A release build must
  not act on command-line arguments: one could make it capture under its Screen Recording grant.
- Fix a bug with a test in the lowest layer that can host it: Core first, then the AppKit tests
  in `Tests/UI`, which drive views in windows that are never shown. Never weaken a test to make
  it pass. Never post synthetic events to the screen from a test.
- No AI attribution in commits, tags, or release notes.

## Check

```bash
swift build          # warnings are errors
swift test           # Core, then AppKit in unshown windows
open "$(Scripts/package-app.sh)"
```

`Scripts/package-app.sh` builds `Shotts.app` (debug unless `CONFIG=release`), signs it, and
prints its path; README's Building says why it signs with the Developer ID and what to do
without that certificate. Releases, Homebrew, and Sparkle updates are in `docs/RELEASING.md`.
