import Cocoa
import ServiceManagement
import SwiftUI

// MARK: - UserDefaults Keys

extension UserDefaults {
    static let baseWaitTimeKey = "baseWaitTime"
    static let holdThresholdKey = "holdThreshold"
    static let scaleIntervalKey = "scaleInterval"

    static let appEnabledKey = "appEnabled"

    static let triggerTypeKey = "triggerType"
    static let mouseButtonTypeKey = "mouseButtonType"
    static let customMouseButtonKey = "customMouseButton"
    static let triggerKeyCodeKey = "triggerKeyCode"
    static let triggerModifierFlagsKey = "triggerModifierFlags"

    func registerAppDefaults() {
        register(defaults: [
            Self.baseWaitTimeKey: 1.0,
            Self.holdThresholdKey: 10.0,
            Self.scaleIntervalKey: 10.0,
            Self.appEnabledKey: true,
            Self.triggerTypeKey: "key",
            Self.mouseButtonTypeKey: "other",
            Self.customMouseButtonKey: 5,
            Self.triggerKeyCodeKey: -1,
            Self.triggerModifierFlagsKey: Int(CGEventFlags.maskSecondaryFn.rawValue),
        ])
    }

    var baseWaitTime: Double { double(forKey: Self.baseWaitTimeKey) }
    var holdThreshold: Double { double(forKey: Self.holdThresholdKey) }
    var scaleInterval: Double { double(forKey: Self.scaleIntervalKey) }
    var triggerType: String { string(forKey: Self.triggerTypeKey) ?? "key" }
    var mouseButtonType: String { string(forKey: Self.mouseButtonTypeKey) ?? "other" }
    var customMouseButton: Int { integer(forKey: Self.customMouseButtonKey) }
    var triggerKeyCode: Int { integer(forKey: Self.triggerKeyCodeKey) }
    var triggerModifierFlags: Int { integer(forKey: Self.triggerModifierFlagsKey) }
}

// MARK: - Event Tap Logic

