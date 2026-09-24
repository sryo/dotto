import Foundation

enum AgentToolCatalog {

    static let plannerTools: [ClaudeToolDefinition] = [readUserInterfaceTool, screenshotTool, askUserTool, submitPlanTool]
        + directRoutePlannerTools
    static let executorTools: [ClaudeToolDefinition] = [readUserInterfaceTool, screenshotTool, clickTool, typeTextTool,
                                                        replaceTextTool, pressKeyTool, scrollTool, clickPointTool, uploadFilesTool,
                                                        waitForTool, finishItemTool]
    static let routineCompilerTools: [ClaudeToolDefinition] = [submitRoutineTool]

    // Descriptions and schemas are part of the cached prompt prefix: never interpolate runtime values into them.
    static func makeStrictTool(_ toolName: AgentToolName, description: String, inputSchemaJSONText: String) -> ClaudeToolDefinition {
        makeTool(toolName, description: description, inputSchemaJSONText: inputSchemaJSONText, isStrict: true)
    }

    /// The API compiles every strict schema in a request into one grammar and refuses the request when that grammar
    /// is too large, so the planner keeps its strict set small (`strictPlannerToolNames`). Tools outside that set
    /// still send their schema; `AgentToolCallDecoder` checks every input's types either way.
    static func makeNonStrictTool(_ toolName: AgentToolName, description: String, inputSchemaJSONText: String) -> ClaudeToolDefinition {
        makeTool(toolName, description: description, inputSchemaJSONText: inputSchemaJSONText, isStrict: false)
    }

    private static func makeTool(_ toolName: AgentToolName, description: String, inputSchemaJSONText: String,
                                 isStrict: Bool) -> ClaudeToolDefinition {
        guard let inputSchema = try? JSONValue(parsingJSONText: inputSchemaJSONText) else {
            preconditionFailure("Invalid JSON schema literal for tool \(toolName.rawValue)")
        }
        return ClaudeToolDefinition(name: toolName.rawValue, description: description, inputSchema: inputSchema, isStrict: isStrict)
    }

    /// The planner's strict tools: the set the API accepted before direct routes were added. More strict schemas in
    /// the planner's request made the API answer "The compiled grammar is too large".
    static let strictPlannerToolNames: Set<AgentToolName> = [.readUserInterface, .screenshot, .askUser, .submitPlan]

