import AppKit
import Carbon

// System-wide hotkey via Carbon's RegisterEventHotKey. Fires the
// supplied closure no matter which app is foreground. The Carbon
// API is the only stable system-wide path on macOS — Cocoa's
// NSEvent.addGlobalMonitorForEvents observes events but cannot
// suppress them, which means the underlying key combo still
// reaches whatever app the user is in. For an "Alfred trigger"
// you need real reservation, hence Carbon.
//
// One instance = one registration. Holding the instance keeps the
// hotkey live; releasing it cleans up.

@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    // A 4-char code that distinguishes our hotkey from anyone
    // else's. Carbon uses this when routing the event back.
    private static let signature: OSType = {
        let chars: [UInt32] = [0x4d, 0x41, 0x4e, 0x49] // M A N I
        return OSType((chars[0] << 24) | (chars[1] << 16) | (chars[2] << 8) | chars[3])
    }()

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            NSLog("GlobalHotkey: RegisterEventHotKey failed status=\(status)")
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotkey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // Carbon callbacks land on the main thread already,
                // but the closure may capture @MainActor state. Hop
                // explicitly so the compiler is happy.
                DispatchQueue.main.async { me.onPress() }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &handlerRef
        )
        if installStatus != noErr {
            NSLog("GlobalHotkey: InstallEventHandler failed status=\(installStatus)")
        }
    }
}

// Common key codes — these are virtual key codes, not characters.
// Full list: Carbon/HIToolbox/Events.h on macOS.
enum HotkeyKey {
    static let m: UInt32 = 0x2E   // 46
}

// Carbon modifier flags. Note: these differ from NSEvent's
// modifier flag values — Carbon uses a smaller bitset.
struct HotkeyModifiers: OptionSet {
    let rawValue: UInt32
    static let command  = HotkeyModifiers(rawValue: UInt32(cmdKey))
    static let shift    = HotkeyModifiers(rawValue: UInt32(shiftKey))
    static let option   = HotkeyModifiers(rawValue: UInt32(optionKey))
    static let control  = HotkeyModifiers(rawValue: UInt32(controlKey))
}
