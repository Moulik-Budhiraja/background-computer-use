import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon (no extra permissions needed).
/// ⌃⌥⌘P toggles pause, ⌃⌥⌘. stops the agent.
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let actions: [UInt32: () -> Void]
    fileprivate static var shared: HotKeys?
    /// Shortcuts that couldn't be registered (another app has them), for Settings.
    private(set) static var failed: [String] = []

    init(togglePause: @escaping () -> Void, stop: @escaping () -> Void) {
        actions = [1: togglePause, 2: stop]
        HotKeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared?.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let mods = UInt32(controlKey | optionKey | cmdKey)
        register(id: 1, keyCode: UInt32(kVK_ANSI_P), modifiers: mods, name: "⌃⌥⌘P")
        register(id: 2, keyCode: UInt32(kVK_ANSI_Period), modifiers: mods, name: "⌃⌥⌘.")
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, name: String) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4243_5548), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("[bcu] hotkey \(name) not registered: \(status)")
            Self.failed.append(name)
        }
        refs.append(ref)
    }
}