    private static let expectSchemaFragment = #"""
    "expect":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,
       "properties":{"kind":{"type":"string","enum":["text_appears","text_disappears","field_value_equals","window_title_contains","document_contains"]},
                     "text":{"type":"string"}},
       "required":["kind","text"]}],
      "description":"What must be true in the target app right after this action; the app checks it for up to 3 seconds. null if nothing checkable."}
    """#

    private static let evidenceSchemaFragment = #"""
    {"type":"object","additionalProperties":false,
       "properties":{"kind":{"type":"string","enum":["text_appears","text_disappears","field_value_equals","window_title_contains","document_contains","none"]},
                     "text":{"type":"string"}},
       "required":["kind","text"],
      "description":"A check the app runs on a fresh outline to confirm the item is done. Required for completed; kind none only for failed or needs_user."}
    """#

    private static let readUserInterfaceTool = makeStrictTool(.readUserInterface,
        description: "Read the Accessibility outline of an app's UI. Returns one line per element: [id] role \"title\" plus value=, desc=, placeholder= and flags (disabled, focused, selected, secure, clickable). Ids are only valid until the next outline. Use query to find specific elements in large windows, scope all_windows for other windows/sheets, menu_bar for menu commands. Menu items from scope menu_bar can be clicked directly without opening their menu.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "scope":{"type":"string","enum":["focused_window","all_windows","menu_bar"]},
          "application_name":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"App name as shown in the Dock; null for the task's target app."},
          "query":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Case-insensitive text filter over titles, values and descriptions; null for the whole outline."}},
         "required":["scope","application_name","query"]}
        """#)

    private static let screenshotTool = makeStrictTool(.screenshot,
        description: "Capture the target app's window only (also when other windows cover it). Use only when the outline lacks the element you need. click_point uses this image's pixel coordinates, relative to that window.",
        inputSchemaJSONText: #"{"type":"object","additionalProperties":false,"properties":{},"required":[]}"#)

    private static let clickTool = makeStrictTool(.click,
        description: "Click an element from the latest outline. The result includes a fresh outline.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "element_id":{"type":"string","description":"Id like e42 from the latest outline."},
          "click_type":{"type":"string","enum":["single","double","right"]},
          \#(expectSchemaFragment)},
         "required":["element_id","click_type","expect"]}
        """#)

    private static let typeTextTool = makeStrictTool(.typeText,
        description: "Type text into an element (focusing it first) or, with element_id null, into the currently focused element. The result includes a fresh outline.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "element_id":{"anyOf":[{"type":"string"},{"type":"null"}]},
          "text":{"type":"string"},
          "replace_existing_text":{"type":"boolean","description":"Select all existing text in the field before typing."},
          "press_return_after":{"type":"boolean"},
          \#(expectSchemaFragment)},
         "required":["element_id","text","replace_existing_text","press_return_after","expect"]}
        """#)

    /// Not strict: every strict schema in a request joins one compiled grammar, and the executor's set is at its limit.
    private static let replaceTextTool = makeNonStrictTool(.replaceText,
        description: "Edit part of a text field's or text area's text in the background, without a caret, clicks or keys. find is the exact current text to replace (case-sensitive, copied from the field's value); occurrence first or all. To insert, give an empty find and position start or end of the field's text. position is at_find whenever find is not empty. The result includes a fresh outline.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "element_id":{"type":"string","description":"Id like e42 of a text field, text area or combo box from the latest outline."},
          "find":{"type":"string","description":"The exact existing text to replace; empty to insert at position."},
          "replace_with":{"type":"string","description":"The new text; empty to delete what find matched."},
          "occurrence":{"type":"string","enum":["first","all"]},
          "position":{"type":"string","enum":["at_find","start","end"],"description":"at_find when find is not empty; start or end of the field's text when find is empty."},
          \#(expectSchemaFragment)},
         "required":["element_id","find","replace_with","occurrence","position","expect"]}
        """#)

    private static let pressKeyTool = makeStrictTool(.pressKey,
        description: "Press one key with optional modifiers, e.g. key \"s\" with [\"command\"]. Key names: a-z, 0-9, return, tab, escape, delete, forward_delete, space, up, down, left, right, home, end, page_up, page_down, f1-f12, or punctuation. Use type_text for text.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "key":{"type":"string"},
          "modifiers":{"type":"array","items":{"type":"string","enum":["command","option","control","shift"]}},
          \#(expectSchemaFragment)},
         "required":["key","modifiers","expect"]}
        """#)

    private static let scrollTool = makeStrictTool(.scroll,
        description: "Scroll inside an element (or the focused window when element_id is null). pages: 1-10.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "element_id":{"anyOf":[{"type":"string"},{"type":"null"}]},
          "direction":{"type":"string","enum":["up","down","left","right"]},
          "pages":{"type":"integer"},
          \#(expectSchemaFragment)},
         "required":["element_id","direction","pages","expect"]}
        """#)

    private static let clickPointTool = makeStrictTool(.clickPoint,
        description: "Fallback: click at pixel coordinates of the most recent window screenshot. Prefer click with an element id whenever the element is in the outline.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "x":{"type":"integer"},"y":{"type":"integer"},
          "click_type":{"type":"string","enum":["single","double","right"]},
          \#(expectSchemaFragment)},
         "required":["x","y","click_type","expect"]}
        """#)

    private static let uploadFilesTool = makeStrictTool(.uploadFiles,
        description: "Attach local files to a file upload control (a file input, or a Choose/Upload button that opens the file dialog). file_paths must be exact paths from the task's attached files (listed in the item's parameters or the task's attachments); anything else is refused. The user is asked first, and Dotto brings the app forward for a few seconds to use the file dialog. Several files must be in one folder.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "element_id":{"type":"string","description":"Id like e42 of the file input or the button that opens the file dialog."},
          "file_paths":{"type":"array","items":{"type":"string"},"description":"1-20 absolute file paths."},
          \#(expectSchemaFragment)},
         "required":["element_id","file_paths","expect"]}
        """#)

    private static let waitForTool = makeStrictTool(.waitFor,
        description: "Wait until text appears anywhere in the target app's focused window outline, up to timeout_seconds (1-15). Returns the outline either way.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{"text":{"type":"string"},"timeout_seconds":{"type":"integer"}},
         "required":["text","timeout_seconds"]}
        """#)

    private static let finishItemTool = makeStrictTool(.finishItem,
        description: "Report the outcome of the current checklist item. Call exactly once. For completed, evidence must prove the item's effect; the app re-checks it before accepting.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "outcome":{"type":"string","enum":["completed","failed","needs_user"]},
          "summary":{"type":"string","description":"One sentence describing what happened."},
          "evidence":\#(evidenceSchemaFragment)},
         "required":["outcome","summary","evidence"]}
        """#)

    // Strict schemas can't express string lengths or item counts, so the limits live in the descriptions and the
    // decoder enforces them.
    private static let askUserTool = makeStrictTool(.askUser,
        description: "Ask the user one short question when you can't make a reasonable plan without the answer. The user sees it in a chat bubble beside the cursor and answers by tapping a choice or typing. The answer comes back as this tool's result, and you continue planning from there. At most 3 questions per task, one per turn.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "question":{"type":"string","description":"At most 2 short sentences of plain text. No markdown, lists or headings. Refer to yourself as Dotto, never I."},
          "choices":{"type":"array","description":"0 to 4 likely answers, when the answer is one of a few options. Empty for an open question.",
            "items":{"type":"object","additionalProperties":false,
             "properties":{
              "label":{"type":"string","description":"The answer as the user would say it, 32 characters or fewer, plain text."},
              "detail":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Optional hint shown under the label, 80 characters or fewer; null if none."}},
             "required":["label","detail"]}},
          "allow_free_text":{"type":"boolean","description":"True if the user may type an answer of their own. Always true when choices is empty."}},
         "required":["question","choices","allow_free_text"]}
        """#)

    private static let submitPlanTool = makeStrictTool(.submitPlan,
        description: "Submit the checklist for the user to review. Call exactly once. Submit an empty items list with message_to_user only when the task can't be planned; ask questions with ask_user instead.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "task_title":{"type":"string","description":"Short title for the whole task."},
          "message_to_user":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"A caveat for the user, or with no items what blocks the plan, in one or two short plain sentences; null if none."},
          "items":{"type":"array","items":{"type":"object","additionalProperties":false,
            "properties":{
             "label":{"type":"string","description":"What the user reads: 60 characters or fewer, sentence case, starts with a verb, names the exact item in curly quotes, no menu paths or shortcuts, no trailing period."},
             "action_summary":{"type":"string","description":"140 characters or fewer: one plain sentence describing the outcome for this item and where, not keystrokes or menu paths. Shown under the item."},
             "parameters":{"type":"array","description":"Only the values that differ between items.","items":{"type":"object","additionalProperties":false,
               "properties":{"name":{"type":"string"},"value":{"type":"string"}},"required":["name","value"]}},
             "is_irreversible":{"type":"boolean","description":"True if the item sends, posts, publishes, schedules, deletes, pays, buys, submits or otherwise cannot be undone."}},
            "required":["label","action_summary","parameters","is_irreversible"]}}},
         "required":["task_title","message_to_user","items"]}
        """#)

    private static let submitRoutineTool = makeStrictTool(.submitRoutine,
        description: "Submit the routine compiled from the recording. Call exactly once.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "routine_name":{"type":"string"},
          "item_label_template":{"type":"string","description":"Checklist label for any item, with {{parameter}} placeholders."},
          "steps":{"type":"array","items":{"type":"object","additionalProperties":false,
            "properties":{
             "event_index":{"type":"integer","description":"Index of the recorded event this step replays."},
             "text_template":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"For typed-text events: the text with {{parameter}} placeholders. null otherwise."},
             "target_text_template":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"The clicked element's identifying text with placeholders when it differs per item; null if the element is the same for every item."},
             \#(expectSchemaFragment),
             "description":{"type":"string","description":"Short step description, e.g. Click “Rename”."}},
            "required":["event_index","text_template","target_text_template","expect","description"]}},
          "completion_evidence":\#(evidenceSchemaFragment)},
         "required":["routine_name","item_label_template","steps","completion_evidence"]}
        """#)
}
