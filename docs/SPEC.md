# Shotts: what it does

This is the product as users see it; `README.md` lists the other documents. When this file and
the code disagree, find out which is wrong and fix that one.

## The product

Shotts is a Mac screenshot tool that lives in the menu bar and takes one motion from key press
to paste: F10, drag out an area, mark it up, Command-C. It runs on macOS 27 on Apple silicon.
It captures only what the user selects, only when the user asks, and keeps nothing on disk
that the user did not save or drag out. With Copy to Clipboard on, a capture is on the
clipboard as soon as it is taken.

## Capturing

F10 is the hot key, and Option-F10 brings the last capture back (see The editor). On a Mac
keyboard whose top row controls the Mac, that is fn-F10, unless "Use F1, F2, etc. keys as
standard function keys" is on. If another app already holds F10, the menu says so: Capture Area
(another app has F10). F10 does nothing while a capture is under way.

| Action | Result |
| --- | --- |
| F10, or Capture Area in the menu bar | The pointer becomes a crosshair over the screen, which goes on updating underneath, windows, shadows, and all. |
| Move over a window | The window under the crosshair gets a blue outline. |
| Click | Captures that window on its own, without whatever was covering it, at the resolution of the display it is on. With Include Window Shadow on, the window comes with the shadow macOS draws around it, on a transparent margin. |
| Drag | Selects an area; everything outside it dims (unless Dim Outside Selection is off). Its size in pixels shows in the magnifier, or beside the selection when the magnifier is off. |
| Shift while dragging | Keeps the selection square. |
| Space while dragging | Moves the selection instead of resizing it. |
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

The menu bar menu holds Capture Area, Show Last Capture, Open Image… (a PNG, JPEG, or TIFF into
the editor), Check for Updates…, Quit, and the picker's options, remembered across launches:

| Option | Default | Effect |
| --- | --- | --- |
| Show Magnifier | on | The magnifier and its color readout. |
| Dim Outside Selection | on | Darkens everything outside the area while it is being dragged out. Aiming and clicking a window never dim. |
| Include Window Shadow | off | A clicked window is captured with its own macOS shadow on a transparent margin, as the system's window screenshots are. An area cut from the screen never has one. |
| Copy to Clipboard | on | The capture is on the clipboard the moment it is taken, before any editing; Copy in the editor replaces it with the annotated one. |
| New Window per Capture | off | Each capture opens in an editor of its own. Off, a new capture takes the place of the open editor, where it was on screen, and the one it replaces becomes the last capture. |

The first F10 asks macOS for Screen Recording permission with the system's own dialog. Until it
is granted, later presses explain where to turn it on and capture nothing. Screen Recording is
the only permission Shotts asks for. Shotts checks for updates once a day without asking, and
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
| Select | V | Click an annotation to select it; drag to move it; Delete removes it. Double-click text or a callout's words to edit them. |
| Arrow with text | N | An arrow with words at its tail, one object; see below. The tool a first capture starts with. |
| Arrow | A | A tapered arrow with a broad head, or an even shaft when Tapered is off. |
| Text | T | Click and type on the picture; the text appears in its final style as you go. Return finishes, as do a click elsewhere or another tool; Shift-Return starts a new line, and Escape cancels the text. Clicking an existing text edits it. |
| Rectangle | R | A stroked rectangle. Shift for a square; Option for a solid one. |
| Ellipse | E | A stroked ellipse. Shift for a circle; Option for a solid one. |
| Pen | P | A smooth freehand stroke. |
| Highlighter | H | A wide translucent stroke, visible on dark and light backgrounds. |
| Obscure | O | Pixelates the area underneath in coarse blocks of flattened color, so text under it cannot be read back. |
| Crop | C | Drag the part to keep; everything outside is left out of the export. A click clears the crop. |

After the first capture, a new capture starts with the drawing tool last used.

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
- A line runs to within 8 points of the picture's edge before it wraps; Shift-Return breaks a
  line sooner, and Return finishes. The words keep that margin from every edge.

An arrow and its words are one object. With the select tool, or with either arrow tool clicking
an existing arrow, dragging the shaft moves the whole; dragging the dot at the tail's end, or
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
closed last again exactly as it was, annotations still editable. Shotts keeps that one closed
capture in memory until another editor closes and takes its place.

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

## Not built

Full-screen capture, repeating the previous area, delayed capture, screen recording, uploads,
cloud storage, and OCR.
