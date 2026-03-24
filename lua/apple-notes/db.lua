--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- SQLite database access for Apple Notes.
---
--- Reads from NoteStore.sqlite via the sqlite3 CLI (ships with macOS).
--- Uses a schema adapter pattern for macOS version resilience.
--- All queries are read-only — mutations go through applescript.lua.
---
--- Data flow:
---   sqlite3 -json -readonly DB SQL → JSON stdout → vim.json.decode → Lua table
---
--- Cache strategy:
---   fs_event watcher on NoteStore.sqlite invalidates on any DB change.
---   TTL fallback (5s) if watcher fails to attach.
---
--- @module apple-notes.db
local job = require("apple-notes.job")
local sanitize = require("apple-notes.sanitize")

local M = {}

--- Path to the Apple Notes SQLite database.
local DB_PATH = vim.fn.expand("~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

--- Apple Core Data epoch offset (seconds between Unix 1970 and Apple 2001-01-01).
local APPLE_EPOCH_OFFSET = 978307200

--- Schema column mappings per macOS major version.
--- Core Data auto-generates column names; they may change between OS versions.
local SCHEMAS = {
  ["14"] = { -- Sonoma
    title = "ZTITLE1",
    snippet = "ZSNIPPET",
    folder = "ZFOLDER",
    account = "ZACCOUNT4",
    mod_date = "ZMODIFICATIONDATE1",
    creation_date = "ZCREATIONDATE1",
    identifier = "ZIDENTIFIER",
    marked_for_deletion = "ZMARKEDFORDELETION",
  },
  ["15"] = { -- Sequoia
    title = "ZTITLE1",
    snippet = "ZSNIPPET",
    folder = "ZFOLDER",
    account = "ZACCOUNT4",
    mod_date = "ZMODIFICATIONDATE1",
    creation_date = "ZCREATIONDATE1",
    identifier = "ZIDENTIFIER",
    marked_for_deletion = "ZMARKEDFORDELETION",
  },
  ["26"] = { -- Tahoe
    title = "ZTITLE1",
    snippet = "ZSNIPPET",
    folder = "ZFOLDER",
    account = "ZACCOUNT4",
    mod_date = "ZMODIFICATIONDATE1",
    creation_date = "ZCREATIONDATE1",
    identifier = "ZIDENTIFIER",
    marked_for_deletion = "ZMARKEDFORDELETION",
  },
}

--- Cached note list and metadata.
local cache = {
  notes = nil,
  folders = nil,
  tags = nil,
  timestamp = 0,
  watcher = nil,
  timer = nil,
}

--- Registered callbacks to invoke when the cache is invalidated.
--- @type fun()[]
local invalidate_listeners = {}

--- TTL for cache fallback in milliseconds (when fs_event watcher fails).
local CACHE_TTL_MS = 5000

--- Darwin kernel version to macOS version mapping.
--- Apple jumped from macOS 15 (Sequoia) to macOS 26 (Tahoe),
--- so a simple offset formula no longer works.
local DARWIN_TO_MACOS = {
  [23] = 14, -- Sonoma
  [24] = 15, -- Sequoia
  [25] = 26, -- Tahoe
}

--- Get the current macOS major version.
---
--- @return string The major version number (e.g., "26")
local function get_macos_major_version()
  local release = vim.loop.os_uname().release or ""
  local major = release:match("^(%d+)%.")
  if not major then
    return "26"
  end
  local darwin_major = tonumber(major)
  if darwin_major and DARWIN_TO_MACOS[darwin_major] then
    return tostring(DARWIN_TO_MACOS[darwin_major])
  end
  return "26"
end

--- Get the schema for the current macOS version.
---
--- Falls back to the latest known schema if the current version is unknown.
---
--- @return table The schema column mapping
local function get_schema()
  local ver = get_macos_major_version()
  return SCHEMAS[ver] or SCHEMAS["26"]
end

--- Invalidate the note/folder cache and notify listeners.
function M.invalidate_cache()
  local had_data = cache.notes ~= nil or cache.folders ~= nil or cache.tags ~= nil
  cache.notes = nil
  cache.folders = nil
  cache.tags = nil
  cache.timestamp = 0
  -- Only notify if there was cached data (avoids spurious refreshes on startup)
  if had_data then
    for _, fn in ipairs(invalidate_listeners) do
      pcall(fn)
    end
  end
end

--- Register a callback to be invoked when the cache is invalidated.
---
--- Used by the neo-tree source to auto-refresh the tree when Apple Notes
--- data changes (note renamed, deleted, folder changed, etc.).
---
--- @param fn fun() The callback function
function M.on_invalidate(fn)
  table.insert(invalidate_listeners, fn)
end

--- Set up fs_event watchers on the database file and its WAL journal.
---
--- SQLite WAL mode writes to NoteStore.sqlite-wal first; the main file
--- is only updated on checkpoint. Watching both ensures we detect changes
--- regardless of when SQLite checkpoints.
---
--- Falls back to TTL-based invalidation if watchers fail to attach.
function M.setup_watcher()
  if cache.watcher then
    return
  end

  local paths = { DB_PATH, DB_PATH .. "-wal" }
  local handles = {}

  for _, path in ipairs(paths) do
    local handle = vim.loop.new_fs_event()
    if handle then
      local ok = handle:start(path, {}, function(err)
        if err then
          return
        end
        vim.schedule(function()
          M.invalidate_cache()
        end)
      end)
      if ok then
        table.insert(handles, handle)
      else
        handle:close()
      end
    end
  end

  if #handles == 0 then
    M._setup_ttl_fallback()
    return
  end

  cache.watcher = handles
end

--- Set up TTL-based cache invalidation as a fallback.
---
--- Used when fs_event watcher fails to attach (permissions, watcher limit).
function M._setup_ttl_fallback()
  if cache.timer then
    return
  end
  cache.timer = vim.loop.new_timer()
  if cache.timer then
    cache.timer:start(
      CACHE_TTL_MS,
      CACHE_TTL_MS,
      vim.schedule_wrap(function()
        M.invalidate_cache()
      end)
    )
  end
end

--- Stop the watchers and timer.
function M.teardown()
  if cache.watcher then
    for _, handle in ipairs(cache.watcher) do
      handle:stop()
      handle:close()
    end
    cache.watcher = nil
  end
  if cache.timer then
    cache.timer:stop()
    cache.timer:close()
    cache.timer = nil
  end
end

--- Execute a SQL query against the Notes database.
---
--- @param sql string The SQL query to execute
--- @param callback fun(err: string|nil, rows: table[]|nil) Called with results
function M.query(sql, callback)
  job.run({ "sqlite3", "-json", "-readonly", DB_PATH, sql }, {}, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    if not result or result == "" then
      callback(nil, {})
      return
    end
    local ok, decoded = pcall(vim.json.decode, result)
    if not ok then
      callback("Failed to parse database output: " .. tostring(decoded), nil)
      return
    end
    callback(nil, decoded)
  end)
end

--- Convert an Apple Core Data timestamp to a Unix timestamp.
---
--- Safely convert a value that may be vim.NIL (JSON null) to a Lua default.
---
--- vim.json.decode returns vim.NIL (userdata) for JSON null values,
--- which is truthy in Lua, so `val or default` does not work.
---
--- @param val any The value to check
--- @param default any The fallback if val is nil or vim.NIL
--- @return any
local function safe(val, default)
  if val == nil or val == vim.NIL then
    return default
  end
  return val
end

--- @param apple_ts number The Apple timestamp (seconds since 2001-01-01)
--- @return number Unix timestamp
local function apple_to_unix(apple_ts)
  if not apple_ts or apple_ts == vim.NIL then
    return 0
  end
  return apple_ts + APPLE_EPOCH_OFFSET
end

--- Fetch all notes (non-deleted) from the database.
---
--- Results are cached and invalidated by the fs_event watcher.
---
--- @param callback fun(err: string|nil, notes: table[]|nil) Called with note list
function M.get_notes(callback)
  if cache.notes then
    callback(nil, cache.notes)
    return
  end

  local s = get_schema()
  local sql = string.format(
    [[
    SELECT
      n.Z_PK as id,
      n.%s as title,
      n.%s as snippet,
      n.%s as mod_date,
      n.%s as identifier,
      f.ZTITLE2 as folder_name,
      f.Z_PK as folder_id
    FROM ZICCLOUDSYNCINGOBJECT n
    LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.%s = f.Z_PK
    WHERE n.%s IS NOT NULL
      AND (n.%s IS NULL OR n.%s = 0)
      AND (f.ZFOLDERTYPE IS NULL OR f.ZFOLDERTYPE != 1)
    ORDER BY n.%s DESC
    LIMIT 500
  ]],
    s.title,
    s.snippet,
    s.mod_date,
    s.identifier,
    s.folder,
    s.title,
    s.marked_for_deletion,
    s.marked_for_deletion,
    s.mod_date
  )

  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end

    local notes = {}
    for _, row in ipairs(rows or {}) do
      table.insert(notes, {
        id = row.id,
        title = safe(row.title, "Untitled"),
        snippet = safe(row.snippet, ""),
        mod_date = apple_to_unix(row.mod_date),
        identifier = safe(row.identifier, ""),
        folder_name = safe(row.folder_name, "Notes"),
        folder_id = row.folder_id,
      })
    end

    cache.notes = notes
    cache.timestamp = vim.loop.now()
    callback(nil, notes)
  end)
