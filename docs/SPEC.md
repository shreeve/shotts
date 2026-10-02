# Shotts: what it does

This is the product as users see it; `README.md` lists the other documents. When this file and
the code disagree, find out which is wrong and fix that one.

## The product

Shotts is a Mac screenshot tool that lives in the menu bar and takes one motion from key press
to paste: F10, drag out an area, mark it up, Command-C. Holding Command as the drag ends records
the area instead, to save as an MP4 or an animated GIF. It runs on macOS 14 and later on Apple
silicon. It captures and records only what the user selects, only when the user asks, and keeps
nothing on disk that the user did not save or drag out, but for a recording's own files while
its window is open. With Copy to Clipboard on, a capture is on the clipboard as soon as it is
taken.

## Installing

Shotts comes through Homebrew or as a download. Opened from anywhere but an Applications folder
(Downloads, the Desktop), a release asks once: "Move Shotts to your Applications folder?"
Move to Applications copies it there, replacing an older copy, puts the downloaded copy in the
Trash, and reopens it from there; without permission to write to the shared Applications folder
it uses the user's own. Not Now leaves it where it is, and "Don't ask again" stops the question.

## Capturing

F10 is the hot key, and Option-F10 brings the last capture back (see The editor). On a Mac
keyboard whose top row controls the Mac, that is fn-F10, unless "Use F1, F2, etc. keys as
standard function keys" is on. If another app already holds F10, the menu says so: Capture Area
(another app has F10). F10 does nothing while a capture or a recording is being set up, and
stops a recording under way.

| Action | Result |
| --- | --- |
| F10, or Capture Area in the menu bar | The pointer becomes a crosshair over the screen, which goes on updating underneath, windows, shadows, and all. |
| Move over a window | The window under the crosshair gets a blue outline. |
| Click | Captures that window on its own, without whatever was covering it, at the resolution of the display it is on. With Include Window Shadow on, the window comes with the shadow macOS draws around it, on a transparent margin. |
| Drag | Selects an area; everything outside it dims (unless Dim Outside Selection is off). Its size in pixels shows in the magnifier, or beside the selection when the magnifier is off. |
| Shift while dragging | Keeps the selection square. |
| Space while dragging | Moves the selection instead of resizing it. |
| Arrow keys | Move the crosshair a pixel, or ten with Shift, and the pointer with it; while dragging, the corner being dragged. |
| Command as the drag ends | Records the area instead (see Recording). While Command is down, the selection's outline is red and its size reads "Record". |
| Release | Captures the area as it is at that moment, at the display's full resolution, puts it on the clipboard (unless Copy to Clipboard is off), and opens the editor. |
| Command-C | Copies the color under the crosshair as `#RRGGBB` and ends the capture. |
| Escape | Cancels, even mid-drag. Nothing is kept. |

F10 leaves every window where it is, Shotts' editors included; Shotts itself comes to the front
only when a capture's editor opens, or with Option-F10. A click on no window does nothing, so a
stray click does not end the capture. Switching to
another app, or a display being added, removed, or rearranged, cancels.

The crosshair is a light line with a dark edge, visible on any background, and shows only on the
display the pointer is on; the keys act on that display. The selection stays on one display.
Beside the pointer a magnifier shows the pixels under the crosshair, fifteen across in a dark
frame, with a translucent cross whose arms are white or black by the pixel under each one and
stop short of the marked pixel under the crosshair, and stay while dragging. Below it are the
pixel's position and its color in hex, or the selection's size while dragging. Until the first
drag, a short list of these keys shows on the other side of the pointer, except near a corner
where it would cover the magnifier. The screen stays live throughout, so you can wait for
something to appear before you drag or click; the magnifier and the window outlines follow it.
Whatever is on screen can be captured, Shotts' own editors included; only the crosshair,
magnifier, dimming, and hints never are. While picking, macOS may show its screen-recording
indicator in the menu bar.

The menu bar menu holds About Shotts (the icon, version, copyright, and a link to the project),
Capture Area, Show Last Capture, Open Image… (a PNG, JPEG, or TIFF into the editor), Check for
Updates…, Quit, and the picker's options, remembered across launches. While a recording is
under way the menu bar item is a red dot and the time so far instead, and a click on it stops
the recording.

| Option | Default | Effect |
| --- | --- | --- |
| Show Magnifier | on | The magnifier and its color readout. |
| Dim Outside Selection | on | Darkens everything outside the area while it is being dragged out. Aiming and clicking a window never dim. |
| Include Window Shadow | off | A clicked window is captured with its own macOS shadow on a transparent margin, as the system's window screenshots are. An area cut from the screen never has one. |
| Copy to Clipboard | on | The capture is on the clipboard the moment it is taken, before any editing; Copy in the editor replaces it with the annotated one. |
| New Window per Capture | off | Each capture opens in an editor of its own. Off, a new capture takes the place of the open editor, where it was on screen, and the one it replaces becomes the last capture. |

