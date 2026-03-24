--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Apple Notes plugin for Neovim.
---
--- Edit, create, and manage Apple Notes directly from Neovim.
--- Notes are presented as Markdown in virtual buffers and synced
--- back to Apple Notes via AppleScript.
---
--- Usage:
---   require('apple-notes').setup({})
---
--- Commands:
---   :AppleNotes        — Open note picker (Telescope)
---   :AppleNotesNew     — Create a new note
---   :AppleNotesQuick   — Quick capture (append text to a note)
---   :AppleNotesTree    — Toggle tree sidebar (neo-tree)
---
--- @module apple-notes
local M = {}

--- Default configuration.
---
--- @type table
local defaults = {
  --- Default folder for new notes (nil = Apple Notes default folder).
  --- @type string|nil
  default_folder = nil,

  --- Note identifier for quick capture target.
  --- Set to a note title or leave nil to prompt on first use.
  --- @type string|nil
  capture_note = nil,

  --- Poll interval for external change detection (ms).
  --- @type number
  poll_interval = 30000,

  --- Keymap prefix for global keymaps.
  --- Set to false to disable default keymaps.
  --- @type string|false
  keymap_prefix = "<leader>an",

  --- Templates for creating new notes.
  --- Each template has a name, optional folder, and body with variable substitution.
  --- Variables: {{title}}, {{date}}, {{time}}
  --- @type { name: string, folder?: string, body: string }[]
  templates = {},
}

--- Active configuration (merged defaults + user config).
--- @type table
M.config = {}

--- Set up the Apple Notes plugin.
---
--- @param opts? table User configuration (merged with defaults)
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Check required dependencies
  M._check_dependencies()

  -- Set up highlight groups
  M._setup_highlights()

  -- Set up user commands
  M._setup_commands()

  -- Set up keymaps
  if M.config.keymap_prefix then
    M._setup_keymaps()
  end

  -- Set up database watcher
  local db = require("apple-notes.db")
  db.setup_watcher()

  -- Handle session restore for apple-notes:// buffers.
  -- Without this, auto-session triggers E325 because Neovim tries to treat
  -- the buffer name as a real file path and creates a swap file.
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "apple-notes://*",
    callback = function(args)
      local bufnr = args.buf
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].buftype = "acwrite"
      vim.bo[bufnr].filetype = "markdown"
      vim.bo[bufnr].modifiable = false

      -- Try to re-open the note by extracting the ID from the buffer name
      local name = vim.api.nvim_buf_get_name(bufnr)
      local id_str = name:match("%[(%d+)%]$")
      if not id_str then
        -- No note ID in name — wipe the stale buffer
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        return
      end

      local note_id = tonumber(id_str)
      local note_db = require("apple-notes.db")
      note_db.get_notes(function(err, notes)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if err or not notes then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
          return
        end
        for _, note in ipairs(notes) do
          if note.id == note_id then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            local buffer = require("apple-notes.buffer")
            buffer.open_note(note, M.config)
            return
          end
        end
        -- Note not found in DB — wipe stale buffer
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end,
  })

  -- Set up neo-tree source (if neo-tree is available)
  local tree = require("apple-notes.tree")
  tree.setup(M.config)
end

--- Check that required external dependencies are available.
---
--- Warns the user once at setup time if any required tool is missing.
--- Does not block setup — the plugin can still partially function
--- (e.g. browsing notes via Telescope without preview conversion).
function M._check_dependencies()
  local missing = {}

  if vim.fn.executable("sqlite3") ~= 1 then
    table.insert(missing, "sqlite3 (ships with macOS — check your PATH)")
  end

  if vim.fn.executable("osascript") ~= 1 then
    table.insert(missing, "osascript (ships with macOS — this plugin requires macOS)")
  end

  if vim.fn.executable("pandoc") ~= 1 then
    table.insert(missing, "pandoc (install: brew install pandoc)")
  end

  if #missing > 0 then
    vim.notify(
      "apple-notes.nvim: missing required dependencies:\n  - "
        .. table.concat(missing, "\n  - ")
        .. "\n\nRun :checkhealth apple-notes for details.",
      vim.log.levels.WARN
    )
  end
