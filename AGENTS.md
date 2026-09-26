# Agent rules

Shotts is a native Mac screenshot and screen-recording tool that feels like a small utility Apple
shipped next to the Screenshot app: F10, select an area, annotate, copy. It lives in the menu
bar, targets macOS 27 on Apple silicon only, and stays small in code and in memory. It never
loses a capture the user is editing, and it never captures anything the user did not ask for;
every rule below serves that, the native feel, or the memory budget.

`docs/SPEC.md` is what the product does. `HANDOFF.md` is how the code does it, with the Traps:
read it before changing capture, the selection overlay, the editor, or export.

## Shape

- `ShottsCore`: values and decisions. The annotation model, styles, geometry, hit testing, the
  selection rules, and undo. No AppKit, no CoreGraphics drawing, no `FileManager`. Anything with
  a decision in it belongs here, with a test.
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
  Shotts' own windows excluded. The picker shows that picture, the magnifier reads it, and the
  selection is cut from it; the pictures are released the moment the picker closes, and only
  the cut-out survives. The picker itself is never in a capture.
- Coordinates: `Document` and every annotation live in image pixels. Screen points, backing
  scale, and display origins are converted at the edges (capture, overlay, canvas) and nowhere
  else.
- Escape always cancels the current thing and nothing more: a drag, then the selection, then the
  editor (asking only when there are unsaved annotations).
- After a copy, save, or drag out that ends the edit, focus returns to the app that was frontmost
  when the hot key fired.
- The hot key is a Carbon hot key, which needs no Accessibility permission. Screen Recording is
  the only permission Shotts asks for, and only when the first capture needs it.
- Fix a bug with a test in the lowest layer that can host it: Core first. Never weaken a test to
  make it pass.
- No AI attribution in commits, tags, or release notes.

## Check

```bash
swift build          # no warnings
swift test
open "$(Scripts/package-app.sh)"
```

`Scripts/package-app.sh` builds `Shotts.app`, signed with the Developer ID so Screen Recording
permission survives rebuilds, and prints its path. Releases, Homebrew, and Sparkle updates are
in `docs/RELEASING.md`.
