# Handoff

How the code works now, why it is built this way, and the traps. `docs/SPEC.md` is what the
product does; `AGENTS.md` is the rule list. The package builds on Apple-silicon macOS 27 with the
Xcode 27 toolchain with no warnings, and `swift test` passes.

## State

The repository is being scaffolded. The first milestone is the daily screenshot workflow: F10,
frozen area selection, an editor with arrow, text, rectangle, ellipse, pen, highlighter, obscure
and crop, undo, and copy, save, and drag out. Window capture, the magnifier, repeat-last-area,
and recording come after it, in that order.

## The seam

`Document` in `ShottsCore` is the seam: the capture's pixel size, a list of `Annotation` values,
and a crop. The editor edits a `Document`; `Renderer` in `ShottsUI` draws one into any
`CGContext`, for the canvas and for export alike. Nothing in Core knows how a document is drawn.

## Capture

Screenshots come from ScreenCaptureKit's `SCScreenshotManager` (macOS 14+; this SDK is 26+),
one image per display at backing resolution, taken the moment the hot key fires. Permission is
checked with `CGPreflightScreenCaptureAccess` and asked for with `CGRequestScreenCaptureAccess`;
macOS records the grant against the app's code signature, which is why local builds are signed
with the Developer ID rather than ad hoc.

## Traps

- Screen Recording permission is keyed to the code signature. An ad-hoc-signed build has a new
  signature every time, so each rebuild would ask again and leave another row in System Settings.
  `Scripts/package-app.sh` signs every build with the Developer ID for that reason.
- A menu bar app (`LSUIElement`) is not active when its windows appear. The editor must
  `NSApp.activate` itself, and remember the app that was frontmost before, to hand focus back.
