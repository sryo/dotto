import Foundation

private let templatingParameters = [ChecklistItemParameter(name: "old_name", value: "IMG_0412.jpg"),
                                    ChecklistItemParameter(name: "stem", value: "IMG_0412"),
                                    ChecklistItemParameter(name: "index", value: "1")]

let routineTemplatingTestSuite = CoreTestSuite(name: "RoutineTemplating", testCases: [
    CoreTestCase(name: "render fills every placeholder and never expands placeholders inside values") {
        try expectEqual(try RoutineTemplating.render("Rename {{old_name}} ({{ stem }})", parameters: templatingParameters),
                        "Rename IMG_0412.jpg (IMG_0412)")
        let trickyParameters = [ChecklistItemParameter(name: "a", value: "{{b}}"), ChecklistItemParameter(name: "b", value: "x")]
        try expectEqual(try RoutineTemplating.render("{{a}}-{{b}}", parameters: trickyParameters), "{{b}}-x")
        try expectEqual(try RoutineTemplating.render("no placeholders", parameters: []), "no placeholders")
    },
    CoreTestCase(name: "an unknown placeholder throws") {
        let thrownError = try expectThrowsError { _ = try RoutineTemplating.render("{{caption}}", parameters: templatingParameters) }
        try expectTrue((thrownError as? RoutineTemplateError)?.message.contains("caption") == true)
    },
    CoreTestCase(name: "templatize replaces the longest value first and ignores 1-character values") {
        try expectEqual(RoutineTemplating.templatize("IMG_0412.jpg was IMG_0412 in folder 1", parameters: templatingParameters),
                        "{{old_name}} was {{stem}} in folder 1")
        try expectEqual(RoutineTemplating.templatize("", parameters: templatingParameters), "")
    },
    CoreTestCase(name: "placeholderNames lists unique names in order") {
        try expectEqual(RoutineTemplating.placeholderNames(in: "{{b}} {{a}} {{b}} {{ c }}"), ["b", "a", "c"])
        try expectEqual(RoutineTemplating.placeholderNames(in: "plain"), [])
    },
])
