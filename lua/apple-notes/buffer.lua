--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Virtual buffer management for Apple Notes.
---
--- Each note is presented as an in-memory buffer with buftype=acwrite.
--- No files are written to disk. The buffer name follows the scheme:
---   apple-notes://{folder}/{title}
---
--- Lifecycle:
---   create buffer → load HTML → convert to MD → set lines → user edits →
---   :w triggers BufWriteCmd → convert to HTML → AppleScript set body
---
--- @module apple-notes.buffer
local applescript = require("apple-notes.applescript")
local converter = require("apple-notes.converter")
local sync = require("apple-notes.sync")

local M = {}

--- Map of note identifier to buffer number for deduplication.
--- @type table<string, number>
local open_buffers = {}

--- Note metadata stored per buffer number (more reliable than vim.b for save operations).
--- @type table<number, { id: number, identifier: string, folder_name: string, title: string }>
local buffer_meta = {}

--- Build the buffer name for a note.
---
--- Encodes the note's Z_PK in the buffer name so it survives module reloads
--- and buffer variable loss. Format: apple-notes://folder/title [id]
---
--- @param folder_name string The folder name
--- @param title string The note title
--- @param note_id number|nil The note's Z_PK (included when creating buffers)
--- @return string The buffer name
function M.buffer_name(folder_name, title, note_id)
  local name = string.format("apple-notes://%s/%s", folder_name or "Notes", title or "Untitled")
  if note_id then
    name = name .. string.format(" [%d]", note_id)
  end
  return name
end

--- Extract the note ID from a buffer name.
---
--- @param bufnr number The buffer number
--- @return number|nil The note's Z_PK, or nil if not found
local function extract_note_id_from_name(bufnr)
  local ok, name = pcall(vim.api.nvim_buf_get_name, bufnr)
  if not ok or not name then
    return nil
  end
  local id_str = name:match("%[(%d+)%]$")
  if id_str then
    return tonumber(id_str)
  end
  return nil
end

--- Check if a buffer is already open for a note.
---
--- @param identifier string The note's ZIDENTIFIER
--- @return number|nil The buffer number, or nil if not open
function M.get_open_buffer(identifier)
  local bufnr = open_buffers[identifier]
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  open_buffers[identifier] = nil
  return nil
end

--- Configure a buffer as an Apple Notes virtual buffer.
---
--- Sets the essential buffer options that prevent Neovim from treating
--- this as a real file. Order matters: buftype must be set before filetype
--- to prevent LSP clients from attaching when the FileType autocmd fires.
---
--- @param bufnr number The buffer number
local function configure_buffer_options(bufnr)
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "markdown"
end

--- Populate buffer content and finalize setup after async load.
---
--- @param bufnr number The buffer number
--- @param markdown string The markdown content
local function set_buffer_content(bufnr, markdown)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = vim.split(markdown or "", "\n")
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.api.nvim_buf_set_var(bufnr, "apple_note_loaded_at", os.time())

  -- Re-set buffer options after content load — Neovim's filetype detection
  -- may have overridden our initial setting since the buffer name has no
  -- .md extension, and ftplugin autocmds may reset buftype.
  configure_buffer_options(bufnr)

  -- Re-fire BufWinEnter so markdown rendering plugins (e.g. render-markdown.nvim)
  -- detect the buffer after async content load. The original BufWinEnter fires
  -- before filetype="markdown" is set and buffer lines are populated.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = bufnr })
  end)
end

