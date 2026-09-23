import AppKit
import ApplicationServices

/// The only place Dotto touches private window-server and Accessibility symbols. Every symbol is resolved with dlsym
/// once at launch, and a missing one only switches off the tiers that need it.
///
/// It is deliberately small: window ids for AX windows, the remote-aware AX observer, the
/// authenticated keyboard path for Chromium and Electron (which the planner uses only once it is approved), and the
/// window location of pointer events, which the foreground assist needs for a per-process click to land. There are
/// no focus-without-raise records and no background clicks: both could disturb the user's front window.
final class PrivateWindowServerBridge: @unchecked Sendable {
    private typealias PostEventToProcessFunction = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetEventWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias SetAuthenticationMessageFunction = @convention(c) (CGEvent, AnyObject) -> Void
    // +[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:] called through objc_msgSend.
    private typealias AuthenticationMessageFactoryFunction =
        @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> AnyObject?
    private typealias WindowOfAccessibilityElementFunction =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AddRemoteAwareNotificationFunction =
        @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError

    private static let skyLightFrameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let applicationServicesFrameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    private static let authenticationMessageClassName = "SLSEventAuthenticationMessage"
    private static let authenticationMessageFactorySelectorName = "messageWithEventRecord:pid:version:"
    /// A CGEvent is a CFRuntimeBase (16 bytes) plus a 4-byte type and padding, then the pointer to its event record.
    private static let eventRecordPointerByteOffset = 24
    /// The event record as the window server lays it out (checked on macOS 27): a 32-bit record length at byte 4, the
    /// 32-bit event type at byte 8 and the location as two doubles at byte 16. A record that doesn't match all of these
    /// is not passed on, because the factory would read whatever the pointer happens to point at.
    private static let eventRecordLengthByteOffset = 4
    private static let eventRecordTypeByteOffset = 8
    private static let eventRecordLocationByteOffset = 16
    private static let minimumPlausibleEventRecordLength = 32
    private static let maximumPlausibleEventRecordLength = 4096

    let capabilities: PrivateWindowServerCapabilities

    private let postEventToProcess: PostEventToProcessFunction?
    private let setEventWindowLocation: SetEventWindowLocationFunction?
    private let setAuthenticationMessage: SetAuthenticationMessageFunction?
    private let authenticationMessageFactory: AuthenticationMessageFactoryFunction?
    private let authenticationMessageClass: AnyClass?
    private let windowOfAccessibilityElement: WindowOfAccessibilityElementFunction?
    private let addRemoteAwareNotificationFunction: AddRemoteAwareNotificationFunction?

    init() {
        let skyLightHandle = dlopen(Self.skyLightFrameworkPath, RTLD_NOW)
        let applicationServicesHandle = dlopen(Self.applicationServicesFrameworkPath, RTLD_NOW)
        let defaultHandle = dlopen(nil, RTLD_NOW)

        func resolvedSymbol<FunctionType>(_ symbolName: String, in libraryHandles: [UnsafeMutableRawPointer?],
                                          as functionType: FunctionType.Type) -> FunctionType? {
            for libraryHandle in libraryHandles {
                guard let libraryHandle, let symbolAddress = dlsym(libraryHandle, symbolName) else { continue }
                return unsafeBitCast(symbolAddress, to: functionType)
            }
            return nil
        }

        postEventToProcess = resolvedSymbol("SLEventPostToPid", in: [skyLightHandle], as: PostEventToProcessFunction.self)
        setEventWindowLocation = resolvedSymbol("CGEventSetWindowLocation", in: [skyLightHandle, defaultHandle],
                                                as: SetEventWindowLocationFunction.self)
        setAuthenticationMessage = resolvedSymbol("SLEventSetAuthenticationMessage", in: [skyLightHandle],
                                                  as: SetAuthenticationMessageFunction.self)
        authenticationMessageFactory = resolvedSymbol("objc_msgSend", in: [defaultHandle],
                                                      as: AuthenticationMessageFactoryFunction.self)
        windowOfAccessibilityElement = resolvedSymbol("_AXUIElementGetWindow", in: [applicationServicesHandle, defaultHandle],
                                                      as: WindowOfAccessibilityElementFunction.self)
        addRemoteAwareNotificationFunction = resolvedSymbol("_AXObserverAddNotificationAndCheckRemote",
                                                            in: [applicationServicesHandle, defaultHandle],
                                                            as: AddRemoteAwareNotificationFunction.self)

        // The class exists on macOS 14 without the factory selector, so both are checked.
        var resolvedAuthenticationMessageClass: AnyClass?
        if let candidateClass = NSClassFromString(Self.authenticationMessageClassName),
           class_respondsToSelector(object_getClass(candidateClass), NSSelectorFromString(Self.authenticationMessageFactorySelectorName)) {
            resolvedAuthenticationMessageClass = candidateClass
        }
        authenticationMessageClass = resolvedAuthenticationMessageClass

        // The record layout is checked once on a throwaway event; an OS that moved it switches the path off here.
        let authenticationSymbolsArePresent = resolvedAuthenticationMessageClass != nil && setAuthenticationMessage != nil
            && authenticationMessageFactory != nil && Self.eventRecordLayoutIsRecognized()
        capabilities = PrivateWindowServerCapabilities(
            canPostEventsThroughWindowServer: postEventToProcess != nil,
            canAuthenticateKeyboardEvents: authenticationSymbolsArePresent,
            canResolveWindowOfAccessibilityElement: windowOfAccessibilityElement != nil,
            canKeepRemoteAccessibilityTreeAlive: addRemoteAwareNotificationFunction != nil)
        print("Dotto window-server capabilities: \(capabilities.auditDescription) location=\(canSetEventWindowLocation ? 1 : 0)")
    }

