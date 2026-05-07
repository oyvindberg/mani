# UI

The product is a single-window SwiftUI Mac app with a sidebar tree on the
left and tabbed terminals on the right.

## Layout

```
┌─────────────────────┬────────────────────────────────────────────┐
│ ◤ atlas             │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  6–8 px project band
│   ◤ feat/auth-rew   ├────────────────────────────────────────────┤
│     • claude    [3] │ atlas › feat/auth-rewrite › claude         │  breadcrumb (project-tinted)
│     • tests         ├────────────────────────────────────────────┤
│     • dev server    │ ┌─[claude]─[tests]─[dev server]─────────┐ │  task tab strip
│ ◤ dispatch          │ │                                        │ │
│   ◤ main            │ │                                        │ │
│     • claude        │ │       [terminal viewport, neutral]     │ │
│                     │ │                                        │ │
│                     │ └────────────────────────────────────────┘ │
└─────────────────────┴────────────────────────────────────────────┘
   ↑                                                                  
   sidebar items: 3 px left border in project color
```

Three regions:

1. **Sidebar (left)** — full project / worktree / task tree. Always visible
   in v0.1 (no collapse). Width ~240 px, user-resizable.
2. **Project band (top right)** — solid 6–8 px stripe in the active
   project's color. Anchors visual identity at a glance.
3. **Content area (right)** — breadcrumb header + task tab strip + terminal
   viewport. The terminal viewport is **neutral** (default background, no
   project tint).

## Sidebar tree

Standard `OutlineView`/`List` hierarchy:

- **Project** rows — bold, with a small color swatch (or filled left border
  3 px wide). Right-side affordance for enable/disable toggle (cascading
  kill switch).
- **Worktree** rows — indented one level. Show the kind via a glyph: ⎇ for
  `.git`, 📁 for `.folder`. (Glyphs TBD; ASCII suggestions only.) Show
  branch name if `.git`.
- **Task** rows — indented two levels. Show:
  - Task name
  - Status indicator (• running, ⏸ idle, ⏹ stopped, ✓ completed, ✗ failed)
  - Unread badge `[3]` when `Job.unread > 0`
  - Optional Claude session glyph if `kind == .claude` and `sessionId != nil`

Selecting a row makes it the **active task**: the right pane shows that
task's tab. Selecting a worktree highlights the worktree, no terminal
change. Selecting a project: same.

Right-click context menus per row:
- **Project**: Rename, Change color, New worktree, Disable/Enable, Delete
- **Worktree**: Rename, New task (Claude or Shell), Disable/Enable,
  Open in Finder, Reveal in terminal (system Terminal.app), Remove
- **Task**: Rename, Restart, Stop, Mark complete, Open transcript (Claude
  only), Disable/Enable, Remove

## Tab strip

Tabs in the right pane represent tasks within the **currently selected
worktree**. Selecting a different worktree replaces the tab strip.

Each tab shows: task name, status dot, unread badge.

Decision (TBD with user): should tabs persist across worktree switches as
"recent tasks," or always show only the current worktree's tasks? Current
plan: only the current worktree's tasks. Discuss before changing.

## Per-project color treatment

The user has 8–12 hand-picked colors plus a hex input. **No auto-assignment.**
Cognitive association is the whole point — the user picks deliberately.

### Where color shows up

1. **Sidebar row left border**: 3 px, full color, cascades visually
   (worktrees and tasks under a project all show the same stripe).
2. **Project band**: 6–8 px, full color, no opacity.
3. **Breadcrumb text**: project name in the project's color, normal weight.

### Where it does NOT show up

- Terminal viewport background or text. Untouched. Anything that tints the
  terminal grid breaks vim/tmux/colored CLI output and is not theming —
  it's user-hostile.
- Window chrome (title bar). macOS chrome stays default.
- Other projects' rows. Each row reflects its own project.

### Color palette (provisional)

Suggested swatch grid for the picker. Goal: distinguishable on both light
and dark backgrounds, no two confusable for typical color vision, room for
"destructive" red elsewhere in UI without confusion.

