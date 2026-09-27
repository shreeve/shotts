# Handoff

How the code works, why it is built this way, and the traps. `docs/SPEC.md` is what the product
does, `AGENTS.md` the rules, `docs/RELEASING.md` how a release is made.

## State

0.2.3 is released: tag `v0.2.3` on `main` (commit "Shotts 0.2.3"), the GitHub release with its
notarized zip and signed `appcast.xml`, and the Homebrew cask (shreeve/homebrew-tap#16);
installed copies are offered it through Sparkle. 0.2.3 (shreeve/shotts#54) makes the screen live
while capturing, keeps the editor open like any window with Option-F10 to bring the last capture
back, adds New Window per Capture, and keeps the magnifier's crosshair while dragging. 0.2.2
(shreeve/shotts#53) printed through the standard Print window; 0.2.1 (shreeve/shotts#52) fixed
0.2.0's editor, whose canvas painted over its bar. 0.2.0 is the revamp (shreeve/shotts#51, merge commit
c24b093): a correctness, security, and performance pass over the whole app, plus Open Sans;
`CHANGELOG.md` says what changed for users. The build has no warnings (warnings are
errors) and `swift test` passes: 41 Core tests and 50 AppKit tests.

Next, in order:

1. Use 0.2.3 by hand on a Retina and a non-Retina display (see "Checking by hand"). The tests
   and headless renders check a lot, but they missed 0.2.0's hidden bar, which only a real window
   showed: look at the bar first, then a capture, every tool, copy into Mail or Notes (it should
   paste at on-screen size), save, drag out, F10 from inside an editor, two displays.
2. Deferred work, below. New changes collect under a `## Unreleased` heading in `CHANGELOG.md`.

Decided against, so they are not rebuilt:

- Wrapping plain text at the picture's edge. The user breaks lines with Shift-Return; text that wrapped
  on its own would either keep its line breaks when moved (a stranded narrow column) or reflow
  as it moves, and both are worse than lines that only change when the user says so.

Deferred, with the reason each waits:

- The picker redraws its whole transparent overlay on each mouse move (the crosshair spans the
  display). Drawing the crosshair as two thin layers would leave only the magnifier to redraw.
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
| | `Style.swift` | `Style` (color, stroke width, font size, font, shadow, outline, tapered arrows), its pixel metrics, `applying(from:to:)`, and decoding that tolerates older and newer saved styles. `FontChoice`: Rounded, System, Open Sans. |
| | `Arrow.swift` | `ArrowGeometry`: an arrow as one filled outline, and its head length. |
| | `Callout.swift` | `CalloutLayout`: where a callout's words go, from the arrow alone. |
| | `HitTest.swift` | Which annotation a point lands on, and which part of an arrow or callout. |
| | `History.swift` | Undo and redo over any `Equatable` state, with `record(since:)` for changes made in place. |
| | `Selection.swift` | `SelectionRule`: the drag rectangle rules the picker and the shape tools share. |
| | `EditorLayout.swift` | The editor's sizing rules: the zoom for a window, the window for a zoom. |
| ShottsUI | `AreaSelection.swift` | The picker: `DisplayImage` (a display's latest picture, its windows, and `cut`), one overlay window per display, the crosshair, magnifier, hints, window outlines, `PixelSampler`. |
| | `EditorWindow.swift` | `EditorWindowController`: the bar, copy, save, print, closing, resizing, the drag grip, remembered tool and style. |
| | `CanvasView.swift` | The picture with its annotations, every tool's mouse handling, text entry (`TextEntry`), selection drawing. |
| | `Renderer.swift` | Draws a `Document` into any `CGContext`; measures text; an annotation's extent. |
| | `StylePopover.swift` | The color and style popover. |
| | `Export.swift` | The one encoder (PNG and TIFF at the capture's resolution), the pasteboard, a file, the drag file. |
| Shotts | `ShottsApp.swift` | `AppDelegate`: menu bar item and menu, main menu, Sparkle. |
| | `CaptureFlow.swift` | One capture from hot key to editor, which app gets focus back, and the capture closed last. |
| | `ScreenCapture.swift` | A clicked window through ScreenCaptureKit, and the window list. |
| | `LiveDisplay.swift` | A display streamed while the picker is up: its latest frame and windows. |
| | `HotKey.swift` | The Carbon hot keys: F10 captures, Option-F10 brings the last capture back. |
| | `DevSwitches.swift` | The developer switches, compiled into debug builds only. |

Settings live in the defaults: the picker options under `selection.*`, `capture.copies`, and
`export.shadow` (`SelectionOptions.current`, defaults registered in one place);
`capture.askedPermission` once the system's permission prompt has been shown, `editor.newWindows`; the editor's last
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

`CaptureFlow` runs one capture at a time: a `Capture` value holds the app to return to, the
picker, and the live displays, from `begin()` until the editor opens or the capture ends, and F10
does nothing meanwhile. The picker is live: `AreaSelection` shows at once, one clear borderless
window per display at `.screenSaver` level with the cursor hidden, and the real screen goes on
updating through it. Behind it, each `LiveDisplay` streams its display through an `SCStream`
(full resolution, BGRA, 30 frames a second, `ignoreShadowsDisplay` false) with only the picker's
windows excluded, so Shotts' editors are captured like anything else on screen. Each frame
becomes `DisplayImage.image` as a `CGImage` reading the frame's own memory, with no copy, and the
window list is read again a few times a second. When the user releases a usable rectangle,
`DisplayImage.cut` redraws that area of the latest frame into a bitmap of its own, in its color
space; `CGImage.cropping` alone would share, and so keep alive, the frame. The cut and the
display's scale become a `Document` in an `EditorWindowController`, and the streams stop.

Focus: the app to return to is the one in front at F10, or, if that was Shotts because an editor
was in front, the app that editor returns to. Each editor keeps its own and activates it when it
closes as the window being worked in; one closing in the background (Close All) leaves focus
alone. A cancelled capture returns to it at once.

The window list comes from `CGWindowListCopyWindowInfo` (layer 0, which leaves out the picker,
shareable, at least 40 points each way), front to back, placed on each display with `CGDisplayBounds`. The
picker outlines the first window containing the pointer, and a click with no drag reports it as
`.window`; the flow then captures that window on its own through
`SCContentFilter(desktopIndependentWindow:)` at the filter's `pointPixelScale`, so nothing
covering it appears. With the option on, `ignoreShadowsSingleWindow` is false and the picture is
the window with the shadow macOS draws around it, on a transparent margin, sized from the
filter's `contentRect`; that is the system's own look, which no synthesized shadow matched. A
window that has gone meanwhile falls back to its area of the latest frame.

Only the overlay under the pointer draws the crosshair, magnifier, hints, and window outline, and
it takes key status as the pointer enters, so Escape, Space, and Command-C act on that display.
The picker cancels when Shotts resigns active or the screen configuration changes. The magnifier
samples its 15 by 15 neighborhood of the latest frame with `PixelSampler.colors(in:of:)`, which
draws the pixels into a small context rather than parsing the capture's pixel format; its center is
the color under the crosshair; a new frame redraws just the magnifier's panel. The selection is
clipped to its display while dragging, and the size shown is `DisplayImage.pixelRect(for:)`, the
same rectangle the cut uses.

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
Copy and Save. The editor is an ordinary window: copy, save, drag out, and print leave it open
(print brings it back to the front after the Print window), and Command-W, the red button, or
Escape with nothing left to cancel closes it with no question. Closing first keeps the words
being typed and puts back a drag in progress. `CaptureFlow` keeps the document and picture of the
editor closed last, and Option-F10 (`showLast`) brings the newest open editor forward or opens
that one again; it is the only capture kept after its editor closes. Unless New Window per
Capture is on (`editor.newWindows`), a new capture's editor takes the place of the newest open
one at its top-left corner, and the one replaced becomes that kept capture, closed without
handing focus back.

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
Command-Z while typing undoes keystrokes and nothing outlives it. Return, Escape, or
Command-Return finishes and Shift-Return breaks a line, except while an input method is
composing, which gets every key. A text shape's `size` is its layout
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

Text is bold Rounded (the default), System, or Open Sans. The first two every Mac has; Trebuchet,
a stand-in for Droid Sans until Open Sans shipped, was dropped in 0.2.4, and a style remembered
with it comes back Rounded. Open Sans, Droid Sans redrawn by its own designer, is bundled: `Support/Fonts` holds
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
  frame alive, and with it a buffer the stream needs back. `DisplayImage.cut` draws into a bitmap
  of its own.
- A filtered display capture leaves window shadows out unless `ignoreShadowsDisplay` is false;
  the old frozen picker's screen looked shadowless for that reason.
- A clear window lets clicks through its transparent parts unless `ignoresMouseEvents` is set to
  false explicitly, even though false is what it reads by default; the live overlay sets it.
- Views no longer clip their drawing to their bounds by default, and the rect `draw(_:)` is asked
  to fill can reach past the view. The canvas filled it and painted its dark field over the bar
  in 0.2.0; it sets `clipsToBounds` and fills only its bounds, and `BarTests` checks the bar
  shows.
- Printing runs the operation on its own (`NSPrintOperation.run()`), in the standard Print window.
  As a sheet on the editor it took the editor's dark look and was squeezed to the window's
  height, cutting off its options.
- `NSWindowController.close()` and `NSWindow.close()` skip `windowShouldClose`; only
  `performClose` asks. Escape closed annotated captures without asking until it used
  `performClose`.
- A sheet on a window that is never shown can end a test process quietly, and `swift test` then
  reports only the other target, exiting 0. Never show a real alert or sheet from a test.
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
