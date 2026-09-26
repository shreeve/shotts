# Handoff

How the code works, why it is built this way, and the traps. `docs/SPEC.md` is what the
product does; `AGENTS.md` is the rules; `docs/RELEASING.md` is how a release is made. The
package builds on Apple-silicon macOS 27 with the Xcode 27 toolchain with no warnings, and
`swift test` passes.

## State

The daily screenshot workflow is built and in daily use: F10, area or window selection with a
magnifier, the editor with every tool, undo, and copy, save, print, and drag out. The app has
its icon and a release pipeline (Developer ID, notarization, a Homebrew cask, Sparkle updates),
but no release has been cut yet; the repository is still private, which the release script
refuses. Not built: repeating the previous area, delayed capture, screen recording, and the
rest of the spec's "Not built" list.

## Map

Three targets, as `AGENTS.md` lays out. Files and what each holds:

| Target | File | Holds |
| --- | --- | --- |
| ShottsCore | `Document.swift` | The seam: pixel size, scale, annotations, crop; `visibleRect` is what exports. |
| | `Annotation.swift` | `Annotation.Shape` (arrow, callout, rectangle, ellipse, text, pen, highlighter, obscure), bounds, translation, degeneracy. |
| | `Style.swift` | `Style` (color, stroke width, font size, font, shadow, outline, tapered arrows), Codable with defaults for old saved styles. |
| | `Callout.swift` | `CalloutLayout`: where a callout's words go, from the arrow alone. |
| | `Arrow.swift` | `ArrowGeometry`: an arrow as one filled outline. |
| | `HitTest.swift` | Which annotation, and which part of a callout, a point lands on. |
| | `History.swift` | Undo and redo over any `Equatable` state. |
| | `Selection.swift` | `SelectionRule`: the drag rectangle rules the picker and the shape tools share. |
| ShottsUI | `AreaSelection.swift` | The picker: one overlay window per display, the crosshair, magnifier, hints, window outlines, `WindowFinder`, `PixelSampler`. |
| | `EditorWindow.swift` | `EditorWindowController`: the tool bar, copy, save, print, the drag grip, remembered tool and style. |
| | `CanvasView.swift` | The picture with its annotations, every tool's mouse handling, text entry, selection drawing. |
| | `Renderer.swift` | Draws a `Document` into any `CGContext`; measures text. |
| | `StylePopover.swift` | The color and style popover. |
| | `Export.swift` | Pasteboard, file, temporary file for a drag. |
| Shotts | `ShottsApp.swift` | `AppDelegate`: menu bar item and menu, main menu, Sparkle, the developer switches. |
| | `CaptureFlow.swift` | One capture from hot key to editor. |
| | `ScreenCapture.swift` | ScreenCaptureKit: every display, or one window. |
| | `HotKey.swift` | The Carbon hot key. |

Settings live in the defaults: the picker options under `selection.*`, `capture.copies`, and
`export.shadow` (`SelectionOptions.current`); the editor's last style as JSON under
`editor.style` and its last drawing tool under `editor.tool`.

## The seam

`Document` in Core is the one thing the editor edits and the renderer draws. `Renderer` in UI
draws it into any `CGContext`, for the canvas and for export alike, so what the user sees is
what they paste; nothing in Core knows how a document is drawn. Undo is a `History<Document>`
of annotation edits; the source pixels are never copied.

## Capture

