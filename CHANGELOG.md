# Changelog

What changed in each release of Shotts. `Scripts/release.sh <version>` publishes that version's
section as the GitHub release notes and as the notes Sparkle shows in the update dialog, and
refuses to release a version that has no section here. Changes not yet released collect under
Unreleased, whose heading becomes the version's when it ships.

## 0.2.4 — 2026-09-27

- Return finishes typing, for text and for an arrow's words; Shift-Return starts a new line.
  Command-Return and a click elsewhere still finish too.
- Escape while typing cancels: new words go (a new arrow with text goes with its arrow), and
  words being edited come back as they were.
- Fewer choices, the same app: Trebuchet leaves the fonts (Open Sans is the one it stood in for;
  a remembered Trebuchet becomes Rounded), and the key hints simply show until the first drag,
  with no option to hide them.

## 0.2.3 — 2026-09-27

- New Window per Capture, in the menu bar menu: off (the default), a new capture takes the
  place of the open editor; on, each capture opens in a window of its own.
- The screen stays live while you capture: it goes on updating under the crosshair, windows keep
  their shadows, and the area is captured as it is when you release, so you can wait for
  something to appear. Shotts' own editors stay on screen and can be captured too. macOS may show
  its screen-recording indicator while you pick.
- The editor is an ordinary window: Copy, Save, drag out, and Print leave it open, and it closes
  when you close it, with no question. Option-F10, or Show Last Capture in the menu bar menu,
  brings the last capture back to the front, or reopens it as you left it if you closed it.
- After printing, the editor comes back to the front.
- The magnifier keeps its crosshair while you drag out an area, so the corner can be put on an
  exact pixel.
- The magnifier is one size, with an even dark frame on the left, top, and right, instead of side
  margins that grew and shrank with its label.

## 0.2.2 — 2026-09-26

- Print… opens the standard Print window, as other apps do, instead of a sheet squeezed into the
  editor's height with its options cut off.

## 0.2.1 — 2026-09-26

- The editor's bar is back. In 0.2.0 the picture's dark field was painted over it, hiding the
  tools, colors, fonts, undo, and Copy and Save (their keys still worked).

## 0.2.0 — 2026-09-26

A pass over the whole app for correctness, safety, and speed, and a new font.

- Open Sans joins the fonts for text: Droid Sans redrawn by its own designer, bundled with the
  app under the SIL Open Font License.
- The editor's window can be resized. The picture scales with it, proportions kept, up to its
  on-screen size; annotations scale along, stay editable, and export unchanged. A capture as big
  as the screen now opens inside it.
- Escape no longer closes an annotated capture without asking. Closing asks in a sheet, and words
  still being typed count.
- Copied, saved, and dragged pictures carry the capture's resolution (144 dpi from a Retina
  display), so they paste at their on-screen size instead of twice it, and keep a wide-gamut
  capture's colors.
- Obscure hides what it covers: coarser blocks of flattened color, on whole pixels.
- Undo takes back a whole callout, text edit, or move in one step. Command-Z while typing undoes
  the typing. Escape during a move puts it back.
- Editing words no longer hides them until the first keystroke, keeps the text in its place, and
  takes style changes made while typing. Changing one style of a selected annotation changes only
  that, and text is laid out again for a new font or size.
- Arrows can be reshaped by their head and tail, like arrows with text, and a short arrow can
  still be moved by its shaft. Arrows, highlighter strokes, and thin ellipses are selected where
  they are drawn on Retina captures.
- Dragging the picture out takes the words being typed with it, works from the first press while
  another app is in front, and leaves at most one file in the temporary folder.
- A click with the Crop tool clears the crop; the Text tool edits a text it clicks.
- A rectangle or ellipse thinner than its line is drawn solid instead of vanishing, and a short,
  thick arrow keeps a head wider than its shaft.
- The picker shows its crosshair only on the display the pointer is on, keys act there, and it
  cancels when another app comes to the front or the displays change.
- The editor keeps only the area you captured in memory, not the whole display it came from, and
  opens sooner: the capture is copied to the clipboard in the background.
- With several editors open, each gives focus back to the app its capture came from. F10 does
  nothing while a capture is under way, and the menu says when another app holds F10.
- A clicked window is captured at the resolution of the display it is on.
- The first capture shows only macOS's own permission prompt. Updates are checked once a day
  without a prompt of their own.
- Saved files are named with the time as the system writes it (`… at 10.12.34 AM.png`).
- Editing is smoother on large captures: drawing redraws only what changed, and an annotated 5K
  picture renders several times faster.

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
