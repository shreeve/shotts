# Handoff

How the code works, why it is built this way, and the traps. `docs/SPEC.md` is what the product
does, `AGENTS.md` the rules, `docs/RELEASING.md` how a release is made.

## State

0.9.2 is the latest release: tag `v0.9.2` on `main`, the GitHub release with its notarized zip
and signed `appcast.xml`, and the Homebrew cask (shreeve/homebrew-tap#148), which also links
`shotts`; installed copies are offered each release through Sparkle. `CHANGELOG.md` has every
release, and its Unreleased section the third revamp, merged into `main` as shreeve/shotts#71
(c9f1c3b) and not yet released. The build
has no warnings (warnings are errors) and `swift test` passes: 157 Core tests and 129 AppKit
tests. Shotts has only ever run on macOS 27.

Tried by hand on a real screen: capture, the editor and its tools, copy, save, drag, print;
recording from the picker with the microphone and with Keys; the Option-drag scrolling capture
of a Google Drive list, auto-scrolled; `shotts` `list`, stills of a window, a display, and a
region in each format with `--width` and `--delay`, recordings of a window and a region with
each sound, and a second Control-C while saving.

Next, in order:

1. Before the next release, by hand ("Checking by hand" has how), on a Retina and a non-Retina
   display:
   - a release package (`CONFIG=release Scripts/package-app.sh`) launches and captures,
     records, and scrolls: it is linked with `-internalize-at-link` and fully stripped;
   - a debug package is its own app (`com.github.shreeve.shotts.debug`) and asks for Screen
     Recording on its first capture;
   - capture and record the whole display, Command-click a window, record with Clicks and with
     Keys (turning Keys on asks for Input Monitoring; a password field shows nothing; ⌥L on a
     German layout shows nothing), and draw during a whole-display recording;
   - quitting: with an annotated capture, an unsaved recording, a recording whose Save is still
     copying, and during a scrolling capture; a log-out cancelled by another app leaves the
     next ⌘Q asking; F10 and ⇧⌘2 do nothing while a Shotts alert is open;
   - scrolling capture: which way the steps scroll under natural scrolling, overlay scroll bars
     in the picture, the pointer put back where it was, and a page with a spinner in its footer;
   - the calibration tone plays on a device's first recording with the Mac's sound and not the
     next;
   - `shotts` `start`/`stop`, F10 and the timer stopping a scripted recording, F10 doing nothing
     while `shotts` counts down, Install Command-Line Tool, and Start at Login (log out and in;
     Login Items agrees with the checkmark);
   - a Sparkle update from 0.5.0 or later (0.5.0 is the first to ship Sparkle thinned to arm64).
2. Check a release on macOS 14, 15, and 26, in virtual machines (UTM runs them on Apple
   silicon). The target is macOS 14, where ScreenCaptureKit gained what Shotts uses (the one-shot
   window capture, `captureResolution`, and the shadow switches); it builds and tests there but
   has only run on 27. Watch the editor and Option-F10 coming to the front (the first Trap), the
   picker taking keys and clicks while another app stays in front, the live screen under the
   picker, the Screen Recording prompts, and recordings' color labels (none on macOS 14).
3. Deferred work, below.

Decided against, so they are not rebuilt:

- Reversing an arrow's direction (CleanShot's "inverse arrow"). The direction is chosen while
  drawing, tail where the press starts and head where it ends, and either end of a drawn arrow
  drags anywhere; an arrow with text keeps its words at the tail, so flipping one would strand
  them or have to move them. Nothing it would do is not already a drag away.
