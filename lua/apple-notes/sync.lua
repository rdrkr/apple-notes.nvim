--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Save queue and external change detection for Apple Notes buffers.
---
--- Handles two critical concerns:
--- 1. Save queue: serializes concurrent :w operations to prevent race conditions
--- 2. External change detection: polls modification dates to detect edits from
---    other devices (iPhone, iPad, web)
---
--- Save queue state machine:
---   IDLE ──(:w)──▶ SAVING ──(done)──▶ IDLE
---                    │                   ▲
---                  (:w again)            │
---                    ▼                   │
---                  QUEUED ──(prev done)──┘
---
--- @module apple-notes.sync
local applescript = require("apple-notes.applescript")
local converter = require("apple-notes.converter")
local db = require("apple-notes.db")

local M = {}

--- Registered buffers for external change detection.
--- @type table<number, { identifier: string, loaded_at: number }>
local registered_buffers = {}

--- Save queue state per buffer.
--- @type table<number, { saving: boolean, pending_markdown: string|nil, last_saved_at: number|nil }>
local save_state = {}

--- Timer for periodic external change detection.
--- @type userdata|nil
local poll_timer = nil

--- Poll interval for external change detection (ms).
local POLL_INTERVAL_MS = 30000

--- Tolerance in seconds for modification date comparison.
--- Apple Notes updates the modification timestamp slightly after a save
--- (internal DB housekeeping), causing false "external change" detections.
--- This tolerance accounts for sub-second precision differences and
--- post-save timestamp bumps.
local MOD_DATE_TOLERANCE_SECS = 5

--- Register a buffer for external change detection.
---
--- @param bufnr number The buffer number
function M.register_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok, identifier = pcall(vim.api.nvim_buf_get_var, bufnr, "apple_note_identifier")
  if not ok or not identifier then
    return
  end

  local _, loaded_at = pcall(vim.api.nvim_buf_get_var, bufnr, "apple_note_loaded_at")

  registered_buffers[bufnr] = {
    identifier = identifier,
    loaded_at = loaded_at or os.time(),
  }

  -- Set up BufEnter check (fires when switching buffers within Neovim)
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    callback = function()
      M._check_external_changes(bufnr)
    end,
  })

  -- Set up FocusGained check (fires when returning to Neovim from another app)
  vim.api.nvim_create_autocmd("FocusGained", {
    buffer = bufnr,
    callback = function()
      M._check_external_changes(bufnr)
    end,
  })

  -- Start poll timer if not running
  M._ensure_poll_timer()
end

--- Unregister a buffer from external change detection.
---
--- @param bufnr number The buffer number
function M.unregister_buffer(bufnr)
  registered_buffers[bufnr] = nil
  save_state[bufnr] = nil

  -- Stop timer if no buffers registered
  if vim.tbl_isempty(registered_buffers) and poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
end

--- Queue a save operation for a buffer.
---
--- If a save is already in flight, the new content is queued and will be
--- saved after the current save completes. Maximum queue depth: 1
--- (latest content always wins).
---
--- @param bufnr number The buffer number
--- @param note_id number The note's Z_PK
--- @param markdown string The markdown content to save
function M.queue_save(bufnr, note_id, markdown)
  if not save_state[bufnr] then
    save_state[bufnr] = { saving = false, pending_markdown = nil }
  end

  local state = save_state[bufnr]

  if state.saving then
    -- Already saving — queue the latest content (overwrites any previous pending)
    state.pending_markdown = markdown
    return
  end

  -- Start saving
  M._execute_save(bufnr, note_id, markdown)
end

--- Execute the actual save operation.
---
--- @param bufnr number The buffer number
--- @param note_id number The note's Z_PK
--- @param markdown string The markdown content to save
function M._execute_save(bufnr, note_id, markdown)
  local state = save_state[bufnr]
  if not state then
    return
  end

  state.saving = true

  -- Convert markdown to HTML
  converter.md_to_html(markdown, function(conv_err, html)
    -- Re-check state — buffer may have been unregistered during async conversion
    if not save_state[bufnr] then
      return
    end

    if conv_err then
      vim.notify("Save failed: " .. conv_err, vim.log.levels.ERROR)
      save_state[bufnr].saving = false
      return
    end

    -- Write HTML to Apple Notes via AppleScript
    applescript.set_note_body(note_id, html or "", function(as_err)
      -- Re-check state again — buffer may have been unregistered during save
      if not save_state[bufnr] then
        return
      end

      if as_err then
        vim.notify("Save failed: " .. as_err, vim.log.levels.ERROR)
        save_state[bufnr].saving = false
        return
      end

      -- Update loaded_at timestamp
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_var(bufnr, "apple_note_loaded_at", os.time())
        vim.bo[bufnr].modified = false
        if registered_buffers[bufnr] then
          registered_buffers[bufnr].loaded_at = os.time()
        end
      end

      vim.notify("Note saved", vim.log.levels.INFO)
      save_state[bufnr].saving = false
      save_state[bufnr].last_saved_at = os.time()

      -- Process pending save if queued
      if save_state[bufnr].pending_markdown then
        local pending = save_state[bufnr].pending_markdown
        save_state[bufnr].pending_markdown = nil
        M._execute_save(bufnr, note_id, pending)
      end
    end)
  end)
