import AppKit
import ApplicationServices
import os
import Security

/// A three-finger click or tap on the trackpad becomes a middle click (opens links in a new tab,
/// closes tabs, pastes in terminals), like the MiddleClick app.
///
/// Fingers are counted with the private MultitouchSupport framework. A click made with three
/// fingers is turned into a middle click by an event tap; a quick tap posts one. Both need the
/// Accessibility permission.
@MainActor
final class MiddleClickEmulator: ObservableObject {
    static let shared = MiddleClickEmulator()

    /// Without the Accessibility permission nothing can be changed or posted.
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var devices: CFArray?
    private var trustPollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// The signing requirement we last asked the permission for. A grant belongs to one signature:
    /// after it changes, the old entry in System Settings looks enabled but no longer applies.
    private static let promptedKey = "middleClickAccessPromptedFor"

    private init() {
        // Sleep drops the trackpad's callbacks; re-register them on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let emulator = MiddleClickEmulator.shared
                guard emulator.devices != nil else { return }
                emulator.stopTouches()
                emulator.startTouches()
            }
        }
    }

    /// Starts or stops according to Settings; call on launch and whenever they change.
    func apply() {
        touches.withLock { $0.tapEnabled = AppSettings.middleClickTapEnabled }
        if AppSettings.middleClickEnabled {
            start()
        } else {
            stop()
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Start / stop

    private func start() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted else {
            // Ask once per signature with the system prompt; after that Settings shows a button instead.
            let requirement = Self.signingRequirement()
            if UserDefaults.standard.string(forKey: Self.promptedKey) != requirement {
                UserDefaults.standard.set(requirement, forKey: Self.promptedKey)
                NSLog("MiddleClick: no Accessibility access, asking for it")
                Self.resetStaleAccess()
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            waitForTrust()
            return
        }
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        if eventTap == nil { startEventTap() }
        if devices == nil { startTouches() }
    }

    /// Identifies the signature the permission is granted to; stable across builds signed with the
    /// local certificate (see build.sh), different for every ad-hoc build.
    private static func signingRequirement() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return "unknown" }
        return text as String
    }

    /// Removes our entry granted to a previous signature, so the prompt adds a fresh one
    /// instead of the user having to delete the stale one by hand.
    private static func resetStaleAccess() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        try? process.run()
        process.waitUntilExit()
    }

    private func stop() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        stopTouches()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        middleClickTap = nil
    }

    /// The permission is granted in System Settings while we run; there's no notification for it.
    private func waitForTrust() {
        guard trustPollTimer == nil else { return }
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let emulator = MiddleClickEmulator.shared
                guard AXIsProcessTrusted() else { return }
                emulator.start()
            }
        }
    }

    private func startEventTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            NSLog("MiddleClick: couldn't create the event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        middleClickTap = tap
        NSLog("MiddleClick: event tap started")
    }

    private func startTouches() {
        guard let api = Multitouch.api,
              let list = api.createList()?.takeRetainedValue()
        else { return }
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            api.register(pointer, contactCallback)
            _ = api.start(pointer, 0)
        }
        devices = list
        NSLog("MiddleClick: listening to %d trackpad(s)", CFArrayGetCount(list))
    }

    private func stopTouches() {
        guard let api = Multitouch.api, let devices else { return }
        for index in 0..<CFArrayGetCount(devices) {
            guard let device = CFArrayGetValueAtIndex(devices, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            api.unregister(pointer, contactCallback)
            _ = api.stop(pointer)
        }
        self.devices = nil
        touches.withLock { $0 = TouchState(tapEnabled: $0.tapEnabled) }
    }
}

// MARK: - Touch state

/// Updated from the multitouch thread and read by the event tap on the main thread.
private struct TouchState {
    /// A touch that may turn out to be a tap.
    struct Tap {
        let start: Double
        let origin: SIMD2<Float>
        var last: SIMD2<Float>
        var isCancelled = false
    }

    var tapEnabled = true
    var fingers = 0
    var tap: Tap?
    /// A click that started with three fingers is being turned into a middle click.
    var isConvertingClick = false