var isButtonDown = false
var buttonDownTime: Date?
var pendingWorkItem: DispatchWorkItem?
var globalEventTap: CFMachPort?
var isAppEnabled: Bool = {
    UserDefaults.standard.object(forKey: "appEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "appEnabled")
}()

func simulateEnterKey() {
    guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false) else {
        return
    }
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func eventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    if !isAppEnabled {
        return Unmanaged.passUnretained(event)
    }

    let defaults = UserDefaults.standard
    let triggerType = defaults.triggerType

    var triggerDown = false
    var triggerUp = false

    if triggerType == "key" {
        let storedKeyCode = defaults.triggerKeyCode
        let storedMods = UInt64(defaults.triggerModifierFlags)

        if storedKeyCode < 0 {
            // Modifier-only trigger (e.g. Fn)
            if type == .flagsChanged {
                let requiredFlags = CGEventFlags(rawValue: storedMods)
                let hasRequired = event.flags.contains(requiredFlags)
                if hasRequired && !isButtonDown {
                    triggerDown = true
                } else if !hasRequired && isButtonDown {
                    triggerUp = true
                }
            }
        } else {
            // Key-based trigger (with optional modifiers)
            let standardModMask: UInt64 =
                CGEventFlags.maskControl.rawValue |
                CGEventFlags.maskAlternate.rawValue |
                CGEventFlags.maskShift.rawValue |
                CGEventFlags.maskCommand.rawValue
            let requiredStandardMods = storedMods & standardModMask

            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let currentStandardMods = event.flags.rawValue & standardModMask
                if keyCode == Int64(storedKeyCode) && currentStandardMods == requiredStandardMods && !isButtonDown {
                    triggerDown = true
                }
            } else if type == .keyUp {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == Int64(storedKeyCode) && isButtonDown {
                    triggerUp = true
                }
            }
        }
    } else {
        // Mouse button trigger
        let mouseButtonType = defaults.mouseButtonType
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        let expectedButton: Int64
        let downType: CGEventType
        let upType: CGEventType

        switch mouseButtonType {
        case "left":
            expectedButton = 0
            downType = .leftMouseDown
            upType = .leftMouseUp
        case "right":
            expectedButton = 1
            downType = .rightMouseDown
            upType = .rightMouseUp
        case "middle":
            expectedButton = 2
            downType = .otherMouseDown
            upType = .otherMouseUp
        default: // "other"
            expectedButton = Int64(defaults.customMouseButton)
            downType = .otherMouseDown
            upType = .otherMouseUp
        }

        if type == downType && buttonNumber == expectedButton {
            triggerDown = true
        } else if type == upType && buttonNumber == expectedButton && isButtonDown {
            triggerUp = true
        }
    }

    if triggerDown {
        isButtonDown = true
        buttonDownTime = Date()
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    } else if triggerUp {
        isButtonDown = false
        let holdDuration = buttonDownTime.map { -$0.timeIntervalSinceNow } ?? 0

        let baseWait = defaults.baseWaitTime
        let threshold = defaults.holdThreshold
        let scale = defaults.scaleInterval

        let waitTime: Double
        if holdDuration <= threshold {
            waitTime = baseWait
        } else {
            waitTime = baseWait + (holdDuration - threshold) / scale
        }

        let workItem = DispatchWorkItem {
            simulateEnterKey()
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTime, execute: workItem)
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Button Tester

class MouseEventLogger: ObservableObject {
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
    }

    @Published var entries: [LogEntry] = []
    private var testerTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    static let shared = MouseEventLogger()

    func log(_ text: String) {
        let entry = LogEntry(timestamp: Date(), text: text)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 500 {
                self.entries.removeFirst(self.entries.count - 500)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}

func testerEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let logger = MouseEventLogger.shared

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        logger.log("!! Event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling...")
        if let refcon = refcon {
            let tap = Unmanaged<CFMachPort>.fromOpaque(refcon).takeUnretainedValue()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
    let clickState = event.getIntegerValueField(.mouseEventClickState)
    let location = event.location

    let typeName: String
    switch type {
    case .leftMouseDown:      typeName = "leftMouseDown"
    case .leftMouseUp:        typeName = "leftMouseUp"
    case .rightMouseDown:     typeName = "rightMouseDown"
    case .rightMouseUp:       typeName = "rightMouseUp"
    case .otherMouseDown:     typeName = "otherMouseDown"
    case .otherMouseUp:       typeName = "otherMouseUp"
    case .mouseMoved:         typeName = "mouseMoved"
    case .leftMouseDragged:   typeName = "leftMouseDragged"
    case .rightMouseDragged:  typeName = "rightMouseDragged"
    case .otherMouseDragged:  typeName = "otherMouseDragged"
    case .scrollWheel:        typeName = "scrollWheel"
    default:                  typeName = "unknown(\(type.rawValue))"
    }

    // Skip mouseMoved to reduce noise
    if type == .mouseMoved { return Unmanaged.passUnretained(event) }

    var detail = "\(typeName)  btn=\(buttonNumber)  clicks=\(clickState)  loc=(\(Int(location.x)),\(Int(location.y)))"

    if type == .scrollWheel {
        let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        detail = "\(typeName)  deltaX=\(deltaX) deltaY=\(deltaY)  loc=(\(Int(location.x)),\(Int(location.y)))"
    }

    logger.log(detail)
    return Unmanaged.passUnretained(event)
}

struct ButtonTesterView: View {
    @ObservedObject var logger = MouseEventLogger.shared
    @State private var testerTap: CFMachPort?
    @State private var testerRunLoopSource: CFRunLoopSource?
    @State private var isListening = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(isListening ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(isListening ? "Listening" : "Not listening")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") { logger.clear() }
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                List(logger.entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                .listStyle(.plain)
                .onChange(of: logger.entries.count) { _, _ in
                    if let last = logger.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 500, height: 350)
        .onAppear { startListening() }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        var allMouseEvents: CGEventMask = 0
        for t: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                .otherMouseDown, .otherMouseUp, .mouseMoved,
                                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel] {
            allMouseEvents |= (1 << t.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: allMouseEvents,
            callback: testerEventCallback,
            userInfo: nil
        ) else {
            logger.log("ERROR: Failed to create event tap. Check Accessibility permissions.")
            return
        }

        // Store tap reference, then set userInfo for re-enable
        testerTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        testerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        logger.log("Button tester started - press any mouse button...")
    }

    private func stopListening() {
        if let tap = testerTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = testerRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        testerTap = nil
        testerRunLoopSource = nil
        isListening = false
    }
}

// MARK: - Key Binding Display

func keyCodeName(_ keyCode: Int) -> String {
    let names: [Int: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
        0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
        0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x24: "Return", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N",
        0x2E: "M", 0x2F: ".", 0x30: "Tab", 0x31: "Space", 0x32: "`",
        0x33: "Delete", 0x35: "Escape",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3", 0x64: "F8",
        0x65: "F9", 0x67: "F11", 0x69: "F13", 0x6B: "F14",
        0x6D: "F10", 0x6F: "F12", 0x71: "F15", 0x72: "Help",
        0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete",
        0x76: "F4", 0x77: "End", 0x78: "F2", 0x79: "Page Down",
        0x7A: "F1", 0x7B: "\u{2190}", 0x7C: "\u{2192}",
        0x7D: "\u{2193}", 0x7E: "\u{2191}",
    ]
    return names[keyCode] ?? "Key \(keyCode)"
}

func keyBindingDisplayName(keyCode: Int, modifierFlags: UInt64) -> String {
    var parts: [String] = []
    if modifierFlags & CGEventFlags.maskControl.rawValue != 0 { parts.append("\u{2303}") }
    if modifierFlags & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("\u{2325}") }
    if modifierFlags & CGEventFlags.maskShift.rawValue != 0 { parts.append("\u{21E7}") }
    if modifierFlags & CGEventFlags.maskCommand.rawValue != 0 { parts.append("\u{2318}") }
    let hasFn = modifierFlags & CGEventFlags.maskSecondaryFn.rawValue != 0
    if hasFn { parts.append("Fn") }

    if keyCode >= 0 {
        if hasFn && !parts.dropLast().isEmpty { /* symbols already joined */ }
        parts.append(keyCodeName(keyCode))
    }

    if parts.isEmpty { return "None" }
    return parts.joined(separator: "")
}

// MARK: - Key Recorder

class KeyRecorderState: ObservableObject {
    @Published var isRecording = false
    private var localMonitor: Any?
    private var trackedModifiers: UInt64 = 0
    private var hadKeyDown = false

    private static let relevantModifierMask: UInt64 =
        UInt64(NSEvent.ModifierFlags.control.rawValue) |
        UInt64(NSEvent.ModifierFlags.option.rawValue) |
        UInt64(NSEvent.ModifierFlags.shift.rawValue) |
        UInt64(NSEvent.ModifierFlags.command.rawValue) |
        UInt64(NSEvent.ModifierFlags.function.rawValue)

    // Mask for standard modifiers only (no Fn), used when recording key presses
    private static let standardModifierMask: UInt64 =
        UInt64(NSEvent.ModifierFlags.control.rawValue) |
        UInt64(NSEvent.ModifierFlags.option.rawValue) |
        UInt64(NSEvent.ModifierFlags.shift.rawValue) |
        UInt64(NSEvent.ModifierFlags.command.rawValue)

    var onRecorded: ((Int, UInt64) -> Void)?

    func startRecording() {
        isRecording = true
        hadKeyDown = false
        trackedModifiers = 0

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleEvent(event)
            return nil // consume the event
        }
    }

    func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        if event.type == .keyDown && !hadKeyDown {
            let keyCode = Int(event.keyCode)
            // Strip Fn modifier for key presses (Fn is implicit for function keys)
            let mods = UInt64(event.modifierFlags.rawValue) & Self.standardModifierMask
            hadKeyDown = true
            finishRecording(keyCode: keyCode, modifiers: mods)
        } else if event.type == .keyUp && hadKeyDown {
            // Already finished on keyDown
        } else if event.type == .flagsChanged && !hadKeyDown {
            let currentMods = UInt64(event.modifierFlags.rawValue) & Self.relevantModifierMask
            if currentMods != 0 {
                trackedModifiers = currentMods
            } else if trackedModifiers != 0 {
                // All modifiers released without any key press — modifier-only binding
                finishRecording(keyCode: -1, modifiers: trackedModifiers)
            }
        }
    }

    private func finishRecording(keyCode: Int, modifiers: UInt64) {
        stopRecording()
        onRecorded?(keyCode, modifiers)
    }
}

