# todo-picker

A powerful agentic Neovim plugin built on top of `snacks.nvim` to bridge the gap between simple markdown TODOs, Kanban boards, and a full Jira/Linear-style ticket management system.

## Features

- **🎨 Dynamic Kanban Board (`:TodoBoard`)**:
  - Interactive multi-column board with round float columns.
  - Smart board navigation mapping (`h`, `j`, `k`, `l`) to jump between status columns.
  - Change task status dynamically by moving cards across lanes.
  - Press `g` to cycle grouping layout modes on the fly: Group by `Parent` (Epics) ➔ Group by `Tag` ➔ `Flat` list.
- **📋 Work & Activity Log (`:TodoLog`)**:
  - Open a floating Work Log dashboard segmented into Completed Tasks, Progress & Activity updates, and Active Focus items.
  - Filter logs on the fly by tag directly from the command line: `:TodoLog week #bau` or `:TodoLog #bau`.
  - Press `r` or `t` to cycle log ranges instantly: `Today` ➔ `Week` ➔ `Month`.
  - Yank log summaries directly to your clipboard with `y`.
- **🛠️ Task Details Panel**:
  - Press `Enter` on any ticket to open a rounded, backdrop-dimmed details card.
  - Supports inline editing of title, description, log messages, tags, status, and priorities.
  - Section navigation: press `Tab` or `Shift-Tab` to cycle between sections—including the `Parent:` metadata row!
  - Clean UI: empty metadata fields (such as Completed dates or Reference links) are automatically hidden instead of displaying messy `—` lines.
- **🌿 Tree-Structure Subtask Hierarchy**:
  - Render subtasks in the Details Panel as clean visual tree branches (`├─` and `└─`).
  - Press `Enter` or `gd` on the parent row or any subtask row to stack details panels and jump straight to that ticket's Details Panel. Closing the child modal returns focus back to the parent ticket.
- **🔍 Modern Search Qualifiers**:
  - Search tags easily by typing `#tagname` in the picker search bar.
  - Search parent subtasks using `@parentname` or `parent:parentname` directly.
- **⚙️ Unified Design Configuration**:
  - Set all status/priority icons, tree branches, and colorscheme highlights inside a single `icons` and `hl_groups` config schema in Neovim.

---

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'george-tk/todo-picker',
  dependencies = {
    'folke/snacks.nvim',
  },
  opts = {}, -- This automatically configures and runs setup()
  keys = {
    { '<leader>tt', ':TodoList<CR>', desc = 'ToDo List' },
    { '<leader>tb', ':TodoBoard<CR>', desc = 'Todo Board' },
    { '<leader>tn', ':TodoNew<CR>', desc = 'New ToDo' },
    { '<leader>tN', ':TodoLinkNew<CR>', desc = 'New Todo + Refference' },
    { '<leader>tr', ':TodoLink<CR>', desc = 'Refference Todo' },
    { '<leader>tj', ':TodoJump<CR>', desc = 'Jump to Todo' },
    { '<leader>tl', ':TodoLog<CR>', desc = 'Log' },
  },
}
```

---

## Configuration Defaults

Custom setup options can be passed to `opts` in lazy.nvim:

```lua
require("todo-picker").setup({
  filetypes = { "markdown", "text" },
  date_format = "%y/%m/%d",
  done_retention_days = 10,
  icons = {
    parent = "󰙅",
    tag = "",
    tree_middle = "├─",
    tree_last = "└─",
    status = {
      TODO = "",
      DOING = "",
      BLOCKED = "",
      PEER_REVIEW = "",
      DONE = "",
    },
    priority = {
      HIGH = "●",
      MEDIUM = "●",
      LOW = " ",
    }
  },
  hl_groups = {
    parent = "TodoParentHint",
    tag = "SnacksPickerKeymapLhs",
    tag_header = "TodoTagHeader",
    priority_high = "DiagnosticError",
    priority_medium = "DiagnosticWarn",
    priority_low = "NonText",
    title_blocked = "TodoTitleBlocked",
    title_peer_review = "TodoTitlePeerReview",
    comment = "Comment",
    normal = "Normal",
  }
})
```

---

## Structure

The plugin is modularly structured:

```text
todo-picker/
├── lua/
│   └── todo-picker/
│       ├── init.lua       -- Plugin entrypoint & API exposure
│       ├── config.lua     -- Configuration options and default tokens
│       ├── utils.lua      -- Highlight helpers, file IO, date parsing
│       ├── store.lua      -- store CRUD, serialization, and JSON representation
│       ├── ui.lua         -- Floating task details card rendering & keymaps
│       ├── picker.lua     -- Snacks.picker configuration and item collection
│       ├── log.lua        -- Work Log generator and UI cycler
│       └── markdown.lua   -- Markdown reference integration & cursor lookups
└── plugin/
    └── todo-picker.lua    -- Automatic keymap and command bootstrap on startup
```

---

## User Commands

- `:TodoList` - Open the TODO list picker.
- `:TodoBoard` - Open the Kanban board.
- `:TodoNew` - Open a blank details panel to create a new task.
- `:TodoLinkNew` - Create a new task and insert its markdown reference at the cursor line.
- `:TodoLink` - Open picker to select a TODO and insert a reference in the current markdown buffer.
- `:TodoJump` - Jump to details panel for the markdown reference under the cursor.
- `:TodoLog [range] [#tag]` - Open the Work & Activity Log (e.g. `:TodoLog week #bau`).

---

## Keymaps

### Picker Window

- `<CR>`: Open task details panel
- `/`: Toggle search input / list focus
- `s`: Cycle status
- `p`: Cycle priority
- `x`: Cycle done visibility (`hide`, `recent`, `all`)
- `r`: Prompt relationship settings (choose direction + unlink)
- `P`: Open parent todo detail
- `f`: Filter picker items by field=value or #label
- `t`: Create a sibling task
- `a`: Create a subtask
- `g`: Toggle grouped hierarchy / flat order
- `z`: Toggle subtask expansion
- `Z`: Toggle all subtask expansions
- `D`: Delete todo
- `e`: Open source JSON file
- `m`: Open markdown reference
- `?`: Toggle help menu
- `q`: Close picker

### Detail Window

- `<CR>`: Save and close details panel (if on Parent/Subtask rows, navigates to that ticket's Details Panel)
- `gd`: Open Details Panel for Parent or Subtask task under cursor
- `q` / `<Esc>`: Close details panel (returns to parent details if stacked)
- `s`: Cycle status
- `p`: Cycle priority
- `D`: Delete todo
- `r`: Prompt relationship settings
- `P`: Open parent details panel
- `c`: Open selected subtask details panel under cursor
- `a`: Add a subtask
- `e`: Open source JSON file
- `m`: Open markdown reference
- `Tab`: Jump to next details field (cycles: Title ➔ Description ➔ Log ➔ Tags ➔ Parent ➔ Subtasks)
- `S-Tab`: Jump to previous details field
- `?`: Toggle help menu

### Kanban Board Window

- `h` / `l`: Move cursor left/right between status lanes
- `j` / `k`: Move cursor down/up within current status lane
- `s`: Cycle task status (moves card to the next column)
- `p`: Cycle task priority
- `Enter` / `e`: Open task details card
- `t`: Create new task in current status lane
- `D`: Delete task with confirmation
- `g`: Cycle grouping mode (Parent ➔ Tag ➔ None)
- `?`: Toggle help menu
- `q` / `<Esc>`: Close Kanban board
