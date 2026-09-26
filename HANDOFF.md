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

`CaptureFlow` (in the app target) runs one capture: it remembers the frontmost app, shows
`AreaSelection` (one borderless window per display at `.screenSaver` level), and when the user
releases a usable rectangle it waits 60 ms for the overlay to leave the screen and calls
`ScreenCapture.capture(rect:on:)`. That reads just that rectangle through ScreenCaptureKit's
`SCScreenshotManager`, at backing resolution, with Shotts' own application excluded from the
content filter. The `CGImage` and the display's scale become a `Document` and open in an
`EditorWindowController`. When the last editor closes the previous app is activated again.

Permission is checked with `CGPreflightScreenCaptureAccess` and asked for with
`CGRequestScreenCaptureAccess`; macOS records the grant against the app's code signature, which
is why local builds are signed with the Developer ID rather than ad hoc.

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
in.png out.png` draws one of every annotation on a picture and writes the PNG, for checking the
renderer by eye. Both are in `AppDelegate.applicationDidFinishLaunching`.

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
- A menu bar app (`LSUIElement`) is not active when its windows appear. The editor must
  `NSApp.activate` itself, and remember the app that was frontmost before, to hand focus back.
- Key equivalents in a menu bar app still route through `NSApp.mainMenu`, which such an app has
  to build by hand (`AppDelegate.makeMainMenu`). Without it, Command-Z, Command-W, and Delete
  reach nothing.
- `NSStackView.fittingSize` before layout is not the bar's width; the editor window sizes
  itself from `layoutSubtreeIfNeeded()` plus a floor of `EditorWindowController.minimumWidth`.
- `NSResponder` already declares `selectAll(_:)` and `cancelOperation(_:)` (override them) but
  not `delete(_:)` or `undo(_:)` (plain `@objc` actions).
- A blend mode is the wrong way to make a highlighter: multiply vanishes on the dark
  backgrounds screenshots are full of. It is a translucent stroke.
- An arrow is one filled outline (`ArrowGeometry.outline`), not a stroked line plus a head:
  that is what lets it taper, and one shape means one shadow with no seam.
