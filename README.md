# todo-picker

A Neovim plugin utilizing Snacks picker to bridge the gap between simple TODO lists and full-featured task details panels, similar to Jira-style tickets.

## Features

- **Snacks Picker Integration**: A rich interactive picker displaying TODOs in hierarchical or flat lists.
- **Task Details Panel**: Pressing `Enter` on any todo item opens a floating panel allowing edits to the title, description, log messages, tags/extra fields, status, and priorities.
- **Markdown Reference Integration**: Easily sync a TODO item in a JSON file to a markdown todo item with a reference string (e.g., `TODO: task name (#id)`).
- **Subtask Hierarchy**: Create parent-child relationships between tickets and navigate between them.
- **Filtering and Querying**: Powerful filter syntax (`#label` or `field=value`) to segment your tasks.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'george-tk/todo-picker', 
  -- for local testing remove gitpath  
  -- dir = '~/todo-picker/',
  -- name = 'todo-picker'
  dependencies = {
    'folke/snacks.nvim',
  },
  opts = {}, -- This automatically configures and runs setup()
  keys = {
    { '<leader>ft', ':Todo<CR>', desc = 'All TODOs' }
  }
}
```
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
│       └── markdown.lua   -- Markdown reference integration & cursor lookups
└── plugin/
    └── todo-picker.lua    -- Automatic keymap and command bootstrap on startup
```

## User Commands

- `:TodoFilter #label[,field=value,...]` - Show TODOs filtered by labels or metadata.
- `:TodoGoTo` - Jump to details panel for the markdown reference under the cursor.
- `:TodoReference` - Open picker to select a TODO and insert a reference in the current markdown buffer.

## Keymaps

### Picker Window

- `<CR>`: Open task details panel
- `/`: Toggle search input / list focus
- `S`: Cycle status
- `P`: Cycle priority
- `x`: Cycle done visibility (`hide`, `recent`, `all`)
- `r`: Prompt relationship settings (choose direction + unlink)
- `p`: Open parent todo detail
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

- `<CR>`: Save and close details panel
- `w`: Save edits in-place
- `q` / `<Esc>`: Close details panel
- `S`: Cycle status
- `P`: Cycle priority
- `D`: Delete todo
- `r`: Prompt relationship settings
- `p`: Open parent details panel
- `c`: Open selected subtask details panel under cursor
- `a`: Add a subtask
- `e`: Open source JSON file
- `m`: Open markdown reference
- `Tab`: Jump to next details field
- `S-Tab`: Jump to previous details field
- `?`: Toggle help menu
