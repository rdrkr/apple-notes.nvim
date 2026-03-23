--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Telescope integration for Apple Notes.
---
--- Provides two pickers:
--- 1. Note picker (:AppleNotes) — browse and open notes by title
--- 2. Search picker (:AppleNotesSearch) — full-text search across title + body
---
--- Layout:
---   Left column:  Title (highlighted) + Folder · relative time (dimmed)
---   Right column: Markdown preview of selected note
---
--- @module apple-notes.telescope
local applescript = require("apple-notes.applescript")
local buffer = require("apple-notes.buffer")
local converter = require("apple-notes.converter")
local db = require("apple-notes.db")

local M = {}

--- Check if a preview buffer is still valid.
---
--- The buffer reference in self.state.bufnr can become nil when the user
--- closes the picker or scrolls to a different entry before the async
--- callback fires.
---
--- @param bufnr any The buffer number (may be nil if picker was closed)
--- @return boolean True if the buffer is a valid number and still exists
local function preview_buf_valid(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- Format a unix timestamp as a human-readable relative time.
---
--- @param timestamp number Unix timestamp
--- @return string Relative time string (e.g., "2 min ago", "yesterday")
local function relative_time(timestamp)
  if not timestamp or timestamp == 0 then
    return ""
  end
  local now = os.time()
  local diff = now - timestamp

  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    local mins = math.floor(diff / 60)
    return mins == 1 and "1 min ago" or mins .. " min ago"
  elseif diff < 86400 then
    local hours = math.floor(diff / 3600)
    return hours == 1 and "1 hour ago" or hours .. " hours ago"
  elseif diff < 172800 then
    return "yesterday"
  elseif diff < 604800 then
    local days = math.floor(diff / 86400)
    return days .. " days ago"
  else
    return os.date("%b %d", timestamp)
  end
end

--- Open the note picker via Telescope.
---
--- Shows all non-deleted notes sorted by modification date.
--- Selecting a note opens it in a virtual buffer.
---
--- @param config table The plugin config
function M.pick_note(config)
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope.nvim is required for :AppleNotes", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")

  db.get_notes(function(err, notes)
    if err then
      vim.notify("Cannot read notes database. Run :checkhealth apple-notes\n" .. err, vim.log.levels.ERROR)
      return
    end

    if not notes or #notes == 0 then
      vim.notify("No notes found. Create one with :AppleNotesNew", vim.log.levels.INFO)
      return
    end

    local displayer = entry_display.create({
      separator = " ",
      items = {
        { width = 2 },
        { remaining = true },
      },
    })

    vim.schedule(function()
      pickers
        .new({}, {
          prompt_title = "Apple Notes",
          finder = finders.new_table({
            results = notes,
            entry_maker = function(note)
              local time_str = relative_time(note.mod_date)
              return {
                value = note,
                display = function(entry)
                  return displayer({
                    { "", "AppleNotesTitle" },
                    {
                      string.format("%s  %s · %s", entry.value.title, entry.value.folder_name, time_str),
                    },
                  })
                end,
                ordinal = note.title .. " " .. note.folder_name .. " " .. (note.snippet or ""),
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          previewer = previewers.new_buffer_previewer({
            title = "Note Preview",
            define_preview = function(self, entry)
              local note = entry.value
              vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Loading preview..." })
              vim.bo[self.state.bufnr].filetype = "markdown"

              applescript.get_note_body(note.id, function(body_err, html)
                if body_err then
                  if preview_buf_valid(self.state.bufnr) then
                    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Failed to load preview" })
                  end
                  return
                end

                converter.html_to_md(html or "", function(conv_err, markdown)
                  if not preview_buf_valid(self.state.bufnr) then
                    return
                  end
                  if conv_err then
                    if conv_err:match("not installed") or conv_err:match("not executable") then
                      vim.api.nvim_buf_set_lines(
                        self.state.bufnr,
                        0,
                        -1,
                        false,
                        { "pandoc is required for preview.", "", "Install: brew install pandoc" }
                      )
                    else
                      local lines = vim.split(html or "", "\n")
                      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                    end
                    return
                  end
                  local lines = vim.split(markdown or "", "\n")
                  vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                end)
              end)
            end,
          }),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry then
                buffer.open_note(entry.value, config)
              end
            end)
            return true
          end,
        })
        :find()
    end)
  end)
end

--- Open the full-text search picker via Telescope.
---
--- Searches across note titles and body snippets.
---
--- @param config table The plugin config
function M.search_notes(config)
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope.nvim is required for :AppleNotesSearch", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { remaining = true },
    },
  })

  pickers
    .new({}, {
      prompt_title = "Search Apple Notes",
      finder = finders.new_dynamic({
        fn = function(prompt)
          if not prompt or prompt == "" then
            return {}
          end

          -- Synchronous wrapper for the async search
          -- Telescope's dynamic finder handles the async nature
          local results = {}
          local done = false

          db.search_notes(prompt, function(err, notes)
            if not err and notes then
              results = notes
            end
            done = true
          end)

          -- Wait briefly for results (db query is fast)
          vim.wait(1000, function()
            return done
          end, 10)

          return results
        end,
        entry_maker = function(note)
          local time_str = relative_time(note.mod_date)
          return {
            value = note,
            display = function(entry)
              return displayer({
                { "", "AppleNotesTitle" },
                {
                  string.format("%s  %s · %s", entry.value.title, entry.value.folder_name, time_str),
                },
              })
            end,
            ordinal = note.title .. " " .. (note.snippet or ""),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Note Preview",
        define_preview = function(self, entry)
          local note = entry.value
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Loading preview..." })
          vim.bo[self.state.bufnr].filetype = "markdown"

          applescript.get_note_body(note.id, function(body_err, html)
            if body_err then
              if preview_buf_valid(self.state.bufnr) then
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Failed to load preview" })
              end
              return
            end

            converter.html_to_md(html or "", function(conv_err, markdown)
              if not preview_buf_valid(self.state.bufnr) then
                return
              end
              if conv_err then
                if conv_err:match("not installed") or conv_err:match("not executable") then
                  vim.api.nvim_buf_set_lines(
                    self.state.bufnr,
                    0,
                    -1,
                    false,
                    { "pandoc is required for preview.", "", "Install: brew install pandoc" }
                  )
                else
                  local lines = vim.split(html or "", "\n")
                  vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                end
                return
              end
              local lines = vim.split(markdown or "", "\n")
              vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
            end)
          end)
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            buffer.open_note(entry.value, config)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
