import Foundation

let agentToolCatalogTestSuite = CoreTestSuite(name: "AgentToolCatalog", testCases: [
    CoreTestCase(name: "the planner's strict tools stay the set the API compiles, and direct-route tools are not strict") {
        let strictPlannerToolNames = Set(AgentToolCatalog.plannerTools.filter(\.isStrict).map(\.name))
        try expectEqual(strictPlannerToolNames, Set(AgentToolCatalog.strictPlannerToolNames.map(\.rawValue)))
        for directRouteTool in AgentToolCatalog.directRoutePlannerTools {
            try expectTrue(!directRouteTool.isStrict, directRouteTool.name)
        }
    },
])
