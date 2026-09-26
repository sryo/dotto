import Foundation
import CoreGraphics

let liveViewStackTestSuite = CoreTestSuite(name: "LiveViewStack", testCases: [
    CoreTestCase(name: "the first live view is expanded; the ones after it arrive as chips") {
        var stack = LiveViewStack()
        stack.show("a")
        stack.show("b")
        stack.show("c")
        try expectTrue(!stack.isCollapsed("a"))
        try expectTrue(stack.isCollapsed("b"))
        try expectTrue(stack.isCollapsed("c"))
    },
    CoreTestCase(name: "expanding a chip collapses the expanded one; toggling it again collapses everything") {
        var stack = LiveViewStack()
        stack.show("a")
        stack.show("b")
        stack.toggle("b")
        try expectEqual(stack.expandedIdentifier, "b")
        try expectTrue(stack.isCollapsed("a"))
        stack.toggle("b")
        try expectEqual(stack.expandedIdentifier, nil)
        stack.toggle("zzz")
        try expectEqual(stack.expandedIdentifier, nil, "a live view that isn't shown can't be expanded")
    },
    CoreTestCase(name: "hiding the expanded one leaves the chips as they are, and the next one shown expands") {
        var stack = LiveViewStack()
        stack.show("a")
        stack.show("b")
        stack.hide("a")
        try expectEqual(stack.expandedIdentifier, nil)
        try expectTrue(stack.isCollapsed("b"))
        stack.show("c")
        try expectEqual(stack.expandedIdentifier, "c")
    },
    CoreTestCase(name: "a live view the user collapsed comes back collapsed until its task ends") {
        var stack = LiveViewStack()
        stack.show("a")
        stack.toggle("a")
        stack.hide("a")
        stack.show("a")
        try expectTrue(stack.isCollapsed("a"))
        stack.hide("a")
        stack.forgetUserChoice("a")
        stack.show("a")
        try expectTrue(!stack.isCollapsed("a"))
    },
    CoreTestCase(name: "each live view sits past the ones before it, with spacing") {
        var stack = LiveViewStack()
        stack.show("a")
        stack.show("b")
        stack.show("c")
        let offsets = stack.stackOffsetsInPoints(heightsInPoints: ["a": 200, "b": 40, "c": 40])
        try expectEqual(offsets, ["a": 0, "b": 208, "c": 256])
    },
])
