# Shotts

Screenshots and screen recordings for the Mac, in one motion: press a key, select an area, mark
it up, and paste it wherever it goes.

**F10 → select → annotate → copy → paste.**

Shotts lives in the menu bar. Press F10, drag out the area you want (the screen is frozen while
you choose), and the capture opens in a small editor with arrows, text, shapes, a pen, a
highlighter, and a blur for things that should not leave your Mac. The annotations are made to
look good on a busy screenshot: rounded strokes, bold text with a contrasting outline, restrained
shadows. Copy it, drag it out, or save it, and Shotts gets out of the way and returns you to the
app you were in.

It does one thing, stays small, and keeps its memory in check: one source image, a list of
editable annotations, and an undo history of edits rather than pixels.

macOS 27 on Apple silicon. Not yet released; see `CHANGELOG.md`.

## Building

```bash
swift build          # no warnings
swift test
open "$(Scripts/package-app.sh)"
```

The first capture asks for Screen Recording permission, once. Every local build is signed with
the same identity so the grant survives rebuilds.

## Documents

- `docs/SPEC.md`: what the product does.
- `HANDOFF.md`: how the code does it, and the traps.
- `AGENTS.md`: the rules for changing it.
- `CHANGELOG.md`: what changed in each release.
