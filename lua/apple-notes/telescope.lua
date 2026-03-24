--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Telescope integration for Apple Notes.
---
--- Provides two pickers:
--- 1. Note picker (:AppleNotes) — browse, search, and open notes by title
--- 2. Tag picker (:AppleNotesTags) — browse and navigate notes by hashtag
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

--- Create a shared entry display for note entries.
---
--- @return function The displayer function
local function make_displayer()
  local entry_display = require("telescope.pickers.entry_display")
  return entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { remaining = true },
    },
  })
end

--- Create a shared entry maker for note entries.
---
--- Formats each note as: icon  Title  Folder · relative time
---
--- @param displayer function The entry_display displayer
--- @return function The entry maker function
local function make_note_entry_maker(displayer)
  return function(note)
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
  end
end

--- Create a shared previewer for note entries.
---
--- Loads the note body via AppleScript and converts to Markdown for preview.
---
--- @return table The Telescope previewer
local function make_note_previewer()
  local previewers = require("telescope.previewers")
  return previewers.new_buffer_previewer({
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
        end, note.id)
      end)
    end,
  })
end

--- Create shared attach_mappings for note selection.
---
--- Opens the selected note in a virtual buffer.
---
--- @param config table The plugin config
--- @return function The attach_mappings function
local function make_note_mappings(config)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  return function(prompt_bufnr)
    actions.select_default:replace(function()
      local entry = action_state.get_selected_entry()
      actions.close(prompt_bufnr)
      if entry then
        buffer.open_note(entry.value, config)
      end
    end)
    return true
  end
end

--- Open the note picker via Telescope.
---
--- Shows all non-deleted notes sorted by modification date.
--- Selecting a note opens it in a virtual buffer.
---
--- @param config table The plugin config
function M.pick_note(config)
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope.nvim is required for :AppleNotes", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values

  db.get_notes(function(err, notes)
    if err then
      vim.notify("Cannot read notes database. Run :checkhealth apple-notes\n" .. err, vim.log.levels.ERROR)
      return
    end

    if not notes or #notes == 0 then
      vim.notify("No notes found. Create one with :AppleNotesNew", vim.log.levels.INFO)
      return
    end

    local displayer = make_displayer()

    vim.schedule(function()
      pickers
        .new({}, {
          prompt_title = "Apple Notes",
          finder = finders.new_table({
            results = notes,
            entry_maker = make_note_entry_maker(displayer),
          }),
          sorter = conf.generic_sorter({}),
          previewer = make_note_previewer(),
          attach_mappings = make_note_mappings(config),
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

  local displayer = make_displayer()

  pickers
    .new({}, {
      prompt_title = "Search Apple Notes",
      finder = finders.new_dynamic({
        fn = function(prompt)
          if not prompt or prompt == "" then
            return {}
          end

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
        entry_maker = make_note_entry_maker(displayer),
      }),
      sorter = conf.generic_sorter({}),
      previewer = make_note_previewer(),
      attach_mappings = make_note_mappings(config),
    })
    :find()
end

--- Open the tag picker via Telescope.
---
--- Stage 1: Shows all tags sorted by frequency with note counts.
--- Stage 2: On tag selection, opens a note picker filtered to that tag.
---
--- @param config table The plugin config
function M.pick_tag(config)
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope.nvim is required for :AppleNotesTags", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  db.get_tags(function(err, tags)
    if err then
      vim.notify("Cannot load tags. Run :checkhealth apple-notes\n" .. err, vim.log.levels.ERROR)
      return
    end

    if not tags or #tags == 0 then
      vim.notify("No tags found. Add #hashtags to your notes in Apple Notes.", vim.log.levels.INFO)
      return
    end

    local tag_displayer = entry_display.create({
      separator = " ",
      items = {
        { width = 2 },
        { remaining = true },
      },
    })

    vim.schedule(function()
      pickers
        .new({}, {
          prompt_title = "Apple Notes Tags",
          finder = finders.new_table({
            results = tags,
            entry_maker = function(tag_entry)
              local note_word = tag_entry.count == 1 and "note" or "notes"
              return {
                value = tag_entry,
                display = function(entry)
                  return tag_displayer({
                    { "#", "AppleNotesTag" },
                    {
                      string.format(
                        "%s  (%d %s)",
                        entry.value.tag:sub(2), -- strip leading # (icon already shows it)
                        entry.value.count,
                        note_word
                      ),
                    },
                  })
                end,
                ordinal = tag_entry.tag,
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry then
                -- Stage 2: open note picker filtered to this tag
                M._pick_notes_for_tag(entry.value.tag, config)
              end
            end)
            return true
          end,
        })
        :find()
    end)
  end)
end

--- Open a note picker filtered to notes containing a specific tag.
---
--- Second stage of the tag picker flow.
---
--- @param tag string The tag to filter by (e.g., "#work")
--- @param config table The plugin config
function M._pick_notes_for_tag(tag, config)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values

  db.get_notes_by_tag(tag, function(err, notes)
    if err then
      vim.notify("Failed to load notes for tag: " .. err, vim.log.levels.ERROR)
      return
    end

    if not notes or #notes == 0 then
      vim.notify("No notes found with tag " .. tag, vim.log.levels.INFO)
      return
    end

    local displayer = make_displayer()

    vim.schedule(function()
      pickers
        .new({}, {
          prompt_title = "Apple Notes: " .. tag,
          finder = finders.new_table({
            results = notes,
            entry_maker = make_note_entry_maker(displayer),
          }),
          sorter = conf.generic_sorter({}),
          previewer = make_note_previewer(),
          attach_mappings = make_note_mappings(config),
        })
        :find()
    end)
  end)
end

return M
