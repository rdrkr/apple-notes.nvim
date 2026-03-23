--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Lazy-load entry point for the Apple Notes plugin.
---
--- This file is loaded by neovim's plugin system. It does nothing
--- until the user calls require('apple-notes').setup().
---
--- The plugin only works on macOS — silently exits on other platforms.

if vim.fn.has("mac") ~= 1 then
  return
end

-- Prevent double-loading
if vim.g.loaded_apple_notes then
  return
end
vim.g.loaded_apple_notes = true
