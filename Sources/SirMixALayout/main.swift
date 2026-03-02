@preconcurrency import AppKit
import Carbon.HIToolbox
import QuartzCore

struct AppConfig {
    static let targetOffset = CGPoint(x: 120, y: 80)
    static let targetSize = CGSize(width: 1320, height: 860)
    static let animationDuration: CFTimeInterval = 0.22
    static let slideDistance: CGFloat = 240
    static let activationDelay: TimeInterval = 0.14

    static let hotkeyModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
}

struct KeyCombo {
    let keyCode: UInt32
    let modifiers: UInt32
}

enum HotkeyError: Error {
    case installHandler(OSStatus)
    case register(OSStatus)
}

final class HotkeyManager {
    typealias Handler = () -> Void

    private var nextID: UInt32 = 1
    private var handlers: [UInt32: Handler] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            HotkeyManager.eventCallback,
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        guard status == noErr else {
            throw HotkeyError.installHandler(status)
        }
    }

    deinit {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(_ combo: KeyCombo, handler: @escaping Handler) throws {
        let id = nextID
        nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("SMLY"), id: id)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            throw HotkeyError.register(status)
        }

        handlers[id] = handler
        hotKeyRefs.append(hotKeyRef)
    }

    private func handleEvent(id: UInt32) {
        handlers[id]?()
    }

    private static let eventCallback: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        manager.handleEvent(id: hotKeyID.id)
        return noErr
    }

    private func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

final class AXWindowService {
    private let systemWide = AXUIElementCreateSystemWide()

    func focusedWindow() -> AXUIElement? {
        copyElementAttribute(systemWide, attribute: kAXFocusedWindowAttribute)
    }

    func focusedAppPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func firstWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        if let focused = copyElementAttribute(appElement, attribute: kAXFocusedWindowAttribute),
           isMinimized(focused) == false {
            return focused
        }

        guard let windows = copyWindowListAttribute(appElement, attribute: kAXWindowsAttribute) else {
            return nil
        }

        for window in windows where isMinimized(window) == false {
            return window
        }

        return windows.first
    }

    func nextAppPID(after currentPID: pid_t) -> pid_t? {
        let ordered = visibleAppOrder()
        if let index = ordered.firstIndex(of: currentPID) {
            for pid in ordered[(index + 1)...] where isSwitchableApp(pid: pid) {
                return pid
            }
        }

        for pid in ordered where pid != currentPID && isSwitchableApp(pid: pid) {
            return pid
        }

        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != currentPID {
            if app.activationPolicy == .regular && !app.isTerminated {
                return app.processIdentifier
            }
        }

        return nil
    }

    func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = copyAXValueAttribute(window, attribute: kAXPositionAttribute, type: .cgPoint),
              let sizeValue = copyAXValueAttribute(window, attribute: kAXSizeAttribute, type: .cgSize) else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    func setFrame(of window: AXUIElement, to rect: CGRect) -> Bool {
        var origin = rect.origin
        var size = rect.size

        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return positionStatus == .success && sizeStatus == .success
    }

    @discardableResult
    func setMinimized(_ window: AXUIElement, _ minimized: Bool) -> Bool {
        let value = NSNumber(value: minimized)
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value) == .success
    }

    func isMinimized(_ window: AXUIElement) -> Bool? {
        copyBoolAttribute(window, attribute: kAXMinimizedAttribute)
    }

    private func isSwitchableApp(pid: pid_t) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }

        return app.activationPolicy == .regular && !app.isTerminated
    }

    private func visibleAppOrder() -> [pid_t] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seen = Set<pid_t>()
        var ordered: [pid_t] = []

        for info in windowInfo {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            let pid = pid_t(pidNumber.int32Value)
            if seen.insert(pid).inserted {
                ordered.append(pid)
            }
        }

        return ordered
    }

    private func copyAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyWindowListAttribute(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        guard let value = copyAttribute(element, attribute: attribute) else {
            return nil
        }
        if let windows = value as? [AXUIElement] {
            return windows
        }
        return nil
    }

    private func copyAXValueAttribute(_ element: AXUIElement, attribute: String, type: AXValueType) -> AXValue? {
        guard let value = copyAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == type else {
            return nil
        }
        return axValue
    }

    private func copyBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute: attribute) else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            let boolValue = unsafeDowncast(value, to: CFBoolean.self)
            return CFBooleanGetValue(boolValue)
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return nil
    }
}

final class WindowAnimator {
    func animate(window: AXUIElement, from start: CGRect, to end: CGRect, duration: TimeInterval, apply: @escaping (AXUIElement, CGRect) -> Void, completion: (() -> Void)? = nil) {
        guard duration > 0 else {
            apply(window, end)
            completion?()
            return
        }

        let startTime = CACurrentMediaTime()

        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(1.0, elapsed / duration)
            let eased = t * t * (3 - (2 * t))
            let frame = Self.interpolate(from: start, to: end, progress: eased)
            apply(window, frame)

            if t >= 1.0 {
                timer.invalidate()
                completion?()
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func interpolate(from: CGRect, to: CGRect, progress: Double) -> CGRect {
        let p = CGFloat(progress)

        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            a + (b - a) * p
        }

        return CGRect(
            x: mix(from.origin.x, to.origin.x),
            y: mix(from.origin.y, to.origin.y),
            width: mix(from.size.width, to.size.width),
            height: mix(from.size.height, to.size.height)
        )
    }
}

@MainActor
final class LayoutController {
    private let hotkeys: HotkeyManager
    private let ax = AXWindowService()
    private let animator = WindowAnimator()