`CaptureFlow` runs one capture: it remembers the frontmost app, calls
`ScreenCapture.captureDisplays()`, which pictures every display once through ScreenCaptureKit's
`SCScreenshotManager` at backing resolution with Shotts' own windows excluded, and shows
`AreaSelection` over them (one borderless window per display at `.screenSaver` level, each
drawing its display's picture, with the cursor hidden). When the user releases a usable
rectangle the flow cuts it out of that picture with `SelectionRule.pixelRect` and
`CGImage.cropping`, and the picture and the display's scale become a `Document` in an
`EditorWindowController`. The display pictures live in the picker's windows and go when it
closes. When the last editor closes, the app that was in front before is activated again.

`WindowFinder` lists the ordinary windows on each display from `CGWindowListCopyWindowInfo`
(layer 0, not Shotts', at least 40 points each way), front to back, converted to the picker's
space: the window server's origin is the primary display's top-left, so a display's rectangle
there is `(frame.minX, primary.height - frame.maxY, …)` and window bounds are offset by that.
The picker outlines the first window containing the pointer, and a click with no drag reports
it as `.window`; the flow then captures that window on its own through
`SCContentFilter(desktopIndependentWindow:)`, so nothing covering it appears. With the option
on, `ignoreShadowsSingleWindow` is false and the picture is the window with the shadow macOS
draws around it, on a transparent margin, sized from the filter's `contentRect`; that is the
system's own look, which no synthesized shadow matched (three tries before this). A window
that has gone since the displays were pictured falls back to its area of the display picture.

The picker's magnifier reads the pointer's neighborhood from the display picture and its
color through `PixelSampler`, which draws one pixel into a one-pixel context rather than
parsing the capture's pixel format. Dimming outside the selection shows only while dragging.
The menu bar menu's check marks are refreshed in `menuNeedsUpdate`.

Permission is checked with `CGPreflightScreenCaptureAccess` and asked for with
`CGRequestScreenCaptureAccess`; macOS records the grant against the app's code signature,
which is why every build is signed with the Developer ID rather than ad hoc.

## The editor

`EditorWindowController` builds its bar by hand: a segmented control of `Tool`s (single-key
shortcuts, the last drawing tool remembered), the color swatch that opens `StylePopover`,
popups for stroke width, text size, and font, undo and redo, the drag grip, and Copy and
Save. Copy, save, and a drag out finish the edit and close the window; print does not. The
window sizes itself from `layoutSubtreeIfNeeded()` with a floor of `minimumWidth`.

`CanvasView` owns the `History<Document>` and the tools' mouse handling. A drag with a drawing
tool builds a `live` annotation that commits on mouse up; Shift squares a rectangle or
ellipse and Option fills it, and either may change mid-drag. With the select tool a drag
edits the document in place and becomes one undo step on mouse up. The arrow tools select an
existing arrow or callout on click instead of drawing: the drag carries its own `dragTool`.
The selection outline is a dashed box, or for a callout a box around its words and a dot at
each end. The canvas shows the ordinary pointer; the crosshair belongs to the picker.

## Text and callouts

Text is typed on the picture: `CanvasView.beginTextEntry` adds an invisible `TextEntry` (an
`NSTextView` with clear text and a colored caret) and draws the live text through the
renderer as the user types, so what is typed looks exactly like the export. Return breaks a
line; Escape or Command-Return finishes. A text shape's `size` is its layout box, which hugs
the words: a callout's words wrap at `CalloutLayout.width` but the box is only as wide as the
widest line, so it can be centered on the tail and its selection outline fits the words.
`Renderer.textSize` measures it and `drawText` draws inside it.

`CalloutLayout` in Core decides where a callout's words go from the arrow alone: the side (left
or right of the tail for a mostly horizontal arrow, above or below for a mostly vertical one,
away from the tip unless there is no room), an `anchor` a quarter of a line out from the tail,
and `origin(for:)`, which hangs a box of any size from that anchor, centered along its near
edge and kept inside the picture. The entry re-asks it after every keystroke. The entry view
is as wide as the wrap width, so lines fold exactly where the renderer's do, and is slid so
the edge its words align to lies on the measured box's edge; the caret sits a hair past the
outline that strokes outside the last glyph.

A callout is one annotation, `.callout(from:to:text:)`, whose `TextBox` is derived state: the
canvas's `relaid(_:from:to:string:)` recomputes it from the arrow whenever the arrow changes.
`HitTest.calloutPart` says which part a point is on (`.text`, `.tail`, `.head`, `.arrow`), and
`dragged(_:by:)` turns a drag into the right edit: the words or the tail's end move the tail,
the head moves the tip, the shaft moves the whole. While its words are being typed the callout
sits in the document with empty text and the `TextEntry` carries its `calloutID`;
`endTextEntry` puts the words back, or turns a wordless callout into a plain `.arrow`.

## Coordinates

Three spaces meet here. `AreaSelection` reports points from the screen's top-left corner, y
down, which is also ScreenCaptureKit's `sourceRect` space for that display. `Document` and
every annotation are in image pixels, top-left origin. `CanvasView` is flipped and holds the
picture in `pictureRect` at `zoom` points per pixel; `imagePoint(_:)`, `viewPoint(_:)`, and
`viewRect(_:)` are the only conversions. `Renderer.draw` expects a flipped context in pixel
space; the canvas sets one up by translating to the picture and scaling by `zoom`, and
`Renderer.image(of:source:)` by flipping a fresh bitmap context. The one wrinkle is the source
bitmap, whose rows are stored top-first: `draw` flips back around the picture for that single
`ctx.draw`, and `drawPixelated` does the same for its block image.

## The app icon

`Support/AppIcon.svg` is the master: a camera in a viewfinder, drawn to look like the menu
bar's `camera.viewfinder` symbol but with our own paths, because the SF Symbols license does
not allow the symbols themselves in app icons. It follows Apple's grid (an 824-point tile with
100 points of margin on a 1024 canvas) and uses gradients but no filters, which AppKit's SVG
renderer ignores. `Scripts/make-app-icon.sh` runs `Scripts/lib/render-app-icon.swift` to
rasterize it at every size with the Dock shadow in the margin and packs `Support/AppIcon.icns`
with iconutil. Rerun it after editing the SVG and commit the `.icns`; `package-app.sh` copies
it into the bundle, where `Info.plist` names it.

