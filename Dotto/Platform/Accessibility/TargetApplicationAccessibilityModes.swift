import AppKit
import ApplicationServices

/// Chromium and Electron only build a full Accessibility tree, and Chromium only answers AXPress in web content,
/// once an assistive client switches these modes on. They are set per task, and every prior value is put back
/// at the end of the task, on cancel, on dismiss and at quit.
///
/// Every change is also written to a small file, so values a crashed Dotto left on are put back at the next launch.
/// EUI makes some apps animate windows and move them oddly, so a stale one is worth undoing.
actor TargetApplicationAccessibilityModes {
    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let enhancedUserInterfaceSettleNanoseconds: UInt64 = 1_000_000_000
    private static let changedModesFileName = "ChangedAccessibilityModes.json"

    /// The process launch date guards against a recycled pid: after a crash the app may have quit and another process
    /// may have got its pid.
    private struct RecordedPriorValue: Codable, Equatable {
        var processIdentifier: pid_t
        var bundleIdentifier: String?
        var processLaunchTimeIntervalSince1970: Double?
        var attributeName: String
        var priorValue: Bool
    }

    private let changedModesFileURL: URL?
    private var recordedPriorValues: [RecordedPriorValue] = []
    private var remoteAwareObserver: AXObserver?
    private var remoteAwareRegistrations: [(element: AXUIElement, notificationName: String)] = []
    /// Bumped by every restoreAll. enable() sleeps for a second after setting EUI; a restore that ran meanwhile has
    /// already put the prior value back, so enable must not report EUI as on.
    private var restoreGeneration = 0

    /// Puts back whatever a previous launch left recorded (it can only still be there if Dotto crashed or was killed).
    init(changedModesDirectoryURL: URL? = TargetApplicationAccessibilityModes.defaultChangedModesDirectoryURL()) {
        changedModesFileURL = changedModesDirectoryURL?.appendingPathComponent(Self.changedModesFileName, isDirectory: false)
        if let changedModesFileURL {
            Self.restorePriorValuesLeftByPreviousLaunch(recordedIn: changedModesFileURL)
        }
    }

    nonisolated static func defaultChangedModesDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dotto", isDirectory: true)
    }

    /// Framework names come from the bundle, so an Electron app with an unknown bundle id is still recognised.
    nonisolated static func applicationKind(of application: TargetApplicationReference) -> TargetApplicationKind {
        let bundleURL = NSRunningApplication(processIdentifier: application.processIdentifier)?.bundleURL
        let frameworksURL = bundleURL?.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let embeddedFrameworkNames = frameworksURL.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        return TargetApplicationKindClassifier.classify(bundleIdentifier: application.bundleIdentifier,
                                                        embeddedFrameworkNames: embeddedFrameworkNames)
    }

    /// Sets the modes `AccessibilityModePolicy` names for the app kind, remembering prior values, and registers the
    /// remote-aware observer. With EUI it waits until 1 s has passed since the set and reads EUI back. Returns whether
    /// EUI is verified on.
    func enable(for application: TargetApplicationReference, applicationKind: TargetApplicationKind,
                windowServerBridge: PrivateWindowServerBridge) async -> Bool {
        let modePolicy = AccessibilityModePolicy.policy(
            for: applicationKind, canKeepRemoteAccessibilityTreeAlive: windowServerBridge.capabilities.canKeepRemoteAccessibilityTreeAlive)
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: application.processIdentifier)
        if modePolicy.setsManualAccessibility {
            setRecordingPriorValue(Self.manualAccessibilityAttribute, on: applicationElement, of: application.processIdentifier)
        }
        if !modePolicy.remoteObserverNotificationNames.isEmpty {
            await registerRemoteAwareObserver(for: application.processIdentifier,
                                              notificationNames: modePolicy.remoteObserverNotificationNames,
                                              windowServerBridge: windowServerBridge)
        }
        guard modePolicy.setsEnhancedUserInterface else { return false }
        setRecordingPriorValue(Self.enhancedUserInterfaceAttribute, on: applicationElement, of: application.processIdentifier)
        let restoreGenerationBeforeSettling = restoreGeneration
        try? await Task.sleep(nanoseconds: Self.enhancedUserInterfaceSettleNanoseconds)
        guard restoreGeneration == restoreGenerationBeforeSettling else { return false }
        return AccessibilityElementReader.boolAttribute(Self.enhancedUserInterfaceAttribute, of: applicationElement) == true
    }

    func restoreAll() {
        restoreGeneration += 1
        for recordedPriorValue in recordedPriorValues.reversed() {
            Self.putBack(recordedPriorValue)
        }
        recordedPriorValues = []
        persistRecordedPriorValues()
        if let remoteAwareObserver {
            // Removed explicitly: while a registration stands, Blink keeps paying to keep the covered tree live.
            for (observedElement, notificationName) in remoteAwareRegistrations {
                _ = AXObserverRemoveNotification(remoteAwareObserver, observedElement, notificationName as CFString)
            }
            let observerRunLoopSource = AXObserverGetRunLoopSource(remoteAwareObserver)
            DispatchQueue.main.async { CFRunLoopRemoveSource(CFRunLoopGetMain(), observerRunLoopSource, .defaultMode) }
            self.remoteAwareObserver = nil
        }
        remoteAwareRegistrations = []
    }

    /// An unreadable prior value counts as false, so restore switches the mode off again.
    private func setRecordingPriorValue(_ attributeName: String, on applicationElement: AXUIElement, of processIdentifier: pid_t) {
        let alreadyRecorded = recordedPriorValues.contains {
            $0.processIdentifier == processIdentifier && $0.attributeName == attributeName
        }
        if !alreadyRecorded {
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
            recordedPriorValues.append(RecordedPriorValue(
                processIdentifier: processIdentifier, bundleIdentifier: runningApplication?.bundleIdentifier,
                processLaunchTimeIntervalSince1970: runningApplication?.launchDate?.timeIntervalSince1970,
                attributeName: attributeName, priorValue: AccessibilityElementReader.boolAttribute(attributeName, of: applicationElement) ?? false))
            // Written before the change, so a crash right after it still leaves the record behind.
            persistRecordedPriorValues()
        }
        _ = AXUIElementSetAttributeValue(applicationElement, attributeName as CFString, kCFBooleanTrue)
    }

    private static func putBack(_ recordedPriorValue: RecordedPriorValue) {
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: recordedPriorValue.processIdentifier)
        _ = AXUIElementSetAttributeValue(applicationElement, recordedPriorValue.attributeName as CFString,
                                         recordedPriorValue.priorValue ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Nothing recorded means no file. The file is only readable by the user, like the rest of Dotto's data.
    private func persistRecordedPriorValues() {
        guard let changedModesFileURL else { return }
        if recordedPriorValues.isEmpty {
            try? FileManager.default.removeItem(at: changedModesFileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(at: changedModesFileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(recordedPriorValues).write(to: changedModesFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: changedModesFileURL.path)
        } catch {
            print("Dotto: couldn't record the accessibility modes it changed: \(error.localizedDescription)")
        }
    }

    /// Only a process that is still the same launch of the same app gets its value back; anything else is dropped.
    private static func restorePriorValuesLeftByPreviousLaunch(recordedIn changedModesFileURL: URL) {
        guard let recordedData = try? Data(contentsOf: changedModesFileURL) else { return }
        let leftoverPriorValues = (try? JSONDecoder().decode([RecordedPriorValue].self, from: recordedData)) ?? []
        for leftoverPriorValue in leftoverPriorValues.reversed() {
            guard let runningApplication = NSRunningApplication(processIdentifier: leftoverPriorValue.processIdentifier),
                  runningApplication.bundleIdentifier == leftoverPriorValue.bundleIdentifier,
                  runningApplication.launchDate?.timeIntervalSince1970 == leftoverPriorValue.processLaunchTimeIntervalSince1970 else {
                continue
            }
            putBack(leftoverPriorValue)
        }
        try? FileManager.default.removeItem(at: changedModesFileURL)
    }

    /// The observer only exists so Blink keeps the tree live while the window is covered; its callback does nothing.
    private func registerRemoteAwareObserver(for processIdentifier: pid_t, notificationNames: [String],
                                             windowServerBridge: PrivateWindowServerBridge) async {
        guard remoteAwareObserver == nil else { return }
        var createdObserver: AXObserver?
        guard AXObserverCreate(processIdentifier, { _, _, _, _ in }, &createdObserver) == .success, let createdObserver else { return }
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: processIdentifier)
        var registrations: [(element: AXUIElement, notificationName: String)] = []
        for notificationName in notificationNames where windowServerBridge.addRemoteAwareNotification(
            notificationName, to: createdObserver, element: applicationElement, context: nil) == .success {
            registrations.append((applicationElement, notificationName))
        }
        guard !registrations.isEmpty else { return }
        let observerRunLoopSource = AXObserverGetRunLoopSource(createdObserver)
        await MainActor.run { CFRunLoopAddSource(CFRunLoopGetMain(), observerRunLoopSource, .defaultMode) }
        remoteAwareObserver = createdObserver
        remoteAwareRegistrations = registrations
    }
}