    init() throws {
        hotkeys = try HotkeyManager()
        try registerHotkeys()
    }

    private func registerHotkeys() throws {
        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: AppConfig.hotkeyModifiers)
        ) { [weak self] in
            Task { @MainActor in
                self?.moveFocusedWindowToPreset()
            }
        }

        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: AppConfig.hotkeyModifiers)
        ) { [weak self] in
            Task { @MainActor in
                self?.minimizeFocusedWindowAnimated()
            }
        }

        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: AppConfig.hotkeyModifiers)
        ) { [weak self] in
            Task { @MainActor in
                self?.switchFocusedApp()
            }
        }
    }

    private func moveFocusedWindowToPreset() {
        guard let window = ax.focusedWindow() else {
            return
        }

        let target = targetFrame(for: ax.frame(of: window))

        guard let start = ax.frame(of: window) else {
            _ = ax.setFrame(of: window, to: target)
            return
        }

        animator.animate(
            window: window,
            from: start,
            to: target,
            duration: AppConfig.animationDuration,
            apply: { [ax] window, rect in
                _ = ax.setFrame(of: window, to: rect)
            }
        )
    }

    private func minimizeFocusedWindowAnimated() {
        guard let window = ax.focusedWindow() else {
            return
        }

        guard let start = ax.frame(of: window) else {
            _ = ax.setMinimized(window, true)
            return
        }

        let endWidth = max(140, start.width * 0.22)
        let endHeight = max(90, start.height * 0.22)
        let endX = start.midX - (endWidth / 2)
        let endY = max(0, start.minY - 40)
        let end = CGRect(x: endX, y: endY, width: endWidth, height: endHeight)

        animator.animate(
            window: window,
            from: start,
            to: end,
            duration: AppConfig.animationDuration,
            apply: { [ax] window, rect in
                _ = ax.setFrame(of: window, to: rect)
            },
            completion: { [ax] in
                _ = ax.setMinimized(window, true)
            }
        )
    }

    private func switchFocusedApp() {
        guard let currentPID = ax.focusedAppPID(),
              let nextPID = ax.nextAppPID(after: currentPID) else {
            return
        }

        let activateNext: () -> Void = { [weak self] in
            self?.activateAndSlideInApp(pid: nextPID)
        }

        guard let currentWindow = ax.focusedWindow(),
              let start = ax.frame(of: currentWindow) else {
            activateNext()
            return
        }

        let end = CGRect(x: start.origin.x - AppConfig.slideDistance, y: start.origin.y, width: start.width, height: start.height)

        animator.animate(
            window: currentWindow,
            from: start,
            to: end,
            duration: AppConfig.animationDuration,
            apply: { [ax] window, rect in
                _ = ax.setFrame(of: window, to: rect)
            },
            completion: { [ax] in
                _ = ax.setMinimized(currentWindow, true)
                activateNext()
            }
        )
    }

    private func activateAndSlideInApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }

        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppConfig.activationDelay * 1_000_000_000))
            guard let self,
                  let window = self.ax.firstWindow(for: pid) else {
                return
            }

            _ = self.ax.setMinimized(window, false)

            let target = self.targetFrame(for: self.ax.frame(of: window))
            let start = CGRect(x: target.origin.x + AppConfig.slideDistance, y: target.origin.y, width: target.width, height: target.height)
            _ = self.ax.setFrame(of: window, to: start)

            self.animator.animate(
                window: window,
                from: start,
                to: target,
                duration: AppConfig.animationDuration,
                apply: { [ax = self.ax] window, rect in
                    _ = ax.setFrame(of: window, to: rect)
                }
            )
        }
    }

    private func targetFrame(for currentFrame: CGRect?) -> CGRect {
        let screenFrame = preferredVisibleFrame(for: currentFrame)
        let proposed = CGRect(
            x: screenFrame.origin.x + AppConfig.targetOffset.x,
            y: screenFrame.origin.y + AppConfig.targetOffset.y,
            width: AppConfig.targetSize.width,
            height: AppConfig.targetSize.height
        )

        return clamp(rect: proposed, to: screenFrame)
    }

    private func preferredVisibleFrame(for currentFrame: CGRect?) -> CGRect {
        if let currentFrame {
            for screen in NSScreen.screens where screen.visibleFrame.intersects(currentFrame) {
                return screen.visibleFrame
            }
        }

        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func clamp(rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)

        let xMax = bounds.maxX - width
        let yMax = bounds.maxY - height

        let x = min(max(rect.origin.x, bounds.origin.x), xMax)
        let y = min(max(rect.origin.y, bounds.origin.y), yMax)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LayoutController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let promptOptions = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(promptOptions)

        if !trusted {
            print("Accessibility permission is required. Grant it in System Settings -> Privacy & Security -> Accessibility.")
            openAccessibilitySettings()
        }

        do {
            controller = try LayoutController()
            print("sir-mix-a-layout is running.")
            print("Hotkeys: Ctrl+Option+Cmd+W place, Ctrl+Option+Cmd+M minimize, Ctrl+Option+Cmd+Tab switch app.")
        } catch {
            fputs("Failed to start hotkey manager: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        _ = NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
