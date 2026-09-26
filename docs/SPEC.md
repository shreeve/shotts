# Shotts: what it does

This is the product as users see it. `HANDOFF.md` is how the code does it, and `AGENTS.md` is
the rule list for changing it. When this file and the code disagree, find out which is wrong and
fix that one.

## The product

Shotts is a Mac screenshot tool that lives in the menu bar and takes one motion from key press
to paste: F10, drag out an area, mark it up, Command-C. It runs on macOS 27 on Apple silicon.
It captures only what the user selects, only when the user asks, and never keeps a capture the
user did not copy, save, or drag out.

## Capturing

| Action | Result |
| --- | --- |
| F10, or Capture Area in the menu bar | Every display is pictured as it is at that moment, the pointer disappears, and a crosshair follows it over that picture. |
| Move over a window | The window under the crosshair gets a blue outline. |
| Click | Captures that window on its own, without whatever was covering it. With Include Window Shadow on, the window comes with the shadow macOS draws around it, on a transparent margin. |
| Drag | Selects an area; everything outside it dims (unless Dim Outside Selection is off). Its size in pixels shows in the magnifier. |
| Shift while dragging | Keeps the selection square. |
| Space while dragging | Moves the selection instead of resizing it. |
| Release | Cuts the area out of the picture at the display's full resolution, puts it on the clipboard (unless Copy to Clipboard is off), and opens the editor. |
| Command-C | Copies the color under the crosshair as `#RRGGBB` and ends the capture. |
| Escape, or a click on no window | Cancels. Nothing is kept. |

The crosshair is a light line with a dark edge, visible on any background. The selection stays
on one display. Beside the pointer a magnifier shows the pixels under the
crosshair, fifteen across, with a translucent cross whose arms are white or black by the pixel
under each one and stop short of the marked pixel under the crosshair, with
the pixel's position and its color in hex below, or the selection's size while dragging. Until the first drag, a short list of these keys shows on
the other side of the pointer, except near a corner where it would cover the magnifier. Because the picture is taken when F10 is pressed, what you
select is exactly what you get, even if the screen changes while you choose.

The menu bar menu holds the picker's options, remembered across launches:

| Option | Default | Effect |
| --- | --- | --- |
| Copy to Clipboard | on | The capture is on the clipboard the moment it is taken, before any editing; Copy in the editor replaces it with the annotated one. |
| Include Window Shadow | off | A clicked window is captured with its own macOS shadow on a transparent margin, as the system's window screenshots are. An area cut from the screen never has one. |
| Dim Outside Selection | on | Darkens everything outside the area while it is being dragged out. Aiming and clicking a window never dim. |
| Show Magnifier | on | The magnifier and its color readout. |
| Show Hints | on | The list of keys until the first drag. |

The first capture asks macOS for Screen Recording permission. Until it is granted, F10 explains
where to turn it on and captures nothing.

## The editor

The capture opens in a dark window sized to show it at its on-screen size, or smaller to fit the
display, on a dark field with a soft shadow. The window is the only Shotts window; several can be
open at once.

### Tools

| Tool | Key | What it draws |
| --- | --- | --- |
| Select | V | Click an annotation to select it; drag to move it; Delete removes it. Double-click text to edit it. |
| Arrow with text | N | Drag from the tail to what the arrow points at, then type. A mostly horizontal arrow puts the text beside the tail on the side away from the tip, centered on the tail vertically, right-justified against it when to its left and left-justified when to its right. A mostly vertical arrow puts it centered on the tail horizontally, below it (arrow pointing up) or above it (pointing down), growing away from the arrow. A line runs to within 8 points of the picture's edge before it wraps; Return breaks a line sooner. The text keeps that margin from every edge. The arrow and its text are one object: with the select tool, dragging the arrow's shaft moves both, dragging the text or the dot at the tail's end moves the tail (the tip stays put and the arrow reshapes), and dragging the head moves the tip (the tail stays put). After any reshape the text relays to the arrow's new direction. Double-click the text to retype it; a callout left without words becomes a plain arrow. The tool a first capture starts with; after that, a new capture starts with the drawing tool last used. |
| Arrow | A | A tapered arrow with a broad head, or an even shaft when Tapered is off. |
| Text | T | Click and type on the picture; the text appears in its final style as you go. Return starts a new line. Escape, Command-Return, a click elsewhere, or another tool finishes. |
| Rectangle | R | A stroked rectangle. Shift for a square; Option for a solid one. |
| Ellipse | E | A stroked ellipse. Shift for a circle; Option for a solid one. |
| Pen | P | A smooth freehand stroke. |
| Highlighter | H | A wide translucent stroke, visible on dark and light backgrounds. |
| Obscure | O | Pixelates the area underneath. |
| Crop | C | Drag the part to keep. Everything outside is left out of the export. |

Every tool but Highlighter and Obscure draws with the chosen color and line width. Text uses
the chosen size and font: Rounded (the system font's rounded design, the default), System, or
Trebuchet, bold in each case. The color swatch in the bar opens a panel with ten colors, a custom color, and
switches for the soft shadow under annotations, the outline on text, tapered arrows, and
including a captured window's shadow. Color, width, size, font, and the switches are remembered across
captures, as is the last tool used. Changing them with an annotation selected restyles it.

### Editing

| Action | Key |
| --- | --- |
| Undo, Redo | Command-Z, Shift-Command-Z |
| Finish typing, cancel the current drag, then clear the selection | Escape |
| Close the editor | Command-W, or Escape with nothing to cancel |

Undo covers annotations and the crop, not the capture itself. Closing a window with unsaved
annotations asks first.

### Output

| Action | Result |
| --- | --- |
| Copy (Command-C) | The picture, with its annotations and crop, goes to the clipboard as PNG and TIFF. The editor closes. |
| Save… (Command-S) | Asks where; suggests the Desktop and a name like `Shotts 2026-09-26 at 10.12.34.png`. The editor closes. |
| Drag the hand icon | Drags a PNG file into another app or the Finder. The editor closes when the drop lands. |

The copied, saved, and dragged pictures are identical to what the editor shows.

After the editor closes, the app that was in front when F10 was pressed comes back to the front.

## Not built

Full-screen capture, repeating the previous area, delayed capture, screen recording, uploads,
cloud storage, and OCR.
