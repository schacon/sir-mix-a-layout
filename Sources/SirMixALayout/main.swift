@preconcurrency import AppKit
import Carbon.HIToolbox
import QuartzCore

struct AppConfig {
    static let slotSize = CGSize(width: 300, height: 300)
    static let maxSlots = 4
}

struct LayoutRuntimeConfig {
    var slotVerticalGap: CGFloat = 100
    var slotTopOffset: CGFloat = 50
    var slotLeftOffset: CGFloat = 50
    var activeLeftOffset: CGFloat = 500
    var activeTopOffset: CGFloat = 120
    var activeAreaWidth: CGFloat = 1320
    var activeAreaHeight: CGFloat = 860
    var activeSplitGap: CGFloat = 20
    var controlPanelLeftOffset: CGFloat = 50
    var controlPanelTopOffset: CGFloat = 20
    var animationDuration: TimeInterval = 0.29

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sir-mix-a-layout")
            .appendingPathComponent("config.toml")
    }

    static func loadFromDisk() -> LayoutRuntimeConfig {
        let defaults = LayoutRuntimeConfig()
        let url = fileURL
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try defaultFileContents().write(to: url, atomically: true, encoding: .utf8)
                print("Created default config at \(url.path)")
            } catch {
                print("Failed to create config at \(url.path): \(error). Using built-in defaults.")
            }
            return defaults
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return parse(contents: contents, defaults: defaults)
        } catch {
            print("Failed to read config at \(url.path): \(error). Using built-in defaults.")
            return defaults
        }
    }

    static func defaultFileContents() -> String {
        """
        # sir-mix-a-layout runtime config
        # Read each time mode is enabled (Ctrl+Cmd+P).

        slot_vertical_gap = 100
        slot_top_offset = 50
        slot_left_offset = 50

        active_left_offset = 500
        active_top_offset = 120
        active_area_width = 1320
        active_area_height = 860
        active_split_gap = 20

        control_panel_left_offset = 50
        control_panel_top_offset = 20

        animation_duration = 0.29
        """
    }

    private static func parse(contents: String, defaults: LayoutRuntimeConfig) -> LayoutRuntimeConfig {
        var parsed = defaults

        for (lineNumber, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") {
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                print("Ignoring config line \(lineNumber + 1): missing '='")
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var valueText = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let commentStart = valueText.firstIndex(of: "#") {
                valueText = valueText[..<commentStart].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !valueText.isEmpty, let value = Double(valueText) else {
                print("Ignoring config line \(lineNumber + 1): non-numeric value for '\(key)'")
                continue
            }

            let number = CGFloat(value)
            switch key {
            case "slot_vertical_gap":
                parsed.slotVerticalGap = max(0, number)
            case "slot_top_offset":
                parsed.slotTopOffset = number
            case "slot_left_offset":
                parsed.slotLeftOffset = number
            case "active_left_offset":
                parsed.activeLeftOffset = number
            case "active_top_offset":
                parsed.activeTopOffset = number
            case "active_area_width":
                parsed.activeAreaWidth = max(240, number)
            case "active_area_height":
                parsed.activeAreaHeight = max(120, number)
            case "active_split_gap":
                parsed.activeSplitGap = max(0, number)
            case "control_panel_left_offset":
                parsed.controlPanelLeftOffset = max(0, number)
            case "control_panel_right_offset":
                // Backward-compatible fallback for older configs.
                parsed.controlPanelLeftOffset = max(0, number)
            case "control_panel_top_offset":
                parsed.controlPanelTopOffset = max(0, number)
            case "animation_duration":
                parsed.animationDuration = max(0, TimeInterval(value))
            default:
                print("Ignoring unknown config key '\(key)' (line \(lineNumber + 1))")
            }
        }

        return parsed
    }
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
            if app.bundleIdentifier == "com.apple.finder" {
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

    func title(of window: AXUIElement) -> String? {
        copyAttribute(window, attribute: kAXTitleAttribute) as? String
    }

    func appName(of window: AXUIElement) -> String? {
        let windowPID = pid(of: window)
        return NSRunningApplication(processIdentifier: windowPID)?.localizedName
    }

    func appIcon(of window: AXUIElement) -> NSImage? {
        let windowPID = pid(of: window)
        return NSRunningApplication(processIdentifier: windowPID)?.icon
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
    func setPosition(of window: AXUIElement, to point: CGPoint) -> Bool {
        var origin = point
        guard let positionValue = AXValueCreate(.cgPoint, &origin) else {
            return false
        }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success
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
final class SlotPanelController: NSObject {
    enum Placement: Int {
        case full = 0
        case leftHalf = 1
        case rightHalf = 2
    }

    struct Item {
        let index: Int
        let shortcut: String
        let icon: NSImage?
        let enabled: Bool
        let activePlacement: Placement?
    }

    private let window: NSWindow
    private let stackView = NSStackView()
    private let minimizeAllButton = NSButton(title: "Minimize All", target: nil, action: nil)
    private let swapButton = NSButton(title: "Swap", target: nil, action: nil)
    private var shortcutLabels: [NSTextField] = []
    private var iconViews: [NSImageView] = []
    private var rowButtons: [[NSButton]] = []
    private let onSelect: (Int, Placement) -> Void
    private let onMinimizeAll: () -> Void
    private let onSwap: () -> Void

    init(slotCount: Int, onSelect: @escaping (Int, Placement) -> Void, onMinimizeAll: @escaping () -> Void, onSwap: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onMinimizeAll = onMinimizeAll
        self.onSwap = onSwap
        self.window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 100, height: 100),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Window Slots"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        minimizeAllButton.target = self
        minimizeAllButton.action = #selector(minimizeAllPressed)
        minimizeAllButton.bezelStyle = .rounded
        minimizeAllButton.setContentHuggingPriority(.required, for: .horizontal)
        swapButton.target = self
        swapButton.action = #selector(swapPressed)
        swapButton.bezelStyle = .rounded
        swapButton.setContentHuggingPriority(.required, for: .horizontal)
        let controlsRow = NSStackView()
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.distribution = .fill
        controlsRow.spacing = 6
        controlsRow.addArrangedSubview(minimizeAllButton)
        controlsRow.addArrangedSubview(swapButton)
        stackView.addArrangedSubview(controlsRow)

        for index in 0..<slotCount {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 6

            let iconView = NSImageView()
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 20),
                iconView.heightAnchor.constraint(equalToConstant: 20)
            ])
            row.addArrangedSubview(iconView)
            iconViews.append(iconView)

            let fullButton = makeButton(title: "Full", index: index, placement: .full)
            let leftButton = makeButton(title: "Left Half", index: index, placement: .leftHalf)
            let rightButton = makeButton(title: "Right Half", index: index, placement: .rightHalf)

            row.addArrangedSubview(fullButton)
            row.addArrangedSubview(leftButton)
            row.addArrangedSubview(rightButton)

            let shortcutLabel = NSTextField(labelWithString: "")
            shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(shortcutLabel)
            shortcutLabels.append(shortcutLabel)

            rowButtons.append([fullButton, leftButton, rightButton])
            stackView.addArrangedSubview(row)
        }

        resizeToFit()
    }

    func show(leftOffset: CGFloat, topOffset: CGFloat) {
        resizeToFit()
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.minX + leftOffset
            let frame = window.frame
            let y = visible.maxY - frame.height - topOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func update(items: [Item], canMinimizeAll: Bool, canSwap: Bool) {
        minimizeAllButton.isEnabled = canMinimizeAll
        swapButton.isEnabled = canSwap
        for index in 0..<shortcutLabels.count {
            shortcutLabels[index].stringValue = "Slot \(index + 1)"
            iconViews[index].image = nil
            for button in rowButtons[index] {
                button.isEnabled = false
                button.state = .off
            }
        }

        for item in items where item.index >= 0 && item.index < shortcutLabels.count {
            shortcutLabels[item.index].stringValue = item.shortcut
            iconViews[item.index].image = item.icon
            for (buttonIndex, button) in rowButtons[item.index].enumerated() {
                button.isEnabled = item.enabled
                button.state = item.activePlacement?.rawValue == buttonIndex ? .on : .off
            }
        }

        resizeToFit()
    }

    private func makeButton(title: String, index: Int, placement: Placement) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        button.tag = (index * 10) + placement.rawValue
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let index = sender.tag / 10
        let rawPlacement = sender.tag % 10
        guard let placement = Placement(rawValue: rawPlacement) else {
            return
        }
        onSelect(index, placement)
    }

    @objc private func minimizeAllPressed() {
        onMinimizeAll()
    }

    @objc private func swapPressed() {
        onSwap()
    }

    private func resizeToFit() {
        guard let contentView = window.contentView else {
            return
        }
        contentView.layoutSubtreeIfNeeded()
        let size = stackView.fittingSize
        if size.width > 0, size.height > 0 {
            window.setContentSize(size)
        }
    }
}

