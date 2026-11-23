// shotts-switcher: switches desktops at once, without the slide, on a three-finger swipe or
// Control-Left/Right. Shotts runs it while Fast Desktop Switching is on, and it quits when
// Shotts does; run from a shell, it quits when the shell does.
//
// From noswoosh 1.7.8 (https://github.com/mmathys/noswoosh), Copyright (c) 2026 Max Mathys,
// MIT License. SwitcherCore holds the decisions and the numbers, and says why they are what
// they are.
//
// It needs Accessibility, which macOS checks for the app that started it. Without it, it
// exits with status 3, and whoever started it asks for Accessibility and starts it again once
// it is allowed: a process cannot pick up a grant made while it runs. Before macOS 26.6 it
// exits with status 4.

import AppKit
import Carbon.HIToolbox
import SwitcherCore

func log(_ message: String) {
    FileHandle.standardError.write(Data("shotts-switcher: \(message)\n".utf8))
}

let version = ProcessInfo.processInfo.operatingSystemVersion

// MARK: - SkyLight: the window server's private interface, found at run time

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

func skyLightFunction<T>(_ name: String, as _: T.Type) -> T {
    guard let symbol = dlsym(skyLight, name) else {
        log("this macOS has no \(name)")
        exit(5)
    }
    return unsafeBitCast(symbol, to: T.self)
}

let mainConnection = skyLightFunction("SLSMainConnectionID", as: (@convention(c) () -> UInt32).self)
let copyDisplaySpaces = skyLightFunction("SLSCopyManagedDisplaySpaces", as: (@convention(c) (UInt32) -> UnsafeRawPointer?).self)
let activeSpace = skyLightFunction("SLSGetActiveSpace", as: (@convention(c) (UInt32) -> UInt64).self)
let copySpacesForWindows = skyLightFunction("SLSCopySpacesForWindows", as: (@convention(c) (UInt32, Int32, CFArray) -> UnsafeRawPointer?).self)
let setSymbolicHotKey = skyLightFunction("SLSSetSymbolicHotKeyEnabled", as: (@convention(c) (Int32, Bool) -> Int32).self)
let connection = mainConnection()

func takeArray(_ pointer: UnsafeRawPointer?) -> [Any] {
    guard let pointer else { return [] }
    return Unmanaged<CFArray>.fromOpaque(pointer).takeRetainedValue() as? [Any] ?? []
}

// MARK: - Desktops

/// The desktops of the display a switch lands on, which is the one under the pointer: the Dock
/// routes a swipe there, not to the display with keyboard focus.
struct Desktops {
    var count: Int
    var current: Int
    var display: String?
}

func pointerDisplay() -> String? {
    guard let location = CGEvent(source: nil)?.location else { return nil }
    var id = CGDirectDisplayID(), found: UInt32 = 0
    guard CGGetDisplaysWithPoint(location, 1, &id, &found) == .success, found > 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}

func desktops() -> Desktops? {
    let displays = takeArray(copyDisplaySpaces(connection)).compactMap { $0 as? [String: Any] }
    func desktops(of display: [String: Any], current: UInt64) -> Desktops? {
        let ids = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let index = ids.firstIndex(of: current) else { return nil }
        return Desktops(count: ids.count, current: index, display: display["Display Identifier"] as? String)
    }
    // Several displays with their own desktops: the pointer's display, at its own current one.
    if displays.count > 1, let uuid = pointerDisplay(),
       let display = displays.first(where: { $0["Display Identifier"] as? String == uuid }),
       let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
       let found = desktops(of: display, current: current.uint64Value) {
        return found
    }
    // One set of desktops, shared or on one display.
    let active = activeSpace(connection)
    return displays.lazy.compactMap { desktops(of: $0, current: active) }.first
}

// MARK: - The switch: a Dock swipe with almost no progress and a hard fling

func field(_ number: UInt32) -> CGEventField { unsafeBitCast(number, to: CGEventField.self) }

enum Field {
    static let eventType = field(55), hidType = field(110), motion = field(123), progress = field(124)
    static let positionX = field(125), velocityX = field(129), velocityY = field(130), phase = field(132)
}

