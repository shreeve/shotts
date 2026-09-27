# Handoff

How the code works, why it is built this way, and the traps. `docs/SPEC.md` is what the product
does, `AGENTS.md` the rules, `docs/RELEASING.md` how a release is made.

## State

0.1.0 is released (GitHub, the Homebrew cask, Sparkle), and the repository is public. The
`revamp` branch (from `main` at e945441) is a correctness, security, and performance pass over
the whole app; `CHANGELOG.md`'s Unreleased section is what it changed for users. It builds with
no warnings (warnings are errors) and `swift test` passes: 40 Core tests and 45 AppKit tests.

Next, in order:

1. Exercise a Release build by hand on a Retina and a non-Retina display (see "Checking by
   hand"): a capture, every tool, copy into Mail or Notes (it should paste at on-screen size),
   save, drag out, F10 from inside an editor, two displays.
2. Merge `revamp` and cut 0.2.0 with `Scripts/release.sh`.
3. Deferred work, below.

Deferred, with the reason each waits:

- The picker redraws its whole overlay and holds a full-size backing store per display while it
  is up (about 4 ms of CPU per mouse move and 88 MB per 6K display). Putting the frozen picture
  in a layer's `contents` and drawing only the crosshair, magnifier, and hints over it would
  remove both; it needs a two-layer overlay and a new `--preview-overlay` path.
- Plain text never wraps: text typed past the picture's right edge is clipped. It could wrap at
  the edge less the callout margin, as callouts do; `TextEntry.place` would grow a wrap width.
- Selecting an annotation does not show its style in the bar. Changing a style changes only what
  changed (`Style.applying(from:to:)`), so nothing is lost, but the bar does not tell you the
  selection's width or font.
- VoiceOver sees the canvas as one image; annotations are not accessibility elements.
- If one display fails to picture, the whole capture fails rather than leaving that display out.
- Not built: see SPEC.

## Map

| Target | File | Holds |
| --- | --- | --- |
| ShottsCore | `Document.swift` | The seam: pixel size, scale, annotations, crop; `visibleRect` is what exports. |
| | `Annotation.swift` | `Annotation.Shape` (arrow, callout, rectangle, ellipse, text, pen, highlighter, obscure), bounds, translation, `dragged(_:by:)` (what a drag on each part moves), degeneracy. |
| | `Style.swift` | `Style` (color, stroke width, font size, font, shadow, outline, tapered arrows), its pixel metrics, `applying(from:to:)`, and decoding that tolerates older and newer saved styles. `FontChoice`: Rounded, System, Trebuchet, Open Sans. |
| | `Arrow.swift` | `ArrowGeometry`: an arrow as one filled outline, and its head length. |
| | `Callout.swift` | `CalloutLayout`: where a callout's words go, from the arrow alone. |
| | `HitTest.swift` | Which annotation a point lands on, and which part of an arrow or callout. |
| | `History.swift` | Undo and redo over any `Equatable` state, with `record(since:)` for changes made in place. |
| | `Selection.swift` | `SelectionRule`: the drag rectangle rules the picker and the shape tools share. |
| | `EditorLayout.swift` | The editor's sizing rules: the zoom for a window, the window for a zoom. |
| ShottsUI | `AreaSelection.swift` | The picker: `DisplayImage` (a display's frozen picture and `cut`), one overlay window per display, the crosshair, magnifier, hints, window outlines, `PixelSampler`. |
| | `EditorWindow.swift` | `EditorWindowController`: the bar, copy, save, print, closing, resizing, the drag grip, remembered tool and style. |
| | `CanvasView.swift` | The picture with its annotations, every tool's mouse handling, text entry (`TextEntry`), selection drawing. |
| | `Renderer.swift` | Draws a `Document` into any `CGContext`; measures text; an annotation's extent. |
| | `StylePopover.swift` | The color and style popover. |
| | `Export.swift` | The one encoder (PNG and TIFF at the capture's resolution), the pasteboard, a file, the drag file. |
| Shotts | `ShottsApp.swift` | `AppDelegate`: menu bar item and menu, main menu, Sparkle. |
| | `CaptureFlow.swift` | One capture from hot key to editor, and which app gets focus back. |
| | `ScreenCapture.swift` | ScreenCaptureKit (every display, or one window) and the window list. |
| | `HotKey.swift` | The Carbon hot key for F10. |
| | `DevSwitches.swift` | The developer switches, compiled into debug builds only. |

Settings live in the defaults: the picker options under `selection.*`, `capture.copies`, and
`export.shadow` (`SelectionOptions.current`, defaults registered in one place);
`capture.askedPermission` once the system's permission prompt has been shown; the editor's last
style as JSON under `editor.style` and its last drawing tool under `editor.tool`.

## The seam

`Document` in Core is the one thing the editor edits and the renderer draws. `Renderer` in UI
draws it into any `CGContext`, for the canvas and for export alike, so what the user sees is
what they paste; nothing in Core knows how a document is drawn. Undo is a `History<Document>`
of annotation edits; the source pixels are never copied.

`Style` lengths are points. `Style.stroke(scale:)`, `highlighterWidth(scale:)`, and
`arrow(from:to:scale:)` turn them into pixels at the document's scale, and both the renderer and
`HitTest` use them, so an annotation is hit where it is drawn. Before, hit testing measured in
points and missed Retina barbs and highlighter bands.

## Capture

`CaptureFlow` runs one capture at a time: a `Capture` value holds the app to return to and the
picker, from `begin()` until the editor opens or the capture ends, and F10 does nothing
meanwhile. `ScreenCapture.captureDisplays()` reads the window list once, then pictures every
display concurrently through `SCScreenshotManager` at backing resolution with Shotts' own
windows excluded (by pid, in the filter and the list). `AreaSelection` shows them, one borderless
window per display at `.screenSaver` level with the cursor hidden. When the user releases a
usable rectangle, `DisplayImage.cut` redraws that area into a bitmap of its own, in the
picture's color space; `CGImage.cropping` alone would share, and so keep alive, the whole display
picture. The cut and the display's scale become a `Document` in an `EditorWindowController`. The
display pictures live in the picker's windows and go when it closes.

Focus: the app to return to is the one in front at F10, or, if that was Shotts because an editor
was in front, the app that editor returns to. Each editor keeps its own and activates it when it
closes as the window being worked in; one closing in the background (Close All) leaves focus
alone. A cancelled capture returns to it at once.

The window list comes from `CGWindowListCopyWindowInfo` (layer 0, not Shotts', shareable, at
least 40 points each way), front to back, placed on each display with `CGDisplayBounds`. The
picker outlines the first window containing the pointer, and a click with no drag reports it as
`.window`; the flow then captures that window on its own through
`SCContentFilter(desktopIndependentWindow:)` at the filter's `pointPixelScale`, so nothing
covering it appears. With the option on, `ignoreShadowsSingleWindow` is false and the picture is
the window with the shadow macOS draws around it, on a transparent margin, sized from the
filter's `contentRect`; that is the system's own look, which no synthesized shadow matched. A
window that has gone since the displays were pictured falls back to its area of the display
picture.

Only the overlay under the pointer draws the crosshair, magnifier, hints, and window outline, and
it takes key status as the pointer enters, so Escape, Space, and Command-C act on that display.
The picker cancels when Shotts resigns active or the screen configuration changes. The magnifier
samples its 15 by 15 neighborhood once per frame with `PixelSampler.colors(in:of:)`, which draws
the pixels into a small context rather than parsing the capture's pixel format; its center is
the color under the crosshair. The selection is clipped to its display while dragging, and the
size shown is `DisplayImage.pixelRect(for:)`, the same rectangle the cut uses.

The clipboard copy at capture time (`Export.copyInBackground`) encodes off the main thread and
writes only if the pasteboard has not changed since, so the editor opens at once and a Copy made
from it first is never overwritten.

Permission is checked with `CGPreflightScreenCaptureAccess`. The first F10 without it calls
`CGRequestScreenCaptureAccess`, which shows the system's prompt; later presses show Shotts' own
explanation. macOS records the grant against the app's code signature, which is why every build
is signed with the Developer ID rather than ad hoc.

## The editor

`EditorWindowController` builds its bar by hand: a segmented control of `Tool`s (single-key
shortcuts, the last drawing tool remembered), the color swatch that opens the window's one
`StylePopover`, popups for stroke width, text size, and font, undo and redo, the drag grip, and
Copy and Save. Copy, save, and a drag out finish the edit and close the window; print does not.
Closing with annotations, words being typed included, asks in a sheet (`askToDiscard`), and
Escape with nothing to cancel closes through `performClose`, so it asks too.

Resizing changes only the canvas's `zoom` (points per picture pixel), never the document.
`EditorLayout` holds the rules: the zoom that fits a content size (capped at the picture's
on-screen size, `1 / scale`, and floored so its longer side stays `minimumPicture` points) and
the snug content size for a zoom (never narrower than the bar). Opening, `windowWillResize`, and
the green button all use it. Text entry is committed before the zoom changes, because an entry
is placed for one zoom.

`CanvasView` owns the `History<Document>` and the tools' mouse handling. A drag with a drawing
tool builds a `live` annotation that commits on mouse up; Shift squares a rectangle or ellipse
and Option fills it, and either may change mid-drag. A change made in place (a move with the
select tool, a text entry, a new callout with its words) keeps `base`, the document when it
began, and ends with `History.record(since:)`: one undo step, or none if nothing changed. Escape
during a move restores `base`. The arrow tools select an existing arrow or callout on click
instead of drawing, and the text tool edits a text it clicks. Arrows and callouts show a dot at
each end; everything else a dashed box. While dragging, only the extent of what moved is redrawn
(`Renderer.extent`, converted to the view); a crop dims the whole picture and redraws it all.

Changing the style (the bar or the popover) applies only what changed: to the words being typed
if there are any, else to the selected annotation, whose text is measured again and a callout's
words laid out again.

## Text and callouts

Text is typed on the picture: `CanvasView.beginTextEntry` adds an invisible `TextEntry` (an
`NSTextView` with clear text and a colored caret) whose `preview` the canvas draws through the
renderer, so what is typed looks exactly like the export. The entry has its own undo manager, so
Command-Z while typing undoes keystrokes and nothing outlives it. Return breaks a line; Escape or
Command-Return finishes, unless an input method is composing. A text shape's `size` is its layout
box, which hugs the words, with the outline's room on every side: a callout's words wrap at
`CalloutLayout.width` but the box is only as wide as the widest line, so it can be centered on
the tail and its selection outline fits the words. `Renderer.textSize` measures it and `drawText`
draws inside it.

`CalloutLayout` in Core decides where a callout's words go from the arrow alone: the side (left
or right of the tail for a mostly horizontal arrow, above or below for a mostly vertical one,
away from the tip unless there is no room), an `anchor` a quarter of a line out from the tail,
and `origin(for:)`, which hangs a box of any size from that anchor, centered along its near edge
and kept inside the picture less its margin (smaller on a tiny picture). The entry re-asks it
after every keystroke. The entry view is as wide as the wrap width, so lines fold exactly where
the renderer's do, and is slid so the edge its words align to lies on the measured box's edge;
it accepts clicks only over the words.

A callout is one annotation, `.callout(from:to:text:)`, whose `TextBox` is derived state: the
canvas's `relaid(_:from:to:string:)` recomputes it whenever the arrow or the style changes.
`HitTest.arrowPart` says which part of an arrow or callout a point is on (`.text`, `.tail`,
`.head`, `.shaft`; the tail grip and head each at most a third of the arrow), and
`Annotation.dragged(_:by:)` says what a drag on it moves. Editing words (`editText`) keeps the
text or callout in the document with empty words, so it keeps its place in the stack;
`endTextEntry` puts the words back, removes a text left empty, and turns a wordless callout into
a plain `.arrow`.

## Rendering and export

`Renderer.draw` expects a flipped context in image pixels. The canvas sets one up by translating
to the picture and scaling by `zoom`; `Renderer.image(of:source:)` by flipping a fresh bitmap in
the source's color space (or returns the source itself for a blank document). The source bitmap's
rows are stored top-first, so `draw` flips back around the picture for that one `ctx.draw`, and
`drawPixelated` does the same for its blocks. The source is drawn without smoothing at one device
pixel per image pixel or more, and smoothed when the canvas shrinks it.

Every annotation is drawn clipped to `Renderer.extent(of:scale:)`, which holds its ink, outline,
and shadow with room to spare; annotations outside the clip are skipped. Shadows are sized in the
context's base units, which the CTM does not scale, so `draw` takes `baseScale` (the canvas passes
its zoom) to keep the canvas's shadows the size of the export's.

Obscure pixelates the source under a rectangle snapped out to whole pixels, in 10-point blocks
whose colors are rounded to 16 levels, drawn from the source every time and never cached.

`Export.encode` is the one encoder: PNG and TIFF through ImageIO, marked at 72 × scale dpi, so a
Retina capture pastes at its on-screen size. Copy renders once and writes both types; a drag
writes into `$TMPDIR/Shotts Drag/`, emptied before each drag, so at most one drag file exists.

## Fonts

Text is bold Rounded (the default), System, Trebuchet, or Open Sans. The first three every Mac
has. Open Sans, Droid Sans redrawn by its own designer, is bundled: `Support/Fonts` holds
`OpenSans-Bold.ttf` from github.com/googlefonts/opensans with its license, `OFL.txt`, which
must ship beside it. `package-app.sh` copies the folder into `Contents/Resources/Fonts`, and
`ATSApplicationFontsPath` in `Info.plist` makes it Shotts' own font, installed nowhere else.
Outside the bundle (`swift test`, a bare debug binary) it is missing and `Renderer.font` falls
back to Rounded; `FontTests` registers the file for its own process.

## The app icon

`Support/AppIcon.svg` is the master: a camera in a viewfinder, drawn to look like the menu
bar's `camera.viewfinder` symbol but with our own paths, because the SF Symbols license does
not allow the symbols themselves in app icons. `Scripts/make-app-icon.sh` rasterizes it with
the Dock shadow and packs `Support/AppIcon.icns`; rerun it after editing the SVG and commit the
`.icns`. The SVG's comment has the grid.

## Releasing

`docs/RELEASING.md`. Sparkle always starts, and `SUEnableAutomaticChecks` makes it check daily
without asking; Check for Updates… is in the menu bar menu and the app menu.

## Tests

`swift test` runs two targets. `Tests/Core` covers Core: selection rules, history, the document,
hit testing at scale 1 and 2, arrow parts and drags, styles, callout layout, and the editor's
layout. `Tests/UI` drives AppKit in windows that are never shown: the editor's gestures, undo,
typing, restyling, closing, and resizing; the renderer (extent, text box, canvas against export);
export (resolution, color space, obscure, the background copy, file names, the drag file); and
the picker (the cut, the pointer per display, clipping, cancelling). `Tests/UI/Support.swift`
has the helpers, and `EditorTests.swift`'s `Mouse` posts events to a view, never to the screen.

## Checking by hand

Debug builds (`Scripts/package-app.sh` without `CONFIG=release`) take these switches; a release
build ignores its arguments.

| Switch | Does |
| --- | --- |
| `--edit file.png` | Opens a picture in the editor without capturing. |
| `--render in.png out.png [--crop]` | Draws one of every annotation on a picture and writes the PNG. |
| `--print-pdf in.png out.pdf [--crop]` | Writes the same sample's print page as a PDF, laid out as Command-P would print it. |
| `--preview-style out.png` | Draws the style popover off screen. |
| `--select out.txt` | Runs the picker alone over a drawn stand-in for each display and writes `selected x,y,w,h on <display>`, `window <id> at x,y on <display>`, or `cancelled`. |
| `--preview-overlay out.png [--dragged] [--dim] [--corner]` | Draws the picker off screen with the pointer three pixels inside the corner of the stand-in's square at 1600,1600, so the magnifier's mapping can be checked (`--dim` shows only with `--dragged`). |
| `--capture-window <id> out.png [--no-shadow]` | Captures one window through ScreenCaptureKit (needs Screen Recording). |

From a shell that macOS trusts for Accessibility, `CGEvent` posts reach a real editor: launch
`Shotts.app --args --edit sample.png`, find the window with `CGWindowListCopyWindowInfo` (owner
`Shotts`, layer 0), and post events into the picture, centered in the canvas 28 points below the
bar. Never do this while someone is at the keyboard: the events land in whatever is in front.

## Traps

- Screen Recording permission is keyed to the code signature. An ad-hoc-signed build has a new
  signature every time, so each rebuild would ask again and leave another row in System
  Settings. `Scripts/package-app.sh` signs every build with the Developer ID for that reason.
- A menu bar app (`LSUIElement`) is not active when its windows appear, and on macOS 27 the
  plain `NSApp.activate()` is refused for it: the overlay showed but Escape went to the app in
  front. `activate(ignoringOtherApps: true)` works, and every activation uses it.
- `CGImage.cropping(to:)` shares its parent's pixels: a cut-out made that way keeps the whole
  display picture alive. `DisplayImage.cut` draws into a bitmap of its own.
- `NSWindowController.close()` and `NSWindow.close()` skip `windowShouldClose`; only
  `performClose` asks. Escape closed annotated captures without asking until it used
  `performClose`.
- A sheet on a window that is never shown can end a test process quietly, and `swift test` then
  reports only the other target, exiting 0. Tests answer `askToDiscard` themselves; never show a
  real alert or sheet from a test.
- Core Graphics sizes a transparency layer to the clip: without the clip to an annotation's
  extent, every shadowed arrow and text allocated and composited a picture-sized layer (116 ms
  per arrow on a 5K capture).
- `CGContext.setShadow` takes its offset and blur in base space, untouched by the CTM. In a
  flipped context an offset meant to fall below falls above, so the shadow has no offset; and the
  blur is scaled by `baseScale` so the canvas's shadow matches the export's.
- `AreaSelection` holds its windows and calls back once; whoever shows one must keep a
  reference to it (`DevSwitches.selection` for `--select`), or its `[weak self]` callback finds
  nothing and the overlay stays up.
- Key equivalents in a menu bar app still route through `NSApp.mainMenu`, which such an app has
  to build by hand (`AppDelegate.makeMainMenu`). Without it, Command-Z, Command-W, Command-P,
  and Delete reach nothing. Print reaches the window controller through the responder chain.
- `NSStackView.fittingSize` before layout is not the bar's width; hence `layoutSubtreeIfNeeded()`
  before measuring, and the width rounded up.
- `NSResponder` already declares `selectAll(_:)` and `cancelOperation(_:)` (override them) but
  not `delete(_:)` or `undo(_:)` (plain `@objc` actions). Menu validation needs the class to adopt
  `NSMenuItemValidation`; a bare `validateMenuItem` is never called.
- A subclass of `NSWindow` or `NSTextView` must provide the designated initializer
  (`init(contentRect:styleMask:backing:defer:)`, `init(frame:textContainer:)`): the convenience
  ones call it, and a missing one traps at first use. `TextEntry` builds the text system by hand
  and hands the container in.
- Sizing the text entry view to the measured width of the words folded the last word onto a
  phantom line whenever the zoomed font came out a hair wider than the measurement, leaving
  the caret a line below the words. The view is as wide as the wrap width instead.
- A blend mode is the wrong way to make a highlighter: multiply vanishes on the dark
  backgrounds screenshots are full of. It is a translucent stroke.
- A bitmap context's first row in memory is its top row, even though its drawing coordinates
  run upward. `PixelSampler.colors` reads row `j` at offset `j * width`.
- An arrow is one filled outline (`ArrowGeometry.outline`), not a stroked line plus a head:
  that is what lets it taper, and one shape means one shadow with no seam.
- `Tool.select` is raw value 0, which is also what an unset default reads as; the remembered
  tool checks for a stored value before trusting the number.
