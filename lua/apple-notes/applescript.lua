--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- AppleScript wrappers for Apple Notes mutations.
---
--- All write operations to Apple Notes MUST go through AppleScript via osascript.
--- Direct SQLite writes corrupt the Core Data store.
---
--- Every function is async (uses job.lua) to avoid blocking neovim's UI.
--- Notes.app cold start can take up to 30 seconds.
---
--- @module apple-notes.applescript
local db = require("apple-notes.db")
local job = require("apple-notes.job")
local sanitize = require("apple-notes.sanitize")

local M = {}

--- Default timeout for AppleScript operations (ms).
--- Cold start of Notes.app can take up to 30 seconds.
local TIMEOUT = 30000

--- Run an AppleScript string via osascript.
---
--- @param script string The AppleScript to execute
--- @param callback fun(err: string|nil, result: string|nil)
local function run(script, callback)
  job.run({ "osascript", "-e", script }, { timeout = TIMEOUT }, callback)
end

--- Get the HTML body of a note by its Core Data URI.
---
--- @param note_id number The Z_PK of the note
--- @param callback fun(err: string|nil, html: string|nil) Called with the HTML body
function M.get_note_body(note_id, callback)
  db.get_core_data_uri(note_id, function(err, uri)
    if err then
      callback(err, nil)
      return
    end

    local script = string.format(
      [[tell application "Notes"
  set theNote to note id "%s"
  return body of theNote
end tell]],
      sanitize.applescript(uri)
    )

    run(script, callback)
  end)
end

--- Set the HTML body of a note by its Core Data URI.
---
--- @param note_id number The Z_PK of the note
--- @param html string The new HTML body
--- @param callback fun(err: string|nil, result: string|nil)
function M.set_note_body(note_id, html, callback)
  db.get_core_data_uri(note_id, function(err, uri)
    if err then
      callback(err, nil)
      return
    end

    local safe_html = sanitize.applescript(html)
    local script = string.format(
      [[tell application "Notes"
  set theNote to note id "%s"
  set body of theNote to "%s"
end tell]],
      sanitize.applescript(uri),
      safe_html
    )

    run(script, function(set_err, result)
      if set_err then
        callback(set_err, nil)
        return
      end
      db.invalidate_cache()
      callback(nil, result)
    end)
  end)
end

--- Create a new note in a specified folder.
---
--- @param title string The note title
--- @param body string The HTML body content
--- @param folder_name string|nil The folder name (nil for default folder)
--- @param callback fun(err: string|nil, result: string|nil)
function M.create_note(title, body, folder_name, callback)
  local safe_body = sanitize.applescript(body)
  local safe_title = sanitize.applescript(title)
  local script

  if folder_name then
    local safe_folder = sanitize.applescript(folder_name)
    script = string.format(
      [[tell application "Notes"
  set theFolder to folder "%s"
  set theNote to make new note at theFolder with properties {name:"%s", body:"%s"}
  return id of theNote
end tell]],
      safe_folder,
      safe_title,
      safe_body
    )
  else
    script = string.format(
      [[tell application "Notes"
  set theNote to make new note with properties {name:"%s", body:"%s"}
  return id of theNote
end tell]],
      safe_title,
      safe_body
    )
  end

  run(script, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    db.invalidate_cache()
    callback(nil, result)
  end)
end

--- Delete a note (move to trash) by its Core Data URI.
---
--- @param note_id number The Z_PK of the note
--- @param callback fun(err: string|nil, result: string|nil)
function M.delete_note(note_id, callback)
  db.get_core_data_uri(note_id, function(err, uri)
    if err then
      callback(err, nil)
      return
    end

    local script = string.format(
      [[tell application "Notes"
  set theNote to note id "%s"
  delete theNote
end tell]],
      sanitize.applescript(uri)
    )

    run(script, function(del_err, result)
      if del_err then
        callback(del_err, nil)
        return
      end
      db.invalidate_cache()
      callback(nil, result)
    end)
  end)
end

--- Restore a note from trash.
---
--- @param note_id number The Z_PK of the note
--- @param callback fun(err: string|nil, result: string|nil)
function M.restore_note(note_id, callback)
  db.get_core_data_uri(note_id, function(err, uri)
    if err then
      callback(err, nil)
      return
    end

    -- Move note from trash back to default folder
    local script = string.format(
      [[tell application "Notes"
  set theNote to note id "%s"
  move theNote to default account
end tell]],
      sanitize.applescript(uri)
    )

    run(script, function(restore_err, result)
      if restore_err then
        callback(restore_err, nil)
        return
      end
      db.invalidate_cache()
      callback(nil, result)
    end)
  end)
end

--- Move a note to a different folder.
---
--- @param note_id number The Z_PK of the note
--- @param folder_name string The destination folder name
--- @param callback fun(err: string|nil, result: string|nil)
function M.move_note(note_id, folder_name, callback)
  db.get_core_data_uri(note_id, function(err, uri)
    if err then
      callback(err, nil)
      return
    end

    local script = string.format(
      [[tell application "Notes"
  set theNote to note id "%s"
  set theFolder to folder "%s"
  move theNote to theFolder
end tell]],
      sanitize.applescript(uri),
      sanitize.applescript(folder_name)
    )

    run(script, function(move_err, result)
      if move_err then
        callback(move_err, nil)
        return
      end
      db.invalidate_cache()
      callback(nil, result)
    end)
  end)
end

--- Create a new folder.
---
--- @param name string The folder name
--- @param callback fun(err: string|nil, result: string|nil)
function M.create_folder(name, callback)
  local script = string.format(
    [[tell application "Notes"
  make new folder with properties {name:"%s"}
end tell]],
    sanitize.applescript(name)
  )

  run(script, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    db.invalidate_cache()
    callback(nil, result)
  end)
end

--- Rename a folder.
---
--- @param old_name string The current folder name
--- @param new_name string The new folder name
--- @param callback fun(err: string|nil, result: string|nil)
function M.rename_folder(old_name, new_name, callback)
  local script = string.format(
    [[tell application "Notes"
  set name of folder "%s" to "%s"
end tell]],
    sanitize.applescript(old_name),
    sanitize.applescript(new_name)
  )

  run(script, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    db.invalidate_cache()
    callback(nil, result)
  end)
end

--- Delete a folder.
---
--- @param name string The folder name
--- @param callback fun(err: string|nil, result: string|nil)
function M.delete_folder(name, callback)
  local script = string.format(
    [[tell application "Notes"
  delete folder "%s"
end tell]],
    sanitize.applescript(name)
  )

  run(script, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    db.invalidate_cache()
    callback(nil, result)
  end)
end

--- Append text to a note's body.
---
--- Used by the quick capture command.
---
--- @param note_id number The Z_PK of the note
--- @param text string The text to append (will be wrapped in HTML paragraph)
--- @param callback fun(err: string|nil, result: string|nil)
function M.append_to_note(note_id, text, callback)
  db.get_core_data_uri(note_id, function(err, uri)
    if err then
      callback(err, nil)
      return
    end

    local safe_text = sanitize.applescript(text)
    local script = string.format(
      [[tell application "Notes"
  set theNote to note id "%s"
  set currentBody to body of theNote
  set body of theNote to currentBody & "<br><p>%s</p>"
end tell]],
      sanitize.applescript(uri),
      safe_text
    )

    run(script, function(append_err, result)
      if append_err then
        callback(append_err, nil)
        return
      end
      db.invalidate_cache()
      callback(nil, result)
    end)
  end)
end

return M
