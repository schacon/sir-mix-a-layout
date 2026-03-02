@preconcurrency import AppKit
import Carbon.HIToolbox
import QuartzCore

struct AppConfig {
    static let activeOffset = CGPoint(x: 120, y: 120)
    static let activeSize = CGSize(width: 1320, height: 860)
    static let slotSize = CGSize(width: 200, height: 200)
    static let slotStartX: CGFloat = 50
    static let slotStartY: CGFloat = 50
    static let slotVerticalGap: CGFloat = 50
    static let animationDuration: CFTimeInterval = 0.22
    static let maxSlots = 5
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

    func visibleWindows(limit: Int) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        var seen = Set<String>()

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated else {
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let appWindows = copyWindowListAttribute(appElement, attribute: kAXWindowsAttribute) else {
                continue
            }

            for window in appWindows {
                guard isMinimized(window) == false,
                      let frame = frame(of: window),
                      frame.width > 80,
                      frame.height > 80,
                      intersectsAnyVisibleScreen(frame) else {
                    continue
                }

                let id = windowID(of: window)
                if seen.insert(id).inserted {
                    windows.append(window)
                }

                if windows.count >= limit {
                    return windows
                }
            }
        }

        return windows
    }

    func windowID(of window: AXUIElement) -> String {
        let pid = pid(of: window)
        if let windowNumber = copyIntAttribute(window, attribute: "AXWindowNumber") {
            return "\(pid):\(windowNumber)"
        }
        return "\(pid):\(ObjectIdentifier(window).hashValue)"
    }

    func pid(of window: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return pid
    }

    @discardableResult
    func raise(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
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

    private func intersectsAnyVisibleScreen(_ frame: CGRect) -> Bool {
        for screen in NSScreen.screens where screen.visibleFrame.intersects(frame) {
            return true
        }
        return false
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

    private func copyIntAttribute(_ element: AXUIElement, attribute: String) -> Int? {
        guard let value = copyAttribute(element, attribute: attribute) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
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
    final class ManagedWindowState {
        let id: String
        let window: AXUIElement
        let originalFrame: CGRect
        let originalMinimized: Bool
        var slotIndex: Int?

        init(id: String, window: AXUIElement, originalFrame: CGRect, originalMinimized: Bool, slotIndex: Int?) {
            self.id = id
            self.window = window
            self.originalFrame = originalFrame
            self.originalMinimized = originalMinimized
            self.slotIndex = slotIndex
        }
    }

    private let hotkeys: HotkeyManager
    private let ax = AXWindowService()
    private let animator = WindowAnimator()
    private var modeEnabled = false
    private var managedWindows: [String: ManagedWindowState] = [:]
    private var slotWindowIDs: [String?] = []
    private var activeWindowID: String?

    private let shiftCmdModifier: UInt32 = UInt32(shiftKey | cmdKey)
    private let keybindings: [String]

    init() throws {
        hotkeys = try HotkeyManager()
        keybindings = LayoutController.buildKeybindingDescriptions()
        try registerHotkeys()
    }

    func startupKeybindingsText() -> String {
        keybindings.joined(separator: "\n")
    }

    private static func buildKeybindingDescriptions() -> [String] {
        [
            "Shift+Cmd+P: Toggle layout mode on/off",
            "Shift+Cmd+O: Minimize active managed window into an empty slot",
            "Shift+Cmd+H/J/K/L/;: Move slot 1..5 window to active area",
            "Shift+Cmd+1..9: Swap active window with slot"
        ]
    }

    private func registerHotkeys() throws {
        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: shiftCmdModifier)
        ) { [weak self] in
            Task { @MainActor in
                self?.toggleMode()
            }
        }

        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: shiftCmdModifier)
        ) { [weak self] in
            Task { @MainActor in
                self?.minimizeActiveToSlot()
            }
        }

        let slotActivationKeyCodes: [UInt32] = [
            UInt32(kVK_ANSI_H),
            UInt32(kVK_ANSI_J),
            UInt32(kVK_ANSI_K),
            UInt32(kVK_ANSI_L),
            UInt32(kVK_ANSI_Semicolon)
        ]

        for (index, keyCode) in slotActivationKeyCodes.enumerated() {
            try hotkeys.register(
                KeyCombo(keyCode: keyCode, modifiers: shiftCmdModifier)
            ) { [weak self] in
                Task { @MainActor in
                    self?.activateSlot(index)
                }
            }
        }

        let swapKeyCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]

        for (index, keyCode) in swapKeyCodes.enumerated() {
            try hotkeys.register(
                KeyCombo(keyCode: keyCode, modifiers: shiftCmdModifier)
            ) { [weak self] in
                Task { @MainActor in
                    self?.swapActiveWithSlot(index)
                }
            }
        }
    }

    private func toggleMode() {
        if modeEnabled {
            exitMode()
        } else {
            enterMode()
        }
    }

    private func enterMode() {
        guard !modeEnabled else {
            return
        }

        let discovered = ax.visibleWindows(limit: AppConfig.maxSlots)
        var windows: [(window: AXUIElement, frame: CGRect, minimized: Bool, id: String)] = []
        var seen = Set<String>()

        for window in discovered {
            guard let frame = ax.frame(of: window) else {
                continue
            }

            let id = ax.windowID(of: window)
            if seen.insert(id).inserted {
                let minimized = ax.isMinimized(window) ?? false
                windows.append((window, frame, minimized, id))
            }
        }

        guard !windows.isEmpty else {
            print("No visible windows were found to slot.")
            return
        }

        modeEnabled = true
        managedWindows.removeAll()
        activeWindowID = nil
        slotWindowIDs = Array(repeating: nil, count: windows.count)
        let slotFrames = currentSlotFrames()

        for (index, item) in windows.enumerated() {
            let state = ManagedWindowState(
                id: item.id,
                window: item.window,
                originalFrame: item.frame,
                originalMinimized: item.minimized,
                slotIndex: index
            )
            managedWindows[item.id] = state
            slotWindowIDs[index] = item.id
            animateWindow(item.window, to: slotFrames[index])
        }

        print("Layout mode ON (\(windows.count) windows slotted).")
    }

    private func exitMode() {
        guard modeEnabled else {
            return
        }

        let restoring = Array(managedWindows.values)
        modeEnabled = false
        activeWindowID = nil
        managedWindows.removeAll()
        slotWindowIDs.removeAll()

        for state in restoring {
            _ = ax.setMinimized(state.window, false)
            animateWindow(state.window, to: state.originalFrame)
        }

        Task { @MainActor [ax] in
            try? await Task.sleep(nanoseconds: UInt64((AppConfig.animationDuration + 0.05) * 1_000_000_000))
            for state in restoring where state.originalMinimized {
                _ = ax.setMinimized(state.window, true)
            }
        }

        print("Layout mode OFF (windows restored).")
    }

    private func activateSlot(_ index: Int) {
        guard modeEnabled,
              index >= 0,
              index < slotWindowIDs.count,
              let incomingID = slotWindowIDs[index],
              let incomingState = managedWindows[incomingID] else {
            return
        }

        slotWindowIDs[index] = nil

        if let currentActiveID = activeWindowID,
           currentActiveID != incomingID,
           let currentActiveState = managedWindows[currentActiveID] {
            if let emptySlot = firstEmptySlotIndex() {
                slotWindowIDs[emptySlot] = currentActiveID
                currentActiveState.slotIndex = emptySlot
                let slotFrames = currentSlotFrames()
                animateWindow(currentActiveState.window, to: slotFrames[emptySlot])
            }
        }

        incomingState.slotIndex = nil
        activeWindowID = incomingID
        bringWindowForward(incomingState.window)
        animateWindow(incomingState.window, to: activeFrame())
    }

    private func minimizeActiveToSlot() {
        guard modeEnabled,
              let activeWindowID,
              let activeState = managedWindows[activeWindowID],
              let emptySlot = firstEmptySlotIndex() else {
            return
        }

        slotWindowIDs[emptySlot] = activeWindowID
        activeState.slotIndex = emptySlot
        self.activeWindowID = nil

        let slotFrames = currentSlotFrames()
        animateWindow(activeState.window, to: slotFrames[emptySlot])
    }

    private func swapActiveWithSlot(_ index: Int) {
        guard modeEnabled,
              index >= 0,
              index < slotWindowIDs.count,
              let currentActiveID = activeWindowID,
              let currentActive = managedWindows[currentActiveID],
              let slotID = slotWindowIDs[index],
              slotID != currentActiveID,
              let slotState = managedWindows[slotID] else {
            return
        }

        slotWindowIDs[index] = currentActiveID
        currentActive.slotIndex = index
        activeWindowID = slotID
        slotState.slotIndex = nil

        let slotFrames = currentSlotFrames()
        animateWindow(currentActive.window, to: slotFrames[index])
        bringWindowForward(slotState.window)
        animateWindow(slotState.window, to: activeFrame())
    }

    private func bringWindowForward(_ window: AXUIElement) {
        _ = ax.setMinimized(window, false)
        let pid = ax.pid(of: window)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        _ = ax.raise(window)
    }

    private func firstEmptySlotIndex() -> Int? {
        slotWindowIDs.firstIndex(where: { $0 == nil })
    }

    private func animateWindow(_ window: AXUIElement, to target: CGRect) {
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

    private func currentSlotFrames() -> [CGRect] {
        slotFrames(count: slotWindowIDs.count, in: workspaceFrame())
    }

    private func activeFrame() -> CGRect {
        let screenFrame = workspaceFrame()
        let proposed = CGRect(
            x: screenFrame.origin.x + AppConfig.activeOffset.x,
            y: screenFrame.origin.y + AppConfig.activeOffset.y,
            width: AppConfig.activeSize.width,
            height: AppConfig.activeSize.height
        )
        return clamp(rect: proposed, to: screenFrame)
    }

    private func slotFrames(count: Int, in screenFrame: CGRect) -> [CGRect] {
        guard count > 0 else {
            return []
        }

        let slotWidth = AppConfig.slotSize.width
        let slotHeight = AppConfig.slotSize.height
        let gap = AppConfig.slotVerticalGap
        let x = screenFrame.minX + AppConfig.slotStartX
        var frames: [CGRect] = []
        frames.reserveCapacity(count)

        for index in 0..<count {
            let y = screenFrame.minY + AppConfig.slotStartY + (CGFloat(index) * (slotHeight + gap))
            let frame = clamp(
                rect: CGRect(x: x, y: y, width: slotWidth, height: slotHeight),
                to: screenFrame
            )
            frames.append(frame)
        }

        return frames
    }

    private func workspaceFrame() -> CGRect {
        NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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
            if let controller {
                print("Active keybindings:")
                print(controller.startupKeybindingsText())
            }
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