end

--- Fetch all folders from the database.
---
--- Includes parent folder ID for building hierarchical trees.
--- Excludes "Recently Deleted" (ZFOLDERTYPE=1).
---
--- @param callback fun(err: string|nil, folders: table[]|nil) Called with folder list
function M.get_folders(callback)
  if cache.folders then
    callback(nil, cache.folders)
    return
  end

  local sql = [[
    SELECT
      Z_PK as id,
      ZTITLE2 as name,
      ZIDENTIFIER as identifier,
      ZPARENT as parent_id
    FROM ZICCLOUDSYNCINGOBJECT
    WHERE ZTITLE2 IS NOT NULL
      AND (ZFOLDERTYPE IS NULL OR ZFOLDERTYPE != 1)
      AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0)
    ORDER BY ZTITLE2
  ]]

  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end

    local folders = {}
    for _, row in ipairs(rows or {}) do
      table.insert(folders, {
        id = row.id,
        name = safe(row.name, "Untitled"),
        identifier = safe(row.identifier, ""),
        parent_id = safe(row.parent_id, nil),
      })
    end

    cache.folders = folders
    callback(nil, folders)
  end)
end

--- Fetch deleted (trashed) notes from the database.
---
--- @param callback fun(err: string|nil, notes: table[]|nil) Called with trashed note list
function M.get_deleted_notes(callback)
  local s = get_schema()
  local sql = string.format(
    [[
    SELECT
      n.Z_PK as id,
      n.%s as title,
      n.%s as snippet,
      n.%s as mod_date,
      n.%s as identifier,
      f.ZTITLE2 as folder_name
    FROM ZICCLOUDSYNCINGOBJECT n
    LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.%s = f.Z_PK
    WHERE n.%s IS NOT NULL
      AND n.%s = 1
    ORDER BY n.%s DESC
  ]],
    s.title,
    s.snippet,
    s.mod_date,
    s.identifier,
    s.folder,
    s.title,
    s.marked_for_deletion,
    s.mod_date
  )

  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end

    local notes = {}
    for _, row in ipairs(rows or {}) do
      table.insert(notes, {
        id = row.id,
        title = safe(row.title, "Untitled"),
        snippet = safe(row.snippet, ""),
        mod_date = apple_to_unix(row.mod_date),
        identifier = safe(row.identifier, ""),
        folder_name = safe(row.folder_name, "Notes"),
      })
    end

    callback(nil, notes)
  end)