@MainActor
final class LayoutController {
    enum ActiveWidthMode {
        case half
        case full

        var label: String {
            switch self {
            case .half:
                return "half"
            case .full:
                return "full"
            }
        }
    }

    struct SlotAnchor {
        let rightX: CGFloat
        let y: CGFloat
    }

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
    private lazy var slotPanel: SlotPanelController = {
        SlotPanelController(slotCount: AppConfig.maxSlots, onSelect: { [weak self] index, placement in
            self?.placeSlot(index, placement: placement)
        }, onMinimizeAll: { [weak self] in
            self?.minimizeAllToSlots()
        }, onSwap: { [weak self] in
            self?.swapActiveWindows()
        })
    }()
    private let ax = AXWindowService()
    private let animator = WindowAnimator()
    private var modeEnabled = false
    private var managedWindows: [String: ManagedWindowState] = [:]
    private var slotWindowIDs: [String?] = []
    private var activeSlotIndex: Int?
    private var secondarySlotIndex: Int?
    private var activeWindowID: String?
    private var activeWidthMode: ActiveWidthMode = .half
    private var layoutConfig = LayoutRuntimeConfig()

    private let keybindings: [String]

    init() throws {
        hotkeys = try HotkeyManager()
        layoutConfig = LayoutRuntimeConfig.loadFromDisk()
        keybindings = LayoutController.buildKeybindingDescriptions()
        try registerHotkeys()
        refreshSlotPanel()
    }

