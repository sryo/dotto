import Foundation

let plannerConversationModelsTestSuite = CoreTestSuite(name: "PlannerConversationModels", testCases: [
    CoreTestCase(name: "the transcript starts with the command and keeps questions and replies in order") {
        var transcript = PlannerConversationTranscript(command: "rename the photos")
        try expectEqual(transcript.containsPlannerMessages, false)
        try expectEqual(transcript.latestUnansweredQuestionEntry, nil)
        let folderQuestion = PlannerQuestion(text: "Which folder?", choices: [PlannerQuestionChoice(label: "Desktop", detail: nil)],
                                             allowsFreeText: true)
        transcript.appendPlannerQuestion(folderQuestion)
        try expectEqual(transcript.containsPlannerMessages, true)
        try expectEqual(transcript.latestUnansweredQuestionEntry?.choices, folderQuestion.choices)
        transcript.appendUserMessage("Desktop")
        try expectEqual(transcript.latestUnansweredQuestionEntry, nil)
        try expectEqual(transcript.entries.map(\.author), [.user, .dotto, .user])
        try expectEqual(transcript.entries.map(\.text), ["rename the photos", "Which folder?", "Desktop"])
        try expectEqual(transcript.entries.map(\.id), [0, 1, 2])
    },
    CoreTestCase(name: "a blocking explanation takes no reply; any question with a choice or free text does") {
        try expectEqual(PlannerQuestion.blockingExplanation("Dotto can't see any files.").acceptsReply, false)
        try expectEqual(PlannerQuestion(text: "q", choices: [PlannerQuestionChoice(label: "a", detail: nil)], allowsFreeText: false).acceptsReply, true)
        try expectEqual(PlannerQuestion(text: "q", choices: [], allowsFreeText: true).acceptsReply, true)
    },
    CoreTestCase(name: "markdown is stripped to plain words, keeping paragraphs") {
        let markdownText = """
        # Which folder?

        Dotto found **two** folders named `Photos`:
        1. Desktop
        - [Downloads](https://example.com/x) with *12* files
        ---


        > Pick one.
        """
        try expectEqual(PlannerPlainText.paragraphs(fromMarkdown: markdownText, maximumLength: 600),
                        "Which folder?\n\nDotto found two folders named Photos:\n1. Desktop\nDownloads with 12 files\n\nPick one.")
        try expectEqual(PlannerPlainText.singleLine(fromMarkdown: "**Keep**\n5 * 3 and snake_case", maximumLength: 80),
                        "Keep 5 * 3 and snake_case")
    },
    CoreTestCase(name: "long text is cut with an ellipsis") {
        try expectEqual(PlannerPlainText.singleLine(fromMarkdown: "abcdefghij", maximumLength: 5), "abcd…")
        try expectEqual(PlannerPlainText.singleLine(fromMarkdown: "abcde", maximumLength: 5), "abcde")
    },
])