end

--- Get the modification date for a specific note.
---
--- Used by sync.lua for external change detection.
---
--- @param identifier string The note's ZIDENTIFIER
--- @param callback fun(err: string|nil, mod_date: number|nil)
function M.get_modification_date(identifier, callback)
  local s = get_schema()
  local safe_id = sanitize.sql(identifier)
  local sql =
    string.format("SELECT %s as mod_date FROM ZICCLOUDSYNCINGOBJECT WHERE %s = '%s'", s.mod_date, s.identifier, safe_id)

  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end
    if not rows or #rows == 0 then
      callback("Note not found", nil)
      return
    end
    callback(nil, apple_to_unix(rows[1].mod_date))
  end)
end

--- Build the Core Data URI for a note.
---
--- @param note_id number The Z_PK of the note
--- @param callback fun(err: string|nil, uri: string|nil)
function M.get_core_data_uri(note_id, callback)
  local sql = "SELECT Z_UUID FROM Z_METADATA"
  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end
    if not rows or #rows == 0 then
      callback("Cannot read database metadata", nil)
      return
    end
    local uuid = rows[1].Z_UUID
    local uri = string.format("x-coredata://%s/ICNote/p%d", uuid, note_id)
    callback(nil, uri)
  end)
end

--- Search notes by title and snippet content.
---
--- @param query string The search query
--- @param callback fun(err: string|nil, notes: table[]|nil)
function M.search_notes(query, callback)
  local s = get_schema()
  local safe_query = sanitize.sql(query)
  local sql = string.format(
    [[
    SELECT
      n.Z_PK as id,
      n.%s as title,
      n.%s as snippet,
      n.%s as mod_date,
      n.%s as identifier,
      f.ZTITLE2 as folder_name,
      f.Z_PK as folder_id
    FROM ZICCLOUDSYNCINGOBJECT n
    LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.%s = f.Z_PK
    WHERE n.%s IS NOT NULL
      AND (n.%s IS NULL OR n.%s = 0)
      AND (n.%s LIKE '%%%s%%' OR n.%s LIKE '%%%s%%')
    ORDER BY n.%s DESC
    LIMIT 100
  ]],
    s.title,
    s.snippet,
    s.mod_date,
    s.identifier,
    s.folder,
    s.title,
    s.marked_for_deletion,
    s.marked_for_deletion,
    s.title,
    safe_query,
    s.snippet,
    safe_query,
    s.mod_date
  )

  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end

    local notes = {}
    for _, row in ipairs(rows or {}) do
      table.insert(notes, {
        id = row.id,
        title = safe(row.title, "Untitled"),
        snippet = safe(row.snippet, ""),
        mod_date = apple_to_unix(row.mod_date),
        identifier = safe(row.identifier, ""),
        folder_name = safe(row.folder_name, "Notes"),
        folder_id = row.folder_id,
      })
    end

    callback(nil, notes)
  end)
