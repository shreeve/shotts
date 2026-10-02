import AppKit
import ShottsCore
import Testing
@testable import ShottsUI

/// A display picture whose pixels report when they are freed, and a flag that says so.
private func trackedPicture(_ width: Int, _ height: Int) -> (CGImage, UnsafeMutablePointer<Bool>) {
    let freed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    freed.pointee = false
    let bytesPerRow = width * 4
    let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
    data.initializeMemory(as: UInt8.self, repeating: 0x80, count: bytesPerRow * height)
    let provider = CGDataProvider(dataInfo: freed, data: data, size: bytesPerRow * height) { info, data, _ in
        info?.assumingMemoryBound(to: Bool.self).pointee = true
        UnsafeMutableRawPointer(mutating: data).deallocate()
    }!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return (image, freed)
}

@MainActor @Suite struct CutTests {
    /// Only the cut-out survives the picker: the display's picture is freed while the cut-out
    /// lives on in the editor.
    @Test func cutOutKeepsNoneOfTheDisplayPicture() throws {
        let screen = try #require(NSScreen.screens.first)
        let (freed, cut): (UnsafeMutablePointer<Bool>, CGImage?) = autoreleasepool {
            let (picture, freed) = trackedPicture(800, 600)
            let display = DisplayImage(screen: screen, image: picture, scale: 2)
            return (freed, display.cut(CGRect(x: 10, y: 10, width: 100, height: 50)))
        }
        defer { freed.deallocate() }
        let image = try #require(cut)
        #expect(freed.pointee)
        #expect(image.width == 200 && image.height == 100)
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    /// The cut-out's pixels are the picture's, from the top-left, in its own color space.
    @Test func cutOutHasThePicturesPixels() throws {
        let screen = try #require(NSScreen.screens.first)
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 30, width: 10, height: 10)) // the top-left corner, as y runs upward
        let display = DisplayImage(screen: screen, image: ctx.makeImage()!, scale: 1)
        let cut = try #require(display.cut(CGRect(x: 5, y: 5, width: 10, height: 10)))
        let colors = PixelSampler.colors(in: CGRect(x: 0, y: 0, width: 10, height: 10), of: cut)
        #expect(colors[0][0]?.hex == "#FF0000")
        #expect(colors[9][9]?.hex == "#0000FF")
    }
}

/// A 200 by 150 point overlay on a 400 by 300 pixel picture, in a window that is never shown.
private func overlay(_ picture: CGImage = blankImage(400, 300), windows: [WindowInfo] = []) throws -> OverlayView {
    let screen = try #require(NSScreen.screens.first)
    let view = OverlayView(display: DisplayImage(screen: screen, image: picture, scale: 2, windows: windows), options: SelectionOptions())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 150), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    return view
}

extension OverlayView {
    /// Moves the pointer to `p` in the view's own coordinates.
    func point(at p: CGPoint) { pointerMoved(to: convert(p, to: nil)) }

    /// Whether the view draws nothing but its picture: every pixel of a plain picture alike.
    var drawsOnlyThePicture: Bool {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let bytes = rep.bitmapData!, bpp = rep.bitsPerPixel / 8
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let o = y * rep.bytesPerRow + x * bpp
                for c in 0..<bpp where bytes[o + c] != bytes[c] { return false }
            }
        }
        return true
    }
}