## Releasing

`docs/RELEASING.md` covers it. In short: `Scripts/package-app.sh` embeds `Sparkle.framework`
and signs its pieces inner-first (a release build adds a secure timestamp);
`Scripts/release.sh` stamps the version, builds, notarizes and staples, signs the feed with the
keychain key under the account `shotts`, and publishes the GitHub release, undoing itself on
failure; `Scripts/update-cask.sh` opens the Homebrew tap's pull request. The app starts the
updater only when `Info.plist` carries `SUPublicEDKey`; Check for Updates… is in the menu bar
menu and the app menu.

## Developer switches

All are in `AppDelegate.applicationDidFinishLaunching`, and none needs Screen Recording.

| Switch | Does |
| --- | --- |
| `--edit file.png` | Opens a picture in the editor without capturing. |
| `--render in.png out.png [--crop]` | Draws one of every annotation on a picture and writes the PNG, for checking the renderer by eye. |
| `--print-pdf in.png out.pdf [--crop]` | Writes the same sample's print page as a PDF, laid out as Command-P would print it. |
| `--preview-style out.png` | Draws the style popover off screen. |
| `--check-text-entry` | Opens text entry in an unshown window, types into it, commits a callout, and exits non-zero if any of that fails. Run it after touching `TextEntry`. |
| `--select out.txt` | Runs the picker alone over a drawn stand-in for each display and writes `selected x,y,w,h on <display>`, `window <id> at x,y on <display>`, or `cancelled`. |
| `--preview-overlay out.png [--dragged] [--dim] [--corner]` | Draws the picker off screen with the pointer three pixels inside the corner of the stand-in's square at 1600,1600, so the magnifier's mapping can be checked (`--dim` shows only with `--dragged`). |
| `--capture-window <id> out.png [--no-shadow]` | Captures one window through ScreenCaptureKit, with or without the system shadow. |

`swift test` covers Core: selection rules, history, the document, hit testing (arrows included), and callout layout.
The scratchpad `sample.png` used with `--render` is any screenshot; the renders are for eyes,
not for diffing.

## Exercising the editor

From a shell that macOS trusts for Accessibility, `CGEvent` posts reach the editor: launch
`Shotts.app --args --edit sample.png`, find the window's bounds with `CGWindowListCopyWindowInfo`
(owner `Shotts`, layer 0), and post mouse and key events into the picture, which sits centered
in the canvas 28 points below the bar. Never do this while someone is at the keyboard: the
events land in whatever is in front. The headless switches above cover most checks without it.

## Traps

- Screen Recording permission is keyed to the code signature. An ad-hoc-signed build has a new
  signature every time, so each rebuild would ask again and leave another row in System
  Settings. `Scripts/package-app.sh` signs every build with the Developer ID for that reason.
- A menu bar app (`LSUIElement`) is not active when its windows appear, and on macOS 27 the
  plain `NSApp.activate()` is refused for it: the overlay showed but Escape went to the app in
  front (measured with `--select`). `activate(ignoringOtherApps: true)` works and is what
  `AreaSelection.show()`, `EditorWindowController.present()`, and the alerts use.
- `AreaSelection` holds its windows and calls back once; whoever shows one must keep a
  reference to it. The `--select` switch first created one inline, its `[weak self]` callback
  found nothing, and the overlay stayed up with no way to finish.
- Key equivalents in a menu bar app still route through `NSApp.mainMenu`, which such an app has
  to build by hand (`AppDelegate.makeMainMenu`). Without it, Command-Z, Command-W, Command-P,
  and Delete reach nothing. Print reaches the window controller through the responder chain.
- `NSStackView.fittingSize` before layout is not the bar's width; hence `layoutSubtreeIfNeeded()`
  plus the floor of `minimumWidth`.
- `NSResponder` already declares `selectAll(_:)` and `cancelOperation(_:)` (override them) but
  not `delete(_:)` or `undo(_:)` (plain `@objc` actions).
- A subclass of `NSWindow` or `NSTextView` must provide the designated initializer
  (`init(contentRect:styleMask:backing:defer:)`, `init(frame:textContainer:)`): the convenience
  ones call it, and a missing one traps at first use. `OverlayWindow` and `TextEntry` both
  crashed this way; `TextEntry` builds the text system by hand and hands the container in.
- Sizing the text entry view to the measured width of the words folded the last word onto a
  phantom line whenever the zoomed font came out a hair wider than the measurement, leaving
  the caret a line below the words. The view is as wide as the wrap width instead.
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
- `Tool.select` is raw value 0, which is also what an unset default reads as; the remembered
  tool checks for a stored value before trusting the number.
- `sips --cropOffset` takes `y x`, and `0 0` means centered, not the top-left corner.