end

--- Fetch image attachments for a note.
---
--- Queries the SQLite database for image attachments linked to the given note,
--- including the account identifier needed to resolve the file path on disk.
---
--- File path pattern:
---   ~/Library/Group Containers/group.com.apple.notes/Accounts/{account_id}/Media/{media_id}/{subfolder}/{filename}
---
--- @param note_id number The Z_PK of the note
--- @param callback fun(err: string|nil, attachments: { filename: string, media_id: string, account_id: string, type_uti: string }[]|nil)
function M.get_attachments(note_id, callback)
  local sql = string.format(
    [[
    SELECT
      att.ZTYPEUTI as type_uti,
      media.ZFILENAME as filename,
      media.ZIDENTIFIER as media_id,
      acct.ZIDENTIFIER as account_id
    FROM ZICCLOUDSYNCINGOBJECT att
    JOIN ZICCLOUDSYNCINGOBJECT media ON att.ZMEDIA = media.Z_PK
    JOIN ZICCLOUDSYNCINGOBJECT n ON att.ZNOTE = n.Z_PK
    JOIN ZICCLOUDSYNCINGOBJECT folder ON n.ZFOLDER = folder.Z_PK
    JOIN ZICCLOUDSYNCINGOBJECT acct ON folder.ZOWNER = acct.Z_PK
    WHERE n.Z_PK = %d
      AND att.Z_ENT = 5
      AND (att.ZTYPEUTI LIKE 'public.png'
        OR att.ZTYPEUTI LIKE 'public.jpeg'
        OR att.ZTYPEUTI LIKE 'public.tiff'
        OR att.ZTYPEUTI LIKE 'public.heic'
        OR att.ZTYPEUTI = 'com.compuserve.gif')
    ORDER BY att.Z_PK ASC
  ]],
    note_id
  )

  M.query(sql, function(err, rows)
    if err then
      callback(err, nil)
      return
    end

    local attachments = {}
    for _, row in ipairs(rows or {}) do
      table.insert(attachments, {
        filename = safe(row.filename, ""),
        media_id = safe(row.media_id, ""),
        account_id = safe(row.account_id, ""),
        type_uti = safe(row.type_uti, ""),
      })
    end

    callback(nil, attachments)
  end)
end

