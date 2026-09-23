import AppKit
import Carbon.HIToolbox

struct GlobalKeyboardMonitorStartResult: Equatable {
    var summonHotkeyRegistered: Bool
    /// Set only when a real check found the shortcut is likely taken (a macOS keyboard shortcut that is on, another
    /// app's registration, or a running launcher known to use it). nil means no conflict was found, not "free".
    var conflictDescription: String? = nil
}

// "SDKH": identifies our Carbon hot key among any others registered in the process.
private let summonHotKeySignature: OSType = 0x5344_4B48
private let summonHotKeyIdentifier: UInt32 = 1

/// The summon hotkey (Carbon, swallowed by the system, no permission needed). Dotto watches no other keys globally:
/// a run stops through its Stop buttons, or pauses when the user touches the target app.
@MainActor final class GlobalKeyboardMonitor {
    var onSummonHotkeyPressed: (() -> Void)?

    private var summonHotKeyReference: EventHotKeyRef?
    private var summonHotKeyEventHandlerReference: EventHandlerRef?
    private var registeredSummonHotkey: SummonHotkey?

    /// Idempotent for the same hotkey; unregisters the previous hotkey first when it differs.
    @discardableResult func start(summonHotkey: SummonHotkey) -> GlobalKeyboardMonitorStartResult {
        if summonHotKeyReference != nil, registeredSummonHotkey == summonHotkey {
            return GlobalKeyboardMonitorStartResult(summonHotkeyRegistered: true,
                                                    conflictDescription: SummonHotkeyConflictCheck.conflictDescription(for: summonHotkey))
        }
        unregisterSummonHotKey()
        let registrationStatus = registerSummonHotKey(summonHotkey)
        let registrationConflict = registrationStatus == OSStatus(eventHotKeyExistsErr)
            ? "Another app already uses \(summonHotkey.displayText)." : nil
        return GlobalKeyboardMonitorStartResult(
            summonHotkeyRegistered: summonHotKeyReference != nil,
            conflictDescription: registrationConflict ?? SummonHotkeyConflictCheck.conflictDescription(for: summonHotkey))
    }

    func stop() {
        unregisterSummonHotKey()
        if let summonHotKeyEventHandlerReference {
            RemoveEventHandler(summonHotKeyEventHandlerReference)
            self.summonHotKeyEventHandlerReference = nil
        }
    }

    // MARK: - Summon hot key

    private func unregisterSummonHotKey() {
        if let summonHotKeyReference {
            UnregisterEventHotKey(summonHotKeyReference)
            self.summonHotKeyReference = nil
        }
        registeredSummonHotkey = nil
    }

    private func registerSummonHotKey(_ summonHotkey: SummonHotkey) -> OSStatus {
        if summonHotKeyEventHandlerReference == nil {
            var hotKeyPressedEventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let hotKeyEventHandler: EventHandlerUPP = { _, hotKeyEvent, userData in
                guard let hotKeyEvent, let userData else { return OSStatus(eventNotHandledErr) }
                var pressedHotKeyIdentifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(hotKeyEvent, EventParamName(kEventParamDirectObject),
                                                        EventParamType(typeEventHotKeyID), nil,
                                                        MemoryLayout<EventHotKeyID>.size, nil, &pressedHotKeyIdentifier)
                guard parameterStatus == noErr, pressedHotKeyIdentifier.signature == summonHotKeySignature,
                      pressedHotKeyIdentifier.id == summonHotKeyIdentifier else { return OSStatus(eventNotHandledErr) }
                let globalKeyboardMonitor = Unmanaged<GlobalKeyboardMonitor>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application-target events on the main thread.
                MainActor.assumeIsolated { globalKeyboardMonitor.onSummonHotkeyPressed?() }
                return noErr
            }
            InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &hotKeyPressedEventType,
                                Unmanaged.passUnretained(self).toOpaque(), &summonHotKeyEventHandlerReference)
        }

        var carbonModifierMask: UInt32 = 0
        if summonHotkey.usesCommand { carbonModifierMask |= UInt32(cmdKey) }
        if summonHotkey.usesOption { carbonModifierMask |= UInt32(optionKey) }
        if summonHotkey.usesControl { carbonModifierMask |= UInt32(controlKey) }
        if summonHotkey.usesShift { carbonModifierMask |= UInt32(shiftKey) }
        var registeredHotKeyReference: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            summonHotkey.keyCode, carbonModifierMask,
            EventHotKeyID(signature: summonHotKeySignature, id: summonHotKeyIdentifier),
            GetApplicationEventTarget(), 0, &registeredHotKeyReference)
        if registrationStatus == noErr {
            summonHotKeyReference = registeredHotKeyReference
            registeredSummonHotkey = summonHotkey
        }
        return registrationStatus
    }
}