struct KeyRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifierFlags: Int
    @StateObject private var recorder = KeyRecorderState()

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            if recorder.isRecording {
                Text("Press a key\u{2026}")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
            } else {
                Text(keyBindingDisplayName(keyCode: keyCode, modifierFlags: UInt64(modifierFlags)))
                    .frame(minWidth: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
            }
            Button(recorder.isRecording ? "Cancel" : "Record") {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    recorder.onRecorded = { newKeyCode, newMods in
                        keyCode = newKeyCode
                        modifierFlags = Int(newMods)
                    }
                    recorder.startRecording()
                }
            }
            .buttonStyle(.bordered)
            if !recorder.isRecording && (keyCode != -1 || modifierFlags != Int(CGEventFlags.maskSecondaryFn.rawValue)) {
                Button("Reset") {
                    keyCode = -1
                    modifierFlags = Int(CGEventFlags.maskSecondaryFn.rawValue)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Preferences View

struct PreferencesView: View {
    @AppStorage(UserDefaults.baseWaitTimeKey) private var baseWaitTime: Double = 1.0
    @AppStorage(UserDefaults.holdThresholdKey) private var holdThreshold: Double = 10.0
    @AppStorage(UserDefaults.scaleIntervalKey) private var scaleInterval: Double = 10.0
    @AppStorage(UserDefaults.triggerTypeKey) private var triggerType: String = "key"
    @AppStorage(UserDefaults.mouseButtonTypeKey) private var mouseButtonType: String = "other"
    @AppStorage(UserDefaults.customMouseButtonKey) private var customMouseButton: Int = 5
    @AppStorage(UserDefaults.triggerKeyCodeKey) private var triggerKeyCode: Int = -1
    @AppStorage(UserDefaults.triggerModifierFlagsKey) private var triggerModifierFlags: Int = 8388608
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("Failed to update login item: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Dictation Key") {
                Text("The input used to trigger dictation. After release, Enter is pressed automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Trigger", selection: $triggerType) {
                    Text("Keyboard").tag("key")
                    Text("Mouse Button").tag("mouse")
                }
                .pickerStyle(.segmented)

                if triggerType == "key" {
                    KeyRecorderView(keyCode: $triggerKeyCode, modifierFlags: $triggerModifierFlags)
                } else {
                    Picker("Button", selection: $mouseButtonType) {
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                        Text("Middle").tag("middle")
                        Text("Other").tag("other")
                    }

                    if mouseButtonType == "other" {
                        Stepper("Button Number: \(customMouseButton)", value: $customMouseButton, in: 3...20)
                    }
                }
            }

            if triggerType == "mouse" {
                Section("Button Tester") {
                    Button("Open Button Tester") {
                        NotificationCenter.default.post(name: .openButtonTester, object: nil)
                    }
                    Text("Logs every mouse event to help identify button numbers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Wait Time Formula") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("If hold \u{2264} threshold:")
                    Text("  Wait = baseWait")
                    Text("Else:")
                    Text("  Wait = baseWait + (hold \u{2212} threshold) / scale")
                }
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("Base Wait Time")
                    Spacer()
                    TextField("", value: $baseWaitTime, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("s")
                }
                Text("Minimum delay after releasing the button (for short presses).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Threshold")
                    Spacer()
                    TextField("", value: $holdThreshold, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("s")
                }
                Text("Hold duration below which the base wait time applies.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Scale")
                    Spacer()
                    TextField("", value: $scaleInterval, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("s")
                }
                Text("For every extra N seconds of hold beyond threshold, add 1s of wait.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .safeAreaInset(edge: .bottom) {
            Text("Created by Radu Vasilescu.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
    }
}

extension Notification.Name {
    static let openButtonTester = Notification.Name("openButtonTester")
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledMenuItem: NSMenuItem!
    private var preferencesWindow: NSWindow?
    private var buttonTesterWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.registerAppDefaults()
        setupStatusItem()
        setupEventTap()
        NotificationCenter.default.addObserver(self, selector: #selector(openButtonTester), name: .openButtonTester, object: nil)
    }

    // MARK: Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledMenuItem.state = isAppEnabled ? .on : .off

        let menu = NSMenu()
        menu.addItem(enabledMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences\u{2026}", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dictation Enter", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        if let button = statusItem.button {
            button.image = makeStatusBarIcon()
            button.appearsDisabled = !isAppEnabled
        }
    }

    private func makeStatusBarIcon() -> NSImage {
        let height: CGFloat = 18
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)

        let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let returnImage = NSImage(systemSymbolName: "return.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()

        let micSize = micImage.size
        let returnSize = returnImage.size
        let spacing: CGFloat = -1
        let totalWidth = micSize.width + spacing + returnSize.width

        let compositeImage = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            let micY = (height - micSize.height) / 2
            micImage.draw(in: NSRect(x: 0, y: micY, width: micSize.width, height: micSize.height))

            let returnX = micSize.width + spacing
            let returnY = (height - returnSize.height) / 2
            returnImage.draw(in: NSRect(x: returnX, y: returnY, width: returnSize.width, height: returnSize.height))
            return true
        }

        compositeImage.isTemplate = true
        return compositeImage
    }

    // MARK: Event Tap

    private var accessibilityPollTimer: Timer?

    private func setupEventTap() {
        if AXIsProcessTrusted() {
            createEventTap()
        } else {
            promptForAccessibility()
        }
    }

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "Dictation Enter needs Accessibility access to detect mouse buttons.\n\n1. Open System Settings > Privacy & Security > Accessibility\n2. Click '+' and add Dictation Enter\n3. The app will activate automatically once access is granted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
            return
        }

        // Open System Settings to Accessibility pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // Poll until access is granted
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityPollTimer = nil
                NSLog("Accessibility access granted.")
                self?.createEventTap()
            }
        }
    }

    private func createEventTap() {
        var eventMask: CGEventMask = 0
        for t: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                .otherMouseDown, .otherMouseUp, .flagsChanged, .keyDown, .keyUp] {
            eventMask |= (1 << t.rawValue)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventCallback,
            userInfo: nil
        ) else {
            let alert = NSAlert()
            alert.messageText = "Failed to create event tap"
            alert.informativeText = "Grant Accessibility access in System Settings and restart the app."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        globalEventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        isAppEnabled.toggle()
        UserDefaults.standard.set(isAppEnabled, forKey: UserDefaults.appEnabledKey)
        enabledMenuItem.state = isAppEnabled ? .on : .off
        updateStatusIcon()
    }

    @objc private func openPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: PreferencesView())
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation Enter Preferences"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        preferencesWindow = window
    }

    @objc private func openButtonTester() {
        if let window = buttonTesterWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: ButtonTesterView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Button Tester"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        buttonTesterWindow = window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