end

--- Set up highlight groups with default links.
function M._setup_highlights()
  local highlights = {
    AppleNotesTitle = { link = "Title" },
    AppleNotesFolder = { link = "Directory" },
    AppleNotesTime = { link = "Comment" },
    AppleNotesTrash = { link = "WarningMsg" },
    AppleNotesChecked = { link = "String" },
    AppleNotesUnchecked = { link = "Todo" },
    AppleNotesTag = { link = "Label" },
  }

  for name, opts in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, { default = true, link = opts.link })
  end
end

--- Set up user commands.
function M._setup_commands()
  vim.api.nvim_create_user_command("AppleNotes", function()
    require("apple-notes.telescope").pick_note(M.config)
  end, { desc = "Find Apple Note" })

  vim.api.nvim_create_user_command("AppleNotesNew", function(cmd_opts)
    local args = cmd_opts.fargs
    local folder_name = args[1] or M.config.default_folder

    --- Prompt for title and create note with optional template body.
    --- @param template_body string|nil The template body (nil for blank note)
    --- @param template_folder string|nil The template's folder override
    local function prompt_and_create(template_body, template_folder)
      local effective_folder = folder_name or template_folder or M.config.default_folder
      vim.ui.input({ prompt = "Note title: " }, function(title)
        if not title or title == "" then
          return
        end
        local body = nil
        if template_body and template_body ~= "" then
          body = M._substitute_template_vars(template_body, title)
        end
        require("apple-notes.buffer").create_note(title, effective_folder, M.config, body)
      end)
    end

    if M.config.templates and #M.config.templates > 0 then
      -- Build template choices: "Blank" first, then configured templates
      local choices = { "Blank" }
      for _, tmpl in ipairs(M.config.templates) do
        table.insert(choices, tmpl.name)
      end

      vim.ui.select(choices, { prompt = "Select template:" }, function(choice)
        if not choice then
          return
        end
        if choice == "Blank" then
          prompt_and_create(nil, nil)
          return
        end
        -- Find the selected template
        for _, tmpl in ipairs(M.config.templates) do
          if tmpl.name == choice then
            prompt_and_create(tmpl.body, tmpl.folder)
            return
          end
        end
      end)
    else
      prompt_and_create(nil, nil)
    end
  end, {
    nargs = "?",
    desc = "Create a new Apple Note",
    complete = function()
      -- Complete with folder names
      local folders = {}
      local db_mod = require("apple-notes.db")
      -- Use cached data if available
      db_mod.get_folders(function(_, result)
        if result then
          for _, f in ipairs(result) do
            table.insert(folders, f.name)
          end
        end
      end)
      return folders
    end,
  })

  vim.api.nvim_create_user_command("AppleNotesQuick", function(cmd_opts)
    local text = cmd_opts.args
    if not text or text == "" then
      vim.notify("No text provided", vim.log.levels.WARN)
      return
    end
    M._quick_capture(text)
  end, {
    nargs = "+",
    desc = "Quick capture: append text to a note",
  })

  vim.api.nvim_create_user_command("AppleNotesTags", function()
    require("apple-notes.telescope").pick_tag(M.config)
  end, { desc = "Browse Apple Notes by tag" })

  vim.api.nvim_create_user_command("AppleNotesTree", function()
    local has_neo_tree = pcall(require, "neo-tree")
    if not has_neo_tree then
      vim.notify("neo-tree.nvim is required for :AppleNotesTree", vim.log.levels.ERROR)
      return
    end

    local ok, err = pcall(vim.cmd, "Neotree source=apple-notes toggle")
    if not ok then
      vim.notify(
        'Add "apple-notes" to your neo-tree sources config:\n\n'
          .. '  require("neo-tree").setup({\n'
          .. '    sources = { "filesystem", "apple-notes" },\n'
          .. "  })",
        vim.log.levels.ERROR
      )
    end
  end, { desc = "Toggle Apple Notes tree sidebar" })
