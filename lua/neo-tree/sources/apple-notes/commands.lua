--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- neo-tree commands for the Apple Notes source.
---
--- Extends the common neo-tree commands (close_node, toggle_preview, etc.)
--- with Apple Notes-specific commands (open, add, delete, etc.).
---
--- @module neo-tree.sources.apple-notes.commands
local cc = require("neo-tree.sources.common.commands")
local tree = require("apple-notes.tree")

--- Start with all common commands so default mappings work.
local M = vim.tbl_deep_extend("force", {}, cc)

--- Override with Apple Notes-specific commands.
local commands = tree._get_commands(tree._config or {})
for name, fn in pairs(commands) do
  M[name] = fn
end

return M