    /// Without it the foreground assist can't click at a point, and such steps fail cleanly.
    var canSetEventWindowLocation: Bool { setEventWindowLocation != nil }

    /// A per-process pointer event carries no hit test, so AppKit needs the point relative to the window it is for.
    func setWindowLocation(_ windowLocation: CGPoint, on event: CGEvent) {
        setEventWindowLocation?(event, windowLocation)
    }

    func windowIdentifier(ofAccessibilityWindow accessibilityWindow: AXUIElement) -> CGWindowID? {
        guard let windowOfAccessibilityElement else { return nil }
        var windowIdentifier: CGWindowID = 0
        guard windowOfAccessibilityElement(accessibilityWindow, &windowIdentifier) == .success, windowIdentifier != 0 else {
            return nil
        }
        return windowIdentifier
    }

    /// Posts through the window server to one process. With the authentication message, Chromium and Electron accept
    /// synthesized keys that they otherwise drop. Returns false when the path isn't available, so nothing was posted.
    func postEvent(_ event: CGEvent, toProcess processIdentifier: pid_t, attachingAuthenticationMessage: Bool) -> Bool {
        guard let postEventToProcess, processIdentifier > 0 else { return false }
        if attachingAuthenticationMessage {
            guard capabilities.canAuthenticateKeyboardEvents, let authenticationMessage = makeAuthenticationMessage(
                for: event, processIdentifier: processIdentifier) else { return false }
            setAuthenticationMessage?(event, authenticationMessage)
        }
        postEventToProcess(processIdentifier, event)
        return true
    }

    /// The public AXObserverAddNotification doesn't tell Blink that someone is listening, so an occluded Electron or
    /// Chromium window stops updating its tree. Returns nil when the private variant is unavailable.
    func addRemoteAwareNotification(_ notificationName: String, to observer: AXObserver, element: AXUIElement,
                                    context: UnsafeMutableRawPointer?) -> AXError? {
        guard let addRemoteAwareNotificationFunction else { return nil }
        return addRemoteAwareNotificationFunction(observer, element, notificationName as CFString, context)
    }

    private func makeAuthenticationMessage(for event: CGEvent, processIdentifier: pid_t) -> AnyObject? {
        guard let authenticationMessageClass, let authenticationMessageFactory,
              let eventRecordPointer = Self.validatedEventRecordPointer(of: event) else { return nil }
        return authenticationMessageFactory(authenticationMessageClass as AnyObject,
                                            NSSelectorFromString(Self.authenticationMessageFactorySelectorName),
                                            eventRecordPointer, processIdentifier, 0)
    }

    private static func eventRecordLayoutIsRecognized() -> Bool {
        guard let layoutCheckEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return false }
        layoutCheckEvent.location = CGPoint(x: 123.5, y: 456.25)
        return validatedEventRecordPointer(of: layoutCheckEvent) != nil
    }

    /// Returns the event's record pointer only when every read stays inside allocations malloc vouches for and the
    /// record's type and location match the event's own public values. Anything else returns nil, and the key is
    /// then not posted on the authenticated path.
    private static func validatedEventRecordPointer(of event: CGEvent) -> UnsafeMutableRawPointer? {
        let eventAddress = Unmanaged.passUnretained(event).toOpaque()
        guard malloc_size(eventAddress) >= eventRecordPointerByteOffset + MemoryLayout<UnsafeMutableRawPointer>.size,
              let eventRecordPointer = eventAddress.load(fromByteOffset: eventRecordPointerByteOffset,
                                                         as: UnsafeMutableRawPointer?.self) else { return nil }
        let eventRecordAllocationSize = malloc_size(eventRecordPointer)
        guard eventRecordAllocationSize >= eventRecordLocationByteOffset + 2 * MemoryLayout<Double>.size else { return nil }
        let eventRecordLength = Int(eventRecordPointer.load(fromByteOffset: eventRecordLengthByteOffset, as: UInt32.self))
        let eventRecordType = eventRecordPointer.load(fromByteOffset: eventRecordTypeByteOffset, as: UInt32.self)
        let eventRecordLocation = CGPoint(
            x: eventRecordPointer.load(fromByteOffset: eventRecordLocationByteOffset, as: Double.self),
            y: eventRecordPointer.load(fromByteOffset: eventRecordLocationByteOffset + MemoryLayout<Double>.size, as: Double.self))
        guard eventRecordLength >= minimumPlausibleEventRecordLength, eventRecordLength <= maximumPlausibleEventRecordLength,
              eventRecordLength <= eventRecordAllocationSize,
              eventRecordType == event.type.rawValue,
              eventRecordLocation == event.location else { return nil }
        return eventRecordPointer
    }
}
