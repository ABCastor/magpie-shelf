import AppKit
import Carbon.HIToolbox

/// Everything a hotkey needs to be registered with Carbon and named in the UI.
/// Each hotkey the app owns gets its own preset list rather than sharing one:
/// the summon shortcut and the copy shortcut have different neighbours to
/// avoid, and a shared list would offer combinations that collide with each
/// other.
protocol HotkeyCombination {
    /// Carbon virtual key code (`kVK_*`) — position on the keyboard, not the
    /// character the current layout produces.
    var keyCode: UInt32 { get }
    /// Carbon modifier mask (`optionKey`, `shiftKey`, …), which is a different
    /// bit layout from `NSEvent.ModifierFlags`.
    var carbonModifiers: UInt32 { get }
    /// Glyph form shown in the picker. Not localized — these are symbols.
    var displayName: String { get }
}

/// What a registered global hotkey does. The raw value is never persisted;
/// `carbonID` is what travels in the Carbon event, and it is what lets one
/// installed handler tell two live hotkeys apart.
enum HotkeyAction: String, CaseIterable {
    case summonShelf
    case copyForChat

    var carbonID: UInt32 {
        switch self {
        case .summonShelf: return 1
        case .copyForChat: return 2
        }
    }

    init?(carbonID: UInt32) {
        guard let match = Self.allCases.first(where: { $0.carbonID == carbonID }) else {
            return nil
        }
        self = match
    }
}

/// The fixed set of summon shortcuts offered in Settings. A short preset list
/// rather than a shortcut recorder: the mapping stays pure (and unit-tested),
/// and we can guarantee nothing collides with the ⌥⇧N / ⌥⇧A key equivalents
/// the status menu already owns.
enum HotkeyPreset: String, CaseIterable, Identifiable, HotkeyCombination {
    case optionShiftS
    case controlOptionCommandS
    case optionShiftD
    case f13

    var id: String { rawValue }

    var keyCode: UInt32 {
        switch self {
        case .optionShiftS, .controlOptionCommandS: return UInt32(kVK_ANSI_S)
        case .optionShiftD: return UInt32(kVK_ANSI_D)
        case .f13: return UInt32(kVK_F13)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionShiftS, .optionShiftD: return UInt32(optionKey | shiftKey)
        case .controlOptionCommandS: return UInt32(controlKey | optionKey | cmdKey)
        case .f13: return 0
        }
    }

    var displayName: String {
        switch self {
        case .optionShiftS: return "⌥⇧S"
        case .controlOptionCommandS: return "⌃⌥⌘S"
        case .optionShiftD: return "⌥⇧D"
        case .f13: return "F13"
        }
    }
}

/// The shortcuts offered for "copy the shelf for the chat I'm in". Every
/// combination here uses a key no `HotkeyPreset` uses, so the two pickers can
/// never be set to the same shortcut.
enum ChatHotkeyPreset: String, CaseIterable, Identifiable, HotkeyCombination {
    case optionShiftC
    case controlOptionCommandC
    case optionShiftV
    case f14

    var id: String { rawValue }

    var keyCode: UInt32 {
        switch self {
        case .optionShiftC, .controlOptionCommandC: return UInt32(kVK_ANSI_C)
        case .optionShiftV: return UInt32(kVK_ANSI_V)
        case .f14: return UInt32(kVK_F14)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionShiftC, .optionShiftV: return UInt32(optionKey | shiftKey)
        case .controlOptionCommandC: return UInt32(controlKey | optionKey | cmdKey)
        case .f14: return 0
        }
    }

    var displayName: String {
        switch self {
        case .optionShiftC: return "⌥⇧C"
        case .controlOptionCommandC: return "⌃⌥⌘C"
        case .optionShiftV: return "⌥⇧V"
        case .f14: return "F14"
        }
    }
}

/// Owns the app's global hotkeys — one live registration per `HotkeyAction`,
/// independently started and stopped.
///
/// Carbon's `RegisterEventHotKey` is the only system-wide keyboard route that
/// needs no Accessibility permission — `NSEvent.addGlobalMonitorForEvents`
/// with a `.keyDown` mask would prompt for one, and the app deliberately asks
/// for nothing.
final class HotkeyManager {
    /// Carries which action fired, and whether a drag was in progress at the
    /// moment the key was pressed, sampled before the hop to main — see
    /// `ShakeDetector.onShake`.
    var onTrigger: ((HotkeyAction, Bool) -> Void)?

    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    // Four-char code identifying our hotkeys in the Carbon event stream ('MGPI').
    private let signature: OSType = 0x4D47_5049

    /// Registers the summon shortcut. Kept as the unlabelled form because it
    /// is the app's original and by far most-used hotkey.
    @discardableResult
    func start(preset: HotkeyPreset) -> Bool {
        start(.summonShelf, preset: preset)
    }

    /// Registers `preset` for `action`, replacing whatever that action had
    /// before and leaving every other action's registration alone. Returns
    /// false when Carbon refuses, so the caller can tell the user rather than
    /// leaving a dead shortcut selected in Settings.
    @discardableResult
    func start(_ action: HotkeyAction, preset: some HotkeyCombination) -> Bool {
        stop(action)
        guard installHandlerIfNeeded() else { return false }

        var ref: EventHotKeyRef?
        let registered = RegisterEventHotKey(
            preset.keyCode,
            preset.carbonModifiers,
            EventHotKeyID(signature: signature, id: action.carbonID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard registered == noErr, let ref else {
            removeHandlerIfIdle()
            return false
        }
        hotKeyRefs[action] = ref
        return true
    }

    /// Unregisters one action, leaving the others live.
    func stop(_ action: HotkeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        removeHandlerIfIdle()
    }

    /// Tears everything down: every registration plus the shared handler.
    func stop() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        removeHandler()
    }

    func isRegistered(_ action: HotkeyAction) -> Bool {
        hotKeyRefs[action] != nil
    }

    // The Carbon handler holds an unretained pointer to us, so it has to be
    // torn down before we go away or it would call into freed memory.
    deinit {
        stop()
    }

    // MARK: - Carbon plumbing

    /// One handler serves every action; it dispatches on the `EventHotKeyID`
    /// carried by the event. Installing one per registration would deliver
    /// every press to every handler.
    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard read == noErr else { return noErr }
                Unmanaged<HotkeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .fire(id)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installed == noErr else {
            handlerRef = nil
            return false
        }
        return true
    }

    private func removeHandlerIfIdle() {
        guard hotKeyRefs.isEmpty else { return }
        removeHandler()
    }

    private func removeHandler() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    /// Runs on the main thread — Carbon delivers hot-key events on the event
    /// loop. The ownership check matters: a handler installed on the
    /// application event target sees presses meant for *any* manager.
    private func fire(_ id: EventHotKeyID) {
        guard id.signature == signature,
              let action = HotkeyAction(carbonID: id.id),
              hotKeyRefs[action] != nil
        else { return }

        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?(action, dragging)
        }
    }
}