end

--- Set up global keymaps with the configured prefix.
function M._setup_keymaps()
  local prefix = M.config.keymap_prefix
  if not prefix then
    return
  end

  local map = function(suffix, cmd, desc)
    vim.keymap.set("n", prefix .. suffix, cmd, { desc = desc })
  end

  map("f", "<cmd>AppleNotes<CR>", "Find Apple Note")
  map("n", "<cmd>AppleNotesNew<CR>", "New Apple Note")
  map("q", function()
    vim.ui.input({ prompt = "Quick capture: " }, function(text)
      if text and text ~= "" then
        M._quick_capture(text)
      end
    end)
  end, "Quick capture to Apple Note")
  map("t", "<cmd>AppleNotesTree<CR>", "Toggle Apple Notes tree")
  map("#", "<cmd>AppleNotesTags<CR>", "Browse Apple Notes tags")
end

--- Substitute template variables in a string.
---
--- Supported variables:
---   {{title}} — the note title
---   {{date}}  — current date (YYYY-MM-DD)
---   {{time}}  — current time (HH:MM)
---
--- @param body string The template body with {{variable}} placeholders
--- @param title string The note title
--- @return string The body with variables replaced
function M._substitute_template_vars(body, title)
  local result = body
  result = result:gsub("{{title}}", title or "")
  result = result:gsub("{{date}}", os.date("%Y-%m-%d"))
  result = result:gsub("{{time}}", os.date("%H:%M"))
  return result
end

--- Quick capture: append text to the configured capture note.
---
--- If no capture note is configured, prompts the user to select one.
---
--- @param text string The text to append
function M._quick_capture(text)
  local db = require("apple-notes.db")
  local applescript = require("apple-notes.applescript")

  if M.config.capture_note then
    -- Find the capture note by title
    db.get_notes(function(err, notes)
      if err then
        vim.notify("Quick capture failed: " .. err, vim.log.levels.ERROR)
        return
      end

      for _, note in ipairs(notes or {}) do
        if note.title == M.config.capture_note then
          applescript.append_to_note(note.id, text, function(append_err)
            if append_err then
              -- If the note is in Recently Deleted, clear capture_note so user is prompted again
              if append_err:match("Recently Deleted") or append_err:match("%-10000") then
                M.config.capture_note = nil
                db.invalidate_cache()
                vim.notify(
                  "Capture note was deleted. Run :AppleNotesQuick again to select a new one.",
                  vim.log.levels.WARN
                )
              else
                vim.notify("Quick capture failed: " .. append_err, vim.log.levels.ERROR)
              end
              return
            end
            vim.notify("Added to " .. note.title, vim.log.levels.INFO)
          end)
          return
        end
      end

      -- Note not found — clear stale capture_note
      local stale_name = M.config.capture_note
      M.config.capture_note = nil
      db.invalidate_cache()
      vim.notify(
        "Capture note '" .. stale_name .. "' not found. Run :AppleNotesQuick again to select a new one.",
        vim.log.levels.WARN
      )
    end)
  else
    -- No capture note configured — prompt user to select one
    db.get_notes(function(err, notes)
      if err then
        vim.notify("Quick capture failed: " .. err, vim.log.levels.ERROR)
        return
      end

      local titles = {}
      for _, note in ipairs(notes or {}) do
        table.insert(titles, note.title)
      end

      vim.schedule(function()
        vim.ui.select(titles, { prompt = "Select capture note:" }, function(choice)
          if not choice then
            return
          end

          -- Save the choice for future captures
          M.config.capture_note = choice

          -- Find and append
          for _, note in ipairs(notes) do
            if note.title == choice then
              applescript.append_to_note(note.id, text, function(append_err)
                if append_err then
                  vim.notify("Quick capture failed: " .. append_err, vim.log.levels.ERROR)
                  return
                end
                vim.notify("Added to " .. note.title, vim.log.levels.INFO)
              end)
              return
            end
          end
        end)
      end)
    end)
  end
end

return M
