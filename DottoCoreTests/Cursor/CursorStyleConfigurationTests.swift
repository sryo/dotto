import Foundation

private let sampleAttentionRequest = UserAttentionRequest(requestIdentifier: "attention-1", kind: .needsDecision, title: "Dotto needs your OK",
                                                          bodyText: "“Reply”: send?", decisionOptions: [])

let cursorStyleConfigurationTestSuite = CoreTestSuite(name: "CursorStyleConfiguration", testCases: [
    CoreTestCase(name: "the defaults are the owner's") {
        let standard = CursorStyleConfiguration.standard
        try expectEqual(standard.taskColorHex, "#F0532D")
        try expectEqual(standard.statusStyle, .chat)
        try expectEqual(standard.cursorScale, 1)
        try expectEqual(standard.motionSpeed, 1)
        try expectEqual(standard.reduceMotion, nil)
        let colorComponents = standard.taskColorRedGreenBlue
        try expectEqual([colorComponents.red, colorComponents.green, colorComponents.blue], [240.0 / 255, 83.0 / 255, 45.0 / 255])
    },
    CoreTestCase(name: "the prototype's copied JSON decodes, missing keys keep defaults and ranges are clamped") {
        let copiedJSON = ##"{"taskColor":"#2B59FF","statusStyle":"ring","cursorScale":1.25,"motionSpeed":9,"reduceMotion":true,"pauseOnlyForClicksInTargetApp":false}"##
        let decoded = try CursorStyleConfiguration.decodingOwnerJSON(Data(copiedJSON.utf8))
        try expectEqual(decoded.taskColorHex, "#2B59FF")
        try expectEqual(decoded.statusStyle, .ring)
        try expectEqual(decoded.cursorScale, 1.25)
        try expectEqual(decoded.motionSpeed, 3)
        try expectEqual(decoded.reduceMotion, true)
        try expectEqual(decoded.pauseOnlyForClicksInTargetApp, false)
        try expectEqual(try CursorStyleConfiguration.decodingOwnerJSON(Data(#"{"statusStyle":"quiet"}"#.utf8)),
                        { var expected = CursorStyleConfiguration.standard; expected.statusStyle = .quiet; return expected }())
    },
    CoreTestCase(name: "an unparsable color falls back to the default") {
        var configuration = CursorStyleConfiguration.standard
        configuration.taskColorHex = "orange"
        let fallbackComponents = configuration.taskColorRedGreenBlue
        try expectEqual(fallbackComponents.red, 240.0 / 255)
    },
    CoreTestCase(name: "notifications are opt-in; with them on, notifications and sound wait until the user looks away") {
        try expectEqual(AttentionPreferences.standard.deliveryChannels(for: sampleAttentionRequest, targetOrThisAppIsFrontmost: false),
                        AttentionDeliveryChannels(postsNotification: false, playsSound: true, pulsesMenuBarIcon: true))
        var preferences = AttentionPreferences.standard
        preferences.notificationsEnabled = true
        try expectEqual(preferences.deliveryChannels(for: sampleAttentionRequest, targetOrThisAppIsFrontmost: false),
                        AttentionDeliveryChannels(postsNotification: true, playsSound: true, pulsesMenuBarIcon: true))
        try expectEqual(preferences.deliveryChannels(for: sampleAttentionRequest, targetOrThisAppIsFrontmost: true),
                        AttentionDeliveryChannels(postsNotification: false, playsSound: false, pulsesMenuBarIcon: true))
        var finishedRequest = sampleAttentionRequest
        finishedRequest.kind = .finished
        try expectEqual(preferences.deliveryChannels(for: finishedRequest, targetOrThisAppIsFrontmost: false).playsSound, false)
        var alwaysNotify = preferences
        alwaysNotify.notifyOnlyWhenTargetOrThisAppNotFrontmost = false
        alwaysNotify.menuBarPulseEnabled = false
        try expectEqual(alwaysNotify.deliveryChannels(for: sampleAttentionRequest, targetOrThisAppIsFrontmost: true),
                        AttentionDeliveryChannels(postsNotification: true, playsSound: true, pulsesMenuBarIcon: false))
    },
])
