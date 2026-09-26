# Changelog

What changed in each release of Shotts. `Scripts/release.sh <version>` publishes that version's
section as the GitHub release notes and as the notes Sparkle shows in the update dialog, and
refuses to release a version that has no section here. Changes not yet released collect under
Unreleased, whose heading becomes the version's when it ships.

## Unreleased

- The editor's window can be resized. The picture scales with it, proportions kept, up to its
  on-screen size; annotations scale along, stay editable, and export unchanged.

## 0.1.0 — 2026-09-26

The first milestone: the daily screenshot workflow.

- F10 pictures every display and opens an area selection over it: drag, Shift for a square,
  Space to move, Escape to cancel; or click a window, outlined as the crosshair passes over
  it, to capture just that window, whatever was covering it. A magnifier beside the pointer shows the pixels under the
  crosshair, the crosshair itself magnified over them, their color in hex, and the selection's size; Command-C copies the color. A
  list of the keys shows until the first drag. The capture goes to the clipboard as soon as
  it is taken. That, dimming outside a dragged selection, the magnifier, and the hints are
  options in the menu bar menu.
- Command-P prints the picture, scaled to fit one page.
- Installs with `brew install --cask shreeve/tap/shotts` and updates itself through Sparkle:
  Check for Updates… in the menu bar menu. Releases are signed with a Developer ID and notarized.
- An app icon: a camera in a viewfinder, like the menu bar's, on a blue gradient tile with a
  glass lens. `Support/AppIcon.svg` is the master; `Scripts/make-app-icon.sh` packs the `.icns`.
- An editor with arrow-with-text (drag the arrow, then type beside its tail; the arrow and its
  text are one object, moved by the arrow, reshaped by the text or the head), arrow, text,
  rectangle, ellipse, pen, highlighter, obscure, and crop tools,
  undo and redo, single-key tool switching, a color panel with ten colors and a custom color,
  and remembered color, width, text size, shadow, outline, and arrow tapering.
- Copy, Save…, and drag out, each closing the editor and returning focus to the previous app.
  An option keeps a captured window's own macOS shadow, on a transparent margin.
