--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- neo-tree source for Apple Notes.
---
--- Discoverable by neo-tree when users add "apple-notes" to their
--- neo-tree sources configuration. Delegates to apple-notes.tree
--- for rendering and commands.
---
--- @module neo-tree.sources.apple-notes
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")

--- @class neotree.sources.AppleNotes : neotree.Source
local M = {
  name = "apple-notes",
  display_name = " Apple Notes",
}

--- @return neotree.State
local get_state = function()
  return manager.get_state(M.name)
end

--- Navigate to the given path (renders the tree).
---
--- @param state neotree.State
--- @param path string|nil Unused — Apple Notes has no filesystem path
--- @param path_to_reveal string|nil Unused
--- @param callback function|nil Called after rendering
--- @param async boolean|nil Unused
M.navigate = function(state, path, path_to_reveal, callback, async)
  state.dirty = false
  if state.path == nil then
    state.path = "apple-notes://"
  end

  local tree = require("apple-notes.tree")
  tree._render_tree(state, tree._config or {})

  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

--- Set up the Apple Notes neo-tree source.
---
--- @param config table Source-specific configuration
--- @param global_config table Global neo-tree configuration
M.setup = function(config, global_config)
  local tree = require("apple-notes.tree")
  tree._neo_tree_setup(config, global_config)
end

return M