--- Open a note in a virtual buffer.
---
--- If the note is already open, focuses the existing buffer instead of
--- creating a duplicate.
---
--- @param note table The note data from db.get_notes()
--- @param config table The plugin config
function M.open_note(note, config)
  -- Validate required fields
  if not note or not note.id or not note.identifier then
    vim.notify("Cannot open note: missing required data", vim.log.levels.ERROR)
    return
  end

  -- Check for existing buffer
  local existing = M.get_open_buffer(note.identifier)
  if existing then
    vim.api.nvim_set_current_buf(existing)
    return
  end

  local bufname = M.buffer_name(note.folder_name, note.title, note.id)

  -- Wipe any stale buffer with the same name (e.g. from a previous session)
  local stale = vim.fn.bufnr(bufname)
  if stale ~= -1 then
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end

  -- Create buffer and set options before making it current — this prevents
  -- LSP attachment and swap file creation from the BufEnter/BufWinEnter events.
  local bufnr = vim.api.nvim_create_buf(true, false)
  configure_buffer_options(bufnr)
  vim.api.nvim_buf_set_name(bufnr, bufname)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_set_current_buf(bufnr)

  -- Store note metadata via the API function (not vim.b[] shorthand)
  -- to ensure variables are set on the correct buffer regardless of context.
  vim.api.nvim_buf_set_var(bufnr, "apple_note_id", note.id)
  vim.api.nvim_buf_set_var(bufnr, "apple_note_identifier", note.identifier)
  vim.api.nvim_buf_set_var(bufnr, "apple_note_folder", note.folder_name)
  vim.api.nvim_buf_set_var(bufnr, "apple_note_title", note.title)
  vim.api.nvim_buf_set_var(bufnr, "apple_note_loaded_at", os.time())

  buffer_meta[bufnr] = {
    id = note.id,
    identifier = note.identifier,
    folder_name = note.folder_name,
    title = note.title,
  }

  -- Track open buffer
  open_buffers[note.identifier] = bufnr

  -- Set up BufWriteCmd BEFORE async load so :w never triggers file-write fallback
  M._setup_write_handler(bufnr, config)

  -- Set up buffer-local keymaps
  M._setup_keymaps(bufnr)

  -- Set up winbar
  M._setup_winbar(bufnr, note)

  -- Clean up tracking state on buffer delete
  local note_identifier = note.identifier
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = bufnr,
    callback = function()
      open_buffers[note_identifier] = nil
      buffer_meta[bufnr] = nil
      sync.unregister_buffer(bufnr)
    end,
  })

  -- Show loading indicator
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading note..." })
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false

  -- Fetch note body via AppleScript
  local note_id = note.id
  applescript.get_note_body(note_id, function(err, html)
    if err then
      vim.notify("Failed to load note: " .. err, vim.log.levels.ERROR)
      M._close_buffer(bufnr, note_identifier)
      return
    end

    -- Convert HTML to Markdown (pass note_id for image resolution)
    converter.html_to_md(html or "", function(conv_err, markdown)
      if conv_err then
        if conv_err:match("not installed") or conv_err:match("not executable") then
          vim.notify("pandoc is required. Install: brew install pandoc", vim.log.levels.ERROR)
        else
          vim.notify("Conversion warning: " .. conv_err, vim.log.levels.WARN)
        end
        -- Fallback: show raw HTML
        markdown = html or ""
      end

      set_buffer_content(bufnr, markdown)

      -- Register with sync module for external change detection
      if vim.api.nvim_buf_is_valid(bufnr) then
        sync.register_buffer(bufnr)
      end
    end, note_id)
  end)
end

--- Set up the BufWriteCmd handler for saving notes.
---
--- @param bufnr number The buffer number
--- @param config table The plugin config
function M._setup_write_handler(bufnr, config)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function(args)
      M._save_note(args.buf, config)
    end,
  })
end

--- Resolve the note ID for a buffer, checking both vim.b and module-level store.
---
--- @param bufnr number The buffer number
--- @return number|nil The note's Z_PK, or nil if not found
local function resolve_note_id(bufnr)
  -- Try module-level store first (fastest, but lost on module reload)
  local meta = buffer_meta[bufnr]
  if meta and meta.id then
    return meta.id
  end
  -- Fall back to buffer-local variable (survives module reloads)
  local ok, id = pcall(vim.api.nvim_buf_get_var, bufnr, "apple_note_id")
  if ok and id and id ~= vim.NIL then
    return id
  end
  -- Last resort: extract from buffer name (always available)
  return extract_note_id_from_name(bufnr)
