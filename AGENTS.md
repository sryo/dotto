# Dotto: instructions for coding agents

Dotto by sryo is a macOS menu bar app: "Teach your Mac a chore once. Dotto does the rest."
The user types a command. Claude plans a checklist, the user approves it, and Dotto works through the items in
the user's own apps with a visible cursor. Once one item has been done, Dotto replays it as a routine for the rest.
Commands are typed. Dotto is a personal tool: the user pastes their own Anthropic API key once (menu bar panel), it
is kept in the macOS Keychain, and the app calls `api.anthropic.com` directly. There is no proxy.

`CLAUDE.md` is a symlink to this file. Edit `AGENTS.md` and keep the symlink.

## What Dotto does

The app is menu bar only (`LSUIElement`): a status item, a command bar, a floating checklist panel and a cursor overlay.

1. **Command bar** (⌃⌥Space by default, rebindable in the menu bar panel; `UI/CommandBar`). Dotto captures the frontmost app as the task's **target app**.
   Or **circle to summon**: circling the pointer opens the same command bar as a pill at the pointer, and the
   target app is the owner of the window under the pointer (see "Circle to summon" below). Either way Dotto records
   the **summon origin** (top-left global points): the point the gesture fired at, or the pointer when the shortcut
   opened the bar (`TaskSessionController.summonOriginOfNextCommandInTopLeftGlobalPoints`). Submitting carries it into
   the task (`currentTaskSummonOriginInTopLeftGlobalPoints`). Both forms take the keyboard as soon as they show (the
   field is focused again once the panel is key, `CommandFieldFocusRequest`).
2. **Planner** (`claude-opus-5-5`, `Core/Checklist/ChecklistPlanner`). It reads the target app's Accessibility
   outline (plus a screenshot when needed) and returns a `Checklist` through the `submit_plan` tool. When it truly
   needs to, it asks the user one short question through the strict `ask_user` tool (plain text, 0–4 choices, free
   text allowed or not; at most 3 per task, `ChecklistPlanner.maximumQuestionsPerTask`). The conversation waits
   (`ClaudeToolConversationRunner` `.pausedForUserReply`) and the answer goes back as that tool's result, inside
   `<user_reply>`, so planning carries on from what it already read. A text-only answer is taken as an open question
   with its markdown stripped (`PlannerPlainText`). Planning turns across questions share the task budget and the
   12-turn planning ceiling. **Everything happens at the cursor:** while it plans there is no card. Dotto's cursor
   appears at the summon origin, parked there (`CursorSurface.parkedAtSummonOrigin`), in the reading state
   ("Reading Finder…", ring text READING FINDER) and then thinking ("Planning…"), fed by `ChecklistPlanningProgress`,
   with Stop and a chevron in its pill. The chevron opens the popover with the planning thread
   (`UI/Checklist/PlannerThreadView`: the command as the first bubble, Dotto's questions, the user's replies, a
   typing indicator); it is only shown while the popover has something to show (planning, a question, the checklist
   under review, the run).
3. **Approval** (`UI/Checklist`). The first panel the user sees is the checklist, a non-activating popover attached
   to the cursor's pill: below and to the right of the tip with a tail aimed at it, flipped left or up when it would
   leave the visible frame of that screen, its anchored edge fixed while its height changes
   (`Core/Cursor/AttachedPanelPlacement`). The cursor waits beside it ("Review the checklist"). The user unchecks or
   edits items, then approves. Nothing runs before approval. The popover never leaves the visible frame of its screen
   (`AttachedPanelPlacementCalculator.maximumPanelHeight`): its header and footer are pinned and the item list or the
   thread scrolls. Rows show one line; clicking a row expands its action summary, values and label field. The
   planner's questions arrive in the same popover as a chat thread: choice chips send their label, the reply field
   sends on Return (Shift-Return adds a line), Esc closes the thread and ends the task. When a question arrives the
   popover becomes key so the field is focused at once (the user summoned Dotto with that command); it gives the
   keyboard back when the plan arrives or the task closes. The checklist then keeps a "Show conversation" disclosure.
   Planning failures hang from the same point.
   **Fastest route first.** The planner picks one route per task and calls exactly one submit tool:
   1. **File operations** (`submit_file_operations_plan`): create folder, move, rename, copy, set tags, move to Trash,
      only inside the task's scope folders (the Finder window the user summoned Dotto over, folders they attached,
      folder paths they typed in the command or a reply; `App/TaskSessionController+DirectRoutes`
      `makePlannerDirectRouteContext`). It reads with `list_folder` and `read_file_metadata` (a list of paths, or a
      whole folder at once). Sorting by date goes through `date_folder_rules` and renaming many files by one pattern
      (`photo-{n:3}`, `{date:yyyy-MM-dd}`, `{width}x{height}`…) through `rename_rules`; Dotto expands both from real
      metadata (`DateFolderRuleExpander`, `RenameRuleExpander`), so the model never writes out one operation per file.
      Month names follow the user's first preferred language and region, not the English-only bundle.
   2. **Script** (`submit_script_plan`): AppleScript or JXA for a scriptable target app, shown verbatim before it runs.
   3. **The user's Shortcut** (`submit_shortcut_plan`), by the exact name `shortcuts list` printed.
   4. **Checklist** (`submit_plan`): everything else, run by the cursor as below.
   A direct plan rides on `Checklist.directRoutePlan`, one item per display group. Its preview replaces the item
   list (`UI/Checklist/DirectRoutePreviewView`, `FileOperationsPreviewTable`, `ScriptPreviewView`,
   `ShortcutPreviewView`): no item toggles, no label editing, no Teach; it is approved and run as a whole. A script's
   preview offers "Use the cursor instead", which plans the same command again with direct routes off.
4. **Executor** (`Core/Execution/TaskExecutor`). When the run starts the checklist folds into the cursor's pill,
   which shows the progress ("2 / 5 · Rename IMG_2042") with Pause and Stop. The pill's chevron (or the live view's
   checklist button while the target window is covered) opens the checklist beside the cursor's current position
   (beside the live view when covered); the run's summary opens there when it ends. A task with no summon origin (a
   saved routine run from the menu bar) keeps its checklist open, inside the top-right corner of the target window.
   An approved direct plan runs through `Core/Execution/DirectRouteExecutor` instead (`startDirectRouteRun`): no
   model calls, no user-input or window observation, no `prepareForTask`, so accessibility modes are never touched
   and nothing takes focus. The cursor stays parked at the summon point and its pill counts operations
   ("12 / 23 · Moving IMG_2041", `CursorActivityEvent.directOperationProgressed`); Pause and Stop work as for any run.
   The result (`UI/Checklist/DirectRouteResultView`) says what changed, lists failures, shows a script's or
   shortcut's output as plain text, and offers "Undo task" for file operations; the menu bar keeps "Undo last task"
   for a day (`UI/MenuBar/UndoLastTaskRow`).
   The executor walks the included items one at a time:
   - **Routine replay first** (`Core/Routines/RoutineReplayEngine`). Replay is deterministic, with no model call
     while every step's expectation holds.
   - **Agent loop as the fallback** (`claude-sonnet-5`, `Core/Agent/ChecklistItemAgentLoop`). It uses custom
     tools (`read_ui`, `click`, `type_text`, `replace_text`, `press_key`, `scroll`, `click_point`, `screenshot`,
     `wait_for`, `finish_item`). The built-in computer-use tool is not used. `replace_text` edits part of a field's
     text (or inserts at its start or end) through Accessibility alone, with no caret, clicks or keys, so text edits
     stay in the background. When replay fails partway, the agent takes over
     from the failed step, and the routine is patched.
   - The first verified agent item is compiled into a parameterized routine (`RoutineCompiler`), and the items
     after it replay that routine.
   - **Stall check** (`Core/Agent/ChecklistItemStallPolicy`): once an item has acted, 4 steps in a row that changed
     nothing (input with no visible change or not delivered, an unmet `expect`, a `wait_for` that timed out, a
     `read_ui` query with no matches) end the item as needs-user ("Nothing changed after the last 4 steps."), which
     asks the user what to do.