The first F10 asks macOS for Screen Recording permission with the system's own dialog. Until it
is granted, later presses explain where to turn it on and capture nothing. The microphone is
the only other permission Shotts asks for, the first time a recording uses it. Shotts checks for updates once a day without asking, and
Check for Updates… checks at once.

## The editor

The capture opens in a dark window sized to show it at its on-screen size, or smaller to fit the
screen, on a dark field with a soft shadow. Several editors can be open at once.

The window can be resized. Only how big the picture is shown changes: it shrinks or grows with
the window, keeping its proportions, down to a small size and up to its on-screen size but no
larger. Annotations scale with it, earlier and later ones alike, stay editable at any size, and
export exactly as before. The green button shows the picture at its on-screen size, or as large
as the screen allows.

### Tools

| Tool | Key | What it draws |
| --- | --- | --- |
| Select | V | Click an annotation to select it; drag to move it, or nudge it with the arrow keys, a pixel at a time or ten with Shift; Delete removes it. Double-click text or a callout's words to edit them. |
| Arrow with text | N | An arrow with words at its tail, one object; see below. The tool a first capture starts with. |
| Arrow | A | A tapered arrow with a broad head, or an even shaft when Tapered is off. |
| Line | L | A straight line, round at both ends. Shift snaps it to horizontal, vertical, or 45°. Drag either end to reshape it. |
| Text | T | Click and type on the picture; the text appears in its final style as you go. Return starts a new line; Command-Return finishes, as do a click elsewhere or another tool, and Escape cancels the text. Clicking an existing text, or a callout's words, edits them. |
| Rectangle | R | A stroked rectangle. Shift for a square; Option for a solid one. |
| Ellipse | E | A stroked ellipse. Shift for a circle; Option for a solid one. |
| Pen | P | A smooth freehand stroke. |
| Highlighter | H | A wide translucent stroke, visible on dark and light backgrounds. |
| Obscure | O | Pixelates the area underneath in coarse blocks of flattened color, so text under it cannot be read back. |
| Crop | C | Drag the part to keep; everything outside is left out of the export. Shift for a square. A click clears the crop. |

After the first capture, a new capture starts with the drawing tool last used.

With any drawing tool, pressing on an annotation already there selects it, as the select tool
would, and dragging moves or reshapes it, rather than drawing a new one on top. The pen and
highlighter mark over anything, crop crops, and only Obscure selects an obscured area: every
other tool draws over one. Holding Space while dragging out a shape (a rectangle, ellipse,
obscured area, crop, arrow, or line) moves it with the pointer instead of growing it, as in the
picker; letting go of Space goes back to growing it.