```
#ff6b6b  coral red
#ff9f43  amber
#feca57  warm yellow
#1dd1a1  mint green
#48dbfb  sky cyan
#5f27cd  electric purple
#ff7f50  salmon
#54a0ff  azure blue
#ff6b9d  pink
#a4b0be  cool gray
```

These are placeholders — finalize with the user. Reserve a couple of
"reds" for system error states; don't put pure system-red in the palette.

The picker UI: a 4-column grid of swatches with the hex value below each,
plus a free-form "#______" input at the bottom that updates a preview swatch
live.

## Notifications

Two surfaces:

### Inline (sidebar badge)

`Job.unread` is the count. Renders next to the task name as `[3]` (or a
filled circle with the count). Click on the task → counter resets via
`Action.markJobRead` (TBD).

### macOS user notifications

Triggered by `Effect.userNotification(title:body:)`. Use
`UNUserNotificationCenter`. Subtitle: project name, in body include the
task name and a short message.

When clicked, the notification deep-links to the task — bring app to
front, select the task in the sidebar, focus the tab.

### Notification policy

- Claude `Stop` event → "{task} is awaiting input" notification, badge++
- Claude `Notification` event → use Claude's message text, badge++
- Process exit non-zero → "{task} exited with {code}" notification, badge++
- Process exit zero → no notification by default (configurable later)

Don't notify for events the user just caused themselves. Track a
"recent user activity" timestamp per task; suppress notifications within
2s of the last user keystroke into that task.

## Window and tab navigation (TBD with user)

Suggested defaults. **Confirm with user before implementing.**

| Action | Shortcut |
|--------|----------|
| Next task | ⌘] |
| Previous task | ⌘[ |
| Project N | ⌘1 ... ⌘9 (in sidebar order) |
| New task in current worktree (Claude) | ⌘T |
| New task in current worktree (Shell) | ⌘⇧T |
| New worktree in current project | ⌘N |
| New project | ⌘⇧N |
| Toggle sidebar | ⌘⇧S |
| Focus search/filter in sidebar | ⌘F |
| Cycle to next worktree | ⌃⇥ |
| Cycle to previous worktree | ⌃⇧⇥ |

## Empty states

- **No projects yet**: "Create your first project" CTA in the sidebar.
  Inline form for name + color picker.
- **Project with no worktrees**: empty content pane with "Add a worktree"
  CTA. Form takes path (file picker), kind (.git or .folder), branch
  (if .git).
- **Worktree with no tasks**: empty content pane with "New Claude session"
  and "New shell" buttons.

## Drag and drop (later)

- Drag a folder from Finder onto the sidebar → "create project" preview.
- Drag a folder onto a project → "add worktree" preview.

Defer to v0.2; not in v0.1.

## Accessibility

- All interactive elements have accessibility labels (`accessibilityLabel`).
- Color is **never** the sole signal. Status uses both color and a glyph
  (• ⏸ ⏹ ✓ ✗). Project identity uses border *and* the project name in the
  breadcrumb.
- Keyboard navigation through the sidebar tree must work without mouse.

## Light vs dark mode

Sidebar and chrome follow system. Project colors are picked to work on both
backgrounds (validate during palette finalization). Terminal viewport: use
SwiftTerm's default theme that adapts to system appearance.

## Window state persistence

Window size, sidebar width, last-selected task per worktree → persisted in
`AppState` (probably under `Settings` or a new `Workspace` substate).

Restoring on launch: open the app to the same window size, the same
project selected, the same task active. If the active task can't be
restored (worktree missing, etc.), fall back to the first available task in
the same worktree, then the first task in the project, then the first
project.

## What v0.1 ships without

- No multi-window. Single window only.
- No per-task themes/fonts. App-wide font and theme.
- No customizable shortcuts. Hardcoded for v0.1.
- No quick switcher (Cmd-K). Sidebar selection only.
- No drag-and-drop.
- No notification settings UI. Hardcoded policy above.

These are all v0.2 or later. Resist scope creep; the v0.1 surface is large
already.