5. **Verification** (`Core/Verification`). Every step and item is checked against a `StepExpectation`.
   Failed items are retried by `ChecklistItemRetryPolicy`, or the user is asked what to do.
6. **Audit log** (`Core/Audit/AuditLogWriter`). Every task writes JSONL to `~/Library/Logs/Dotto/<task-id>.jsonl`.

What else the app does:
- **Background work.** Dotto works in the target app while the user keeps using other apps. It delivers input
  without taking focus, through the tiers `Core/InputDelivery/InputTierPlanner` picks: Accessibility actions and
  values, then per-process keys. When input provably didn't land, or a step needs the app in front (file dialogs,
  pixel clicks), Dotto asks first ("Bring the app forward for a moment?",
  `Core/Execution/ForegroundAssistingActionPerformer`), then puts the user's app, window and cursor back. Even then,
  and under a rest-of-task grant too, the app comes forward only once the user has paused
  (`Core/Execution/ForegroundAssistReadinessPolicy`: no real click, scroll or key for 1.5 s and no password field
  active in another app, read by `Platform/Input/ForegroundAssistReadinessProbe`), after a 1 s "Bringing <App>
  forward…" countdown on the pill with Cancel. After 20 s of waiting, Dotto asks once more.
  The optional **Avoid foreground assists** setting disables foreground assists for a task. Steps that need
  the target in front stay undone and mark their items needs-user; the setting is fixed for the task.