end

--- Save the buffer content back to Apple Notes.
---
--- @param bufnr number The buffer number
--- @param config table The plugin config (unused currently, reserved for future options)
function M._save_note(bufnr, config)
  local note_id = resolve_note_id(bufnr)
  if not note_id then
    vim.notify(
      "Cannot save: buffer has no associated Apple Note. Re-open the note via :AppleNotes.",
      vim.log.levels.ERROR
    )
    return
  end

  -- Get buffer content
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local markdown = table.concat(lines, "\n")

  -- Queue the save via sync module
  sync.queue_save(bufnr, note_id, markdown)
end

--- Set up buffer-local keymaps for note interaction.
---
--- @param bufnr number The buffer number
function M._setup_keymaps(bufnr)
  -- Checklist toggle: <C-Space>
  vim.keymap.set("n", "<C-Space>", function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      M._toggle_checkbox(bufnr)
    end
  end, { buffer = bufnr, desc = "Toggle Apple Notes checkbox" })
end

--- Toggle a markdown checkbox on the current line.
---
--- Changes `- [ ]` to `- [x]` and vice versa, then triggers an async save
--- to sync the change to Apple Notes.
---
--- @param bufnr number The buffer number
function M._toggle_checkbox(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]

  if not line then
    return
  end

  local new_line
  if line:match("%- %[ %]") then
    new_line = line:gsub("%- %[ %]", "- [x]", 1)
  elseif line:match("%- %[x%]") then
    new_line = line:gsub("%- %[x%]", "- [ ]", 1)
  else
    return -- Not a checkbox line
  end

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { new_line })
  vim.bo[bufnr].modified = true
end

--- Set up the winbar for a note buffer.
---
--- @param bufnr number The buffer number
--- @param note table The note data
function M._setup_winbar(bufnr, note)
  local display_name = M.buffer_name(note.folder_name, note.title)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    callback = function()
      local winid = vim.fn.bufwinid(bufnr)
      if winid ~= -1 then
        vim.wo[winid].winbar = string.format(" %s  [Apple Notes]", display_name)
      end
    end,
  })
  -- Set immediately if already in a window
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    vim.wo[winid].winbar = string.format(" %s  [Apple Notes]", display_name)
  end
end

--- Close a buffer and clean up tracking state.
---
--- @param bufnr number The buffer number
--- @param identifier string The note's ZIDENTIFIER
function M._close_buffer(bufnr, identifier)
  open_buffers[identifier] = nil
  buffer_meta[bufnr] = nil
  sync.unregister_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

--- Create a new note and open it in a buffer.
---
--- @param title string|nil The note title (defaults to "Untitled Note")
--- @param folder_name string|nil The folder name (nil for default folder)
--- @param config table The plugin config
--- @param body string|nil Optional markdown body (from template). Converted to HTML before creating.
function M.create_note(title, folder_name, config, body)
  title = title or "Untitled Note"

  --- Create the note via AppleScript and open it.
  --- @param html string The HTML body content
  local function do_create(html)
    applescript.create_note(title, html, folder_name, function(err)
      if err then
        vim.notify("Failed to create note: " .. err, vim.log.levels.ERROR)
        return
      end

      vim.notify("Note created: " .. title, vim.log.levels.INFO)

      -- Refresh and open the new note
      local db = require("apple-notes.db")
      db.invalidate_cache()
      db.get_notes(function(db_err, notes)
        if db_err or not notes then
          return
        end
        -- Find the newly created note (should be first — most recent)
        for _, note in ipairs(notes) do
          if note.title == title then
            M.open_note(note, config)
            return
          end
        end
      end)
    end)
  end

  if body and body ~= "" then
    -- Convert markdown body to HTML for Apple Notes
    converter.md_to_html(body, function(conv_err, html)
      if conv_err then
        vim.notify("Template conversion failed: " .. conv_err, vim.log.levels.WARN)
        do_create("")
        return
      end
      do_create(html or "")
    end)
  else
    do_create("")
  end
end

return M