- A background tool (CleanShot's padding, backdrop presets, and auto balance): decoration for
  posting screenshots, not capture. Shotts stays a small capture utility; Include Window Shadow
  is the one finish it adds, and layout tools exist for the rest.

- A self-timer in the picker (the Screenshot app's 5 and 10 seconds). The owner: fluff; `shotts
  --delay` has one for scripts, and the rest is CleanShot's.
- Bringing back more than one closed capture with Option-F10. With New Window per Capture off
  there is one capture window, each capture replaces it, and Option-F10 brings back the one
  before; a list of closed captures would make that one window a stack.

- Wrapping plain text at the picture's edge. The user breaks lines with Return; text that
  wrapped on its own would either keep its line breaks when moved (a stranded narrow column) or
  reflow as it moves, and both are worse than lines that only change when the user says so.

Deferred, with the reason each waits:

- Allow Command-Line Capture is a preference, so any program the user runs can turn it on with
  `defaults write` and then capture through Shotts' grants; launch arguments cannot (it is read
  from Shotts' own saved settings only). The owner keeps it so (2026-10-11): it guards against
  accidents, as SPEC says, and asking once per launch was declined.
- Configurable shortcuts: not for now, the owner says. F10 and ⇧⌘2 both work, with no setting:
  F10 for a top row of F-keys (fn-F10 otherwise), ⇧⌘2 on any keyboard. 0.9.1's ⇧⌘4 needed
  macOS's own turned off first (both answer a key two apps hold, so Shotts deferred to it), too
  much to ask; ⇧⌘6 was too far for the left hand; ⇧⌘2 is no macOS shortcut, at the cost of
  taking it from apps that use it (Xcode's Devices and Simulators).
  The Mission Control key (F3 without fn on a stock keyboard) was tried and cannot be had: a
  Carbon hot key on its key code (160) registers but never fires, macOS keeping it. A red dot
  for a key another app holds was asked for with shortcut work, but cannot be told reliably:
  macOS lets two apps register one key (both answer it), and even an exclusive registration
  succeeds while another app holds the key shared; registration fails only against one held
  exclusively, and then only Capture Area's title says so.
- The picker redraws its whole transparent overlay on each mouse move (the crosshair spans the
  display). Drawing the crosshair as two thin layers would leave only the magnifier to redraw.
- Selecting an annotation does not show its style in the bar. Changing a style changes only what
  changed (`Style.applying(from:to:)`), so nothing is lost, but the bar does not tell you the
  selection's width or font.
- VoiceOver sees the canvas as one image; annotations are not accessibility elements.
- If one display fails to picture, the whole capture fails rather than leaving that display out.
- Crash recovery: a recording's movie is written in fragments, so a crash leaves it playable, but
  the next launch removes it as a leftover instead of offering it back.
- Pausing a recording drops samples but leaves the stream running (and the GPU busy) until it
  resumes; stopping and restarting the stream would need its own frame-continuity handling.
- Decisions in the app target have no tests, as no test target reaches it: which editor a
  capture replaces, what Option-F10 brings back, focus return (an `EditorStack` in ShottsUI
  would host them), and `shotts`' recording lifecycle in `ScriptRunner` (stop and abort before
  and after the first frame, hang-up, `last`, the `start` cap).
- Scrolling capture: on a nearly blank area, a changing spinner reads as small moves (the
  stitcher grows the picture with copies of it and never sees the bottom); deciding between
  still and a move from the rows that changed alone would fix it. Overlay scroll bars are taken with the rows (a dev check with a visible
  scroller would show it), and `CGAssociateMouseAndMouseCursorPosition` is documented to work
  only for the app in front, which Shotts is not while it scrolls; the tap's warp holds the
  pointer either way. Both need a spare screen.
- A display rearranged during a recording leaves the outline and bar where they were; files a
  recording window made for earlier settings stay until it closes; clicks in Shotts' own windows
  show no ripple (a global monitor never sees them).
- `shotts` walks the whole window list for every request and encodes stills on the main actor;
  a Shotts that runs but does not listen makes the tool wait its full timeout; alerts give no
  focus back after Cancel; Option-F10 reopens on the main display.
- Some diagnostics (concurrency checks in `ShottsCLI/main.swift`'s top level) print without
  failing the build despite `treatAllWarnings(as: .error)`: read the build's output, not only
  its status.
- Revamp audits' deferred rows (Sparkle feed signing, text/TextBox overlap in `Annotation`,
  one-pass GIF export) are summarized here; the full tables lived outside the repository.
- Not built: see SPEC.

## Map

| Target | File | Holds |
| --- | --- | --- |
| ShottsCore | `Document.swift` | The seam: pixel size, scale, annotations, crop; `visibleRect` is what exports. |
| | `Annotation.swift` | `Annotation.Shape` (arrow, callout, line, rectangle, ellipse, text, pen, highlighter, obscure), bounds, translation, `dragged(_:by:)` (what a drag on each part moves), degeneracy. |
| | `Style.swift` | `Style` (color, stroke width, font size, font, shadow, outline, tapered arrows), its pixel metrics, `applying(from:to:)`, and decoding that tolerates older and newer saved styles. `FontChoice`: Rounded, System, Open Sans. |
| | `Arrow.swift` | `ArrowGeometry`: an arrow as one filled outline, and its head length. |
| | `Callout.swift` | `CalloutLayout`: where a callout's words go, from the arrow alone. |
| | `HitTest.swift` | Which annotation a point lands on, and which part of an arrow or callout. |
| | `History.swift` | Undo and redo over any `Equatable` state, with `record(since:)` for changes made in place. |
| | `Selection.swift` | `SelectionRule`: the drag rectangle rules the picker and the shape tools share. |
| | `AppLocation.swift` | Whether to offer moving the app to Applications, and to which one. |
| | `EditorLayout.swift` | The editor's sizing rules: the zoom for a window, the window for a zoom. |
| | `Recording.swift` | `RecordingSettings` (format, size, frame rate, sound, trim), `Trim`, `TimelineLayout`, `PauseClock`, `RecordingTimeline` (where each recorded sample goes), `RecordingRule` (sizes, rates, the H.264 limit, defaults, bit rate), `FrameSampler` (which frames a rate keeps), the clock text. |
| | `SystemShortcuts.swift` | Whether macOS answers a key itself, from its Keyboard Shortcuts list (an entry missing is at its default): ⇧⌘2 is Shotts' unless a macOS shortcut is set to it. |
| | `Quitting.swift` | What Quit does (`reply`: quit now, stop what is under way, or ask) and the question it asks about what would be lost. |
| | `AutoScroll.swift` | How Shotts paces its scrolling: waiting for the first frame, the step and its recovery, backing up and slowing when a frame is not matched, giving up, the bottom as where the picture stops growing, the other direction tried once, the 30 s limit. |
| | `ScrollStitcher.swift` | A scrolling capture's picture from its frames, in one buffer reserved at the cap and handed to the image uncopied: row fingerprints, the shift that fits, bands decided at the first move, new rows added and taken again until they scroll up. |
| | `Keystrokes.swift` | `KeystrokeLine`: which keys show (shortcuts and keys that act on their own, never typing) and as what (⇧⌘4, ↩), and how those within two seconds join one line (`⌘I  ⌃K  ↩`) that stays five seconds after the last. |
| | `Script.swift` | The command line's language: `ScriptParser` (arguments, times, what each command takes), `ScriptRequest` and `ScriptResult` (the JSON lines), `WindowMatch`, `ScriptAim` (what a target comes to), the error codes and exit codes, the socket's path. |
| | `TextTable.swift` | How `shotts` prints a table: boxed with a title tab and color on a terminal, plain columns for a pipe, widths in terminal columns (wide characters count two). |
| | `GIF.swift` | The GIF encoder: `BlueNoise` (void-and-cluster), `PaletteBuilder` (exact prominent colors, median cut for the rest), `Quantizer` (blue-noise dithering), `GIFWriter` (GIF89a, changed rectangles only), `GIFTiming`, `LZW`. |
| ShottsUI | `AreaSelection.swift` | The picker: `DisplayImage` (a display's latest picture, its windows, and `cut`), one overlay window per display, the crosshair, magnifier, hints, window outlines, `PixelSampler`. |
| | `EditorWindow.swift` | `EditorWindowController`: the bar, copy, save, print, closing, resizing, the drag grip, remembered tool and style. |
| | `CanvasView.swift` | The picture with its annotations, every tool's mouse handling, text entry (`TextEntry`), selection drawing. |
| | `Renderer.swift` | Draws a `Document` into any `CGContext`; measures text; an annotation's extent. |
| | `StylePopover.swift` | The color and style popover. |
| | `Export.swift` | The one encoder (PNG and TIFF at the capture's resolution), the pasteboard, a file, the drag file, one-file temporary folders. |
| | `Front.swift` | The one way Shotts comes to the front, and the one way it hands focus back. |
| | `RecordingSetup.swift` | The red outline around an area being recorded, and the panel beside it: Record, Microphone, Clicks, Keys, and Cancel, then the recording bar (Arrow, Rectangle, Pause, Stop). |
| | `ScrollSetup.swift` | A scrolling capture's blue outline and its panel: where it stands, the height so far, Done, and Cancel. |
| | `DrawingLayer.swift` | The clear, recorded window over the area that takes arrows and rectangles while recording and fades each out, and shows click ripples and the keys pressed (`KeysBadge`). |
| | `Timeline.swift` | The recording window's timeline: play, the playhead, and the trim brackets. |
| | `RecordingWindow.swift` | `RecordingWindowController`: the player, the export settings, the file made in the background, Copy, Save, the drag grip, the question before deleting a recording that went nowhere, and deleting it all once the last Copy or Save is done. |
| | `RecordingExport.swift` | `Recording` (the kept files) and `RecordingExport`: MP4 and GIF files from it, off the main thread. |
| | `ScriptServer.swift` | The socket `shotts` talks to, on Dispatch: the user's own folder, the peer's uid, a request line in (with a deadline), result lines out without blocking, and a tool hanging up first. |
| | `ScriptFiles.swift` | Where `shotts`' files go when none are named (never over another), stills written at a width, and every file made in a private folder on its place's volume and moved there once all are made. |
| Shotts | `ShottsApp.swift` | `AppDelegate`: menu bar item and menu, main menu, the hot keys and whether macOS answers ⇧⌘2 itself, quitting, Start at Login, Install Command-Line Tool, Sparkle. |
| | `CaptureFlow.swift` | One capture from hot key to editor, a recording and a scrolling capture from setup to window, whether Shotts is busy, what quitting would lose, which app gets focus back, and the capture closed last. |
| | `ScreenCapture.swift` | Screen Recording permission and its one prompt, a clicked window through ScreenCaptureKit, and the window list; for `shotts`, the numbered displays, the windows it lists, and an area of a display. |
| | `ScriptRunner.swift` | What `shotts` asks, done: list, shot, and a recording from its request to its files, the countdown, Allow Command-Line Capture. |
| | `LiveDisplay.swift` | A display streamed while the picker is up: its latest frame and windows. |
| | `AutoScroller.swift` | Scrolls a scrolling capture's area, with Accessibility, in steps `AutoScroll` paces, and says when it reaches the bottom or gives up. |
| | `ScrollCapture.swift` | Streams the area for a scrolling capture, in the display's colors, and feeds each frame to `ScrollStitcher` off the main thread; started and stopped on the main actor. |
| | `InputWatcher.swift` | Clicks (a global mouse monitor) and keys (a listen-only event tap, needing Input Monitoring) while a recording that shows them runs. |
| | `Recorder.swift` | Records an area through ScreenCaptureKit, the Mac's sound with it, and the microphone through AVFoundation. |
| | `SoundCalibrator.swift` | Measures how much quieter macOS hands over the Mac's sound on the current output device, with a tone too quiet to hear, once per device. |
| | `HotKey.swift` | Registers a Carbon hot key and runs its action: F10 and ⇧⌘2, each with Option, from `ShottsApp`. |
| | `MoveToApplications.swift` | A release launched outside Applications offers to move itself there. |
| | `DevSwitches.swift` | The developer switches, compiled into debug builds only. |
| ShottsCLI | `main.swift` | `shotts`: parses, checks, connects (starting the Shotts it is inside with `open -g` when nothing listens), prints, exits with the answer's code, and turns Control-C into `stop`, then `abort`. |

Start at Login is not in the defaults: macOS keeps it (`SMAppService.mainApp`, shown in System
Settings › General › Login Items, where the user can turn it off too), and the menu's checkmark
reads it each time the menu opens.

Settings live in the defaults: the picker options under `selection.*`, `capture.copies`, and
`export.shadow` (`SelectionOptions.current`, defaults registered in one place);
`capture.askedPermission` once the system's permission prompt has been shown, `commandLine.allowed` (Allow Command-Line Capture, read from Shotts' own saved settings only), `recording.soundCalibration` (each output device's measured sound loss and when), `editor.newWindows`,
`recording.microphone`, `recording.clicks`, `recording.keys`, `recording.askedInputMonitoring` (macOS's own Input Monitoring dialog shown), `scroll.askedAccessibility` (its Accessibility dialog shown for scrolling), `app.skipMoveToApplications` ("Don't ask again" on the move offer); the
editor's last style as JSON under `editor.style` and its last drawing tool under `editor.tool`.

## The seam

`Document` in Core is the one thing the editor edits and the renderer draws. `Renderer` in UI
draws it into any `CGContext`, for the canvas and for export alike, so what the user sees is
what they paste; nothing in Core knows how a document is drawn. Undo is a `History<Document>`
of annotation edits; the source pixels are never copied.

`Style` lengths are points. `Style.stroke(scale:)`, `highlighterWidth(scale:)`, and
`arrow(from:to:scale:)` turn them into pixels at the document's scale, and both the renderer and
`HitTest` use them, so an annotation is hit where it is drawn: measured in points, a hit would
miss Retina barbs and highlighter bands.

## Capture

`CaptureFlow` runs one capture at a time: a `Capture` value holds the app to return to, the
picker, and the live displays, from `begin()` until the editor opens or the capture ends, and F10
does nothing meanwhile. The picker is live: `AreaSelection` shows at once, one clear non-activating
panel per display at `.screenSaver` level with a blank cursor, over whatever app is in front,
which stays in front, and the real screen goes on updating through it. Behind it, each `LiveDisplay` streams its display through an `SCStream`
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
The picker cancels when another app becomes active or the screen configuration changes. The magnifier
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

## Recording

Pressing Command during a drag turns the selection red ("Record"), and letting go of the drag
then reports `.record` rather than `.selected` (`OverlayView.released(at:recording:)`). Each
Command press flips it; letting go of Command does not, since Command and the mouse let go
together often send Command's release first. `CaptureFlow` stops the picker's streams and shows a `RecordingSetup`: a red
outline window just outside the area and a non-activating panel beside it, like the picker's,
so nothing on screen moves. Record (Return) asks for the microphone if it is on and not yet
allowed, then starts a `Recorder`; the panel becomes the recording bar and the outline stays. F10
while recording, the bar's Stop, or the menu bar item, which shows a red dot and the time
(`AppDelegate.showRecording`), stops it.

The bar's Arrow and Rectangle turn on a tool in the `DrawingLayer`, a clear non-activating panel
exactly over the area that lets every click through until a tool is on. Shapes are ordinary
`Annotation`s in the area's pixels, in the editor's remembered style, drawn by `Renderer` at a
zoom of one over the display's scale; each is opaque for four seconds and fades over one, a
timer redrawing only while any are showing. The recorder leaves out Shotts' windows above layer
0 but keeps the layer (`keptNumbers`), so what is drawn is recorded. Pause and resume go to
`Recorder`, which asks Core's `RecordingTimeline` where each sample goes: samples from within a
pause are dropped, later ones move back by the time paused, the last frame that came while
paused is written at the resume (an unchanging screen sends no new one), and a frame the
encoder was not ready for is offered again with the next sample and at the stop rather than
lost; a frame from a pause already over is dropped. Quitting while recording stops it and opens
its window (Core's `Quitting.reply`), unless the quit is a log-out, restart, or shut-down (the
quit Apple event's `kAEQuitReason`), which is never held up. Stopping stops the stream first and
then takes the outline, bar, and drawing layer down, so the file ends on the area as it was.

`Recorder` streams the area with `SCStreamConfiguration.sourceRect` at full pixels, 4:2:0
(`420v`, captured as sRGB: BT.709 primaries and matrix with the sRGB curve, which `VideoColor`
labels the files with on macOS 15 and later; on 14 they carry the frames' own attachments), up to 60 frames a second, with the pointer and `capturesAudio` (the Mac's own
sound, Shotts' excluded). Only `.complete` frames are written: an idle stream sends frames with
no picture, and the frame before goes on showing. The filter leaves out the outline, the panel,
and every other Shotts window above layer 0 (the menu bar item among them), but keeps the
drawing layer. Everything is retimed to the first
frame, which starts both writers' sessions; the stop time ends them, so the last frame lasts
until then. The movie is HEVC at quality 0.9, a key frame at least every 2 s, with the Mac's
sound as AAC; the microphone (`AVCaptureSession`, resampled to 48 kHz mono, its clock converted
to the host's) goes to its own `Microphone.m4a`, so the window can offer either sound, both, or
none. Both are written in 10 s fragments: a movie whose writer fails at the stop (a full disk)
is kept with what it holds, and a microphone file that fails is dropped and the recording kept. All of it is in one folder under `Recording.parentFolder`,
removed when the window closes. Each folder holds a lock on a file in it (`.in-use`) while it
is in use; at launch `Recording.removeLeftovers` removes only the folders no running Shotts
holds, which a crash leaves.

The window's `Timeline` replaces the player's own controls: play (Space), a playhead, and trim
brackets whose `TimelineLayout` (Core) maps points to times and picks the handle a press takes.
A trim is part of every format's settings once the drag ends, and `RecordingExport` builds its
composition from just that part, so the first frame is the one showing at the trim's start.

`RecordingWindowController` keeps settings per format and, 250 ms after any change, makes the
file for them in a folder of its own (`RecordingExport.write`), so a file still being made for
earlier settings never meets it; files made earlier stay until the window closes, so one already
copied still pastes. Copy puts a copy of the file outside the recording's folder (one at a time,
in `Shotts Copied`) on the pasteboard, so it pastes after the window closes; Save copies it off
the main thread beside its destination and moves it into place, so a file under the user's
name is always whole; the grip drags it. A Copy or Save counts as `pending` from the moment it
is chosen: closing the window then neither asks nor cancels the file it waits on, and the last
to finish removes the folder (`closedWhileBusy` counts such windows for Quit). Until a
recording has been saved, copied, or dragged out (`kept`), closing asks "Delete this
recording?" first. `RecordingExport` reads the movie back with `AVAssetReader` through an `AVMutableComposition`,
keeps the frames `FrameSampler` picks (the latest frame at each tick of the rate, so the last
change before a pause is never lost), and scales them with `VTPixelTransferSession`, averaging
as it shrinks. MP4: H.264 High, labeled as `VideoColor` says, one AAC track mixed by
`AVAssetReaderAudioMixOutput` from the sounds chosen, `shouldOptimizeForNetworkUse` for the index
first; video and sound are pumped in turn, since the writer wants them interleaved. GIF: two
passes, the first gathering the clip's colors into one `PaletteBuilder`, the second writing
frames with `GIFWriter`, streamed to the file.

The GIF encoder is Shotts' own, in Core. Prominent colors (1 in 500 samples or more, up to half
the palette) are kept exactly and never dithered; median cut over 5-bit bins picks the rest, 255
at most, leaving one index for "unchanged". A color not in the palette is drawn as a blue-noise
mix of the palette color nearest it and the one nearest its reflection past that color, in
proportion; the 64 by 64 threshold map is made once by void-and-cluster. Being fixed per pixel,
the dithering leaves still areas identical from frame to frame, so each frame after the first
stores only the rectangle whose indices changed, with the unchanged inside it transparent, and a
frame that changes nothing only lengthens the one before. Delays are whole hundredths measured
between rounded times, so they never drift.

## Command line

`shotts` (ShottsCLI, on Core alone, shipped as `Contents/Helpers/shotts`) parses its arguments
into a `ScriptRequest` and sends it as one JSON line to `~/Library/Caches/com.github.shreeve.shotts/cli.sock`;
Shotts answers with `ScriptResult` lines and closes. Every decision (the parse, the window
match, what a target comes to, the codes) is in Core's `Script.swift`, with tests; the tool and
`ScriptRunner` only move bytes and capture.

- **Who may ask.** `ScriptServer` makes the folder 0700 (closing it again if opened up) and
  refuses one that is another user's or a link, makes the socket 0600, and drops a peer whose
  `getpeereid` uid is not its own. It always listens, so that with Allow Command-Line Capture off
  it can answer `not_allowed` at once; `stop` and `abort` are taken even then, as they only end
  a recording already running. The switch is read from Shotts' own saved settings, never the
  launch arguments `UserDefaults.standard` also searches. Every request is checked again in
  Shotts (`ScriptParser.check`, with bounds), since any program of the user's can send one. A
  second Shotts finds the socket answering and leaves it to the first.
- **The server.** Each socket is waited on by a Dispatch source and closed in that source's
  cancel handler, so nothing waits on a number once it is reused (Traps). Each connection reads
  its request line within 10 s and writes from a queue of its own without ever blocking: a tool
  that stops reading keeps only the newest progress line waiting and gets 5 s to take the final
  answer.
- **The connection is the recording's life.** `record` keeps its connection until the files are
  made; when the tool goes first (Control-C sends `stop` on a new connection, but a closed
  terminal just goes), `onClose` ends the recording and keeps the files. `start` is answered
  once recording and closed by Shotts, which `onClose` does not count as hanging up. A second
  Control-C sends `abort`. `stop` with nothing recording gives `last`, the latest answer.
- **Recording.** A window target is `Recorder.start(window:)`, a `desktopIndependentWindow`
  filter that follows the window and scales a grown one to fit; anything else is the area
  recorder with no exclusions but Shotts' own above-normal windows. Sound only with `--audio`:
  the recorder takes the Mac's sound (`sound`) and the microphone as the picker's recordings do,
  and only an MP4 gets it. A window's filter gives only its app's sound (checked: a chime from
  `afplay` is in a display's recording and not in a window's). The microphone's permission is
  asked before the countdown, and refused, it is a `permission` failure, never an alert. The
  "recording" answer waits for the first frame (`firstFrame(within:)`, five seconds: a minimized
  window sends none). The menu bar timer shows it, and F10, the timer, and quitting stop it
  through `AppDelegate`, which asks `ScriptRunner` before `CaptureFlow`. F10 and `shotts` wait for
  each other: while a request is under way (`ScriptRunner.isBusy`, from its countdown until its
  files are placed), F10 stops its recording or its countdown and otherwise beeps, and Option-F10
  does nothing; `shotts` answers `busy` while F10 has a picker,
  recording, scrolling capture, or alert up (`CaptureFlow.isBusyHere`).
- **The tool's threads.** Everything in `main.swift` happens on the main queue: Control-C
  arrives there, and each line read from Shotts is handed there. The main thread runs its run
  loop rather than `dispatchMain()`, which parks the main thread and drains the main queue on
  another, where the main actor's runtime checks stop the tool. Debug builds of the tool take
  `SHOTTS_SOCKET` to talk to a stand-in Shotts (a few lines of Python on a Unix socket, which
  must answer each connection on its own, as Shotts does), so its output and Control-C
  can be checked without the screen; `HOME` does not move `NSHomeDirectory()`.
- **Sound level.** ScreenCaptureKit hands over the Mac's sound quieter than it played, by an
  amount fixed per output device and whatever the volume (12 dB through a Studio Display; none
  from MacBook speakers; Apple's forums, since macOS 14.2). `SoundCalibrator` runs beside a
  recording with system sound when the output device has no measurement under 30 days old, so
  most recordings play no tone: it plays a 200 Hz tone at -60 dB, waits until it has been played
  back (three seconds at most), and captures the display's sound
  with every listed app left out, since ScreenCaptureKit lists every app but the one asking and
  so cannot pick Shotts. Background processes (`afplay`, say) are not apps and stay in, so Core's
  `SoundCalibration.level` measures at the tone's pitch alone and believes only four steady
  windows, and no loss over 20 dB; a spoiled reading falls back to the device's saved one
  (`recording.soundCalibration`, by device UID, with when it was measured). The gain rides on `Recording.systemGain` and is
  applied when a file is made: the mix turns the microphone down by it and the whole up by it,
  clamped at full scale, which leaves the microphone as it was. The recording, and so the
  window's player, keeps the level as captured. Checked on a real screen: a chime and a tone
  came out within 0.2 dB of their files.
- **Saving.** Once stopped, a recording sends "saving" lines (the file being made, and how far
  through them all) to the tool and to anyone waiting in `stop`; `abort` then cancels the export,
  and as files are placed only once all are made, what was at each path stays as it was. A GIF without `--width` starts at the recording window's
  size (`RecordingRule.defaults`): on screen, not full Retina.
- **Files.** `RecordingExport.write` with `RecordingSettings.width` (never wider than the
  recording), returning size and frame count; stills scaled by `ScriptRequest.stillSize` and
  encoded by `Export.encode`, so they carry the capture's resolution. Each is made in a private,
  randomly named folder on its place's volume (macOS's item-replacement folder in the user's
  private temporary folder, which macOS clears; or `.shotts-…` beside the place, 0700, should
  that fail), where nothing planted can redirect the write, and moved into place once every file
  is made. A path the user named replaces what
  is there; a default name never does, but takes " 2", " 3"… as the Finder numbers. The
  recording's folder goes once they are made, as a closed window's does.

## Scrolling capture

Option is to scrolling what Command is to recording: each press during a drag flips the
selection blue ("■ Scroll") or back, letting go of it changes nothing, and turning either on
turns the other off; a drag released blue is `AreaSelection.Outcome.scroll`, and a click is as
ever. `CaptureFlow.setUpScroll` puts up `ScrollSetup` (the blue outline and a panel with Done
and Cancel, left out of the capture) and starts `ScrollCapture` at once, which streams the area
at up to 60 frames a second, BGRA, in the display's colors, without the pointer, handing each
frame to Core's `ScrollStitcher` on a queue of its own. The stream is started and stopped on the
main actor, and a Done or Escape while it starts stops it once started. Done, Return, or F10
stops it and opens the picture in an editor as any capture; Escape cancels; quitting ends it as
Done; a display change ends it as Done too, unless the area's display is still there unmoved.

With Accessibility, Shotts scrolls (`AutoScroller`, paced by Core's `AutoScroll`). Nothing is
posted until the first frame has come, and with none in 2 s it gives up. Then scroll-wheel steps
in points, a sixth of the area up to 120, twenty times a second, go with `CGEvent.post` to what
is under the pointer, put in the middle of the area. Until it stops, the mouse is held, since a
nudge of it would send the steps elsewhere: `CGAssociateMouseAndMouseCursorPosition(0)` keeps
the pointer put, and an active session event tap, which Accessibility allows, drops every mouse
move, click, and scroll but Shotts' own steps (marked in `eventSourceUserData`), warping the
pointer back should it have moved all the same. When scrolling stops, however it stops, the
mouse is let go and the pointer put back where it was; macOS turning the tap off for the user
(`tapDisabledByUserInput`) stops it too, and `AutoScroll.limit` (30 s) ends it with what it has,
so the mouse is never held longer. The bottom, where the picture has not grown for 0.8 s, opens
the picture. A frame not matched backs it up a step and halves the step (a miss right after a
back-up, from frames already in flight, is not counted); each step that adds rows speeds it up
by a quarter, back to the first step; five misses in a row with nothing added give up and leave
the user to scroll, as an area that does not all scroll together never matches; nothing new at
all tries the other direction once. An area under 24 points tall gives up at once. Without
Accessibility, macOS's own dialog asks once (`scroll.askedAccessibility`) and the user scrolls.

The stitcher reduces each row to 64 block brightnesses and finds the shift that best lines the
frame's middle up with the last frame's: every fourth shift over every other row, then every
shift within four of the one chosen. Among coarse shifts within half a level of the best it
takes the one nearest the last move, since lists of rows alike fit at several. Rows within a
level count as the same, a shift is believed below three levels, and it must keep a quarter of
the middle overlapping. A frame is still only when every row is alike; otherwise no move is one
more candidate, so a few lines moving over a blank page still count as a move. At the first
nonzero shift that fits, the rows that stayed put at the top and bottom (a third of the frame at
most) become bands, or, if strict bands leave no shift that fits, the rows that mostly stayed:
a spinner or a status line in a sticky bar changing before the first move does not cut the bar
short. The top band is kept from the frame before the first move, the bottom from the last frame to reach the
picture's end (not simply the last, which may have backed up), the middle stitched between. The
bottom band is at least a twelfth of the frame: a window's rounded corners sit in its last rows
over moving content. The last third of the middle is not final: each frame showing it, moved or
not, takes it again, and only rows that have scrolled above it stay as taken, since a browser
leaves rows blank for a moment where they come into view when scrolling fast. A third keeps the
retaking below the middle of the area, where the pointer rests and a row under it may be
highlighted. A band taken wrongly (a blank margin) costs nothing, since what passes under it is
still taken in the middle.

The picture lives in one buffer reserved at the cap (256 MB, some 20,000 rows of a wide window),
[top][middle][bottom] written in place, untouched pages costing nothing; no frame is copied once
the bands are known, and once full no frame is read. The buffer becomes the `CGImage` through a
`CGDataProvider` that frees it, uncopied. Optimized, a 3000 by 1600 frame stitches in about
5 ms, and a capture at the cap peaks near the picture's own size (291 MB) and hands it over in
about 5 ms. `--scroll-test out.png` (debug) scrolls a window of 300 numbered lines in code
through the real capture and writes the picture beside the document drawn directly (build Core
optimized for it: a debug build falls behind). It is tested on generated pages: uneven scrolls, a
still frame, scrolling back up, a jump too far then recovered, noise, a blinking cursor, padded
rows, the cap, the handover, a bar that changes before or at the first move, a sparse page, a
first move too far to match, and a list of rows alike with rows drawn late, a last frame backed
up, and random speeds; real apps need trying by hand.

## The editor

`EditorWindowController` builds its bar by hand: a segmented control of `Tool`s (single-key
shortcuts, the last drawing tool remembered), the color swatch that opens the window's one
`StylePopover`, popups for stroke width, text size, and font, undo and redo, the drag grip, and
Copy and Save. The editor is an ordinary window: copy, save, drag out, and print leave it open
(print brings it back to the front after the Print window), and Command-W, the red button, or
Escape with nothing left to cancel closes it with no question. Closing first keeps the words
being typed and puts back a drag in progress. `CaptureFlow` keeps the document and picture of
the editor closed last, and Option-F10 (`showLast`) brings the newest open editor forward or
opens that one again; it is the only capture kept after its editor closes. Unless New Window per
Capture is on (`editor.newWindows`), a new capture's editor takes the place of the open editor
in front (else the newest one) at its top-left corner, and the one replaced becomes that kept
capture, closed without handing focus back.

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
during a move restores `base`. A drawing tool pressed on an annotation selects it instead of
drawing (`Tool.selects`: not the pen, highlighter, or crop, and an obscured area only for
Obscure), and the text tool edits the text or callout words it clicks. Space during a drag
moves the shape being drawn (its anchor follows the pointer). The arrow keys nudge the
selection (`nudge`), a pixel at a time or ten with Shift, one undo step each; while typing they
are the text view's. In the picker they move the crosshair (`SelectionRule.nudged`) and warp
the real pointer to match (`OverlayView.warp`, replaced in tests). Arrows and callouts show a dot at
each end; everything else a dashed box. While dragging, only the extent of what moved is redrawn
(`Renderer.extent`, converted to the view); a crop dims the whole picture and redraws it all.

Changing the style (the bar or the popover) applies only what changed: to the words being typed
if there are any, else to the selected annotation, whose text is measured again and a callout's
words laid out again.

## Text and callouts

Text is typed on the picture: `CanvasView.beginTextEntry` adds an invisible `TextEntry` (an
`NSTextView` with clear text and a colored caret) whose `preview` the canvas draws through the
renderer, so what is typed looks exactly like the export. A click with the text tool stands the
caret on the pixel clicked (`Renderer.textOrigin(caretFoot:)`): the words' left edge there and
the bottom of their first line, so the text goes above the click, not below it as when the click
was the box's top-left corner. The entry has its own undo manager, so
Command-Z while typing undoes keystrokes and nothing outlives it. Command-Return finishes (a
Return pressed out of habit only adds a line), Return with or without Shift or Option breaks a
line, and Escape cancels, restoring `base`: new words go, a new callout goes with its arrow, and
edited words come back. An input method composing gets every key. Closing the window keeps the
words. A text shape's `size` is its layout box, which hugs the words, with the outline's room on
every side: a callout's words wrap at `CalloutLayout.width` but the box is only as wide as the
widest line, so it can be centered on the tail and its selection outline fits the words.
`Renderer.textSize` measures it and `drawText` draws inside it.

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
`HitTest.arrowPart` says which part of an arrow, callout, or line a point is on (`.text`,
`.tail`, `.head`, `.shaft`; the tail grip and head each at most a third of the arrow), and
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

Text is bold Rounded (the default), System, or Open Sans. The first two every Mac has; a style
remembered with a font Shotts no longer offers (Trebuchet) comes back Rounded. Open Sans, Droid Sans redrawn by its own designer, is bundled: `Support/Fonts` holds
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

`docs/RELEASING.md`. Sparkle always starts, but for a developer switch in a debug build, and `SUEnableAutomaticChecks` makes it check daily
without asking; Check for Updates… is in the menu bar menu and the app menu.

## Tests

`swift test` runs two targets. `Tests/Core` covers Core: selection rules, history, the document,
hit testing at scale 1 and 2, arrow parts and drags, styles, callout layout, the editor's
layout, the recording rules, the GIF encoder (read back by a GIF decoder of the tests' own),
the command line's language (parsing, checks, window matching, aim, listing, help, tables),
the scroll stitcher and auto-scroll pacing, keystrokes, sound calibration, macOS's shortcuts,
and quitting. `Tests/UI` drives AppKit in windows that are never shown: the editor's gestures, undo,
typing, restyling, closing, and resizing; the renderer (extent, text box, canvas against export);
export (resolution, color space, obscure, the background copy, file names, the drag file); and
the picker (the cut, the pointer per display, clipping, cancelling, Command-release); and
recording (the setup panel, the window's settings and files, and MP4 and GIF export from a
recording the tests write themselves, with no screen); the scrolling panel; the drawing layer,
ripples, and keys plate. `ScriptServerTests` round-trips the socket with a stand-in handler
(stopping, a tool that never reads, oversized and unreadable requests), and `ScriptFilesTests`
places files. Tests that copy or drag call `useOwnTemporaryRoot()` first, so they never empty
the folders a running Shotts keeps its last copied and dragged files in. `Tests/UI/Support.swift`
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
| `--cursor-check out.txt [--live]` | Opens the picker over stand-ins (or, with `--live`, the live screen) without moving the pointer, and writes the cursor's size every tenth of a second for two seconds (1×1 is the blank one). |
| `--scroll-test out.png` | A scrolling capture of a window of numbered lines, scrolled in code, through ScreenCaptureKit and the stitcher; writes the picture and `out.expected.png`, the document drawn directly. Build ShottsCore optimized for it, or it falls behind. |
| `--select out.txt` | Runs the picker alone over a drawn stand-in for each display and writes `selected x,y,w,h on <display>`, `window <id> at x,y on <display>`, `record x,y,w,h on <display>`, `scroll x,y,w,h on <display>`, or `cancelled`. |
| `--preview-overlay out.png [--dragged] [--dim] [--corner]` | Draws the picker off screen with the pointer three pixels inside the corner of the stand-in's square at 1600,1600, so the magnifier's mapping can be checked (`--dim` shows only with `--dragged`). |
| `--capture-window <id> out.png [--no-shadow]` | Captures one window through ScreenCaptureKit (needs Screen Recording). |
| `--preview-recording out.png [--recording]` | Draws the recording frame and the setup panel, or with `--recording` the recording bar, off screen over a light page. |
| `--export-recording in.mov out.(mp4\|gif) [--size percent] [--fps N] [--sound none\|system\|microphone\|both] [--microphone file]` | Makes the file a recording window would from any movie standing in for a recording, and prints its settings and time. |

`shotts` needs a packaged app (`open "$(Scripts/package-app.sh)"`, quitting the installed Shotts
first, since both want F10) and Allow Command-Line Capture on; run `.build/Shotts.app/Contents/Helpers/shotts`.
Try `list`; `shot` of a window, a display, and a region, in each format, with `--width` and
`--delay` (the countdown in the menu bar); `record` of a window while moving and covering it,
stopped by `--duration`, Control-C, F10, the timer, and closing the terminal; two Control-Cs;
`start` then `stop`, and `stop` again; a second `start` while one records (exit 5); and the
toggle off (exit 3).

From a shell that macOS trusts for Accessibility, `CGEvent` posts reach a real editor: launch
`Shotts.app --args --edit sample.png`, find the window with `CGWindowListCopyWindowInfo` (owner
`Shotts`, layer 0), and post events into the picture, centered in the canvas 28 points below the
bar. Never do this while someone is at the keyboard: the events land in whatever is in front.

## Traps

- The picker hides the pointer as a background app, and the app in front stays active: when
  what is under the still pointer changes (a page loading, a list updating, the Claude app
  streaming), that app sets its own cursor, which macOS lets the active app do, and an arrow sat
  beside the crosshair until the mouse moved. Sometimes, because it depends on that app. Caught
  with `--cursor-check out.txt --live` (debug), which writes the cursor macOS shows every tenth of
  a second for two seconds after the picker opens: blank for 600 ms, then 28×40 and 23×22 in one
  run of three. `AreaSelection.show` sets the blank cursor at once and thirty times a second until
  the picker closes, beside the views' cursor rects; that alone held in 120 samples of six runs.
- AppKit's automatic termination ends a background app quietly once its last window closes,
  and the AppKit test process is one: a test that brings a real window on screen and closes it
  can end the whole run partway, with no crash and exit code 0, as ordering the recording bar
  front in `recording()` once did; the bar sits a window level above the drawing layer
  instead, and the tests' windows are never shown. So `swift test` succeeding is not
  enough: both summary lines, Core's and AppKit's ("Test run with N tests … passed"), must be
  there.

- A window that animates as it appears gets pointer events placed wrongly while it does: the
  picker's overlay, opening with the system's animation, had a pointer-entered event report a
  position about 2% further from the screen's center than the pointer, and the crosshair opened
  up to 22 points off until the pointer moved. `OverlayWindow` sets `animationBehavior = .none`
  (shreeve/shotts#70, Philip Lindberg). No test can catch it: windows that are never shown do
  not animate. Check it by hand: press F10 without moving the pointer, and the crosshair is on it.

- A file descriptor's number goes to the next one opened the moment it is closed, so only what
  waits on a descriptor may close it. `ScriptServer` waits on its sockets with Dispatch sources
  and closes each in a cancel handler, which runs after the source's last event: `stop` cancels
  the listening source, so it stops listening at once and nothing can wait on the number once it
  is reused. A connection's read and write sources leave a `DispatchGroup` as they are cancelled,
  and its socket closes once both are done. `shutdown(2)` on a listening socket does nothing on
  macOS: it neither stops it listening nor wakes `accept`. `stoppingStopsListening` checks,
  through a second name for the socket, that `stop` leaves nothing listening.

- Screen Recording permission is keyed to the code signature. An ad-hoc-signed build has a new
  signature every time, so each rebuild would ask again and leave another row in System
  Settings. `Scripts/package-app.sh` signs every build with the Developer ID for that reason, and
  gives a debug build an id of its own (`com.github.shreeve.shotts.debug`): signed alike, it would
  share the release's grant, and its developer switches would let any program capture through it.
- `UserDefaults.standard` searches the launch arguments first: `-key value` on the command line
  overrides what the user saved. A setting that guards something, such as Allow Command-Line
  Capture, is read from the app's persistent domain alone.
- The quit Apple event says why the app is quitting (`kAEQuitReason`), and only while
  `applicationShouldTerminate` runs; a ⌘Q or the menu has none. Read it there, as a type or an
  enum code: a flag set by `willPowerOffNotification` outlives a log-out that is cancelled.
- A menu bar app (`LSUIElement`) is not active when its windows appear, and on macOS 27 (the one
  version this was seen on) the plain `NSApp.activate()` is refused for it. `activate(ignoringOtherApps: true)` works, and every
  activation uses it; but activating brings all of an app's windows forward, so the picker does
  not activate at all. Its overlays are non-activating panels (`.nonactivatingPanel`), which
  become key and take keys and clicks while the app in front stays in front, and show a blank
  cursor, since an app that is not active may not hide the pointer.
- A downloaded app still carrying its quarantine runs from a hidden read-only copy ("App
  Translocation"), where Sparkle cannot update it. `MoveToApplications` copies the bundle into
  Applications, removes `com.apple.quarantine` from the copy, and finds the real download to
  trash through `SecTranslocateCreateOriginalPathForURL`, which has no public header; it is
  looked up with `dlsym`, and when it is missing the download simply stays. The move runs only
  in release builds (`#if !DEBUG`), and it replaces whatever `/Applications/Shotts.app` there is:
  test it with a downloaded release, not over a copy you want to keep.
- `CGImage.cropping(to:)` shares its parent's pixels: a cut-out made that way keeps the whole
  frame alive, and with it a buffer the stream needs back. `DisplayImage.cut` draws into a bitmap
  of its own.
- A filtered display capture leaves window shadows out unless `ignoreShadowsDisplay` is false;
  the old frozen picker's screen looked shadowless for that reason.
- A clear window lets clicks through its transparent parts unless `ignoresMouseEvents` is set to
  false explicitly, even though false is what it reads by default; the live overlay sets it.
- Views do not clip their drawing to their bounds by default, and the rect `draw(_:)` is asked
  to fill can reach past the view, where a canvas filling it paints over the bar; the canvas sets `clipsToBounds` and fills only its bounds, and `BarTests` checks the bar
  shows.
- Printing runs the operation on its own (`NSPrintOperation.run()`), in the standard Print window,
  on a portrait page with a wide picture turned onto it (`PrintSheet`): a landscape page made
  the Print window's preview short and wide, its page badge over the picture.
  As a sheet on the editor it took the editor's dark look and was squeezed to the window's
  height, cutting off its options.
- `NSWindowController.close()` and `NSWindow.close()` skip `windowShouldClose`; only
  `performClose` asks. Anything that must happen on every close goes in `windowWillClose`: a new
  capture replacing an editor closes it with `close()`, and typing in it was lost until finishing
  the text moved there.
- A zip of a release fetched by clicking a link inside the Claude app gets a quarantine
  Gatekeeper calls "damaged", though the app is fine; test downloads through a browser.
- Modifier changes reach only the first responder, and letting go of Command comes a moment
  before the mouse when both are let go together. So the picker's view is its window's first
  responder (`initialFirstResponder`), a Command press toggles recording and its release does
  nothing, and a release records exactly when the selection shows red.
- Swift Testing interleaves `@MainActor` tests at their `await`s, and a notification one test
  posts is delivered later on the main queue, possibly to the next test's observer. The picker
  tests are `.serialized` for that reason.
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
- An `AVAssetTrack` does not keep its `AVAsset`: a track from an asset made inline and let go
  fails later, as `-12780` from `insertTimeRange`. `RecordingExport` holds its assets while it
  reads.
- An `AVAssetWriter` whose inputs are not real-time wants their samples interleaved: waiting on
  one input's readiness while never feeding the other waits forever. `RecordingExport` pumps the
  sound whenever the video waits; a writer fed all its video first needs
  `expectsMediaDataInRealTime`, as the tests' recording helper sets.
- The hardened runtime keeps the microphone from an app that does not claim
  `com.apple.security.device.audio-input`; `package-app.sh` signs with `Support/Shotts.entitlements`
  for it. macOS still asks the user the first time.
- A non-activating panel belongs to an app that is not active, and AppKit draws its standard
  buttons faded, as in a window in the background: white on gray. The recording panel's buttons
  are `PillButton`s, drawn by Shotts, on a solid panel, so they read the same either way.
- Removing leftover recordings at launch must not take another running Shotts' open ones: a
  second launch emptying the whole folder once deleted a recording being worked on. Folders are
  held by a file lock, which a crash releases, and a developer switch skips the cleanup.
- A debug binary run from a shell has no feed to check, and Sparkle's modal alert about it would
  hold up the main thread, so a developer switch runs without the updater.
- An arrow is one filled outline (`ArrowGeometry.outline`), not a stroked line plus a head:
  that is what lets it taper, and one shape means one shadow with no seam.
- `Tool.select` is raw value 0, which is also what an unset default reads as; the remembered
  tool checks for a stored value before trusting the number.