- **Dotto's cursor** (`Core/Cursor`, drawn by `UI/Cursor`). One seam, two surfaces: the pure
  `CursorPresentationStateMapper` turns executor, replay, safety and backend events into a `CursorPresentationState`
  (pointing, reading, thinking, clicking, typing, replaying, waiting, paused, done, error), and
  `CursorSurfacePlacementPolicy` draws it in a click-through overlay over the target window while that window is
  visible, or in a floating live view of the window when it is covered. Before the run knows its window (planning,
  approval, the first moments of a run) the cursor is parked at the summon origin, above other windows. The style defaults live in
  `CursorStyleConfiguration` (the owner can paste the cursor lab's JSON into the `dottoCursorStyleJSON` default).
  When Dotto needs the user, the same mapper produces a `UserAttentionRequest`. The question and its buttons ride
  on the cursor's pill, or on the same pill docked to the live view, in non-activating panels that take clicks
  without focus; a chime, a menu bar pulse and optional notifications (off by default) point the user to it
  (`AttentionPreferences`, `App/TaskSessionController+Attention`). Every answer takes the checklist card's path.
  The pill grows up to 420 points, then wraps its text to two lines with its buttons below. No Dotto panel opens a
  menu (non-activating panels can't): a rest-of-task grant behind Allow is revealed inline by Allow's chevron. For
  bringing the app forward, "Allow for this task" leads and "Just this once" follows, since one task brings its one
  target app forward many times; the readiness wait and countdown still run every time.
- **Uploads** (`upload_files`, `Core/Uploads/UploadFileAllowlist`). Only files the user attached or dropped in the
  command bar, or files inside a folder picked for a folder routine, can be uploaded. A typed path never grants
  anything. Grants of `/`, `/Users`, `/Volumes` or a whole volume are never honored, `Users/<name>/Library` is
  protected at any depth, and `/System/Volumes/Data/…` paths count as their `/…` spelling. The open panel is driven
  inside the approved assist (`Platform/Accessibility/NativeOpenPanelDriver`), with the one focused keyboard path
  Dotto has (invariant 3c).
- **Teach mode** (`App/TaskSessionController+Teaching`, `Platform/Input/DemonstrationRecorder`). The user does
  the first item by hand. Claude compiles the recording into a routine (`DemonstrationRoutineCompiler`), and the
  user reviews it before it is used.
- **Saved routines** (`Core/Routines/RoutineLibraryStore`). Each routine is one signed JSON file. A saved routine
  can run on a pasted list or on every file in a folder (`RoutineChecklistFactory`), with no planning call.
- **Circle to summon** (on by default; clockwise, 1.5 loops within 1.2 s, or 0.85 s per loop needed when that is
  longer). Layers:
  - `Core/SummonGesture`: `CircleSummonGestureRecognizer` (a rolling buffer of pointer samples, winding around
    their centroid, radius and roundness limits, a reversal limit read on a tremor-thinned path, a 0.7 s
    cooldown), `SummonGestureConfiguration`, `SummonGestureEligibility` (observation: enabled, no task in
    progress, command bar or pill closed, frontmost app not excluded, not full screen on the pointer's display,
    screen not locked, asleep or in the screen saver; and at fire time, `allowsSummoning`: the app under the
    pointer is not excluded, blocked by `TargetApplicationPolicy` or Dotto itself), `SummonGesturePreferenceModels`
    (what is stored: the user's choices and exclusion additions/removals) and `SummonGestureDisplayGeometry`
    (edge-inclusive display lookup; full screen means the app's largest window on that display covers it).
    Unit-tested.
  - `Platform/SummonGesture`: `PointerMovementObserver` (NSEvent global and local monitors for mouse moves and
    button down/up only; each event's own timestamp and location, in top-left global points),
    `PointerTargetApplicationResolver` (the owner of the topmost ordinary or floating window under the pointer,
    skipping Dotto, overlays and shields; the full-screen check on the pointer's display) and
    `SessionScreenLockReader` (lock and fast-user-switching state).
  - `UI/SummonGesture`: the click-through ring around the real pointer (task color, fire pulse, no pulse with
    Reduce Motion). The pill is `UI/CommandBar/CommandPillView`, hosted by `CommandBarPanelController` in the
    command bar's own panel, so it may take the keyboard (the user summoned it) and submits through
    `submitCommand`. Esc or a click elsewhere closes it and hands activation back (`PreviousApplicationTracker`).
  - `App/SummonGestureController` starts and stops the observation whenever an eligibility input changes (the
    frontmost app, the Space, the session state, the command panel, the settings, lock, screen saver, display
    sleep, fast user switching and display changes), never per move. It re-reads lock and full screen when a
    circle is recognized, and hides the ring once the pointer has been still for 0.25 s.
    `App/TaskSessionController+SummonGesture` holds the settings and opens the pill (or does nothing when
    `allowsSummoning` refuses).
  This is the one global input observation Dotto makes while no task is running (invariant 10b).
- **Pause, takeover and Stop.** Clicks or keys aimed at the target app, or moving or closing its window, pause a
  run (`UserTakeoverDetector`); input in other apps and pointer travel never do. Only the window the run pinned at its
  start counts (`TargetWindowObserver`), not windows Dotto's steps open (Get Info, inspectors, sheets), and only when
  its frame really changed and no Dotto action or bring-forward assist is under way or ended within 1.5 s
  (`AutomatedTargetActivityRelay`, fed by the backend and `ForegroundAssistSession`). A close that follows Dotto's own
  ⌘W, ⌘M, Esc, Return or click re-pins the app's front window instead of pausing. A click on a Dotto panel is
  recognized by AppKit having delivered it (`UserInputObserver`'s local monitor) or the pixel hit test, and clicks
  within 0.75 s of Resume or a pill answer never count. Resume re-baselines the pinned window's frame. The user can pause, resume, skip or
  stop from the checklist panel; Pause and Stop are also on the cursor pill, and Stop on the live view (expanded or
  collapsed) and the menu bar panel. The pill keeps its buttons in every status style (in ring style, and once the
  quiet style's text fades, it shows just the buttons). Questions and pauses ride the pill (or the live view's docked
  pill); the checklist opens for them only when no cursor is showing. There is no global stop shortcut (see
  invariant 10).

## Status and what comes next

- **Web chores are in progress.** They run through the same Accessibility backend, in the user's own browser
  (Arc, Dia, Safari…), with no browser-specific automation.

## Layers (layer first, then feature)

Every `.swift` file under `Dotto/` belongs to exactly one layer folder. The root of `Dotto/` holds only bundle
resources: `Info.plist`, `Dotto.entitlements` and `Assets.xcassets`.

| Layer | May import / use | Holds |
|---|---|---|
| `Dotto/App/` | everything | `DottoApp` (the composition root, which wires every concrete type) and `TaskSessionController` (the coordinator, split per flow into `+Planning`, `+Run`, `+Decisions`, `+Pause`, `+ExecutionObserving`, `+Teaching`, `+SavedRoutines`, `+Attention`, `+ForegroundAssist`, `+SummonHotkey`, `+SummonGesture`, `+AnthropicAPIKey` and `+DirectRoutes`, with `SummonGestureController` running the gesture; it conforms to no executor protocol, so only a run-scoped `TaskRunDelegateBridge` is handed to Core) |
| `Dotto/Core/<Feature>/` | **Foundation and CoreGraphics only** | pure logic: models, planning, the agent loop, execution, replay, safety, verification, audit |
| `Dotto/Platform/<Feature>/` | Core plus macOS frameworks (AppKit, AX, CGEvent, ScreenCaptureKit, Security) | real implementations of Core protocols. Never uses UI or App types |
| `Dotto/UI/<Feature>/` | Core, SwiftUI and AppKit | SwiftUI views and the `NSPanel` controllers that host them |

- `zsh scripts/run-core-tests.sh` enforces the Core rule twice:
  - It greps every Core file and fails on any `import` other than Foundation or CoreGraphics.
  - It compiles `Dotto/Core/**` alone, so any Core file that names a Platform or UI type fails to build.
- Put anything that can be pure in Core, because only Core is unit-tested.
- Where new things go:
  - A new pure concept goes in `Core/<Feature>/`. The test glob picks up new folders automatically.
  - A macOS-API adapter goes in `Platform/<Feature>/`, and a new panel or view goes in `UI/<Feature>/`.
  - New Core tests go in `DottoCoreTests/<Feature>/`, mirroring `Core/`.
- Xcode uses file-system synchronized groups, so adding a file to a folder is enough. Don't hand-edit
  `project.pbxproj`.

## Vocabulary

| Concept | Word | Examples |
|---|---|---|
| A user's request, its session and its run | **Task** | `TaskSessionController`, `TaskSessionStateMachine`, `TaskExecutor`, `TaskRunControl`, `TaskAbortSignal` |
| The plan the user approves | **Checklist** | `Checklist`, `ChecklistPlanner` |
| One line of the plan | **ChecklistItem** | `ChecklistItem`, `ChecklistItemAgentLoop`, `ChecklistItemRetryPolicy` |
| One UI operation | **Action** | `AgentAction`, `ActionBackend`, `ActionOutcome` |
| An action plus its expectation | **Step** | `RoutineStep`, `StepExpectation` |
| A learned, parameterized replay | **Routine** | `Routine`, `RoutineCompiler`, `RoutineReplayEngine` |
| The user showing Dotto how | **Demonstration** (the UI says "teach") | `DemonstrationRecorder` |
| The raw typed text | **Command** | `CommandBarView` |

- Never use **Chore** in type or folder names. It is a marketing word only.
- Don't bring back `TaskPlan` or `Orchestration`.
- The product prefix `Dotto` goes on a type only when it names the product's own thing, as opposed to the user's,
  or when the name would be ambiguous without it: `DottoApp`, `DottoAppDelegate`, `DottoPanel` (the base of every
  Dotto window), `DottoWindowPointerHitTest`. Otherwise use a descriptive role name (`CursorView`,
  `AttentionChime`, `ScreenCorner`). In members, don't use the product name: say `ThisApp`
  (`isSynthesizedByThisApp`, `targetIsThisAppWindow`) or name the role (`appAuthoredText`,
  `noteAutomatedActionStarted`).
- `Claude*` names belong to the Messages API wire layer (`Core/Claude`, `Platform/Claude`) and nowhere above it.
- `…Manager` and `…Utility` are banned. An `NSPanel` owner is a `…PanelController`.
- A file is named after its primary type. There are two exceptions:
  - `…Models.swift` holds a cohesive bundle of value types.
  - `Type+Area.swift` holds extensions.

## Safety invariants (never regress these)

Every one of these has tests in `DottoCoreTests/`. If a change weakens one of them, stop and ask the owner.

1. **SafetyGate classifies everything, failing closed; only some categories ask** (`Core/Safety/SafetyGate`).
   Every action Dotto can't positively identify as harmless gets a risk category: risky words in labels
   (`SafetyRiskVocabulary`; a label with several risky words takes the one that asks), Return and Return-equivalent
   keys, ⌘Delete, ⌘Q/⌘W, per-app send shortcuts, every ⌘V paste variant (`.pastingClipboard`), unlabeled or
   unidentifiable clicks, every `click_point`, bringing the target app forward (`.bringingAppForward`,
   `SafetyGate.evaluateForegroundAssist`) and every upload (`.uploadingFiles`, whose card lists what a rest-of-task
   grant can cover). By the owner's decision (2026-09-23), only categories whose `SafetyRiskCategory.asksUser` is
   true reach the user (`SafetyGate.applyingAskPolicy`): sending or publishing, deleting, paying or buying, bringing
   the app forward, uploading files and running a Shortcut. Return (and ⌃M/⌃J/⌃O, or typing that ends in Return)
   counts as sending in browsers, chat apps (`chatApplicationLowercasedBundleIdentifiers`) and apps whose send
   shortcut is plain Return (`applicationTreatsReturnAsSend`), and there a focused control that doesn't ask can't
   turn it into a click that runs; elsewhere it is `.pressingReturn`. The approved checklist's own wording and
   `isIrreversible` never ask (`evaluateChecklistItem` asks only for a routine step category that asks), and neither
   does a replayed step flagged under a category that doesn't. The other categories still count as risky
   (`actionIsRiskyWithoutAnyGrant`, the unfiltered verdict), so an item that took one is never retried automatically.
2. **Confirmations are scoped to a category** (`SafetyRiskCategory` in `SafetyModels`). "Allow for the rest of
   this task" grants one category only. Approving sends never approves deletes or payments, and a category that
   doesn't ask covers none that does. `.bringingAppForward` and `.uploadingFiles` never cover each other.
3. **The target app is pinned, and some apps are blocked.** The task is bound to the app that was frontmost at
   command time (`TaskSessionController.captureFrontmostApplicationAsTarget`), or, for circle to summon, to the
   owner of the window under the pointer when the gesture fired (`PointerTargetApplicationResolver`),
   never an excluded or blocked app or Dotto itself. At submit, a target app that has quit (or whose process id
   now belongs to another app) fails planning with "<App> quit before Dotto could start".
   `AccessibilityActionBackend` posts
   input only to the target app's process (per-process AX calls and events through `TargetProcessPin`), never
   through the HID or session event tap (the one exception is invariant 3c), and refuses elements that belong to
   another process. Dotto never launches an app.
   `Core/Safety/TargetApplicationPolicy` blocks terminals, System Settings, Keychain Access, SecurityAgent,
   loginwindow and password managers, plus app-switch, hide, quit, Spotlight, Force Quit and lock shortcuts.
   Saved routines run only against their recorded bundle identifier.
3b. **Dotto never takes focus.** No activation, no raising, no cursor moves, no private focus tricks that could
   disturb the user's front window. The only exception is the user-approved foreground assist
   (`.bringingAppForward` / `.uploadingFiles`), which restores the previous app, window and cursor. Every assist,
   also under a rest-of-task grant, waits until the user has paused and shows a 1 s countdown with Cancel first
   (`ForegroundAssistReadinessPolicy`), and a `.deny` from `SafetyGate.evaluateForegroundAssist` counts as declined.
   Under the optional background-only task policy, foreground assists and native file uploads are unavailable;
   scripts and Shortcuts are unavailable too because their contents can activate apps outside the action backend.
   After Dotto's own file pickers or a click on its notification, activation goes back to the app the user was in
   (`App/PreviousApplicationTracker`), never to the target unless that is where they were. Per-task
   accessibility modes (`AXManualAccessibility`, `AXEnhancedUserInterface`) are restored at the task's end, on
   cancel, on dismiss and on quit. While they are changed, `TargetApplicationAccessibilityModes` keeps a record in
   `~/Library/Application Support/Dotto/ChangedAccessibilityModes.json`, so after a crash the next launch puts them
   back (same process, bundle id and launch date only) and deletes the file. Menus never open in the background: a
   context menu (`AXShowMenu`), pop-up button or menu button covers the user's work and takes their keyboard, so
   `InputTierPlanner` only presses them with the target in front (the assist), and the backend re-checks the live
   role. A background menu-item press,
   posted key or pointer event counts only when a visible change is seen (`InputTierPlanner.deliveryConfirmation`);
   otherwise it is reported as not delivered and the assist is offered. Text set as an AXValue and then committed
   with Return must still show afterwards (`AccessibilityValueCommitCheck`); when the app dropped it, that is reported
   as not delivered and the rest of the task types into the app with real keys only.
3c. **The one focused keyboard path: choosing files in an open panel.** Per-process keys never reach an
   `NSOpenPanel` (Chromium routes them to the browser window; a sandboxed app's panel runs in the system panel
   service), so during an approved upload assist only, `NativeOpenPanelDriver` posts real keyboard events at the
   session tap (`InputSynthesizer.postFocusedKeyPress` / `typeFocusedUnicodeText`): "/" (the layout's own key, no
   ⌘) to open Go to Folder from the file list, the path, Return. ⇧⌘G is never sent: it is a key equivalent, and
   Chrome answers it with Find Previous. Return is sent only when the Go to Folder field's value equals the path
   exactly. The selection is then verified and confirmed through Accessibility. Before every chunk,
   `FocusedKeyboardInputGuard` requires the assist to be active, the run not stopped, the target (or the open-panel
   service process drawing this panel, and no other) frontmost, the panel still the key window, the keyboard focus
   (read through Accessibility; unreadable refuses) on this panel's file list and then on its Go to Folder field,
   and no real user click, scroll or key since the assist began
   (`UserInputObserver.realUserInputCounter`; not observing counts as "the user may be typing" and refuses). Any
   refusal, error or Stop cancels the panel, and the assist restores the user's app, window and cursor. Nothing
   else in Dotto may post focused input, and this path must never be used outside the assist.
4. **Secure fields are refused.** Dotto never types into `AXSecureTextField`. SafetyGate denies it, with no
   confirmation possible, and the AX backend re-checks the live element. Secure values are stripped from outlines,
   locators and recordings (`AccessibilityOutlineFormatter`, `ElementLocatorResolver`, `RoutineCompiler`,
   `DemonstrationRecorder`).
5. **Screen text is data** (`Core/Agent/PromptLibrary`). Screen content and parameter values go inside
   `<untrusted_ui>`, and planner text goes inside `<planner_notes>`. The user's answers to the planner are their own
   text and go inside `<user_reply>` (`plannerUserReplyText`), never inside `<untrusted_ui>`. Tag look-alikes of all
   three are neutralized (`neutralizingTrustTags`). The system prompts say neither can add items or widen the task. Tool results fence
   anything the app reported (action reports, error details) the same way: Dotto's own wording stays outside the
   block (`ActionBackendError.fencedMessageForModel`, `ClaudeToolResultBuilding.fencedMessageForModel`).
6. **The audit log is redacted** (`Core/Audit/AuditLogWriter`). Text Dotto typed (and `replace_text`'s `find` and
   `replace_with`) is replaced by its SHA-256 fingerprint wherever it resurfaces, and messages and details are truncated. The log directory is `0700` and
   its files are `0600`.
7. **Routines are signed.** Each file carries an HMAC-SHA256 signature (`RoutineIntegritySigning`, with the key
   held in the Keychain by `Platform/Routines/KeychainRoutineSigningKeyProvider`). A file is skipped if it is
   unsigned, tampered with, not owned by the user, not a regular file, too large, or missing a bundle identifier.
   Loading a routine never bypasses SafetyGate: replayed steps are evaluated like agent steps.
8. **Routines are reviewed before they are saved.** `TaskExecutor` never writes routines to disk. Learned,
   patched and taught routines are shown in `UI/Checklist/RoutineReviewCard`, and they are saved only when the
   user chooses "save". `zsh scripts/run-core-tests.sh` fails if anything under `Core/Execution` names
   `RoutineLibraryStore`.
9. **Ceilings** (`SafetyLimits` in `Core/Safety/SafetyModels`, enforced through `TaskResourceBudget`). One budget is
   created with the task, before planning, and planning, compiling a taught routine and the run all draw on it; the
   wall clock starts with the run:
   - 25 actions per item and 500 per task
   - 40 model turns per item, 12 for planning and 600 per task
   - 6M input tokens per task
   - 30 minutes of wall clock
   - 3 consecutive failed items stop the run
   - at most 200 checklist items
10. **Stop always works, and Dotto never watches the keyboard to stop.** `ActionBackend.perform` checks
    `TaskAbortSignal` before every posted input event (never between a mouse down and its up), and element walks
    check it between elements. A Stop during a bring-forward assist also cancels any open file dialog before the
    user's windows come back. The ways to stop are: clicking or typing in the target app (a takeover pause), a Stop
    button (checklist panel, cursor pill while planning or a run is live, the live view expanded or collapsed, the
    menu bar panel), and Esc only while an Dotto panel is key (the checklist panel stops the run or planning, and on
    the planner's question ends the task; the command bar and pill just close). There is no global stop shortcut and no Esc event tap: Esc in the user's other apps is theirs.
10b. **While no task runs, Dotto observes pointer position only, for circle to summon.** `PointerMovementObserver`
    sees mouse moves and whether a button went down or up, never keys, click positions or drags, and only while
    `SummonGestureEligibility` allows it (never while the screen is locked, asleep or in the screen saver). Moves go
    straight into the recognizer's rolling buffer (1.2 s, up to about 2 s at 2.5 loops needed:
    `effectiveWindowSeconds`) and are never stored, logged or sent. The user can turn it off in the menu bar panel.
11. **The API key lives only in the Keychain and is only ever sent to api.anthropic.com.** The user's Anthropic key
    is a Keychain generic password (`Platform/Claude/AnthropicAPIKeyStore`), read into memory only to fill the
    `x-api-key` header of a request to `AnthropicMessagesEndpoint.messagesURL`. It is never written to disk, logs,
    the audit log, prompts, errors or crash text, and the UI shows it only masked (`AnthropicAPIKeyFormat.maskedForDisplay`:
    `sk-ant-…a1b2`). No secret ships in the repo or the bundle. Because the user's key pays for every call,
    `Core/Claude/ClaudeMessagesRequestGuard` checks the encoded body of every request before it is sent:
    - a model allowlist (`claude-opus-5-5`, `claude-sonnet-5`)
    - a `max_tokens` cap of 16000
    - custom tools only (no server tools)
12. **Direct routes stay in scope and never destroy.**
    - File operations run only inside scope roots that came from the user: the Finder window they summoned over,
      attached folders, or paths they typed in the command or an `ask_user` reply. Nothing the model or a screen says
      ever adds a root. Roots are allowlisted (`FileOperationScopePolicy`: a folder below home outside `~/Library`, or
      below a named volume folder; never a package, never `Application Support/Dotto`), at most 4 per task. A folder
      word counts only when named as a folder ("Downloads folder", "carpeta de Descargas") or quoted
      (`CommandPathExtractor`); a bare noun ("the documents") never adds a root.
    - Every operation is dry-run validated at plan time and again at run time (`FileOperationPlanValidator`). Nothing
      is ever overwritten (" 2" is added instead). There is no delete, only `move_to_trash`, which always asks under
      `.deleting`.
    - Symbolic links are left alone: no operation takes a link as its operand, and an operand whose folder (in the
      simulated file system, after earlier operations) is a link counts as outside the scope. Right before every
      change, and every undo step, the operand's real folder is resolved with realpath and must be the planned one,
      inside a scope root and not protected (`FileOperationContainmentCheck`); folders are created, renamed and removed
      through descriptors opened component by component with O_NOFOLLOW (`FileManagerFileSystem`).
    - At most 2,000 changes of existing items per task (created folders don't count, up to 2,000 of their own; a date
      or rename rule counts only the files it matches). Rule-expanded operations go through the same dry run. Every operation is journaled for "Undo task"
      (`FileOperationJournalStore`), and so is every step undo reverses, so a stopped undo carries on with the rest;
      undo never overwrites and never deletes (a folder Dotto created goes only when it holds nothing but Finder's
      `.DS_Store`/`Icon\r`).
13. **Scripts are shown, inspected and bounded.**
    - A script runs only after the user saw it verbatim in the preview and clicked Run.
    - It may address exactly one running, non-blocked, declared app (`ScriptTargetPolicy`); Dotto never launches it.
    - `ScriptSourceInspector` denies shell, System Events, UI scripting, ObjC bridges, dynamic targets and script
      loading, in strings and comments too.
    - It runs out of process: `/usr/bin/osascript` with an argument array, the source on stdin, no shell, a hard
      timeout, and Stop kills it.
    - The user reads the script and clicks Run, so only a risky verb whose category asks (send, delete, pay) asks
      again, under that category, naming any Finder places the script reaches outside the scope folders (POSIX, `~`,
      HFS paths, `path to …`, Finder's special locations, or file verbs that name no place inside them).
      `modifies_data`, other risky verbs and those places alone no longer ask (the owner's decision, 2026-09-23).
14. **Shortcuts run by exact listed name through `/usr/bin/shortcuts` with an argument array**, never through a
    shell, and every run asks first under `.runningShortcut`: no rest-of-task grant covers a shortcut
    (`SafetyRiskCategory.offersRestOfTaskGrant`, honored by `SafetyConfirmationFlow`), and neither the confirmation
    card nor the pill offers one.

## Build and test

- Open `Dotto.xcodeproj`, choose the **Dotto** scheme, set your signing team, and press Cmd+R.
- **Never run `xcodebuild` from the terminal.** It re-signs the app, which invalidates the Screen Recording and
  Accessibility grants. (`scripts/release.sh` is the owner's release pipeline. Agents never run it.)
- Both gates must pass before you hand work back:
  - `zsh scripts/typecheck.sh` typechecks every file under `Dotto/` with Xcode's `swiftc` (arm64,
    macOS 14.2) and produces no bundle.
  - `zsh scripts/run-core-tests.sh` runs the import guard and the invariant 8 guard, then compiles `Dotto/Core/**`
    together with `DottoCoreTests/**` into a scratch binary and runs it.
- There is no XCTest and no Xcode test target. Tests use the small harness in
  `DottoCoreTests/Support/CoreTestHarness.swift`. To add tests:
  - Declare a top-level `let <name>TestSuite = CoreTestSuite(name: "…", testCases: [CoreTestCase(name: "…") { … }])`
    in a file under `DottoCoreTests/<Feature>/`. The script finds suites by grepping for the pattern
    `let …TestSuite = CoreTestSuite(`, and it generates `main`. No registration is needed.
  - Assert with `expectEqual`, `expectTrue`, `unwrapOrFail` and `expectThrowsError`.
  - Put fakes in `DottoCoreTests/TestDoubles/` (for example `ScriptedClaudeTransport` and
    `FakeActionBackend`), and fixtures in `DottoCoreTests/Support/`.
- Known, non-blocking warnings: Swift 6 concurrency warnings. Don't fix them in passing.
- Live probes run on the owner's real Mac, so they must never touch the owner's data or input:
  - Only drive throwaway targets: documents created in a scratch folder, or a browser launched with a throwaway
    `--user-data-dir`. Never the owner's Notes, Mail, Safari profile, browsers or documents.
  - Never post session- or HID-level keystrokes or clicks (anything not addressed to a specific throwaway pid)
    unless the screen is unlocked and the throwaway target is verified frontmost immediately before each event.
    A locked screen means the login window is focused, so a stray keystroke lands in the password field.
  - Quit everything you launched and delete throwaway profiles when done.

## Configuration

| What | Where |
|---|---|
| Anthropic API key | Keychain generic password, service `com.sryo.dotto.anthropic-api-key`, account `default`, accessible after first unlock, this device only (`Platform/Claude/AnthropicAPIKeyStore`). Set, replaced and removed in the menu bar panel. At launch, a key left under the pre-rename service `com.sryo.again.anthropic-api-key` is moved to this item once, only when this item is empty (`Core/Claude/AnthropicAPIKeyRenameMigration`). No secrets in the repo or `Info.plist` |
| API endpoint and headers | `POST https://api.anthropic.com/v1/messages` (SSE) with `x-api-key`, `anthropic-version: 2023-06-01` and `content-type: application/json` (`Core/Claude/AnthropicMessagesEndpoint`). No `anthropic-beta` value is sent: nothing the requests use needs one |
| Models | `Core/Claude/ClaudeModelConfiguration`: planner `claude-opus-5-5`, executor `claude-sonnet-5`. Keep this in sync with `ClaudeMessagesRequestGuard.allowedModelIdentifiers` |
| Audit logs | `~/Library/Logs/Dotto/<task-id>.jsonl` |
| Saved routines | `~/Library/Application Support/Dotto/Routines/*.json` |
| Undo journals | `~/Library/Application Support/Dotto/Journals/<task-id>.jsonl` (directory 0700, files 0600): a header, one line per change, one per change undo reverted, and status lines. The newest 20 and anything younger than 7 days are kept, pruned at launch |
| Accessibility modes to restore after a crash | `~/Library/Application Support/Dotto/ChangedAccessibilityModes.json` (0600, only while modes are changed) |
| Summon shortcut | UserDefaults `dottoSummonHotkey` (JSON `SummonHotkey`, default ⌃⌥Space), set with the menu bar panel's recorder |
| Circle to summon | UserDefaults `dottoSummonGesture` (JSON `SummonGestureUserChoices`: `enabled`, `direction`, `loopsNeeded` only; every tuning value comes from `SummonGestureConfiguration`'s defaults), and `dottoSummonGestureExclusionAdditions` / `dottoSummonGestureExclusionRemovals` (string arrays applied on top of `SummonGestureEligibility.defaultExcludedBundleIdentifiers`; absent when empty, cleared by "Reset to defaults"), set in the menu bar panel. The old `dottoSummonGestureExcludedApps` full list is migrated once at launch and deleted |
| Other preferences | UserDefaults `dottoAttentionPreferences`, `dottoLiveViewCorner`, and `dottoCursorStyleJSON` (the cursor lab's JSON, set with `defaults write com.sryo.dotto dottoCursorStyleJSON '<json>'`) |
| Task focus policy | UserDefaults `dottoTaskFocusPolicy` (`allow_approved_assist` by default, or `background_only`), changed in the menu bar panel before a task |
| Notifications | Category ids `dotto.<option>-<option>…`, one per set of answer buttons (`App/UserAttentionNotificationPoster`) |
| Routine signing key | Keychain generic password, service `com.sryo.dotto.routine-signing` |
| Bundle id and minimum OS | `com.sryo.dotto`, macOS 14.2 |
| Permissions | Accessibility and Screen Recording (checked in `Platform/Permissions/SystemPermissions`). Direct routes add Automation (asked by macOS after the user clicks Run on a script, per target app, and once for Finder when a command is submitted over a Finder window: Finder windows expose no folder to Accessibility, so the folder and selection are read with a fixed, read-only AppleScript) and Files & Folders (asked by macOS when the planner first lists a protected folder such as Desktop) |
| Info.plist usage strings | `NSScreenCaptureUsageDescription`, `NSAppleEventsUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` (in `Dotto/Info.plist`, the target's `INFOPLIST_FILE`) |
| Entitlements | `Dotto/Dotto.entitlements`: no sandbox, `network.client`, the ScreenCaptureKit picker exception, and `com.apple.security.automation.apple-events` (required under the hardened runtime for scripts, the Automation probe and the Finder folder query) |

## Code style

- **Clarity beats brevity.** Use very explicit, long names
  (`accessibilityElementIdentifierToElementReference`, not `map`). Never use single-letter names. Pass arguments
  under the same names as the variables they come from.
- Clear beats clever. Write more lines if they read better.
- Comments explain *why*. Add a *what* comment only when names can't carry it (dense math, cryptic system APIs,
  non-obvious invariants). Never reference tasks, fixes or callers ("added for X"). Don't add comments or
  docstrings to code you didn't change.
- Use SwiftUI for all UI. Use AppKit only where SwiftUI can't do the job: `NSPanel` hosts bridged through
  `NSHostingView`, event taps, and AX.
- UI state is `@MainActor`. Use async/await, not completion handlers.
- **Motion is liquid.** Dotto's UI morphs and bounces in a fluid, liquid way (the owner's direction):
  - An element turns into the next one; it never fades out while another pops in somewhere else. The command pill
    becomes the cursor's status pill, and the status pill grows into the checklist.
  - Arrivals and size changes bounce visibly: springy, then settled. That means spring damping around 0.6–0.7, and
    a pill pops in from about 60% of its size. An arrival must never flatten into a plain fade or a stiff ease-only
    slide.
  - When text swaps, the old text leaves before the new one arrives, so two texts are never both clearly visible.
  - A shadow stays continuous across a handoff, and the last frame of a morph matches the element that replaces it.
  - Use the shared motion tokens in `DesignSystem.Motion` (`UI/DesignSystem/DesignSystemMotion.swift`), never ad hoc
    springs:
    - `appear`, `morph` and `resize` are soft springs
    - `disappear` is a short ease-out
    - `contentFade` swaps text
    - window fades use `windowFadeTimingFunction`

    The staged pill morph is timed by `Core/Cursor/CommandPillMorphTimeline`.
  - Reduce Motion drops scale and position springs: changes are instant or a short fade.
  - Check new motion in a frame-by-frame recording before calling it done.
- Every button shows the pointer cursor on hover (`.pointerCursor()`) and has a hover state. For any interactive
  element, decide its cursor, its visual feedback, and whether hover should signal that it is clickable.
- Panels size themselves; hosting views never do (`UI/Shared/PanelContentSizing`). Every `NSHostingView` in a Dotto
  panel is `.sizedOnlyByItsPanel()` (no sizing options, so it never pushes constraints onto the window: that loop
  crashed AppKit's Update Constraints pass). Content that follows its own size is `fixedSize` and reports it with
  `.reportingPanelContentSize(to:)`; the panel then changes its frame through a `DeferredPanelFrameApplier`
  (a later run-loop turn, coalesced, no-ops under 0.5 pt skipped, origin-only moves while the size is unchanged).
  Never set a window's frame from inside a SwiftUI geometry callback or a layout pass. Measure at show time with
  `laidOutContentSize(reportedTo:)`, not `fittingSize` (which is zero without sizing options).
- Don't add features, refactors or "improvements" beyond what was asked.

## Git

- Name branches `feature/…` or `fix/…`. Never force-push to `main`.
- Write commit messages in the imperative mood, and explain why the change was made.
- **No AI attribution** in commits or PRs: no `Co-Authored-By` trailers and no "Generated with" footers.

## Key files

| Path | What lives there |
|---|---|
| `Dotto/App/DottoApp.swift` | `DottoApp` and `DottoAppDelegate`, the composition root. Builds the transport, backends, monitors, store and panels |
| `Dotto/App/TaskSessionController.swift` | The coordinator: its published state and the state machine events it applies |
| `Dotto/App/TaskSessionController+Planning.swift`, `+Run`, `+Decisions`, `+Pause`, `+ExecutionObserving` | Command and planning; starting and finishing a run; safety confirmations and failure decisions (each a `PendingUserAnswer`); pause, resume and takeover; executor callbacks that drive the cursor and the takeover detector |
| `Dotto/App/TaskSessionController+Teaching.swift`, `+SavedRoutines`, `+Attention`, `+ForegroundAssist`, `+SummonHotkey`, `+SummonGesture`, `+AnthropicAPIKey` | Teach mode; saved routines and file pickers; chimes, notifications and the cursor's attention requests; the bring-forward countdown; the summon shortcut; circle-to-summon settings and opening the pill; saving, replacing and removing the API key, and opening the panel's key card when a command needs one |
| `Dotto/App/SummonGestureController.swift` | Starts and stops the pointer observation per eligibility, feeds the recognizer, draws the ring, fires the pill |
| `Dotto/App/TaskSessionController+DirectRoutes.swift`, `DirectRouteSessionState.swift` | The planner's direct-route context (scope roots, scriptability, Automation state); running an approved direct plan; undo; planning the same command again; what the direct-route views show |
| `Dotto/App/TaskRunDelegateBridge.swift`, `PreviousApplicationTracker.swift`, `UserAttentionNotificationPoster.swift` | The run-scoped executor delegate; handing activation back to the user's app; optional notifications |
| `Dotto/Core/Task/` | `TaskSessionStateMachine` (every legal state transition), `PendingUserAnswer` (the run's one outstanding question, answered exactly once from any surface), run summary, user-facing messages |
| `Dotto/Core/Checklist/` | `Checklist` and `ChecklistItem` models, `ChecklistPlanner` (one conversation per task, paused on `ask_user` and continued with the reply), `ChecklistPlanningProgress` (what the planner is doing, for the status line and the cursor), `PlannerConversationModels` (the question and its choices, the thread's transcript, markdown to plain text) |
| `Dotto/Core/Agent/` | Tool schemas and the decoder, `PromptLibrary`, `ChecklistItemAgentLoop`, `ChecklistItemExecutionModels` (an item's execution context and result) |
| `Dotto/Core/Claude/` | Messages API models, the SSE accumulator, the tool-conversation runner, `ClaudeTransport` and its metered wrapper, model ids, `ClaudeMessagesRequestGuard` (model allowlist, `max_tokens` cap, custom tools only), `AnthropicMessagesEndpoint` (URL and headers), `AnthropicAPIKeyFormat` (validation on save and the masked form), `AnthropicAPIKeyRenameMigration` (whether to move a key saved under the pre-rename Keychain service) |
| `Dotto/Core/Execution/` | `TaskExecutor`, `DirectRouteExecutor` (approved direct plans: re-validation, confirmations, file operations, one script or shortcut), the `ActionBackend` protocol, the bring-forward assist decision and readiness policy, abort, run control, takeover, retry, budget, metrics |
| `Dotto/Core/InputDelivery/` | `InputTierPlanner` (tiers and delivery confirmation) with `MenuShortcutMatcher`, `TextReplacementPlanner` (`replace_text`'s UTF-16 edits, expected value and routes), pointer recipes for the assist, `FocusedKeyboardInputGuard` for open panels, change fingerprints, app kind classification |
| `Dotto/Core/Cursor/` | The cursor seam: presentation state and mapper (planning, review and run states), `CursorPillText` (the pill's one line, with the item position), attention requests and preferences, which answers still apply and the 0.5 s click guard (`UserDecisionAnswerPolicy`), surface placement with hysteresis, `AttachedPanelPlacement` (the checklist popover beside the cursor or the live view: flips, clamping, tail), `PillPlacement` (the cursor's pill, the command pill and the live view kept inside the visible frame of their point's screen, flipped left of or above the point), `CommandPillHandoff` (the status pill taking the submitted command pill's capsule's place: shared tip-facing edge and vertical center, same flips), flight path, style defaults |
| `Dotto/Core/Uploads/` | `UploadFileAllowlist` and `ProtectedPathPolicy` (the protected-path deny list, shared with file operations) |
| `Dotto/Core/DirectRoutes/` | `DirectRouteModels` (scope, plans, run reports, and the performer protocols Platform implements) and `CommandPathExtractor` (folder paths typed by the user) |
| `Dotto/Core/FileOperations/` | Scope policy, path rules, the dry-run validator, the date-folder and rename rule expanders (sharing `FileRuleFileFilter`), `FileOperationContainmentCheck` (each operand's real folder right before a change), `FileOperationRunner`, the undo journal and `FileOperationUndoRunner` |
| `Dotto/Core/Scripting/` | `ScriptSourceInspector`, `ScriptTargetPolicy`, `ScriptFileReferenceInspector` (places a Finder script names outside the scope, file verbs with no place inside it: named in a delete's or send's question), `ShortcutNameRules` |
| `Dotto/Core/Routines/` | Routine models, compilers (agent run and demonstration), templating, locators, replay, signing, the library store, `RoutineLiteralInspector` (fixed text a routine types, and text that looks like a secret) |
| `Dotto/Core/Safety/` | `SafetyGate`, `SafetyConfirmationFlow` (the one place a confirmation is asked and applied), `SafetyModels` (limits, categories), `SafetyRiskVocabulary`, `TargetApplicationPolicy` |
| `Dotto/Core/SummonGesture/` | `CircleSummonGestureRecognizer`, `SummonGestureConfiguration`, `SummonGestureModels` (sample, analysis, update), `SummonGestureEligibility` (with the default exclusion list and the fire-time check), `SummonGesturePreferenceModels` (stored choices, exclusion additions/removals), `SummonGestureDisplayGeometry` |
| `Dotto/Core/Support/` | `CanonicalJSONEncoding` (stable bytes for prompt caching and routine signatures; never change its options), `JSONValue`, SHA-256, the `SummonHotkey` model |
| `Dotto/Core/Verification/`, `UserInterfaceReading/`, `Audit/`, `Permissions/` | Expectations and waiting, the AX snapshot and outline formatter, the audit log, permission policy |
| `Dotto/Platform/Accessibility/AccessibilityActionBackend.swift` | The backend's entry point: target pinning, element resolution, tier dispatch |
| `Dotto/Platform/Accessibility/AccessibilityActionBackend+Click.swift`, `+Typing`, `+ReplaceText`, `+Keys`, `+Scroll`, `+ChangeConfirmation`, `+Uploads` | One file per action family (`+ReplaceText`: `replace_text` through AXSelectedTextRange/AXSelectedText, else the whole AXValue, read back), the visible-change confirmation, and `upload_files` inside the assist |
| `Dotto/Platform/Accessibility/AccessibilityElementReader.swift` with `+AttributeReading`, `+DeliverySupport`, `+Recording` | Outlines and snapshots; shared attribute reads; what delivery planning reads; what teach mode reads |
| `Dotto/Platform/Accessibility/NativeOpenPanelDriver.swift` with `+FocusedKeyboardGuard`, `+PanelReading` | Choosing files in an open panel (invariant 3c); the inputs to Core's guard; finding the panel's parts |
| `Dotto/Platform/Accessibility/TargetApplicationAccessibilityModes.swift`, `TargetWindowObserver.swift` | Per-task accessibility modes with crash recovery; window move and close events for takeover |
| `Dotto/Platform/Input/InputSynthesizer.swift`, `InputSynthesizerModels.swift`, `VirtualKeyCodeTables.swift`, `KeyboardLayoutCharacterTable.swift` | CGEvent synthesis; `TargetProcessPin` and the synthetic-input marker; key code tables; the current layout's character map |
| `Dotto/Platform/Input/GlobalKeyboardMonitor.swift`, `SummonHotkeyConflictCheck.swift` | The summon shortcut (and nothing else) and the check for macOS or launchers already owning it |
| `Dotto/Platform/Input/UserInputObserver.swift`, `RealUserInputCounter.swift`, `ForegroundAssistReadinessProbe.swift`, `ForegroundAssistSession.swift`, `DottoWindowPointerHitTest.swift`, `DemonstrationRecorder.swift` | The user-input observer and its real-input counter, the bring-forward readiness probe and session, the hit test that keeps clicks on Dotto's own windows from counting as takeover, the teach-mode recorder |
| `Dotto/Platform/SummonGesture/PointerMovementObserver.swift`, `PointerTargetApplicationResolver.swift`, `SessionScreenLockReader.swift` | The one idle-time pointer observation (moves and button state only); the app under the pointer and the full-screen check on the pointer's display; lock and fast-user-switching state |
| `Dotto/Platform/WindowServer/` | `PrivateWindowServerBridge` (window ids, the optional authenticated key path) and `WindowListEntryClassification`, the overlay and shield rule shared by the hit test, the visibility monitor and the backend |
| `Dotto/Platform/FileOperations/`, `Dotto/Platform/Scripting/` | `FileManagerFileSystem` (mutations and reads), `FinderWindowFolderResolver`; `BoundedProcessRunner` (fixed executables, argument arrays, capped pipes, timeout and Stop; the child leads its own process group, which Stop kills), `OsascriptScriptRunner`, `ShortcutsCommandRunner`, `AutomationPermissionProbe`, `ScriptabilityProbe` |
| `Dotto/Platform/{Capture,Claude,Permissions,Routines,Uploads}/` | Window capture and visibility (ScreenCaptureKit), `AnthropicMessagesTransport` (direct to api.anthropic.com: SSE, retries, error mapping, cancellation) and `AnthropicAPIKeyStore` (the Keychain item), TCC checks, the Keychain signing key, upload path canonicalization |
| `Dotto/UI/Shared/` | `DottoPanel` (the non-activating base of every Dotto window, with `KeyablePanel` and `NonActivatingClickablePanel`), `NSHostingView+Panels`, `PanelContentSizing` (hosting views sized only by their panel, reported content sizes, deferred frame changes), `AttachedPanelTailView`, `ScreenCorner`, screen geometry, the drag area |
| `Dotto/UI/Cursor/` | `CursorController` (the one presenter, with `CursorViewModel`), `CursorSurfaces` (the cursor parked at the summon origin, the overlay window, the pill panel and the live view panel), `CursorView`, `CursorShapes`, `CursorAppearance` (with `CursorPalette`), `CursorPillView` (with `DecisionPill`), `LiveViewPanelView` |
| `Dotto/UI/SummonGesture/` | `SummonGestureRingPanelController` (the click-through ring panel) and `SummonGestureRingView` |
| `Dotto/UI/` (other) | `MenuBar` (incl. `AnthropicAPIKeySection`, `UndoLastTaskRow`, the summon shortcut recorder, circle-to-summon and attention settings), `CommandBar` (the bar with file attachments, `CommandPillView`, the pill at the pointer, and `CommandPillMorphView`, the pill turning into the cursor's status pill on Return), `Checklist` (the popover panel attached to the cursor, rows, the planning thread and reply field, intervention cards, routine review, direct-route previews, progress and results), `Routines` (step list), `Attention` (`AttentionChime`), `DesignSystem` |
| `DottoCoreTests/` | Suites mirroring `Core/`, plus `Support/` (harness and fixtures) and `TestDoubles/` |
| `scripts/` | `typecheck.sh`, `run-core-tests.sh`, and `release.sh` (owner only) |

## Keep this file current

Update this file in the same change whenever you:
- add, move or delete a feature folder
- change a safety invariant or ceiling
- change models, the API endpoint or headers, Keychain items, Info.plist keys, or on-disk paths
- change the build and test gates
- adopt a convention the owner asks for

Don't update it for small edits.
