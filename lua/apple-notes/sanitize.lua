--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Input sanitization for SQL and AppleScript string literals.
---
--- All user input that enters SQL queries or AppleScript commands MUST be
--- routed through these functions to prevent injection attacks.
---
--- @module apple-notes.sanitize
local M = {}

--- Escape a string for safe use in SQL single-quoted literals.
---
--- Doubles single quotes, strips null bytes and control characters.
---
--- @param str string|nil The raw user input
--- @return string The escaped string safe for SQL interpolation
function M.sql(str)
  if not str then
    return ""
  end
  return str:gsub("%z", ""):gsub("'", "''"):gsub("[%c]", "")
end

--- Escape a string for safe use in AppleScript double-quoted string literals.
---
--- Escapes backslashes, double quotes, and strips null bytes.
---
--- @param str string|nil The raw user input
--- @return string The escaped string safe for AppleScript interpolation
function M.applescript(str)
  if not str then
    return ""
  end
  return str:gsub("%z", ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

return M
