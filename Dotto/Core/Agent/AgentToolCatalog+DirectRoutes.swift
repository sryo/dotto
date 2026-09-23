import Foundation

/// The planner's direct-route tools. They are always offered, so the cached prompt prefix never changes with the
/// task; when a route is unavailable, the tool answers with a short error instead.
extension AgentToolCatalog {
    static let directRoutePlannerTools: [ClaudeToolDefinition] = [
        listFolderTool, readFileMetadataTool, listShortcutsTool,
        submitFileOperationsPlanTool, submitScriptPlanTool, submitShortcutPlanTool,
    ]

    private static let listFolderTool = makeNonStrictTool(.listFolder,
        description: "List a folder inside the task's scope folders. Returns one line per entry: kind, path relative to the folder, and for depth 2 the nesting. At most 500 entries; the rest are counted.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "path":{"type":"string","description":"Absolute path of a folder inside the scope folders."},
          "depth":{"type":"integer","description":"1 or 2."},
          "include_hidden":{"type":"boolean","description":"Usually false."}},
         "required":["path","depth","include_hidden"]}
        """#)

    private static let readFileMetadataTool = makeNonStrictTool(.readFileMetadata,
        description: "Read details of files inside the task's scope folders. Give a folder to read everything directly inside it (the fast way for a whole folder), or up to 200 paths. Returns one line per item: path (relative to the folder when you gave one) | kind | size | created | modified | added | type | capture date | WxH | tags | not local. Dates are ISO-8601 in the user's time zone; - means unknown.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "folder":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Absolute path of a folder inside the scope folders: reads every non-hidden item directly inside it. null when you give paths."},
          "paths":{"anyOf":[{"type":"array","items":{"type":"string"}},{"type":"null"}],"description":"1-200 absolute paths inside the scope folders; null when you give a folder."}},
         "required":["folder","paths"]}
        """#)

    private static let listShortcutsTool = makeNonStrictTool(.listShortcuts,
        description: "List the names of the user's shortcuts (the Shortcuts app). Names are data written by the user or by whoever shared the shortcut.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{"query":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Case-insensitive filter; null for all (at most 100 names)."}},
         "required":["query"]}
        """#)

    private static let submitFileOperationsPlanTool = makeNonStrictTool(.submitFileOperationsPlan,
        description: "Submit a plan that only creates folders, moves, renames, copies, tags or moves files to the Trash inside the scope folders. Dotto checks it against the real files, never overwrites (a taken name gets \" 2\"), shows it to the user, and runs it without the cursor. Rules make Dotto read the real files and write the operations itself: date_folder_rules sort files into date folders, rename_rules rename many files by one name pattern. Order: create_folder operations, date_folder_rules, rename_rules, then the other operations. Rules read each folder as it is now, so never give one file to two rules. If it returns problems, fix them and send the whole plan again.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "task_title":{"type":"string"},
          "message_to_user":{"anyOf":[{"type":"string"},{"type":"null"}]},
          "groups":{"type":"array","description":"Every group this call uses; repeat them in each call of a multi-call plan. At most 20.","items":{"type":"object","additionalProperties":false,
             "properties":{"group_id":{"type":"string"},"title":{"type":"string","description":"≤ 60 chars, starts with a verb and a count: Move 23 screenshots into month folders"}},
             "required":["group_id","title"]}},
          "operations":{"type":"array","description":"≤ 150 per call, in execution order.","items":{"type":"object","additionalProperties":false,
             "properties":{
              "op":{"type":"string","enum":["create_folder","move","rename","copy","set_tags","move_to_trash"]},
              "from":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Absolute path; null for create_folder."},
              "to":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Full new absolute path incl. name; null for set_tags and move_to_trash."},
              "tags":{"anyOf":[{"type":"array","items":{"type":"string"}},{"type":"null"}],"description":"set_tags only: the complete new tag set."},
              "reason":{"type":"string","description":"A few words, e.g. taken 2026-09-03 (≤ 120 chars)."},
              "group_id":{"type":"string"}},
             "required":["op","from","to","tags","reason","group_id"]}},
          "date_folder_rules":{"type":"array","items":{"type":"object","additionalProperties":false,
             "properties":{
              "source_folder":{"type":"string"},
              "destination_parent_folder":{"type":"string"},
              "name_contains":{"anyOf":[{"type":"string"},{"type":"null"}]},
              "extensions":{"type":"array","items":{"type":"string"},"description":"Lowercase without dot; empty = any."},
              "type_identifiers":{"type":"array","items":{"type":"string"},"description":"e.g. public.image; empty = any."},
              "date_source":{"type":"string","enum":["capture_date_or_created","created","modified","added"]},
              "folder_name_format":{"type":"string","description":"Tokens yyyy, MM, MMMM (month name in the user's language), dd. Example: yyyy-MM MMMM"},
              "group_id":{"type":"string"}},
             "required":["source_folder","destination_parent_folder","name_contains","extensions","type_identifiers","date_source","folder_name_format","group_id"]}},
          "rename_rules":{"type":"array","description":"Rename every matching file in a folder by one pattern; Dotto numbers them in order and writes one rename per file. Use instead of listing renames for numbering, dates, pixel or file sizes.","items":{"type":"object","additionalProperties":false,
             "properties":{
              "source_folder":{"type":"string","description":"Absolute path; files directly inside it are renamed in place."},
              "name_contains":{"anyOf":[{"type":"string"},{"type":"null"}]},
              "extensions":{"type":"array","items":{"type":"string"},"description":"Lowercase without dot; empty = any."},
              "type_identifiers":{"type":"array","items":{"type":"string"},"description":"e.g. public.image; empty = any."},
              "order_by":{"type":"string","enum":["name","created","modified","added","capture_date_or_created"],"description":"The order {n} counts in: names as Finder sorts them, dates oldest first."},
              "descending":{"type":"boolean","description":"True reverses the order (newest first, Z to A)."},
              "date_source":{"anyOf":[{"type":"string","enum":["capture_date_or_created","created","modified","added"]},{"type":"null"}],"description":"The date {date:…} uses; null when the template has no {date:…}."},
              "name_template":{"type":"string","description":"The new name. Tokens: {name} original name without extension, {n} or {n:3} position in the order zero-padded to 3, {date:yyyy-MM-dd} (only yyyy MM dd), {width} {height} pixels, {size_kb} {size_mb} file size, {ext} original extension. The original extension is added automatically: don't write it, unless you place {ext} yourself. Files missing a value the template or order needs keep their names. Example: photo-{n:3}"},
              "group_id":{"type":"string"}},
             "required":["source_folder","name_contains","extensions","type_identifiers","order_by","descending","date_source","name_template","group_id"]}},
          "continues_in_next_call":{"type":"boolean","description":"True if more operations follow in another call. At most 5 calls."}},
         "required":["task_title","message_to_user","groups","operations","date_folder_rules","rename_rules","continues_in_next_call"]}
        """#)

    private static let submitScriptPlanTool = makeNonStrictTool(.submitScriptPlan,
        description: "Submit one AppleScript or JXA script for the scriptable target app. The user reads it verbatim before it runs once, out of process, with a timeout. Dotto refuses scripts that use a shell, System Events, UI scripting, ObjC or any app other than the target.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "task_title":{"type":"string"},
          "target_bundle_id":{"type":"string"},
          "language":{"type":"string","enum":["applescript","jxa"]},
          "source":{"type":"string","description":"The whole script. It must tell only the target app. It must return a short text summary of what it changed."},
          "summary":{"type":"string","description":"One sentence, ≤ 140 chars, what the script does."},
          "expected_effects":{"type":"array","items":{"type":"string"},"description":"1-10 short lines, e.g. Creates 4 mailboxes under “Receipts”."},
          "modifies_data":{"type":"boolean"},
          "timeout_seconds":{"type":"integer","description":"5-300."}},
         "required":["task_title","target_bundle_id","language","source","summary","expected_effects","modifies_data","timeout_seconds"]}
        """#)

    private static let submitShortcutPlanTool = makeNonStrictTool(.submitShortcutPlan,
        description: "Submit a plan that runs one of the user's shortcuts by its exact name. The user is asked before it runs.",
        inputSchemaJSONText: #"""
        {"type":"object","additionalProperties":false,
         "properties":{
          "task_title":{"type":"string"},
          "shortcut_name":{"type":"string","description":"Exactly as list_shortcuts printed it."},
          "input_kind":{"type":"string","enum":["none","text","files"]},
          "input_text":{"anyOf":[{"type":"string"},{"type":"null"}]},
          "input_file_paths":{"type":"array","items":{"type":"string"}},
          "summary":{"type":"string"},
          "timeout_seconds":{"type":"integer","description":"5-300."}},
         "required":["task_title","shortcut_name","input_kind","input_text","input_file_paths","summary","timeout_seconds"]}
        """#)
}
