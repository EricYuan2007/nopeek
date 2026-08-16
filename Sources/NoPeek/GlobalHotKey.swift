import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via the legacy-but-fully-supported Carbon HotKey API.
///
/// Why Carbon instead of NSEvent.addGlobalMonitorForEvents: global key *monitors*
/// require Input Monitoring consent on modern macOS; RegisterEventHotKey needs no
/// permission at all. These hotkeys are the escape hatch for the privacy shield —
/// it frosts the whole screen (menu bar included) and is click-through, so without
/// a global shortcut a manual blur would be impossible to dismiss.
///
///   ⌥⌘B  toggle manual blur
///   ⌥⌘P  pause / resume monitoring (drops an auto shield: alert ends with it)
@MainActor
final class GlobalHotKey {

    struct Binding {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    private static let signature = OSType(0x4E504B48) // 'NPKH'

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var bindings: [UInt32: Binding] = [:]

    func register(_ newBindings: [Binding]) {
        unregister()
        for (index, binding) in newBindings.enumerated() {
            let id = UInt32(index + 1)
            bindings[id] = binding
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                Log.ui.warning("hotkey #\(id) registration failed (status \(status)) — conflict with another app?")
            }
        }
        installHandler()
    }

    func unregister() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        bindings = [:]
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        // The closure must not capture context (C function pointer) — self travels
        // through userData.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Application-event-target handlers are dispatched on the main runloop.
            MainActor.assumeIsolated { hotKey.bindings[hotKeyID.id]?.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
    }
}