let dockControl: Int64 = 30, gesture: Int64 = 29, dockSwipe: Int64 = 23, horizontal: Int64 = 1
/// Marks the events this posts, which come back through its own tap: it lets them pass.
let ownTag: Int64 = 0x5348_5357 // 'SHSW'
let needsPayload = DesktopSwitch.needsPayload(major: version.majorVersion)
let naturalScrolling = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true

func dockSwipeEvent(_ phase: DesktopSwitch.Phase, right: Bool) -> CGEvent? {
    let swipe = DesktopSwitch.swipe(phase, right: right, payload: needsPayload, naturalScrolling: naturalScrolling)
    guard let event = CGEvent(source: nil) else { return nil }
    event.setIntegerValueField(Field.eventType, value: dockControl)
    event.setIntegerValueField(Field.hidType, value: dockSwipe)
    event.setIntegerValueField(Field.phase, value: phase.rawValue)
    event.setIntegerValueField(Field.motion, value: horizontal)
    event.setDoubleValueField(Field.progress, value: swipe.progress)
    guard needsPayload else {
        event.setDoubleValueField(Field.velocityX, value: swipe.velocity)
        event.setDoubleValueField(Field.velocityY, value: swipe.velocity)
        event.setIntegerValueField(.eventSourceUserData, value: ownTag)
        return event
    }
    event.setDoubleValueField(Field.positionX, value: 0.1)
    if swipe.velocity != 0 { event.setDoubleValueField(Field.velocityX, value: swipe.velocity) }
    let payload = DesktopSwitch.payload(timestamp: event.timestamp != 0 ? event.timestamp : mach_absolute_time(), phase: phase, swipe: swipe)
    guard let data = event.data, let bytes = DesktopSwitch.appending(payload, to: [UInt8](data as Data)),
          let withPayload = CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData) else { return nil }
    // After the round trip, which drops it.
    withPayload.setIntegerValueField(.eventSourceUserData, value: ownTag)
    return withPayload
}

/// The space list catches up a moment after a switch, so a quick second switch trusts where the
/// last one landed, on the same display, for a while (macOS 27's list settles slower).
var landed: (index: Int, display: String?, at: Date)?
let landedTrusted = needsPayload ? 0.4 : 0.25

func switchDesktop(right: Bool) {
    // All three phases or none: a gesture cut short leaves the Dock mid-swipe on a blank desktop.
    let phases: [DesktopSwitch.Phase] = [.began, .changed, .ended]
    let events = phases.compactMap { dockSwipeEvent($0, right: right) }
    guard events.count == phases.count else { return }
    if let list = desktops() {
        var current = list.current
        if let landed, landed.display == list.display, Date().timeIntervalSince(landed.at) < landedTrusted { current = landed.index }
        guard let target = DesktopSwitch.target(from: current, of: list.count, right: right) else { return }
        landed = (target, list.display, Date())
    }
    for event in events {
        event.post(tap: .cgSessionEventTap)
        // macOS 27 wants each paired with a gesture event.
        if needsPayload, let companion = CGEvent(source: nil) {
            companion.setIntegerValueField(Field.eventType, value: gesture)
            companion.setIntegerValueField(.eventSourceUserData, value: ownTag)
            companion.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Control-Left/Right

// macOS's own animated Control-arrow shortcuts (79 left, 81 right) would take the keys first:
// off while this runs, and back as the user has them when it quits.
func userHasShortcut(_ id: Int) -> Bool {
    let shortcuts = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    return ((shortcuts?[String(id)] as? [String: Any])?["enabled"] as? NSNumber)?.boolValue ?? true
}

func restoreShortcuts() {
    for id in [79, 81] { _ = setSymbolicHotKey(Int32(id), userHasShortcut(id)) }
}

func takeControlArrows() {
    for id in [79, 81] { _ = setSymbolicHotKey(Int32(id), false) }
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        let right = id.id == 2
        MainActor.assumeIsolated { switchDesktop(right: right) }
        return noErr
    }, 1, &pressed, nil, nil)
    for (id, key) in [(UInt32(1), kVK_LeftArrow), (UInt32(2), kVK_RightArrow)] {
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(key), UInt32(controlKey), EventHotKeyID(signature: OSType(ownTag), id: id), GetApplicationEventTarget(), 0, &ref) != noErr {
            log("Control-arrow is taken by another app")
        }
    }
}

