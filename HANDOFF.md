# Handoff

How the code works now, why it is built this way, and the traps. `docs/SPEC.md` is what the
product does; `AGENTS.md` is the rule list. The package builds on Apple-silicon macOS 27 with the
Xcode 27 toolchain with no warnings, and `swift test` passes.

## State

The first milestone, the daily screenshot workflow, is built and exercised end to end with
synthesized input: F10, area selection, the editor with every tool, undo, and copy, save, and
drag out. Window capture, the magnifier, repeat-last-area, and recording come after it, in that
order. `docs/SPEC.md` describes the behavior.

## The seam

`Document` in `ShottsCore` is the seam: the capture's pixel size, a list of `Annotation` values,
and a crop. The editor edits a `Document`; `Renderer` in `ShottsUI` draws one into any
`CGContext`, for the canvas and for export alike. Nothing in Core knows how a document is drawn.

## Capture

`CaptureFlow` (in the app target) runs one capture: it remembers the frontmost app, calls
`ScreenCapture.captureDisplays()`, which reads every display once through ScreenCaptureKit's
`SCScreenshotManager` at backing resolution with Shotts' own application excluded, and shows
`AreaSelection` over them (one borderless window per display at `.screenSaver` level, each
drawing its display's picture). When the user releases a usable rectangle the flow cuts it out
of that picture with `SelectionRule.pixelRect` and `CGImage.cropping`, and the picture and the
display's scale become a `Document` in an `EditorWindowController`. The display pictures live in
the picker's windows and go when it closes. When the last editor closes the previous app is
activated again.

`WindowFinder` lists the ordinary windows on each display from `CGWindowListCopyWindowInfo`
(layer 0, not Shotts', at least 40 points each way), front to back, converted to the picker's
space: the window server's origin is the primary display's top-left, so a display's rectangle
there is `(frame.minX, primary.height - frame.maxY, …)` and window bounds are offset by that.
The picker outlines the first window containing the pointer, and a click with no drag reports
it as `.window`; the flow then captures that window on its own through
`SCContentFilter(desktopIndependentWindow:)`, so nothing covering it appears. With the option
on, `ignoreShadowsSingleWindow` is false and the picture is the window with the shadow macOS
draws around it, on a transparent margin, sized from the filter's `contentRect`; that is the
system's own look, which no synthesized shadow matched (three tries, compared side by side
with Monosnap's, before this). A window that has gone since the displays were pictured falls
back to its area of the display picture. `Shotts --capture-window <id> out.png [--no-shadow]`
exercises it on any window.

The picker's magnifier reads the pointer's neighborhood from the display picture and its color
through `PixelSampler`, which draws one pixel into a one-pixel context rather than parsing the
capture's pixel format. `SelectionOptions` (copy on capture, window shadow, dimming, magnifier, hints) live in
the defaults and are toggled from the menu bar menu, whose check marks are refreshed in
`menuNeedsUpdate`.

Permission is checked with `CGPreflightScreenCaptureAccess` and asked for with
`CGRequestScreenCaptureAccess`; macOS records the grant against the app's code signature, which
is why local builds are signed with the Developer ID rather than ad hoc.

## Text and callouts

Text is typed on the picture: `CanvasView.beginTextEntry` adds an invisible `TextEntry`
(an `NSTextView` with clear text and a colored caret) and draws the live text through the
renderer as the user types, so what is typed looks exactly like the export. A text shape's
`size` is its layout box: with a wrap width (a callout), lines wrap inside that width in both
the entry and the renderer, which is why `Renderer.textSize` and `drawText` take and use the
box. `CalloutLayout` in Core decides where a callout's text goes from the arrow alone, and
`origin(for:in:)` keeps a right-anchored box against its edge and inside the picture as the text
grows; the entry re-asks it after every keystroke.

A callout is one annotation, `.callout(from:to:text:)`, whose `TextBox` is derived state: the
canvas's `relaid(_:from:to:string:)` recomputes it from the arrow whenever the arrow changes.
`HitTest.calloutPart` says which part a point is on (`.text`, `.head`, `.arrow`), and
`dragged(_:by:)` turns a select-tool drag into the right edit: text moves the tail, head moves
the tip, anything else moves the whole. While its words are being typed the callout sits in the
document with empty text and the `TextEntry` carries its `calloutID`; `endTextEntry` puts the
words back, or turns a wordless callout into a plain `.arrow`.

## Coordinates

Three spaces meet here. `AreaSelection` reports points from the screen's top-left corner, y
down, which is also ScreenCaptureKit's `sourceRect` space for that display. `Document` and every
annotation are in image pixels, top-left origin. `CanvasView` is flipped and holds the picture
in `pictureRect` at `zoom` points per pixel; `imagePoint(_:)` and `viewRect(_:)` are the only
conversions. `Renderer.draw` expects a flipped context in pixel space; the canvas sets one up
by translating to the picture and scaling by `zoom`, and `Renderer.image(of:source:)` by flipping
a fresh bitmap context. The one wrinkle is the source bitmap, whose rows are stored top-first:
`draw` flips back around the picture for that single `ctx.draw`, and `drawPixelated` does the
same for its block image.

## Developer switches

`Shotts --edit file.png` opens a picture in the editor without capturing. `Shotts --render
in.png out.png [--crop]` draws one of every annotation on a picture and writes the PNG, for
checking the renderer by eye. `Shotts --preview-style out.png` draws the editor's style popover. `Shotts --check-text-entry`
exercises text entry headlessly.
`Shotts --select out.txt` runs the picker alone over a drawn
stand-in for each display and writes `selected x,y,w,h on <display>` or `cancelled`, which
exercises the overlay on a Mac that has not granted Screen Recording. `Shotts --preview-overlay
out.png [--dragged] [--dim] [--corner]` draws the picker off screen (`--dim` is the option on;
it shows only with `--dragged`), with the pointer three pixels inside
the corner of the stand-in's square at 1600,1600 so the magnifier's mapping can be checked
without touching the screen. All are in `AppDelegate.applicationDidFinishLaunching`.

## Exercising the editor

From a shell that macOS trusts for Accessibility, `CGEvent` posts reach the editor: launch
`Shotts.app --args --edit sample.png`, find the window's bounds with `CGWindowListCopyWindowInfo`
(owner `Shotts`, layer 0), and post mouse and key events into the picture, which sits centered
in the canvas 28 points below the bar. This session's scripts for that lived in the scratchpad;
they are ten lines each and worth recreating rather than keeping.

## Traps

- Screen Recording permission is keyed to the code signature. An ad-hoc-signed build has a new
  signature every time, so each rebuild would ask again and leave another row in System Settings.
  `Scripts/package-app.sh` signs every build with the Developer ID for that reason.
- A menu bar app (`LSUIElement`) is not active when its windows appear, and on macOS 27 the
  plain `NSApp.activate()` is refused for it: the overlay showed but Escape went to the app in
  front (measured with `--select`). `activate(ignoringOtherApps: true)` works and is what
  `AreaSelection.show()`, `EditorWindowController.present()`, and the alerts use. The flow
  remembers the app that was frontmost before, to hand focus back.
- `AreaSelection` holds its windows and calls back once; whoever shows one must keep a
  reference to it. The `--select` switch first created one inline, its `[weak self]` callback
  found nothing, and the overlay stayed up with no way to finish.
- Key equivalents in a menu bar app still route through `NSApp.mainMenu`, which such an app has
  to build by hand (`AppDelegate.makeMainMenu`). Without it, Command-Z, Command-W, and Delete
  reach nothing.
- `NSStackView.fittingSize` before layout is not the bar's width; the editor window sizes
  itself from `layoutSubtreeIfNeeded()` plus a floor of `EditorWindowController.minimumWidth`.
- `NSResponder` already declares `selectAll(_:)` and `cancelOperation(_:)` (override them) but
  not `delete(_:)` or `undo(_:)` (plain `@objc` actions).
- A subclass of `NSWindow` or `NSTextView` must provide the designated initializer
  (`init(contentRect:styleMask:backing:defer:)`, `init(frame:textContainer:)`): the convenience
  ones call it, and a missing one traps at first use. `OverlayWindow` and `TextEntry` both
  crashed this way; `TextEntry` builds the text system by hand and hands the container in.
  `Shotts --check-text-entry` opens text entry in an unshown window and exits non-zero if it
  cannot; run it after touching `TextEntry`.
- A blend mode is the wrong way to make a highlighter: multiply vanishes on the dark
  backgrounds screenshots are full of. It is a translucent stroke.
- A bitmap context's first row in memory is its top row, even though its drawing coordinates
  run upward. `PixelSampler.colors` reads row `j` at offset `j * width`; reversing the rows
  put the magnifier's adaptive arms upside down, which the `--preview-overlay` square showed.
- `CGContext.setShadow` takes its offset in device space, untouched by the CTM, so in a flipped
  context an offset meant to fall below the shape falls above it. The renderer's shadow has no
  offset, only blur, which looks like macOS's own and cannot flip.
- An arrow is one filled outline (`ArrowGeometry.outline`), not a stroked line plus a head:
  that is what lets it taper, and one shape means one shadow with no seam.
