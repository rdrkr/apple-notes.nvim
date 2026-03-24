--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Checkhealth integration for Apple Notes.
---
--- Run `:checkhealth apple-notes` to verify all dependencies are
--- installed and configured correctly.
---
--- Checks:
--- - sqlite3 binary exists and version >= 3.33.0 (for -json flag)
--- - osascript binary exists
--- - pandoc binary exists and version >= 3.0
--- - NoteStore.sqlite exists and is readable (Full Disk Access)
--- - Notes.app is accessible
--- - macOS version and schema adapter status
---
--- @module apple-notes.health
local M = {}

--- Run the health check.
function M.check()
  vim.health.start("apple-notes")

  -- Check sqlite3
  M._check_sqlite3()

  -- Check osascript
  M._check_osascript()

  -- Check pandoc
  M._check_pandoc()

  -- Check database access
  M._check_database()

  -- Check macOS version
  M._check_macos_version()
end

--- Check sqlite3 binary and version.
function M._check_sqlite3()
  local sqlite3 = vim.fn.exepath("sqlite3")
  if sqlite3 == "" then
    vim.health.error("sqlite3 not found in PATH", {
      "sqlite3 ships with macOS. Check your PATH.",
    })
    return
  end

  vim.health.ok("sqlite3 found: " .. sqlite3)

  -- Check version for -json support (added in 3.33.0)
  local version_output = vim.fn.system({ "sqlite3", "--version" })
  local version = version_output:match("(%d+%.%d+%.%d+)")
  if version then
    local major, minor = version:match("(%d+)%.(%d+)")
    major = tonumber(major)
    minor = tonumber(minor)
    if major and minor and (major > 3 or (major == 3 and minor >= 33)) then
      vim.health.ok("sqlite3 version " .. version .. " (>= 3.33.0, -json supported)")
    else
      vim.health.error("sqlite3 version " .. version .. " is too old", {
        "Version 3.33.0+ required for -json flag support.",
        "Update via: brew install sqlite3",
      })
    end
  else
    vim.health.warn("Could not determine sqlite3 version")
  end
end

--- Check osascript binary.
function M._check_osascript()
  local osascript = vim.fn.exepath("osascript")
  if osascript == "" then
    vim.health.error("osascript not found in PATH", {
      "osascript ships with macOS. This plugin requires macOS.",
    })
    return
  end

  vim.health.ok("osascript found: " .. osascript)
end

--- Check pandoc binary and version.
function M._check_pandoc()
  local pandoc = vim.fn.exepath("pandoc")
  if pandoc == "" then
    vim.health.error("pandoc not found in PATH", {
      "Install pandoc: brew install pandoc",
      "pandoc is required for HTML to Markdown conversion.",
    })
    return
  end

  vim.health.ok("pandoc found: " .. pandoc)

  -- Check version
  local version_output = vim.fn.system({ "pandoc", "--version" })
  local version = version_output:match("pandoc ([%d%.]+)")
  if version then
    local major = tonumber(version:match("^(%d+)"))
    if major and major >= 3 then
      vim.health.ok("pandoc version " .. version .. " (>= 3.0)")
    else
      vim.health.warn("pandoc version " .. version .. " is older than recommended", {
        "Version 3.0+ recommended for best HTML conversion.",
        "Update via: brew upgrade pandoc",
      })
    end
  else
    vim.health.warn("Could not determine pandoc version")
  end
end

--- Check database file access.
function M._check_database()
  local db = require("apple-notes.db")
  local db_path = db.get_db_path()

  if vim.fn.filereadable(db_path) == 1 then
    vim.health.ok("Apple Notes database found: " .. db_path)

    -- Try a simple query to verify access
    local test_output = vim.fn.system({
      "sqlite3",
      "-readonly",
      db_path,
      "SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 IS NOT NULL",
    })
    local count = test_output:match("(%d+)")
    if count then
      vim.health.ok("Database readable. Found " .. count .. " notes.")
    else
      vim.health.warn("Database exists but query failed", {
        "The database may be locked or corrupted.",
        "Try closing Notes.app and retrying.",
      })
    end
  else
    vim.health.error("Apple Notes database not found at: " .. db_path, {
      "Your terminal needs Full Disk Access to read this file.",
      "Grant access: System Settings → Privacy & Security → Full Disk Access",
      "Add your terminal app (iTerm2, Terminal.app, Alacritty, etc.)",
      "Then restart your terminal and neovim.",
    })
  end
end

--- Darwin kernel version to macOS version mapping.
--- Apple jumped from macOS 15 (Sequoia) to macOS 26 (Tahoe).
local DARWIN_TO_MACOS = {
  [23] = 14, -- Sonoma
  [24] = 15, -- Sequoia
  [25] = 26, -- Tahoe
}

--- Check macOS version and schema adapter status.
function M._check_macos_version()
  local uname = vim.loop.os_uname()
  local release = uname.release or "unknown"
  local major = release:match("^(%d+)%.")
  local darwin_major = tonumber(major)
  local macos_version = darwin_major and DARWIN_TO_MACOS[darwin_major] or nil

  if macos_version then
    vim.health.ok("macOS " .. macos_version .. " (Darwin " .. release .. ")")

    -- Check if we have a schema adapter for this version
    local known_versions = { 14, 15, 26 }
    local has_adapter = false
    for _, v in ipairs(known_versions) do
      if v == macos_version then
        has_adapter = true
        break
      end
    end

    if has_adapter then
      vim.health.ok("Schema adapter available for macOS " .. macos_version)
    else
      vim.health.warn("No specific schema adapter for macOS " .. macos_version, {
        "Using fallback schema (macOS 26). Plugin may work but column names might differ.",
        "Please report any issues at the project's issue tracker.",
      })
    end
  else
    vim.health.warn("Could not determine macOS version from Darwin release: " .. release)
  end

  -- Check image support (read-only, requires access to attachment files)
  local notes_base = vim.fn.expand("~/Library/Group Containers/group.com.apple.notes")
  local accounts_dir = notes_base .. "/Accounts"
  if vim.fn.isdirectory(accounts_dir) == 1 then
    vim.health.ok("Image attachment directory accessible: " .. accounts_dir)
  else
    vim.health.info("Image attachment directory not found (images will show as [image] placeholders)")
  end

  -- Check optional dependencies
  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    vim.health.ok("telescope.nvim found (note picker available)")
  else
    vim.health.info("telescope.nvim not found (note picker unavailable, install for :AppleNotes)")
  end

  local has_neo_tree = pcall(require, "neo-tree")
  if has_neo_tree then
    vim.health.ok("neo-tree.nvim found (tree view available)")
  else
    vim.health.info("neo-tree.nvim not found (tree view unavailable, install for :AppleNotesTree)")
  end
end

return M