Every tool but Obscure draws with the chosen color and line width; the highlighter uses them
translucent and three times as wide, never under 12 points. Text uses the chosen size and font:
Rounded (the system font's rounded design, the default), System, or Open Sans, which ships
inside the app, bold in each case. The color swatch in the bar opens a panel with ten
colors, a custom color, and switches for the soft shadow under annotations, the outline on
text, and tapered arrows. Color, width,
size, font, and the switches are remembered across captures. Changing one with an annotation
selected, or while typing, changes that one thing on it and nothing else.

### Arrows and arrow with text

Drag from the tail to what the arrow points at. With Arrow with text, typing then starts beside
the tail:

- A mostly horizontal arrow puts the words beside the tail on the side away from the tip,
  centered on the tail vertically: right-justified against it when to its left, left-justified
  when to its right.
- A mostly vertical arrow centers them on the tail horizontally, below it (arrow pointing up) or
  above it (pointing down), growing away from the arrow.
- A line runs to within 8 points of the picture's edge before it wraps; Return breaks a line
  sooner, and Command-Return finishes. The words keep that margin from every edge.

An arrow and its words are one object. Pressed with the select tool, or any drawing tool but
the pen, highlighter, and crop, dragging the shaft moves the whole; dragging the dot at the tail's end, or
the words, moves the tail with the tip staying put; dragging the head moves the tip with the
tail staying put. The words lay themselves out again after any reshape. Double-click the words
to retype them; words left empty turn the callout into a plain arrow.

### Editing

| Action | Key |
| --- | --- |
| Undo, Redo | Command-Z, Shift-Command-Z. While typing, they undo and redo the typing. |
| Cancel typing, then the current drag, then clear the selection | Escape |
| Close the editor | Command-W, the red button, or Escape with nothing to cancel |
| Bring the last capture back | Option-F10, or Show Last Capture in the menu bar menu |

Escape while typing cancels the text: new words go, a new arrow with text goes with its arrow,
and words being edited come back as they were. Undo covers annotations and the crop, not the
capture itself. Drawing, moving, or typing an
annotation is one step.

The editor is an ordinary window: it stays open until it is closed, and closing asks nothing.
Option-F10 brings the newest open editor to the front, or, when none is open, opens the one
closed last again exactly as it was, annotations still editable; a minimized editor comes back
too. Shotts keeps that one closed capture in memory until another editor closes and takes its
place, except that a capture with no annotations or crop never takes the place of one with
them: annotated work is what Option-F10 is for.

### Output

| Action | Result |
| --- | --- |
| Copy (Command-C) | The picture, with its annotations and crop, goes to the clipboard as PNG and TIFF. The editor stays open. Command-C copies the picture even while typing. |
| Save… (Command-S) | Asks where; suggests the Desktop and a name like `Shotts 2026-09-26 at 10.12.34 AM.png`, with the time as the system writes it. The editor stays open. |
| Drag the hand icon | Drags a PNG file into another app or the Finder, even from the first press while another app is in front. The editor stays open. |
| Print… (Command-P) | Prints the picture, with its annotations and crop, scaled to fit one portrait page, turned a quarter turn onto it when it is wider than tall, in the standard Print window. The editor comes back to the front afterwards. |

The copied, saved, and dragged pictures are identical to what the editor shows. They carry the
capture's resolution (144 dpi from a Retina display), so they paste at their on-screen size,
and its color space.

When the editor you are working in closes, the app that was in front when its F10 was pressed
comes back to the front; with several editors open, each gives focus back to the app its own
capture came from. A cancelled capture goes back to the app that was in front.

## Recording

Holding Command as the drag ends records the area rather than capturing it. Letting go leaves
the area outlined in red, with a small panel beside it; nothing records yet.

| Control | Effect |
| --- | --- |
| Record, or Return | Starts recording. The panel becomes the recording bar; the outline stays. |
| Microphone | Records your voice as well. Off until turned on, and remembered. The first recording with it on asks macOS for the microphone. |
| Cancel, or Escape | Ends without recording. |

Everything in the area is recorded as it happens, at the display's full resolution, up to 60
frames a second, with the pointer, and with the Mac's own sound, kept apart from the
microphone. The outline sits just outside the area; neither it, the bar, nor Shotts' menu bar
item is ever recorded. While recording, the menu bar item shows a red dot and the time so far,
and the bar beside the area has:

| Control | Effect |
| --- | --- |
| Arrow, Rectangle | Draws on the area as it records, in the editor's last style: tapered or even arrows, the color, the width, the shadow. Each shape stays four seconds, then fades over one, and is recorded. While a tool is on, clicks in the area draw rather than reaching what is underneath; its button again, or Escape, turns it off. Shift keeps a rectangle square. |
| Pause | Stops taking the screen and sound until pressed again; the recording goes straight from before the pause to after it. The menu bar item shows ❚❚ and holds the time. |
| Stop | Ends the recording, as F10 and a click on the menu bar item do. |

Quitting Shotts while it records stops the recording and opens it instead; quitting again
quits. Logging out or shutting down is not held up, and the recording goes with it. If the display being recorded goes, the recording stops there and opens.
With the microphone on but turned off for Shotts in System Settings, Record asks: record
without the microphone, open System Settings, or cancel.

The recording then opens in a window of its own, which plays it and makes files from it:

| Setting | Choices |
| --- | --- |
| Format | MP4: H.264, which plays nearly everywhere. GIF: animated, looping, silent, 255 colors. |
| Size | 100%, 75%, 50%, or 25% of the recording, the pixels it comes to shown on hover; an MP4 stays within 4096 by 2304. |
| Frame rate | 60, 30, 20, 10, 5, or 1 frames a second; a GIF up to 30. |
| Sound | MP4 only: none, the Mac's sound, the microphone, or both mixed, of what was recorded. |

Below the video, a timeline plays it (Space plays and pauses; the playhead can be clicked or
dragged) and trims it: the bracket at either end drags in, the part left out is dimmed, and
every file made keeps only the part between, whatever its format.

An MP4 starts at the recording's full size, 30 frames a second, with the microphone if it was
on; a GIF at the size the area had on screen (50% from a Retina display), 10 frames a second. Each format keeps its own
settings while the window is open. Whenever they change, the window makes the file again in the
background and shows its size, or why it could not be made. Copy puts the file on the
clipboard, as the Finder copies files, and it still pastes after the window closes (the last
file copied is kept until the next); Save… asks where, suggesting the Desktop and a name like
`Shotts Recording 2026-09-30 at 2.15.00 PM.mp4`, and replaces a file already there only once the
copy has worked; dragging the hand icon drags the file out. Each leaves the window open, so one
recording can be saved several ways. Command-W, the red button, or Escape closes the window,
which deletes the recording and every file made from it; saved and copied files stay. When the window you are working in closes, focus goes back to the app that was in
front when F10 was pressed.

A GIF has one palette for the whole clip. Colors that cover much of the picture are kept
exactly, so text and flat backgrounds stay crisp; colors between the palette's are dithered with
a fixed blue-noise pattern, so gradients do not band and what stays still in the recording stays
still in the GIF, which stores only the part of each frame that changed. An MP4 puts its index
first, so a preview in Messages or Mail plays at once.

## Not built

Full-screen capture, repeating the previous area, delayed capture, recording a single window,
clicks shown in a recording, uploads, cloud storage, and OCR.