    static let requiredFingers = 3
    /// Seconds from touch to lift, like MiddleClick's default 300 ms.
    static let maxTapDuration = 0.3
    /// Travel of the fingers' center, as a fraction of the trackpad; more is a swipe, not a tap.
    static let maxTapDistance: Float = 0.05

    /// Returns true when the fingers were lifted after a three-finger tap.
    mutating func update(fingers count: Int, center: SIMD2<Float>, time: Double) -> Bool {
        fingers = count
        switch count {
        case 0:
            defer { tap = nil }
            guard tapEnabled, let tap, !tap.isCancelled, time - tap.start <= Self.maxTapDuration else { return false }
            let travel = tap.last - tap.origin
            return (travel * travel).sum().squareRoot() <= Self.maxTapDistance
        case Self.requiredFingers:
            if tap == nil {
                tap = Tap(start: time, origin: center, last: center)
            } else {
                tap?.last = center
            }
        case let more where more > Self.requiredFingers:
            tap?.isCancelled = true
        default:
            // Fingers lifting one by one: the remaining ones' center would jump, so keep the last one.
            break
        }
        return false
    }
}

private let touches = OSAllocatedUnfairLock(initialState: TouchState())

/// Needed by the event tap callback to re-enable itself; only touched on the main thread.
nonisolated(unsafe) private var middleClickTap: CFMachPort?

private func postMiddleClick() {
    let location = CGEvent(source: nil)?.location ?? .zero
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center)?
            .post(tap: .cghidEventTap)
    }
}

// MARK: - Callbacks

/// MultitouchSupport's frame callback: `int (*)(MTDeviceRef, Finger *, int, double, int)`.
private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private let contactCallback: ContactCallback = { _, data, count, timestamp, _ in
    let fingers = Int(count)
    var center = SIMD2<Float>(0, 0)
    if let data, fingers > 0 {
        for index in 0..<fingers {
            // Finger is 96 bytes; its normalized position (two floats) starts at byte 32.
            let base = index * Multitouch.fingerSize + Multitouch.positionOffset
            center += SIMD2(data.load(fromByteOffset: base, as: Float.self), data.load(fromByteOffset: base + 4, as: Float.self))
        }
        center /= Float(fingers)
    }
    let finalCenter = center
    if touches.withLock({ $0.update(fingers: fingers, center: finalCenter, time: timestamp) }) {
        postMiddleClick()
    }
    return 0
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let middleClickTap { CGEvent.tapEnable(tap: middleClickTap, enable: true) }
    case .leftMouseDown:
        let isMiddle = touches.withLock { state -> Bool in
            guard state.fingers == TouchState.requiredFingers else { return false }
            // The press is the click; lifting the fingers afterwards mustn't add a tap.
            state.tap?.isCancelled = true
            state.isConvertingClick = true
            return true
        }
        if isMiddle { makeMiddle(event, as: .otherMouseDown) }
    case .leftMouseDragged:
        if touches.withLock({ $0.isConvertingClick }) { makeMiddle(event, as: .otherMouseDragged) }
    case .leftMouseUp:
        let wasConverting = touches.withLock { state -> Bool in
            defer { state.isConvertingClick = false }
            return state.isConvertingClick
        }
        if wasConverting { makeMiddle(event, as: .otherMouseUp) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

private func makeMiddle(_ event: CGEvent, as type: CGEventType) {
    event.type = type
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
}

// MARK: - MultitouchSupport

/// The private framework's few functions we need, looked up at runtime.
private struct Multitouch {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32

    static let fingerSize = 96
    static let positionOffset = 32

    let createList: CreateList
    let register: Register
    let unregister: Register
    let start: Start
    let stop: Stop

    static let api: Multitouch? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop")
        else {
            NSLog("MiddleClick: MultitouchSupport isn't available")
            return nil
        }
        return Multitouch(
            createList: unsafeBitCast(createList, to: CreateList.self),
            register: unsafeBitCast(register, to: Register.self),
            unregister: unsafeBitCast(unregister, to: Register.self),
            start: unsafeBitCast(start, to: Start.self),
            stop: unsafeBitCast(stop, to: Stop.self)
        )
    }()
}
