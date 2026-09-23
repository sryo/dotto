# Dotto

**Teach your Mac a chore once. Dotto does the rest.**

Dotto is a macOS menu bar app for the repetitive work that lives in Mac apps with no API, no Shortcuts support and
no bulk-edit button. Type what you want done. Dotto shows you a checklist. When you approve it, Dotto works through
the list in your own apps, in the background, with its own cursor showing every step before it happens. You keep
using your Mac while it works.

The first item is the only one that needs working out. After that, Dotto replays the same steps for the rest of
the list, so most items make no AI call at all.

## How it works

1. **Ask.** In the app you want to automate, press ⌃⌥Space (you can change it in the menu bar panel), or circle
   the pointer over it, and type a command, for example "Rename these 40 photos to the event name plus the date".
   Dotto works in the app you asked in, and only in that app.
2. **Plan.** Claude (Opus) reads the app's accessibility outline, plus a screenshot when it needs one, and turns
   your command into a checklist: one line per photo, invoice or file, with the values each line needs. If the
   command is unclear, it asks you instead.
   **Fastest route first.** When a chore can be done without the cursor, Dotto plans it that way:
   - direct file operations in Finder (rename, move, tag, sort into folders, with Undo)
   - a short AppleScript you read before it runs
   - one of your own Shortcuts

   In testing, numbering 150 photos by date took about 10 seconds to plan and about a second to run.
3. **Approve.** Uncheck items, edit them, or cancel. Nothing runs before you approve.
4. **Watch, or keep working.** Dotto works through the items in the background with its own colored cursor. It
   never takes your mouse, your keyboard or your front window. When the app is covered, the cursor moves into a
   small live view of it. Every step is checked against what the screen should show afterwards.
   - Clicking or typing in the app Dotto is using pauses it. Working in other apps doesn't.
   - When Dotto needs you, its cursor asks, with a soft chime and a pulse in the menu bar.
   - If a step truly needs the app in front (a file dialog, say), Dotto asks first, waits until you pause, brings
     the app forward for a few seconds, and then puts your app, window and pointer back.
   - **To stop Dotto**, click Stop on its cursor, the live view, the checklist or the menu bar panel. Esc works
     while the checklist is focused. There is no global stop shortcut, so Esc in your other apps stays theirs.
5. **Teach, or let it learn.** Do the first item yourself while Dotto records, or let Claude (Sonnet) do it.
   Either way, you review the resulting routine before it is used or saved.
6. **Replay.** The remaining items replay the routine directly. Claude is called again only when a replayed step
   doesn't produce what it should. Saved routines can run later on a pasted list, or on every file in a folder,
   without planning.

## Summon it

Press ⌃⌥Space, or circle the pointer (clockwise, about one and a half loops) over the app you want Dotto to work
in. A ring fills around your pointer as you circle, and the command pill opens right there, for the app under the
pointer. Return plans it; Esc closes it.

The gesture only watches where your pointer moves (never your keyboard), only while Dotto is idle, and not in
full-screen apps or excluded apps such as drawing tools and games. Nothing it sees is stored or sent. The menu bar
panel has its on/off switch, the direction, how many loops it takes, and the exclusion list.

## Examples

- Rename, tag, caption or export a batch of photos in a desktop photo app.
- Enter a stack of invoices or receipts into an accounting or inventory app that has no import.
- Bulk-edit files in Finder: rename them from a list, set tags, move them into folders.
- Copy rows from a list into a form in a native app, one record at a time.
- Upload a folder of files, one per form, using only the files you attached to the task.
- Web chores such as scheduling posts or filling in web forms, in the browser you already use.

## Safety and privacy

Dotto acts in your real apps, so it is built to stop and ask rather than guess.

**It will never:**
- run anything before you approve the checklist
- send, post, delete, pay or buy, bring an app forward, upload a file, or run one of your Shortcuts without asking
  you first. In mail, chat and browser apps, pressing Return counts as sending. Approving one kind of action ("send")
  never approves another ("delete"), and each approval lasts one task at most.
- type into password fields
- operate Terminal and other terminals, System Settings, Keychain Access, password managers or system security
  prompts, or use app-switch, quit, lock or Spotlight shortcuts
- act in an app other than the one you started the task in, or open an app by itself
- bring an app to the front without asking you, or while you are in the middle of clicking or typing
- upload a file you didn't attach to the task
- follow instructions it finds on screen. Screen text is treated as data and can't add items to your checklist.
- load a saved routine that was changed outside Dotto. Routines are signed with a key kept in your Keychain.
- save a routine you haven't reviewed

It also stops itself at fixed limits on actions, model calls, tokens, time (30 minutes) and consecutive failures.

**What stays on your Mac.** Each task writes an audit log to `~/Library/Logs/Dotto/`: every plan, tool call,
safety decision and result. Text Dotto typed is replaced by a fingerprint. Saved routines live in
`~/Library/Application Support/Dotto/Routines/`. Both are readable only by your user account. There is no
analytics.

**What leaves your Mac.** To plan and act, Dotto sends Anthropic's API:
- your command
- the target app's accessibility outline (element names, roles and visible values)
- screenshots of the target window, when needed

These requests go straight from your Mac to `api.anthropic.com`, signed with **your own** API key. Anthropic's data
policies apply to them. Nothing else is sent anywhere.

## Requirements

- macOS 14.2 or later
- Xcode, with a signing team
- An Anthropic API key

## Setup

### 1. Get an Anthropic API key

Create a key at [platform.claude.com/settings/keys](https://platform.claude.com/settings/keys). Dotto is a
personal tool: every request is billed to that key. Dotto only uses its two models (`claude-opus-5-5` to plan,
`claude-sonnet-5` to act), caps output tokens per request, and never sends server tools, so each call stays bounded.

### 2. Build, run and grant permissions

Open `Dotto.xcodeproj`, choose the **Dotto** scheme, set your signing team, and press Cmd+R. Dotto appears in the
menu bar and has no Dock icon. On first launch its panel asks for:
- **Your Anthropic API key**: paste it into the card at the top and press Save. It is stored in your login
  Keychain (item `com.sryo.dotto.anthropic-api-key`), only ever sent to `api.anthropic.com`, and shown afterwards
  only in masked form (`sk-ant-…a1b2`). Replace or remove it from the same panel.
- **Accessibility**, to read and operate app interfaces
- **Screen Recording**, to see the target window when the accessibility outline isn't enough, and for the live view

The first time you save a routine, macOS may ask to let Dotto use its Keychain item.

Build from Xcode rather than running `xcodebuild` in a terminal. Re-signing the app from the command line makes
macOS drop the Accessibility and Screen Recording grants.

## Development

- `Dotto/Core/` holds the pure logic (Foundation and CoreGraphics only). It is the unit-tested part.
- `Dotto/Platform/` wraps the macOS APIs, and `Dotto/UI/` holds the SwiftUI views and panels.
- `Dotto/App/` wires them together.

Before opening a PR, run every gate:

```bash
zsh scripts/typecheck.sh        # typechecks the whole app with Xcode's toolchain, without building a bundle
zsh scripts/run-core-tests.sh   # import guards, then compiles Core with DottoCoreTests and runs every suite
```

[`AGENTS.md`](AGENTS.md) covers the architecture, the conventions and the safety invariants every change must
keep. It is written for coding agents and is just as useful for people.

## License

Dotto is released under the license in [LICENSE](LICENSE): use it, change it and share it, but keep it under the
same license. There are no warranties and no liability.

## Author

Made by [sryo](https://github.com/sryo).