// One test at a time: notifications one test posts reach the next one's picker on the main queue.
@MainActor @Suite(.serialized) struct PickerTests {
    /// A display the pointer is not on shows no crosshair line, no magnifier pinned to its
    /// edge, no hints, and no window outline, whichever side the pointer is on.
    @Test func displayWithoutThePointerShowsOnlyItsPicture() throws {
        let view = try overlay(windows: [WindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 150))])
        view.point(at: CGPoint(x: 100, y: 75))
        #expect(view.pointer != nil && view.hoveredWindow != nil)
        #expect(!view.drawsOnlyThePicture)
        for outside in [CGPoint(x: -30, y: 40), CGPoint(x: 260, y: 40), CGPoint(x: 50, y: -20), CGPoint(x: 50, y: 400)] {
            view.point(at: outside)
            #expect(view.pointer == nil && view.hoveredWindow == nil && view.colorUnderPointer() == nil)
            #expect(view.drawsOnlyThePicture)
        }
    }

    /// The display the pointer leaves drops its crosshair and magnifier.
    @Test func leavingTheDisplayClearsIt() throws {
        let view = try overlay()
        view.point(at: CGPoint(x: 100, y: 75))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseExited(with: exit)
        #expect(view.pointer == nil)
        #expect(view.drawsOnlyThePicture)
    }

    /// A drag past the display's edge stops at the edge, and the size shown is the size cut,
    /// even with edges off the pixel grid.
    @Test func selectionIsClippedAndItsSizeIsTheCutsSize() throws {
        let view = try overlay()
        view.pressed(at: CGPoint(x: 150, y: 100))
        view.dragged(to: CGPoint(x: 260, y: 190), square: false)
        #expect(view.selection == CGRect(x: 150, y: 100, width: 50, height: 50))
        #expect(view.pointer == nil)

        view.pressed(at: CGPoint(x: 10.3, y: 10.3))
        view.dragged(to: CGPoint(x: 20.6, y: 20.6), square: false)
        let selection = try #require(view.selection)
        let cut = try #require(view.display.cut(selection))
        #expect(view.magnifier(at: CGPoint(x: 20.6, y: 20.6)).text.hasPrefix("\(cut.width) × \(cut.height) "))
        #expect(cut.width == 22 && cut.height == 22)
    }

    /// The magnifier's crosshair arms show while aiming and go on showing while dragging, when
    /// the corner is being put on a pixel.
    @Test func theMagnifiersArmsStayWhileDragging() throws {
        let view = try overlay()
        func armShows(at p: CGPoint) -> Bool {
            let m = view.magnifier(at: p)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            func color(_ cellX: Int, _ cellY: Int) -> NSColor? {
                let cell = OverlayView.magnifierCell
                let x = m.pixels.minX + (CGFloat(cellX) + 0.5) * cell, y = m.pixels.minY + (CGFloat(cellY) + 0.5) * cell
                return rep.colorAt(x: Int(x * scale), y: Int(y * scale))
            }
            // The top arm's first cell against the corner cell beside it: plain picture in both
            // but for the arm.
            let half = OverlayView.magnifierCells / 2
            return color(half, 0) != color(0, 0)
        }
        view.point(at: CGPoint(x: 60, y: 40))
        #expect(armShows(at: CGPoint(x: 60, y: 40)))
        view.pressed(at: CGPoint(x: 30, y: 20))
        view.dragged(to: CGPoint(x: 60, y: 40), square: false)
        #expect(view.selection != nil)
        #expect(armShows(at: CGPoint(x: 60, y: 40)))
    }

    /// The magnifier is one size wherever it is and whatever its label says: the pixels in a
    /// frame two cells wide on the left, top, and right, and the longest label fits under them.
    @Test func theMagnifierHasAnEvenFrameAndFixedSize() throws {
        let view = try overlay()
        let near = view.magnifier(at: CGPoint(x: 1, y: 1))
        view.pressed(at: CGPoint(x: 0, y: 0))
        view.dragged(to: CGPoint(x: 199, y: 149), square: false)
        let far = view.magnifier(at: CGPoint(x: 199, y: 149))
        #expect(near.panel.size == far.panel.size)
        let frame = OverlayView.magnifierCell * 2
        for m in [near, far] {
            #expect(m.pixels.minX - m.panel.minX == frame)
            #expect(m.panel.maxX - m.pixels.maxX == frame)
            #expect(m.pixels.minY - m.panel.minY == frame)
        }
        let widest = "9999 × 9999   #FFFFFF" as NSString
        #expect(widest.size(withAttributes: OverlayView.labelAttributes).width + 4 <= near.panel.width)
    }

    /// Live, the real screen shows through: the overlay is clear, still takes the mouse, draws
    /// nothing where the pointer is not, and redraws the magnifier when a new frame comes.
    /// The picker never activates Shotts, which would bring every editor in front of what is
    /// about to be captured: its windows are non-activating panels that still take keys.
    @Test func thePickerDoesNotActivateShotts() throws {
        let screen = try #require(NSScreen.screens.first)
        let window = OverlayWindow(display: DisplayImage(screen: screen, image: nil, scale: 2, isLive: true), options: SelectionOptions())
        #expect(window.styleMask.contains(.nonactivatingPanel) && window.canBecomeKey && !window.hidesOnDeactivate)
    }

    @Test func aLiveOverlayShowsTheRealScreen() throws {
        let screen = try #require(NSScreen.screens.first)
        let display = DisplayImage(screen: screen, image: nil, scale: 2, isLive: true)
        #expect(display.pixelBounds.width == (screen.frame.width * 2).rounded())
        let window = OverlayWindow(display: display, options: SelectionOptions())
        #expect(!window.isOpaque && window.backgroundColor == .clear && !window.ignoresMouseEvents)
        let view = window.overlayView
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 150)

        view.pointerMoved(to: view.convert(CGPoint(x: -50, y: -50), to: nil))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let alpha = (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).map { x in rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 } }
        #expect(alpha.allSatisfy { $0 == 0 })

        view.point(at: CGPoint(x: 60, y: 40))
        view.cacheDisplay(in: view.bounds, to: rep) // draws the magnifier, and notes where
        view.needsDisplay = false
        display.image = blankImage(400, 300)
        #expect(view.needsDisplay)
    }

    /// The magnifier's color and Command-C's are the pixel under the crosshair.
    @Test func colorIsThePixelUnderThePointer() throws {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 300 - 61, width: 1, height: 1)) // pixel 100,60 from the top
        let view = try overlay(ctx.makeImage()!)
        view.point(at: CGPoint(x: 50.2, y: 30.4))
        #expect(view.colorUnderPointer()?.hex == "#FF0000")
        #expect(view.magnifier(at: CGPoint(x: 50.2, y: 30.4)).text == "100,60   #FF0000")
        view.point(at: CGPoint(x: 51, y: 30.4))
        #expect(view.colorUnderPointer()?.hex == "#00FF00")
    }

    /// A display change or another app coming to the front cancels the picker.
    @Test func screenChangeOrLosingActiveCancels() async throws {
        let screen = try #require(NSScreen.screens.first)
        let changes: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification),
        ]
        for (center, name) in changes {
            var outcome: AreaSelection.Outcome?
            let selection = AreaSelection(displays: [DisplayImage(screen: screen, image: blankImage(40, 30), scale: 2)], options: SelectionOptions()) {
                outcome = $0
            }
            center.post(name: name, object: NSWorkspace.shared)
            try await Task.sleep(for: .milliseconds(20))
            guard case .cancelled? = outcome else { Issue.record("\(name.rawValue) left the picker up"); continue }
            _ = selection
        }
    }

    /// Shotts itself coming to the front, as when one of its editors opens, leaves the picker up:
    /// only another app does not.
    @Test func shottsComingForwardLeavesThePickerUp() async throws {
        let screen = try #require(NSScreen.screens.first)
        var outcome: AreaSelection.Outcome?
        let selection = AreaSelection(displays: [DisplayImage(screen: screen, image: blankImage(40, 30), scale: 2)], options: SelectionOptions()) {
            outcome = $0
        }
        defer { selection.cancel() }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try await Task.sleep(for: .milliseconds(20))
        #expect(outcome == nil)
    }
}

