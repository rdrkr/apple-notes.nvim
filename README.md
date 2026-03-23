<!-- Copyright (c) 2026 apple-notes.nvim by Ronen Druker. -->

<h1 align="center">
  apple-notes.nvim
</h1>

<div align="center">

Edit, create, and manage **Apple Notes** directly from Neovim.
Notes appear as Markdown in virtual buffers — no files on disk, no GUI app needed.

[![Neovim 0.10+](https://img.shields.io/badge/neovim-0.10%2B-57A143?style=flat&logo=neovim&logoColor=white)](https://neovim.io/)
[![Lua](https://img.shields.io/badge/lua-5.1%2B-2C2D72?style=flat&logo=lua&logoColor=white)](https://www.lua.org/)
[![macOS only](https://img.shields.io/badge/macOS-14%2B-000000?style=flat&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-yellow.svg)](LICENSE)

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[Features](#-features) • [Requirements](#-requirements) • [Installation](#-installation) • [Configuration](#%EF%B8%8F-configuration) • [Usage](#-usage) • [Keybindings](#%EF%B8%8F-keybindings) • [Architecture](#%EF%B8%8F-architecture)
<!-- prettier-ignore-end -->

</div>

---

> **Why?** Terminal users who prefer TUI over GUI shouldn't need to switch to the
> Apple Notes app just to get iCloud sync and the native Apple ecosystem.
> apple-notes.nvim brings your notes into Neovim while Apple handles the sync.

## ✨ Features

- **📝 Edit as Markdown** — Notes render as Markdown in virtual buffers; save with `:w`
- **🔍 Telescope Picker** — Find and open notes with live preview
- **🌲 neo-tree Sidebar** — Folder/note tree with full CRUD operations
- **⚡ Quick Capture** — Append text to a note without leaving your workflow
- **🔄 Bidirectional Sync** — Changes sync back to Apple Notes via AppleScript
- **📱 External Change Detection** — Detects edits from iPhone, iPad, or web
- **📁 Folder Management** — Create, rename, delete, and move notes between folders
- **☑️ Checklist Toggle** — Toggle checkboxes with `<C-Space>`

---

## 📋 Requirements

| Dependency    | Version      | Notes                                     |
| ------------- | ------------ | ----------------------------------------- |
| **macOS**     | 14+ (Sonoma) | Required — Apple Notes database access    |
| **Neovim**    | 0.10+        | `vim.fn.jobstart`, `vim.loop` APIs        |
| **sqlite3**   | 3.33+        | Ships with macOS — used for reading notes |
| **osascript** | —            | Ships with macOS — used for writing notes |
| **pandoc**    | 3.0+         | HTML ↔ Markdown conversion                |

**Full Disk Access** must be granted to your terminal app (Terminal.app, iTerm2, Kitty, etc.)
in **System Settings → Privacy & Security → Full Disk Access** to read the Notes database.

### Optional Dependencies

| Plugin                                                             | Purpose                                                     |
| ------------------------------------------------------------------ | ----------------------------------------------------------- |
| [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) | Note picker and search (`:AppleNotes`, `:AppleNotesSearch`) |
| [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)    | Tree sidebar (`:AppleNotesTree`)                            |

---

## 📦 Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "rdrkr/apple-notes.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim", -- optional: for note picker
    "nvim-neo-tree/neo-tree.nvim",   -- optional: for tree sidebar
  },
  event = "VeryLazy",
  keys = {
    { "<leader>anf", "<cmd>AppleNotes<CR>", desc = "Find Apple Note" },
    { "<leader>ann", "<cmd>AppleNotesNew<CR>", desc = "New Apple Note" },
    { "<leader>ant", "<cmd>AppleNotesTree<CR>", desc = "Toggle Apple Notes tree" },
  },
  opts = {},
}
```

> **Note:** Using `event = "VeryLazy"` ensures `:checkhealth apple-notes` works
> immediately. If you prefer full lazy-loading via `cmd` or `keys`, the health
> check will only be available after the plugin has been triggered.

### neo-tree Integration

If using **neo-tree**, you **must** add `"apple-notes"` to your neo-tree `sources` list.
Add this to your **neo-tree plugin spec** (not the apple-notes spec):

```lua
-- In your neo-tree plugin spec (lazy.nvim):
{
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    sources = {
      "filesystem",
      "buffers",
      "git_status",
      "apple-notes", -- add this
    },
    ["apple-notes"] = {
      window = {
        mappings = {
          ["o"] = "open",
          ["a"] = "add",
          ["A"] = "add_directory",
          ["d"] = "delete",
          ["r"] = "rename",
          ["m"] = "move",
          ["R"] = "refresh",
        },
      },
    },
  },
}
```

> Without this, `:AppleNotesTree` will show an error asking you to add the source.

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "rdrkr/apple-notes.nvim",
  requires = {
    "nvim-telescope/telescope.nvim", -- optional
    "nvim-neo-tree/neo-tree.nvim",   -- optional
  },
  config = function()
    require("apple-notes").setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'nvim-telescope/telescope.nvim' " optional
Plug 'nvim-neo-tree/neo-tree.nvim'   " optional
Plug 'rdrkr/apple-notes.nvim'

" In your init.vim / init.lua:
lua require('apple-notes').setup()
```

### [mini.deps](https://github.com/echasnovski/mini.deps)

```lua
MiniDeps.add({
  source = "rdrkr/apple-notes.nvim",
  depends = {
    "nvim-telescope/telescope.nvim", -- optional
    "nvim-neo-tree/neo-tree.nvim",   -- optional
  },
})
require("apple-notes").setup()
```

---

## ⚙️ Configuration

```lua
require("apple-notes").setup({
  -- Default folder for new notes (nil = Apple Notes default folder)
  default_folder = nil,

  -- Note title for quick capture target
  -- Set to a note title or leave nil to prompt on first use
  capture_note = nil,

  -- Poll interval for external change detection (ms)
  poll_interval = 30000,

  -- Keymap prefix for global keymaps
  -- Set to false to disable default keymaps
  keymap_prefix = "<leader>an",
})
```

### Configuration Options

| Option           | Type            | Default        | Description                                                               |
| ---------------- | --------------- | -------------- | ------------------------------------------------------------------------- |
| `default_folder` | `string\|nil`   | `nil`          | Default folder when creating notes. `nil` uses Apple Notes default.       |
| `capture_note`   | `string\|nil`   | `nil`          | Title of the note used for quick capture. Prompts on first use if `nil`.  |
| `poll_interval`  | `number`        | `30000`        | Interval (ms) for checking external changes from other devices.           |
| `keymap_prefix`  | `string\|false` | `"<leader>an"` | Prefix for global keymaps. Set to `false` to disable all default keymaps. |

### Highlight Groups

All highlight groups can be overridden in your colorscheme:

| Group                 | Default Link | Used For                   |
| --------------------- | ------------ | -------------------------- |
| `AppleNotesTitle`     | `Title`      | Note titles in picker/tree |
| `AppleNotesFolder`    | `Directory`  | Folder names               |
| `AppleNotesTime`      | `Comment`    | Relative timestamps        |
| `AppleNotesTrash`     | `WarningMsg` | Deleted notes indicator    |
| `AppleNotesChecked`   | `String`     | Checked checkboxes         |
| `AppleNotesUnchecked` | `Todo`       | Unchecked checkboxes       |

---

## 🚀 Usage

### Commands

| Command                   | Description                                  |
| ------------------------- | -------------------------------------------- |
| `:AppleNotes`             | Find and open a note (Telescope picker)      |
| `:AppleNotesFind`         | Alias for `:AppleNotes`                      |
| `:AppleNotesNew [folder]` | Create a new note (optional folder argument) |
| `:AppleNotesQuick {text}` | Append text to your capture note             |
| `:AppleNotesTree`         | Toggle neo-tree sidebar                      |

### Editing Notes

When you open a note, it appears as Markdown in a virtual buffer. Edit normally and
save with `:w` — changes are converted back to HTML and written to Apple Notes.

If the note was modified on another device (iPhone, iPad, web), you'll be prompted
to reload, keep your version, or view a diff.

### Quick Capture

Quickly append text to a designated note without opening it:

```vim
:AppleNotesQuick Buy milk
```

On first use, you'll be prompted to select which note receives captures.
Set `capture_note` in your config to skip the prompt.

---

## ⌨️ Keybindings

### Global (with default `<leader>an` prefix)

| Key           | Action                           |
| ------------- | -------------------------------- |
| `<leader>anf` | Find note (Telescope picker)     |
| `<leader>ann` | New note                         |
| `<leader>anq` | Quick capture (prompts for text) |
| `<leader>ant` | Toggle tree sidebar              |

### In Note Buffer

| Key         | Action                          |
| ----------- | ------------------------------- |
| `<C-Space>` | Toggle checkbox on current line |

### neo-tree Sidebar

| Key          | Action                |
| ------------ | --------------------- |
| `o` / `<CR>` | Open note             |
| `a`          | Add new note          |
| `A`          | Add new folder        |
| `d`          | Delete note or folder |
| `r`          | Rename folder         |
| `m`          | Move note to folder   |
| `R`          | Refresh tree          |

---

## 🏗️ Architecture

```text
apple-notes.nvim/
├── plugin/
│   └── apple-notes.lua        # Lazy-load entry point (guards macOS)
├── lua/apple-notes/
│   ├── init.lua               # Plugin entry: setup(), commands, keymaps
│   ├── db.lua                 # SQLite reads via sqlite3 CLI (read-only)
│   ├── applescript.lua        # Apple Notes mutations via osascript
│   ├── converter.lua          # HTML ↔ Markdown via pandoc
│   ├── buffer.lua             # Virtual buffer lifecycle (buftype=acwrite)
│   ├── sync.lua               # Save queue + external change detection
│   ├── telescope.lua          # Telescope pickers (browse + search)
│   ├── tree.lua               # neo-tree rendering + CRUD commands
│   ├── job.lua                # Shared async shell-out utility
│   ├── sanitize.lua           # SQL + AppleScript injection prevention
│   └── health.lua             # :checkhealth apple-notes
├── lua/neo-tree/sources/apple-notes/
│   └── init.lua               # neo-tree source entry point
└── tests/
    └── test_sanitize.lua      # Unit tests for input sanitization
```

### Data Flow

```text
┌──────────────────────────────────────────────────────────┐
│                       Neovim                             │
│                                                          │
│   Buffer (Markdown)                                      │
│       │           ▲                                      │
│       │ :w        │ open                                 │
│       ▼           │                                      │
│   converter.lua ──┤  pandoc (MD → HTML / HTML → MD)      │
│       │           │                                      │
│       ▼           │                                      │
│   applescript.lua │  db.lua                               │
│   (osascript)     │  (sqlite3 -json -readonly)           │
│       │           │                                      │
└───────┼───────────┼──────────────────────────────────────┘
        │           │
        ▼           │
  ┌─────────────────┴──────┐
  │     Apple Notes        │
  │   NoteStore.sqlite     │
  │        ▲               │
  │        │  iCloud Sync  │
  │   iPhone / iPad / Web  │
  └────────────────────────┘
```

### Key Design Decisions

- **Read via SQLite, write via AppleScript** — The SQLite database is read-only safe;
  mutations go through the official AppleScript interface to maintain data integrity.
- **Schema adapter pattern** — Core Data column names change between macOS versions.
  A version-aware adapter maps columns per OS release.
- **Save queue** — Serializes concurrent `:w` operations to prevent race conditions.
- **Input sanitization** — Dedicated module prevents SQL and AppleScript injection.

---

## 🩺 Health Check

Run `:checkhealth apple-notes` to verify your setup. It checks:

- sqlite3 binary and version (>= 3.33.0)
- osascript availability
- pandoc binary and version (>= 3.0)
- Database file readable (Full Disk Access)
- macOS version and schema adapter status
- Optional dependencies (Telescope, neo-tree)

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Run `make test` before submitting
4. Open a pull request

---

<!-- markdownlint-disable-next-line MD033 -->
<div align="center">

Made with ❤️ by Ronen Druker

</div>