// MARK: - The swipe

var tracker = SwipeTracker()
var tap: CFMachPort?

/// Whether the event goes on; `SwipeTracker` decides for a horizontal swipe.
func passes(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tracker.reset()
        reenableTap()
        return true
    }
    if event.getIntegerValueField(.eventSourceUserData) == ownTag { return true }
    let kind = event.getIntegerValueField(Field.eventType)
    if kind == gesture { return tracker.passesCompanion }
    guard kind == dockControl, event.getIntegerValueField(Field.hidType) == dockSwipe,
          event.getIntegerValueField(Field.motion) == horizontal else { return true }
    let verdict = tracker.swipe(phase: event.getIntegerValueField(Field.phase), progress: event.getDoubleValueField(Field.progress),
                                velocity: event.getDoubleValueField(Field.velocityX), passEnd: needsPayload)
    if let right = verdict.switchRight { switchDesktop(right: right) }
    if verdict.emptied {
        for field in [Field.velocityX, Field.velocityY, Field.progress] { event.setDoubleValueField(field, value: 0) }
    }
    return verdict.passes
}

func watchSwipes() {
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: CGEventMask(1) << gesture | CGEventMask(1) << dockControl,
                            callback: { _, type, event, _ in
                                MainActor.assumeIsolated { passes(type, event) } ? Unmanaged.passUnretained(event) : nil
                            }, userInfo: nil)
    guard let port = tap else { return log("could not watch the swipe; Control-arrow still switches") }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    // macOS can turn a tap off without telling it, under load.
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
        MainActor.assumeIsolated { reenableTap() }
    }
}

func reenableTap() {
    if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
}

// MARK: - The empty-desktop guard

// Landing on a desktop with no windows, macOS activates some other app, which orders in its
// window from another desktop, and the Dock follows that window there about 400 ms later. Made
// active itself the moment it lands, a windowless app leaves nothing to follow. It must be on
// landing (before, the landing undoes it) and it must be windowless (Finder has a window to
// follow); turning the Dock's follow off would also stop a Dock icon taking you to its window.
func hasWindows(_ space: UInt64) -> Bool {
    let windows = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { $0[kCGWindowLayer as String] as? Int == 0 }
        .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    guard !windows.isEmpty else { return false }
    return takeArray(copySpacesForWindows(connection, 0x7, windows as CFArray)).contains { ($0 as? NSNumber)?.uint64Value == space }
}

func guardEmptyDesktops() {
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { arrived() }
    }
}

func arrived() {
    if !hasWindows(activeSpace(connection)) { NSApp.activate(ignoringOtherApps: true) }
}

// MARK: - Running, and quitting with what started it

func quit() -> Never {
    restoreShortcuts()
    exit(0)
}

var watchers: [any DispatchSourceProtocol] = []

/// Quits on a signal, and when what started it goes, however it goes; under launchd (parent
/// 1) it runs on.
func quitWithParent() {
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { quit() } }
        source.resume()
        watchers.append(source)
    }
    let parent = getppid()
    guard parent > 1 else { return }
    let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { quit() } }
    source.resume()
    watchers.append(source)
    if getppid() != parent { quit() }
}

@main
enum Switcher {
    static func main() {
        guard DesktopSwitch.isAvailable(major: version.majorVersion, minor: version.minorVersion) else {
            log("needs macOS 26.6 or later")
            exit(4)
        }
        guard AXIsProcessTrusted() else {
            log("needs Accessibility")
            exit(3)
        }
        quitWithParent()
        takeControlArrows()
        watchSwipes()
        guardEmptyDesktops()
        // An accessory app: no Dock icon or menu, but able to become active, which the guard needs.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
