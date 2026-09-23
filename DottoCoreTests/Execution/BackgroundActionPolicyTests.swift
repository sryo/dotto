import Foundation
import CoreGraphics

let backgroundActionPolicyTestSuite = CoreTestSuite(name: "BackgroundActionPolicy", testCases: [
    CoreTestCase(name: "known pointer and chooser actions are refused before action confirmation") {
        try expectTrue(BackgroundActionPolicy.requiresForeground(.uploadFiles(elementIdentifier: "e1", filePaths: ["/tmp/a"]), targetNode: nil))
        try expectTrue(BackgroundActionPolicy.requiresForeground(.clickScreenshotPoint(screenshotPixelPoint: .zero, clickType: .single), targetNode: nil))
        try expectTrue(BackgroundActionPolicy.requiresForeground(.clickElement(elementIdentifier: "e1", clickType: .double), targetNode: nil))
        try expectTrue(BackgroundActionPolicy.requiresForeground(.clickElement(elementIdentifier: "e1", clickType: .right), targetNode: nil))
    },
    CoreTestCase(name: "element actions that may work in the background still reach the delivery tiers") {
        try expectTrue(!BackgroundActionPolicy.requiresForeground(.clickElement(elementIdentifier: "e1", clickType: .single), targetNode: nil))
        try expectTrue(!BackgroundActionPolicy.requiresForeground(.pressKey(keyName: "a", modifiers: [.command]), targetNode: nil))
        try expectTrue(!BackgroundActionPolicy.requiresForeground(.typeText(elementIdentifier: "e1", text: "hello", replaceExistingText: false,
                                                                           pressReturnAfter: false), targetNode: nil))
    },
    CoreTestCase(name: "a recorded upload causes routine replay to yield to the agent in background-only mode") {
        let uploadStep = RoutineStep(stepDescription: "Attach a file", action: .uploadFiles(filePathTemplates: ["{{file}}"]),
                                     targetLocator: nil, expectation: nil, requiresConfirmationEachItem: true)
        let textStep = RoutineStep(stepDescription: "Type text", action: .typeText(textTemplate: "hello", replaceExistingText: false,
                                                                                 pressReturnAfter: false), targetLocator: nil,
                                   expectation: nil, requiresConfirmationEachItem: false)
        try expectTrue(BackgroundActionPolicy.requiresForeground(uploadStep))
        try expectTrue(!BackgroundActionPolicy.requiresForeground(textStep))
    },
])