@MainActor @Suite struct RecordPickerTests {
    /// Command held as the drag ends records the area; without it, the area is captured.
    @Test func commandAtReleaseRecords() throws {
        for command in [false, true] {
            let view = try overlay()
            var outcome: AreaSelection.Outcome?
            view.onFinish = { outcome = $0 }
            view.pressed(at: CGPoint(x: 20, y: 20))
            view.dragged(to: CGPoint(x: 120, y: 80), square: false)
            view.released(at: CGPoint(x: 120, y: 80), recording: command)
            switch outcome {
            case let .record(_, rect)?: #expect(command && rect == CGRect(x: 20, y: 20, width: 100, height: 60))
            case let .selected(_, rect)?: #expect(!command && rect == CGRect(x: 20, y: 20, width: 100, height: 60))
            default: Issue.record("no area came back")
            }
        }
    }

    /// While Command is down the selection reads "Record" and its size, not the color.
    @Test func commandShowsTheRecordingToBe() throws {
        let view = try overlay()
        view.pressed(at: CGPoint(x: 20, y: 20))
        view.dragged(to: CGPoint(x: 120, y: 80), square: false)
        #expect(!view.magnifier(at: CGPoint(x: 120, y: 80)).text.hasPrefix("Record"))
        view.commandChanged(true)
        #expect(view.records)
        #expect(view.magnifier(at: CGPoint(x: 120, y: 80)).text == "Record  200 × 120")
        view.commandChanged(false)
        #expect(!view.records)
    }

    /// A click, Command or not, still captures the window under it.
    @Test func aClickStillCapturesAWindow() throws {
        let view = try overlay(windows: [WindowInfo(id: 7, frame: CGRect(x: 0, y: 0, width: 100, height: 100))])
        var outcome: AreaSelection.Outcome?
        view.onFinish = { outcome = $0 }
        view.pressed(at: CGPoint(x: 50, y: 50))
        view.released(at: CGPoint(x: 50, y: 50), recording: true)
        guard case let .window(_, window)? = outcome else { Issue.record("no window came back"); return }
        #expect(window.id == 7)
    }
}

@MainActor @Suite struct PickerArrowKeyTests {
    /// The arrow keys move the crosshair a pixel (ten with Shift), and the real pointer with it;
    /// during a drag they move the corner being dragged.
    @Test func arrowKeysMoveAPixel() throws {
        let view = try overlay()
        var warps = 0
        view.warp = { _ in warps += 1 }
        view.point(at: CGPoint(x: 20.2, y: 30.2))
        view.nudge(by: CGPoint(x: 1, y: 0))
        let pointer = try #require(view.pointer)
        #expect(abs(pointer.x - 20.75) < 1e-6 && abs(pointer.y - 30.25) < 1e-6)
        #expect(warps == 1)
        view.pressed(at: CGPoint(x: 10, y: 10))
        view.dragged(to: CGPoint(x: 50.25, y: 40.25), square: false)
        view.nudge(by: CGPoint(x: 10, y: 0))
        let selection = try #require(view.selection)
        #expect(abs(selection.maxX - 55.25) < 1e-6 && abs(selection.maxY - 40.25) < 1e-6 && selection.minX == 10)
        #expect(warps == 2)
    }

    /// Keyboard events reach it: Shift moves ten.
    @Test func shiftArrowMovesTen() throws {
        let view = try overlay()
        view.warp = { _ in }
        view.point(at: CGPoint(x: 20.2, y: 30.2))
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        view.keyDown(with: down)
        let pointer = try #require(view.pointer)
        #expect(abs(pointer.y - 35.25) < 1e-6)
    }
}