end

--- Check if a specific buffer's note was modified externally.
---
--- Compares the note's modification date in the database against
--- the last loaded timestamp stored in the buffer.
---
--- @param bufnr number The buffer number
function M._check_external_changes(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    registered_buffers[bufnr] = nil
    return
  end

  local reg = registered_buffers[bufnr]
  if not reg then
    return
  end

  -- Don't check while saving (we'd detect our own writes)
  local state = save_state[bufnr]
  if state and state.saving then
    return
  end

  -- Don't check shortly after saving — Apple Notes updates the modification
  -- timestamp internally after a save, which causes false positives.
  if state and state.last_saved_at and (os.time() - state.last_saved_at) < MOD_DATE_TOLERANCE_SECS then
    return
  end

  db.get_modification_date(reg.identifier, function(err, mod_date)
    if err then
      return -- Silently skip — note may have been deleted
    end

    if mod_date and (mod_date - reg.loaded_at) > MOD_DATE_TOLERANCE_SECS then
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          registered_buffers[bufnr] = nil
          return
        end

        local choice = vim.fn.confirm("Note changed externally. Reload?", "&Reload\n&Keep mine\n&Show diff", 1)

        if choice == 1 then
          M._reload_buffer(bufnr)
        elseif choice == 3 then
          M._show_diff(bufnr)
        end
        -- choice == 2: keep current content, do nothing
      end)
    end
  end)
end

--- Reload a buffer with fresh content from Apple Notes.
---
--- @param bufnr number The buffer number
function M._reload_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok, note_id = pcall(vim.api.nvim_buf_get_var, bufnr, "apple_note_id")
  if not ok or not note_id then
    return
  end

  applescript.get_note_body(note_id, function(err, html)
    if err then
      vim.notify("Failed to reload note: " .. err, vim.log.levels.ERROR)
      return
    end

    converter.html_to_md(html or "", function(conv_err, markdown)
      if conv_err then
        vim.notify("Conversion warning: " .. conv_err, vim.log.levels.WARN)
        markdown = html or ""
      end

      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      local lines = vim.split(markdown or "", "\n")
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modified = false
      vim.api.nvim_buf_set_var(bufnr, "apple_note_loaded_at", os.time())

      if registered_buffers[bufnr] then
        registered_buffers[bufnr].loaded_at = os.time()
      end

      vim.notify("Note reloaded", vim.log.levels.INFO)
    end, note_id)
  end)
end

--- Show a diff between the current buffer content and the latest Apple Notes version.
---
--- Opens a vertical split with the latest version for comparison.
---
--- @param bufnr number The buffer number
function M._show_diff(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok, note_id = pcall(vim.api.nvim_buf_get_var, bufnr, "apple_note_id")
  if not ok or not note_id then
    return
  end

  applescript.get_note_body(note_id, function(err, html)
    if err then
      vim.notify("Failed to fetch latest version: " .. err, vim.log.levels.ERROR)
      return
    end

    converter.html_to_md(html or "", function(conv_err, markdown)
      if conv_err then
        markdown = html or ""
      end

      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      -- Create a scratch buffer with the remote version
      local diff_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(diff_buf, "apple-notes://diff (latest)")
      local lines = vim.split(markdown or "", "\n")
      vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, lines)
      vim.bo[diff_buf].buftype = "nofile"
      vim.bo[diff_buf].filetype = "markdown"
      vim.bo[diff_buf].modifiable = false

      -- Open in vertical split and enable diff mode
      vim.cmd("vsplit")
      vim.api.nvim_set_current_buf(diff_buf)
      vim.cmd("diffthis")

      -- Also enable diff on the original buffer
      local orig_win = vim.fn.bufwinid(bufnr)
      if orig_win ~= -1 then
        vim.api.nvim_set_current_win(orig_win)
        vim.cmd("diffthis")
      end
    end, note_id)
  end)
end

--- Ensure the poll timer is running.
function M._ensure_poll_timer()
  if poll_timer then
    return
  end

  poll_timer = vim.loop.new_timer()
  if poll_timer then
    poll_timer:start(
      POLL_INTERVAL_MS,
      POLL_INTERVAL_MS,
      vim.schedule_wrap(function()
        M._check_all_buffers()
      end)
    )
  end
end

--- Check all registered buffers for external changes.
function M._check_all_buffers()
  for bufnr, _ in pairs(registered_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M._check_external_changes(bufnr)
    else
      registered_buffers[bufnr] = nil
    end
  end
end

--- Stop all sync operations (cleanup).
function M.teardown()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
  registered_buffers = {}
  save_state = {}
end

return M
