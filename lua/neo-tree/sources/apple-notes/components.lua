--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- neo-tree component renderers for the Apple Notes source.
---
--- Each component is a function that receives (config, node, state) and returns
--- a table with `text` and `highlight` keys for rendering in the tree.
---
--- @module neo-tree.sources.apple-notes.components
local common = require("neo-tree.sources.common.components")
local highlights = require("neo-tree.ui.highlights")

local M = {}

--- Render the name component for a tree node.
---
--- Folders use directory highlighting, notes use file highlighting,
--- and the trash section uses warning highlighting.
---
--- @param config table Component config from the user's renderer
--- @param node table NuiNode for the current item
--- @param state table Current source state
--- @return table Component with text and highlight keys
M.name = function(config, node, state)
  local highlight = config.highlight or highlights.FILE_NAME
  local name = node.name

  if node.type == "directory" then
    if node:get_depth() == 1 then
      highlight = highlights.ROOT_NAME
    else
      highlight = highlights.DIRECTORY_NAME
    end
  end

  return {
    text = name,
    highlight = highlight,
  }
end

--- No-op git_status component.
---
--- Apple Notes nodes have no filesystem paths, so git status is not applicable.
--- Returns an empty table to prevent neo-tree's default git_status from crashing.
---
--- @return table Empty component
M.git_status = function()
  return {}
end

return vim.tbl_deep_extend("force", common, M)