    func startupKeybindingsText() -> String {
        keybindings.joined(separator: "\n")
    }

    private static func buildKeybindingDescriptions() -> [String] {
        [
            "Ctrl+Cmd+P: Toggle layout mode on/off",
            "Ctrl+Cmd+I: Toggle active window width (half/full)",
            "F1..F12: Slot panel actions (slot 1..4: Full/Left Half/Right Half)",
            "F13: Minimize All",
            "F14: Swap",
            "Slot panel appears in management mode; use Full/Left/Right buttons per slot and Minimize All"
        ]
    }

    private func registerHotkeys() throws {
        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | cmdKey))
        ) { [weak self] in
            Task { @MainActor in
                self?.toggleMode()
            }
        }

        try hotkeys.register(
            KeyCombo(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | cmdKey))
        ) { [weak self] in
            Task { @MainActor in
                self?.toggleActiveWidthMode()
            }
        }

        let panelActionKeyCodes: [UInt32] = [
            UInt32(kVK_F1),
            UInt32(kVK_F2),
            UInt32(kVK_F3),
            UInt32(kVK_F4),
            UInt32(kVK_F5),
            UInt32(kVK_F6),
            UInt32(kVK_F7),
            UInt32(kVK_F8),
            UInt32(kVK_F9),
            UInt32(kVK_F10),
            UInt32(kVK_F11),
            UInt32(kVK_F12),
            UInt32(kVK_F13),
            UInt32(kVK_F14)
        ]

        for (index, keyCode) in panelActionKeyCodes.enumerated() {
            try hotkeys.register(
                KeyCombo(keyCode: keyCode, modifiers: 0)
            ) { [weak self] in
                Task { @MainActor in
                    self?.performPanelAction(for: index)
                }
            }
        }
    }

    private func performPanelAction(for actionIndex: Int) {
        guard actionIndex >= 0 else {
            return
        }

        if actionIndex < AppConfig.maxSlots * 3 {
            let slotIndex = actionIndex / 3
            let placementIndex = actionIndex % 3
            let placement: SlotPanelController.Placement
            switch placementIndex {
            case 0:
                placement = .full
            case 1:
                placement = .leftHalf
            default:
                placement = .rightHalf
            }
            placeSlot(slotIndex, placement: placement)
            return
        }

        if actionIndex == AppConfig.maxSlots * 3 {
            minimizeAllToSlots()
            return
        }

        if actionIndex == (AppConfig.maxSlots * 3 + 1) {
            swapActiveWindows()
        }
    }

    private func toggleMode() {
        if modeEnabled {
            exitMode()
        } else {
            enterMode()
        }
    }

    private func toggleActiveWidthMode() {
        let nextMode: ActiveWidthMode = (activeWidthMode == .half) ? .full : .half
        if nextMode == .full,
           let secondaryIndex = secondarySlotIndex,
           secondaryIndex >= 0,
           secondaryIndex < slotWindowIDs.count,
           let secondaryID = slotWindowIDs[secondaryIndex],
           let secondaryState = managedWindows[secondaryID] {
            secondaryState.slotIndex = secondaryIndex
            animateToSlot(secondaryState.window, slotIndex: secondaryIndex)
            secondarySlotIndex = nil
        }

        activeWidthMode = nextMode
        print("Active width mode: \(activeWidthMode.label)")

        guard modeEnabled,
              let activeSlotIndex,
              let primaryID = slotWindowIDs[activeSlotIndex],
              let primaryState = managedWindows[primaryID] else {
            return
        }

        animateWindow(primaryState.window, to: activeFrame())

        if activeWidthMode == .half,
           let secondarySlotIndex,
           secondarySlotIndex >= 0,
           secondarySlotIndex < slotWindowIDs.count,
           let secondaryID = slotWindowIDs[secondarySlotIndex],
           let secondaryState = managedWindows[secondaryID] {
            animateWindow(secondaryState.window, to: secondaryActiveFrame())
        }
        refreshSlotPanel()
    }

    private func enterMode() {
        guard !modeEnabled else {
            return
        }

        layoutConfig = LayoutRuntimeConfig.loadFromDisk()

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
        activeSlotIndex = nil
        secondarySlotIndex = nil
        activeWindowID = nil
        slotWindowIDs = Array(repeating: nil, count: AppConfig.maxSlots)

        for (index, item) in windows.prefix(AppConfig.maxSlots).enumerated() {
            let state = ManagedWindowState(
                id: item.id,
                window: item.window,
                originalFrame: item.frame,
                originalMinimized: item.minimized,
                slotIndex: index
            )
            managedWindows[item.id] = state
            slotWindowIDs[index] = item.id
            animateToSlot(item.window, slotIndex: index)
        }

        refreshSlotPanel()
        slotPanel.show(
            leftOffset: layoutConfig.controlPanelLeftOffset,
            topOffset: layoutConfig.controlPanelTopOffset
        )
        print("Layout mode ON (\(min(windows.count, AppConfig.maxSlots)) windows assigned).")
        print(slotAssignmentsText())
    }

    private func exitMode() {
        guard modeEnabled else {
            return
        }

        let restoring = Array(managedWindows.values)
        modeEnabled = false
        activeSlotIndex = nil
        secondarySlotIndex = nil
        activeWindowID = nil
        managedWindows.removeAll()
        slotWindowIDs.removeAll()

        for state in restoring {
            _ = ax.setMinimized(state.window, false)
            animateWindow(state.window, to: state.originalFrame)
        }

        Task { @MainActor [ax] in
            let delay = max(0, layoutConfig.animationDuration) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            for state in restoring where state.originalMinimized {
                _ = ax.setMinimized(state.window, true)
            }
        }

        refreshSlotPanel()
        slotPanel.hide()
        print("Layout mode OFF (windows restored).")
    }

    private func toggleSlot(_ index: Int) {
        guard modeEnabled,
              index >= 0,
              index < slotWindowIDs.count,
              let incomingID = slotWindowIDs[index],
              let incomingState = managedWindows[incomingID] else {
            return
        }

        if secondarySlotIndex == index {
            secondarySlotIndex = nil
            incomingState.slotIndex = index
            animateToSlot(incomingState.window, slotIndex: index)
            refreshSlotPanel()
            return
        }

        if activeSlotIndex == index {
            if let promotedSecondary = secondarySlotIndex,
               promotedSecondary >= 0,
               promotedSecondary < slotWindowIDs.count,
               let promotedID = slotWindowIDs[promotedSecondary],
               let promotedState = managedWindows[promotedID] {
                incomingState.slotIndex = index
                animateToSlot(incomingState.window, slotIndex: index)

                activeSlotIndex = promotedSecondary
                secondarySlotIndex = nil
                promotedState.slotIndex = nil
                activeWindowID = promotedID
                bringWindowForward(promotedState.window)
                animateSlotToActive(promotedState.window)
                refreshSlotPanel()
                return
            }

            activeSlotIndex = nil
            activeWindowID = nil
            incomingState.slotIndex = index
            animateToSlot(incomingState.window, slotIndex: index)
            refreshSlotPanel()
            return
        }

        if let previousIndex = activeSlotIndex,
           previousIndex >= 0,
           previousIndex < slotWindowIDs.count,
           let previousID = slotWindowIDs[previousIndex],
           let previousState = managedWindows[previousID] {
            previousState.slotIndex = previousIndex
            animateToSlot(previousState.window, slotIndex: previousIndex)
        }

        incomingState.slotIndex = nil
        activeSlotIndex = index
        activeWindowID = incomingID
        if activeWidthMode == .half,
           let secondarySlotIndex,
           secondarySlotIndex >= 0,
           secondarySlotIndex < slotWindowIDs.count,
           let secondaryID = slotWindowIDs[secondarySlotIndex],
           let secondaryState = managedWindows[secondaryID],
           secondaryID == incomingID {
            self.secondarySlotIndex = nil
            secondaryState.slotIndex = nil
        }
        bringWindowForward(incomingState.window)
        animateSlotToActive(incomingState.window)

        if activeWidthMode == .half,
           let secondarySlotIndex,
           secondarySlotIndex >= 0,
           secondarySlotIndex < slotWindowIDs.count,
           let secondaryID = slotWindowIDs[secondarySlotIndex],
           let secondaryState = managedWindows[secondaryID],
           secondaryID != incomingID {
            animateWindow(secondaryState.window, to: secondaryActiveFrame())
        }
        refreshSlotPanel()
    }

    private func activateSecondarySlot(_ index: Int) {
        guard modeEnabled,
              index >= 0,
              index < slotWindowIDs.count,
              let secondaryID = slotWindowIDs[index],
              let secondaryState = managedWindows[secondaryID] else {
            return
        }

        if secondarySlotIndex == index {
            secondarySlotIndex = nil
            secondaryState.slotIndex = index
            animateToSlot(secondaryState.window, slotIndex: index)
            refreshSlotPanel()
            return
        }

        if activeWidthMode == .full {
            activeWidthMode = .half
            print("Active width mode: \(activeWidthMode.label)")
        }

        if activeSlotIndex == nil {
            activeSlotIndex = index
            secondarySlotIndex = nil
            activeWindowID = secondaryID
            secondaryState.slotIndex = nil
            bringWindowForward(secondaryState.window)
            animateSlotToActive(secondaryState.window)
            refreshSlotPanel()
            return
        }

        if activeSlotIndex == index {
            return
        }

        if let previousSecondary = secondarySlotIndex,
           previousSecondary >= 0,
           previousSecondary < slotWindowIDs.count,
           previousSecondary != index,
           let previousSecondaryID = slotWindowIDs[previousSecondary],
           let previousSecondaryState = managedWindows[previousSecondaryID] {
            previousSecondaryState.slotIndex = previousSecondary
            animateToSlot(previousSecondaryState.window, slotIndex: previousSecondary)
        }

        secondarySlotIndex = index
        secondaryState.slotIndex = nil

        if let primaryIndex = activeSlotIndex,
           primaryIndex >= 0,
           primaryIndex < slotWindowIDs.count,
           let primaryID = slotWindowIDs[primaryIndex],
           let primaryState = managedWindows[primaryID] {
            animateWindow(primaryState.window, to: activeFrame())
        }

        bringWindowForward(secondaryState.window)
        animateWindow(secondaryState.window, to: secondaryActiveFrame())
        refreshSlotPanel()
    }

    private func placeSlot(_ index: Int, placement: SlotPanelController.Placement) {
        guard modeEnabled,
              index >= 0,
              index < slotWindowIDs.count,
              let selectedID = slotWindowIDs[index],
              let selectedState = managedWindows[selectedID] else {
            return
        }

        if currentPlacement(for: index) == placement {
            if activeSlotIndex == index {
                activeSlotIndex = nil
                activeWindowID = nil
            }
            if secondarySlotIndex == index {
                secondarySlotIndex = nil
            }
            selectedState.slotIndex = index
            animateToSlot(selectedState.window, slotIndex: index)
            refreshSlotPanel()
            return
        }

        switch placement {
        case .full:
            if let secondaryIndex = secondarySlotIndex,
               secondaryIndex >= 0,
               secondaryIndex < slotWindowIDs.count,
               secondaryIndex != index,
               let secondaryID = slotWindowIDs[secondaryIndex],
               let secondaryState = managedWindows[secondaryID] {
                secondaryState.slotIndex = secondaryIndex
                animateToSlot(secondaryState.window, slotIndex: secondaryIndex)
            }

            if let primaryIndex = activeSlotIndex,
               primaryIndex >= 0,
               primaryIndex < slotWindowIDs.count,
               primaryIndex != index,
               let primaryID = slotWindowIDs[primaryIndex],
               let primaryState = managedWindows[primaryID] {
                primaryState.slotIndex = primaryIndex
                animateToSlot(primaryState.window, slotIndex: primaryIndex)
            }

            activeWidthMode = .full
            activeSlotIndex = index
            secondarySlotIndex = nil
            activeWindowID = selectedID
            selectedState.slotIndex = nil
            bringWindowForward(selectedState.window)
            animateSlotToActive(selectedState.window)

        case .leftHalf:
            activeWidthMode = .half

            if let primaryIndex = activeSlotIndex,
               primaryIndex >= 0,
               primaryIndex < slotWindowIDs.count,
               primaryIndex != index,
               let primaryID = slotWindowIDs[primaryIndex],
               let primaryState = managedWindows[primaryID] {
                primaryState.slotIndex = primaryIndex
                animateToSlot(primaryState.window, slotIndex: primaryIndex)
            }

            if secondarySlotIndex == index {
                secondarySlotIndex = nil
            }

            activeSlotIndex = index
            activeWindowID = selectedID
            selectedState.slotIndex = nil
            bringWindowForward(selectedState.window)
            animateSlotToActive(selectedState.window)

            if let secondaryIndex = secondarySlotIndex,
               secondaryIndex >= 0,
               secondaryIndex < slotWindowIDs.count,
               let secondaryID = slotWindowIDs[secondaryIndex],
               let secondaryState = managedWindows[secondaryID],
               secondaryID != selectedID {
                animateWindow(secondaryState.window, to: secondaryActiveFrame())
            }

        case .rightHalf:
            activeWidthMode = .half

            if let secondaryIndex = secondarySlotIndex,
               secondaryIndex >= 0,
               secondaryIndex < slotWindowIDs.count,
               secondaryIndex != index,
               let secondaryID = slotWindowIDs[secondaryIndex],
               let secondaryState = managedWindows[secondaryID] {
                secondaryState.slotIndex = secondaryIndex
                animateToSlot(secondaryState.window, slotIndex: secondaryIndex)
            }

            if activeSlotIndex == index {
                if let previousSecondary = secondarySlotIndex,
                   previousSecondary >= 0,
                   previousSecondary < slotWindowIDs.count,
                   previousSecondary != index,
                   let promotedID = slotWindowIDs[previousSecondary],
                   let promotedState = managedWindows[promotedID] {
                    activeSlotIndex = previousSecondary
                    activeWindowID = promotedID
                    promotedState.slotIndex = nil
                    animateSlotToActive(promotedState.window)
                } else {
                    activeSlotIndex = nil
                    activeWindowID = nil
                }
            }

            secondarySlotIndex = index
            selectedState.slotIndex = nil
            bringWindowForward(selectedState.window)
            animateWindow(selectedState.window, to: secondaryActiveFrame())

            if let primaryIndex = activeSlotIndex,
               primaryIndex >= 0,
               primaryIndex < slotWindowIDs.count,
               let primaryID = slotWindowIDs[primaryIndex],
               let primaryState = managedWindows[primaryID],
               primaryID != selectedID {
                animateWindow(primaryState.window, to: activeFrame())
            }
        }

        refreshSlotPanel()
    }

    private func minimizeAllToSlots() {
        guard modeEnabled else {
            return
        }

        for index in 0..<slotWindowIDs.count {
            guard let windowID = slotWindowIDs[index],
                  let state = managedWindows[windowID],
                  state.slotIndex == nil else {
                continue
            }

            state.slotIndex = index
            animateToSlot(state.window, slotIndex: index)
        }

        activeSlotIndex = nil
        secondarySlotIndex = nil
        activeWindowID = nil
        refreshSlotPanel()
    }

    private func swapActiveWindows() {
        guard modeEnabled,
              activeWidthMode == .half else {
            return
        }

        if let leftIndex = activeSlotIndex,
           let rightIndex = secondarySlotIndex,
           leftIndex >= 0,
           leftIndex < slotWindowIDs.count,
           rightIndex >= 0,
           rightIndex < slotWindowIDs.count,
           let leftID = slotWindowIDs[leftIndex],
           let rightID = slotWindowIDs[rightIndex],
           let leftState = managedWindows[leftID],
           let rightState = managedWindows[rightID] {
            activeSlotIndex = rightIndex
            secondarySlotIndex = leftIndex
            activeWindowID = rightID
            leftState.slotIndex = nil
            rightState.slotIndex = nil

            animateWindow(leftState.window, to: secondaryActiveFrame())
            bringWindowForward(rightState.window)
            animateWindow(rightState.window, to: activeFrame())
            refreshSlotPanel()
            return
        }

        if let leftIndex = activeSlotIndex,
           leftIndex >= 0,
           leftIndex < slotWindowIDs.count,
           let leftID = slotWindowIDs[leftIndex],
           let leftState = managedWindows[leftID] {
            activeSlotIndex = nil
            secondarySlotIndex = leftIndex
            activeWindowID = nil
            leftState.slotIndex = nil

            bringWindowForward(leftState.window)
            animateWindow(leftState.window, to: secondaryActiveFrame())
            refreshSlotPanel()
            return
        }

        if let rightIndex = secondarySlotIndex,
           rightIndex >= 0,
           rightIndex < slotWindowIDs.count,
           let rightID = slotWindowIDs[rightIndex],
           let rightState = managedWindows[rightID] {
            activeSlotIndex = rightIndex
            secondarySlotIndex = nil
            activeWindowID = rightID
            rightState.slotIndex = nil

            bringWindowForward(rightState.window)
            animateWindow(rightState.window, to: activeFrame())
            refreshSlotPanel()
            return
        }

        refreshSlotPanel()
    }

    private func bringWindowForward(_ window: AXUIElement) {
        _ = ax.setMinimized(window, false)
        let pid = ax.pid(of: window)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        _ = ax.raise(window)
    }

    private func slotAssignmentsText() -> String {
        var lines: [String] = []
        for index in 0..<AppConfig.maxSlots {
            let shortcut = slotShortcutLabel(for: index)
            if index < slotWindowIDs.count,
               let windowID = slotWindowIDs[index],
               let state = managedWindows[windowID] {
                lines.append("  \(shortcut): \(windowLabel(for: state.window))")
            } else {
                lines.append("  \(shortcut): (empty)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func refreshSlotPanel() {
        var items: [SlotPanelController.Item] = []
        items.reserveCapacity(AppConfig.maxSlots)

        for index in 0..<AppConfig.maxSlots {
            let shortcut = slotShortcutLabel(for: index)
            let icon: NSImage?
            let enabled: Bool
            let activePlacement = currentPlacement(for: index)
            if index < slotWindowIDs.count,
               let windowID = slotWindowIDs[index],
               let state = managedWindows[windowID] {
                icon = ax.appIcon(of: state.window)
                enabled = modeEnabled
            } else {
                icon = nil
                enabled = false
            }

            items.append(
                SlotPanelController.Item(
                    index: index,
                    shortcut: shortcut,
                    icon: icon,
                    enabled: enabled,
                    activePlacement: activePlacement
                )
            )
        }

        let canMinimizeAll = modeEnabled && (activeSlotIndex != nil || secondarySlotIndex != nil)
        let canSwap = modeEnabled && activeWidthMode == .half && (activeSlotIndex != nil || secondarySlotIndex != nil)
        slotPanel.update(items: items, canMinimizeAll: canMinimizeAll, canSwap: canSwap)
    }

    private func currentPlacement(for index: Int) -> SlotPanelController.Placement? {
        if activeSlotIndex == index {
            return activeWidthMode == .full ? .full : .leftHalf
        }
        if secondarySlotIndex == index, activeWidthMode == .half {
            return .rightHalf
        }
        return nil
    }

    private func slotShortcutLabel(for index: Int) -> String {
        switch index {
        case 0:
            return "F1/F2/F3"
        case 1:
            return "F4/F5/F6"
        case 2:
            return "F7/F8/F9"
        case 3:
            return "F10/F11/F12"
        default:
            return "F?"
        }
    }

    private func windowLabel(for window: AXUIElement) -> String {
        let appName = ax.appName(of: window) ?? "Unknown App"
        let title = ax.title(of: window)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            let shortTitle = String(title.prefix(30))
            return "\(appName) - \(shortTitle)"
        }
        return appName
    }

    private func animateWindow(_ window: AXUIElement, to target: CGRect, duration: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        let effectiveDuration = max(0, duration ?? layoutConfig.animationDuration)
        guard let start = ax.frame(of: window) else {
            _ = ax.setFrame(of: window, to: target)
            completion?()
            return
        }

        animator.animate(
            window: window,
            from: start,
            to: target,
            duration: effectiveDuration,
            apply: { [ax] window, rect in
                _ = ax.setFrame(of: window, to: rect)
            },
            completion: completion
        )
    }

    private func animateSlotToActive(_ window: AXUIElement) {
        let target = activeFrame()
        guard let start = ax.frame(of: window) else {
            _ = ax.setFrame(of: window, to: target)
            return
        }

        let phase = max(0.08, max(0, layoutConfig.animationDuration) / 2.0)
        let expandFrame = CGRect(
            x: start.origin.x,
            y: target.origin.y,
            width: target.width,
            height: target.height
        )

        animateWindow(window, to: expandFrame, duration: phase) { [weak self] in
            guard let self else { return }
            let slideFrame = CGRect(
                x: target.origin.x,
                y: target.origin.y,
                width: target.width,
                height: target.height
            )
            self.animateWindow(window, to: slideFrame, duration: phase)
        }
    }

    private func animateToSlot(_ window: AXUIElement, slotIndex: Int) {
        let screenFrame = workspaceFrame()
        let slotRect = slotFrame(for: slotIndex, in: screenFrame)
        let anchor = slotAnchor(for: slotIndex, in: screenFrame)

        guard let start = ax.frame(of: window) else {
            _ = ax.setFrame(of: window, to: slotRect)
            alignWindow(window, to: anchor)
            return
        }

        let phase = max(0.05, max(0, layoutConfig.animationDuration) / 4.0)
        let fixedWidth = start.width
        let targetX = anchor.rightX - fixedWidth
        let slideFrame = CGRect(
            x: targetX,
            y: start.origin.y,
            width: fixedWidth,
            height: start.height
        )
        let moveFrame = CGRect(
            x: targetX,
            y: slotRect.origin.y,
            width: fixedWidth,
            height: start.height
        )
        let shrinkHeightFrame = CGRect(
            x: moveFrame.origin.x,
            y: moveFrame.origin.y,
            width: moveFrame.width,
            height: slotRect.height
        )

        animateWindow(window, to: slideFrame, duration: phase) { [weak self] in
            guard let self else { return }
            self.animateWindow(window, to: moveFrame, duration: phase) { [weak self] in
                guard let self else { return }
                self.animateWindow(window, to: shrinkHeightFrame, duration: phase) { [weak self] in
                    guard let self else { return }
                    self.alignWindow(window, to: anchor)
                }
            }
        }
    }

    private func alignWindow(_ window: AXUIElement, to anchor: SlotAnchor) {
        guard let actual = ax.frame(of: window) else {
            return
        }
        let adjustedOrigin = CGPoint(
            x: anchor.rightX - actual.width,
            y: anchor.y
        )
        _ = ax.setPosition(of: window, to: adjustedOrigin)
    }

    private func activeFrame() -> CGRect {
        let screenFrame = workspaceFrame()
        let x = screenFrame.origin.x + layoutConfig.activeLeftOffset
        let totalWidth = max(240, layoutConfig.activeAreaWidth)
        let splitGap = max(0, layoutConfig.activeSplitGap)
        let width: CGFloat
        if activeWidthMode == .half {
            width = max(120, (totalWidth - splitGap) / 2.0)
        } else {
            width = totalWidth
        }
        let proposed = CGRect(
            x: x,
            y: screenFrame.origin.y + layoutConfig.activeTopOffset,
            width: width,
            height: max(120, layoutConfig.activeAreaHeight)
        )
        return clamp(rect: proposed, to: screenFrame)
    }

    private func secondaryActiveFrame() -> CGRect {
        let screenFrame = workspaceFrame()
        let x = screenFrame.origin.x + layoutConfig.activeLeftOffset
        let totalWidth = max(240, layoutConfig.activeAreaWidth)
        let splitGap = max(0, layoutConfig.activeSplitGap)
        let halfWidth = max(120, (totalWidth - splitGap) / 2.0)
        let proposed = CGRect(
            x: x + halfWidth + splitGap,
            y: screenFrame.origin.y + layoutConfig.activeTopOffset,
            width: halfWidth,
            height: max(120, layoutConfig.activeAreaHeight)
        )
        return clamp(rect: proposed, to: screenFrame)
    }

    private func slotFrame(for index: Int, in screenFrame: CGRect) -> CGRect {
        let slotHeight = max(120, layoutConfig.activeAreaHeight)
        let anchor = slotAnchor(for: index, in: screenFrame)
        return CGRect(
            x: anchor.rightX - AppConfig.slotSize.width,
            y: anchor.y,
            width: AppConfig.slotSize.width,
            height: slotHeight
        )
    }

    private func slotAnchor(for index: Int, in screenFrame: CGRect) -> SlotAnchor {
        _ = index
        let rightX = screenFrame.minX + layoutConfig.slotLeftOffset + AppConfig.slotSize.width
        let y = screenFrame.minY + layoutConfig.slotTopOffset
        return SlotAnchor(rightX: rightX, y: y)
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