--- Extract hashtag patterns from text with word boundary checking.
---
--- Matches #tagname preceded by whitespace or start-of-string, followed by
--- whitespace, punctuation, or end-of-string. Excludes # inside URLs, hex
--- colors, and other non-tag contexts.
---
--- @param text string The text to scan for tags
--- @return table<string, boolean> Set of unique tags found
local function extract_tags_from_text(text)
  local tags = {}
  if not text or text == "" then
    return tags
  end
  -- Strip HTML tags first (note bodies come as HTML)
  local plaintext = text:gsub("<[^>]+>", " ")
  -- Match #tagname with word boundary: preceded by whitespace or punctuation.
  -- Pad with space so start-of-string boundary check works.
  local padded = " " .. plaintext
  for tag in padded:gmatch("[%s%p]#(%w+)") do
    if #tag >= 2 then
      tags["#" .. tag] = true
    end
  end
  return tags
end

--- Fetch all unique tags from note bodies via batch AppleScript.
---
--- Note bodies in the SQLite database are stored as gzip-compressed blobs,
--- making SQL-based tag extraction impractical. Instead, this function uses
--- a single AppleScript call to fetch all note bodies, then extracts
--- #tagname patterns in Lua.
---
--- Results are cached and invalidated alongside the note cache by the
--- fs_event watcher.
---
--- Tags are case-sensitive (#Work != #work), matching Apple Notes behavior.
---
--- @param callback fun(err: string|nil, tags: { tag: string, count: number, note_ids: string[] }[]|nil)
function M.get_tags(callback)
  if cache.tags then
    callback(nil, cache.tags)
    return
  end

  local applescript = require("apple-notes.applescript")
  applescript.get_all_note_bodies(function(err, notes)
    if err then
      callback(err, nil)
      return
    end

    -- Count tags across all notes and track which notes have each tag
    local tag_counts = {}
    local tag_note_ids = {}

    for _, note in ipairs(notes or {}) do
      local tags = extract_tags_from_text(note.body)
      for tag, _ in pairs(tags) do
        tag_counts[tag] = (tag_counts[tag] or 0) + 1
        if not tag_note_ids[tag] then
          tag_note_ids[tag] = {}
        end
        table.insert(tag_note_ids[tag], note.id)
      end
    end

    -- Convert to sorted array
    local result = {}
    for tag, count in pairs(tag_counts) do
      table.insert(result, { tag = tag, count = count, note_ids = tag_note_ids[tag] })
    end
    table.sort(result, function(a, b)
      if a.count ~= b.count then
        return a.count > b.count
      end
      return a.tag < b.tag
    end)

    cache.tags = result
    callback(nil, result)
  end)
end

--- Get notes that contain a specific tag.
---
--- Cross-references tag note IDs with the cached note list to return
--- full note data for notes matching the tag.
---
--- @param tag string The tag to filter by (including the # prefix)
--- @param callback fun(err: string|nil, notes: table[]|nil)
function M.get_notes_by_tag(tag, callback)
  M.get_tags(function(tag_err, tags)
    if tag_err then
      callback(tag_err, nil)
      return
    end

    -- Find note Z_PKs for the requested tag
    -- AppleScript returns Core Data URIs like "x-coredata://UUID/ICNote/p123"
    -- Extract the Z_PK (number after "p") to match against get_notes() results
    local note_zpks = {}
    for _, t in ipairs(tags or {}) do
      if t.tag == tag then
        for _, uri in ipairs(t.note_ids) do
          local zpk = uri:match("/p(%d+)$")
          if zpk then
            note_zpks[tonumber(zpk)] = true
          end
        end
        break
      end
    end

    if vim.tbl_isempty(note_zpks) then
      callback(nil, {})
      return
    end

    -- Cross-reference with full note data
    M.get_notes(function(notes_err, notes)
      if notes_err then
        callback(notes_err, nil)
        return
      end

      local filtered = {}
      for _, note in ipairs(notes or {}) do
        if note_zpks[note.id] then
          table.insert(filtered, note)
        end
      end

      callback(nil, filtered)
    end)
  end)
end

--- Check if the database file exists and is readable.
---
--- @return boolean exists True if the database is accessible
function M.db_exists()
  return vim.fn.filereadable(DB_PATH) == 1
end

--- Get the database file path.
---
--- @return string The path to NoteStore.sqlite
function M.get_db_path()
  return DB_PATH
end

return M
