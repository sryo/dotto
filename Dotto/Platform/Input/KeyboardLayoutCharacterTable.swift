import AppKit
import Carbon.HIToolbox

/// A physical key plus the modifiers the current layout needs to produce a character on it
/// (for example "?" is shift+slash on US but shift+comma on French AZERTY).
struct LayoutKeyStroke: Equatable {
    var virtualKeyCode: CGKeyCode
    var requiredModifiers: [AgentKeyModifier]
}

/// Maps printable characters to key codes for the user's current keyboard layout, so press_key "z" hits the key
/// labelled Z on a German or French keyboard instead of the US-ANSI position. Rebuilt whenever the user switches
/// input sources. Lookups are lock-protected because the action backend reads from off the main thread.
final class KeyboardLayoutCharacterTable: @unchecked Sendable {
    private static let highestTranslatedVirtualKeyCode: UInt16 = 127

    // UCKeyTranslate wants the Carbon EventRecord modifier bits shifted down by 8.
    private static let modifierCombinationsInPreferenceOrder: [(modifiers: [AgentKeyModifier], carbonModifierKeyState: UInt32)] = [
        ([], 0),
        ([.shift], UInt32(shiftKey >> 8) & 0xFF),
        ([.option], UInt32(optionKey >> 8) & 0xFF),
        ([.shift, .option], UInt32((shiftKey | optionKey) >> 8) & 0xFF),
    ]

    /// Non-Latin layouts (Cyrillic, Greek, Hebrew...) define a separate key map for when command is held, which is
    /// where cmd+A and friends find their Latin letters.
    private static let commandHeldCarbonModifierKeyState = UInt32(cmdKey >> 8) & 0xFF

    private let tableLock = NSLock()
    private var keyStrokesByCharacter: [Character: LayoutKeyStroke] = [:]
    private var keyStrokesByCharacterWhileCommandHeld: [Character: LayoutKeyStroke] = [:]
    private var inputSourceChangeObserver: NSObjectProtocol?

    init() {
        inputSourceChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildFromCurrentKeyboardLayout()
        }
        // Text Input Sources APIs must run on the main thread.
        if Thread.isMainThread {
            rebuildFromCurrentKeyboardLayout()
        } else {
            DispatchQueue.main.async { [weak self] in self?.rebuildFromCurrentKeyboardLayout() }
        }
    }

    deinit {
        if let inputSourceChangeObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceChangeObserver)
        }
    }

    /// False when the current input source exposes no Unicode layout data (rare legacy layouts); callers then
    /// fall back to US-ANSI key codes.
    var hasLayoutData: Bool {
        tableLock.lock()
        defer { tableLock.unlock() }
        return !keyStrokesByCharacter.isEmpty
    }

    /// Looks in the plain layout first, then in the command-held key map (only reachable with command pressed).
    func keyStroke(producing character: Character) -> LayoutKeyStroke? {
        tableLock.lock()
        defer { tableLock.unlock() }
        return keyStrokesByCharacter[character] ?? keyStrokesByCharacterWhileCommandHeld[character]
    }

    func unmodifiedCharacter(forVirtualKeyCode virtualKeyCode: CGKeyCode) -> Character? {
        tableLock.lock()
        defer { tableLock.unlock() }
        return keyStrokesByCharacter.first { $0.value.virtualKeyCode == virtualKeyCode && $0.value.requiredModifiers.isEmpty }?.key
    }

    private func rebuildFromCurrentKeyboardLayout() {
        let rebuiltKeyStrokesByCharacter = Self.readCurrentKeyboardLayout(
            modifierCombinations: Self.modifierCombinationsInPreferenceOrder)
        let rebuiltKeyStrokesByCharacterWhileCommandHeld = Self.readCurrentKeyboardLayout(
            modifierCombinations: [([], Self.commandHeldCarbonModifierKeyState)])
        tableLock.lock()
        keyStrokesByCharacter = rebuiltKeyStrokesByCharacter
        keyStrokesByCharacterWhileCommandHeld = rebuiltKeyStrokesByCharacterWhileCommandHeld
        tableLock.unlock()
    }

    private static func readCurrentKeyboardLayout(
        modifierCombinations: [(modifiers: [AgentKeyModifier], carbonModifierKeyState: UInt32)]
    ) -> [Character: LayoutKeyStroke] {
        guard let currentLayoutInputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(currentLayoutInputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data
        let physicalKeyboardType = UInt32(LMGetKbdType())

        var translatedKeyStrokesByCharacter: [Character: LayoutKeyStroke] = [:]
        layoutData.withUnsafeBytes { layoutDataBuffer in
            guard let layoutBaseAddress = layoutDataBuffer.baseAddress else { return }
            let keyboardLayout = layoutBaseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            // Fewer modifiers win: combinations are visited in preference order and the first key found is kept,
            // and within one combination lower key codes (main block) come before the keypad.
            for modifierCombination in modifierCombinations {
                for virtualKeyCode in 0...highestTranslatedVirtualKeyCode {
                    var deadKeyState: UInt32 = 0
                    var producedCodeUnits = [UniChar](repeating: 0, count: 4)
                    var producedCodeUnitCount = 0
                    let translateStatus = UCKeyTranslate(
                        keyboardLayout, virtualKeyCode, UInt16(kUCKeyActionDown), modifierCombination.carbonModifierKeyState,
                        physicalKeyboardType, OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                        producedCodeUnits.count, &producedCodeUnitCount, &producedCodeUnits)
                    guard translateStatus == noErr, producedCodeUnitCount > 0 else { continue }
                    let producedText = String(utf16CodeUnits: producedCodeUnits, count: producedCodeUnitCount)
                    guard producedText.count == 1, let producedCharacter = producedText.first,
                          isPrintableCharacter(producedCharacter),
                          translatedKeyStrokesByCharacter[producedCharacter] == nil else { continue }
                    translatedKeyStrokesByCharacter[producedCharacter] = LayoutKeyStroke(
                        virtualKeyCode: CGKeyCode(virtualKeyCode), requiredModifiers: modifierCombination.modifiers)
                }
            }
        }
        return translatedKeyStrokesByCharacter
    }

    /// Excludes control characters, space (handled as the named key "space"), and the private-use range AppKit
    /// reports for function and arrow keys.
    private static func isPrintableCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { unicodeScalar in
            let scalarValue = unicodeScalar.value
            let isControlCharacter = scalarValue < 0x21 || scalarValue == 0x7F
            let isFunctionKeyPrivateUse = (0xF700...0xF8FF).contains(scalarValue)
            return !isControlCharacter && !isFunctionKeyPrivateUse
        }
    }
}
