--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- neo-tree custom source logic for Apple Notes.
---
--- Provides tree rendering and CRUD commands for the neo-tree sidebar.
--- The neo-tree source entry point lives at lua/neo-tree/sources/apple-notes/init.lua
--- and delegates here for the actual logic.
---
--- Tree structure:
---    Folder 1
---      Note A
---      Note B
---    Folder 2
---      Note C
---
--- @module apple-notes.tree
local applescript = require("apple-notes.applescript")
local buffer = require("apple-notes.buffer")
local db = require("apple-notes.db")

local M = {}

--- Stored plugin config for use by commands.
--- @type table
M._config = {}

--- Initialize the tree module with the plugin config.
---
--- Called from init.lua during plugin setup. Registers a DB invalidation
--- listener so the tree auto-refreshes when Apple Notes data changes.
--- The neo-tree source entry point lives at
--- lua/neo-tree/sources/apple-notes/init.lua.
---
--- @param config table The plugin config
function M.setup(config)
  M._config = config

  -- Register DB invalidation listener for auto-refresh.
  -- This runs at plugin init time so the listener is always active,
  -- regardless of when neo-tree calls source setup.
  if not M._invalidate_registered then
    M._invalidate_registered = true
    db.on_invalidate(function()
      -- Skip if _render_tree triggered this invalidation (avoids infinite loop)
      if M._rendering then
        return
      end
      -- Debounce: Apple Notes often writes multiple DB changes in quick succession
      if M._refresh_timer then
        M._refresh_timer:stop()
      end
      M._refresh_timer = vim.defer_fn(function()
        M._refresh_timer = nil
        local ok, manager = pcall(require, "neo-tree.sources.manager")
        if ok then
          pcall(manager.refresh, "apple-notes")
        end
      end, 500)
    end)
  end
end

--- Called by the neo-tree source module during neo-tree's own setup.
---
--- The DB invalidation listener is registered in setup() at plugin init time,
--- so this is a no-op kept for API compatibility with the neo-tree source module.
---
--- @param source_config table Source-specific neo-tree config
--- @param global_config table Global neo-tree config
function M._neo_tree_setup(source_config, global_config)
  -- Listener registration moved to M.setup() so it works regardless
  -- of neo-tree source initialization order.
end

--- Build a neo-tree folder node with its notes as children.
---
--- @param folder table The folder data from db.get_folders()
--- @param notes_by_folder table<number, table[]> Notes grouped by folder_id
--- @param children_by_parent table<number, table[]> Subfolders grouped by parent_id
--- @return table The neo-tree node
local function build_folder_node(folder, notes_by_folder, children_by_parent)
  local children = {}

  -- Add subfolder nodes recursively
  for _, subfolder in ipairs(children_by_parent[folder.id] or {}) do
    table.insert(children, build_folder_node(subfolder, notes_by_folder, children_by_parent))
  end

  -- Add note nodes
  for _, note in ipairs(notes_by_folder[folder.id] or {}) do
    table.insert(children, {
      id = "note:" .. note.id,
      name = note.title or "Untitled",
      type = "file",
      extra = { note = note },
    })
  end

  return {
    id = "folder:" .. folder.id,
    name = folder.name,
    type = "directory",
    children = children,
    extra = { folder_name = folder.name },
  }
end

--- Render the tree with current notes data.
---
--- Clears the DB cache before fetching to ensure fresh data,
--- then builds a hierarchical tree matching Apple Notes' folder structure.
---
--- @param state table neo-tree state
--- @param config table The plugin config
function M._render_tree(state, config)
  -- Clear cache directly (without triggering on_invalidate listeners,
  -- which would cause an infinite refresh loop via manager.refresh).
  M._rendering = true
  db.invalidate_cache()
  M._rendering = false

  db.get_folders(function(folder_err, folder_list)
    if folder_err then
      vim.notify("Cannot load folders. Run :checkhealth apple-notes", vim.log.levels.ERROR)
      return
    end

    db.get_notes(function(err, notes)
      if err then
        vim.notify("Cannot load notes tree. Run :checkhealth apple-notes", vim.log.levels.ERROR)
        return
      end

      -- Group notes by folder_id
      local notes_by_folder = {}
      for _, note in ipairs(notes or {}) do
        local fid = note.folder_id
        if fid then
          if not notes_by_folder[fid] then
            notes_by_folder[fid] = {}
          end
          table.insert(notes_by_folder[fid], note)
        end
      end

      -- Group folders by parent_id to build hierarchy
      local children_by_parent = {}
      local root_folders = {}

      for _, folder in ipairs(folder_list or {}) do
        if folder.parent_id then
          if not children_by_parent[folder.parent_id] then
            children_by_parent[folder.parent_id] = {}
          end
          table.insert(children_by_parent[folder.parent_id], folder)
        else
          table.insert(root_folders, folder)
        end
      end

      -- Build tree items from root folders
      local items = {}
      for _, folder in ipairs(root_folders) do
        local node = build_folder_node(folder, notes_by_folder, children_by_parent)
        table.insert(items, node)
      end

      vim.schedule(function()
        if state then
          local renderer_mod = require("neo-tree.ui.renderer")
          renderer_mod.show_nodes(items, state)
        end
      end)
    end)
  end)
end

--- Get the command table for neo-tree keymaps.
---
--- @param config table The plugin config
--- @return table Commands table for neo-tree
function M._get_commands(config)
  return {
    --- Open note or toggle folder (o / <CR>).
    ["open"] = function(state)
      local node = state.tree:get_node()
      if not node then
        return
      end

      -- Folders: toggle expand/collapse
      if node.type == "directory" then
        local cc = require("neo-tree.sources.common.commands")
        cc.toggle_node(state)
        return
      end

      -- Notes: open in buffer
      if node.extra and node.extra.note then
        buffer.open_note(node.extra.note, config)
      end
    end,

    --- Add new note (a).
    ["add"] = function(state)
      local node = state.tree:get_node()
      local folder_name = nil

      if node and node.extra then
        if node.extra.folder_name then
          folder_name = node.extra.folder_name
        elseif node.extra.note then
          folder_name = node.extra.note.folder_name
        end
      end

      vim.ui.input({ prompt = "Note title: " }, function(title)
        if not title or title == "" then
          return
        end
        buffer.create_note(title, folder_name, config)
        -- Refresh tree after a short delay
        vim.defer_fn(function()
          M._render_tree(state, config)
        end, 1000)
      end)
    end,

    --- Add new folder (A).
    ["add_directory"] = function(state)
      vim.ui.input({ prompt = "Folder name: " }, function(name)
        if not name or name == "" then
          return
        end
        applescript.create_folder(name, function(err)
          if err then
            vim.notify("Failed to create folder: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify("Folder created: " .. name, vim.log.levels.INFO)
          -- Delay re-render to allow Apple Notes to commit DB changes
          vim.defer_fn(function()
            M._render_tree(state, config)
          end, 500)
        end)
      end)
    end,

    --- Delete note (d).
    ["delete"] = function(state)
      local node = state.tree:get_node()
      if not node or not node.extra then
        return
      end

      if node.extra.note then
        local note = node.extra.note
        local choice = vim.fn.confirm(string.format("Delete '%s'?", note.title), "&Yes\n&No", 2)
        if choice ~= 1 then
          return
        end

        applescript.delete_note(note.id, function(err)
          if err then
            vim.notify("Delete failed: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify("Note moved to trash", vim.log.levels.INFO)
          vim.defer_fn(function()
            M._render_tree(state, config)
          end, 500)
        end)
      elseif node.extra.folder_name then
        local folder = node.extra.folder_name
        local choice = vim.fn.confirm(string.format("Delete folder '%s' and all its notes?", folder), "&Yes\n&No", 2)
        if choice ~= 1 then
          return
        end

        applescript.delete_folder(folder, function(err)
          if err then
            vim.notify("Delete failed: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify("Folder deleted", vim.log.levels.INFO)
          vim.defer_fn(function()
            M._render_tree(state, config)
          end, 500)
        end)
      end
    end,

    --- Rename (r).
    ["rename"] = function(state)
      local node = state.tree:get_node()
      if not node or not node.extra then
        return
      end

      if node.extra.folder_name then
        local old_name = node.extra.folder_name
        vim.ui.input({ prompt = "New folder name: ", default = old_name }, function(new_name)
          if not new_name or new_name == "" or new_name == old_name then
            return
          end
          applescript.rename_folder(old_name, new_name, function(err)
            if err then
              vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
              return
            end
            vim.notify("Folder renamed", vim.log.levels.INFO)
            vim.defer_fn(function()
              M._render_tree(state, config)
            end, 500)
          end)
        end)
      end
    end,

    --- Move note to folder (m).
    ["move"] = function(state)
      local node = state.tree:get_node()
      if not node or not node.extra or not node.extra.note then
        return
      end

      local note = node.extra.note

      db.get_folders(function(err, folder_list)
        if err then
          vim.notify("Failed to load folders: " .. err, vim.log.levels.ERROR)
          return
        end

        local folder_names = {}
        for _, f in ipairs(folder_list or {}) do
          if f.name ~= note.folder_name then
            table.insert(folder_names, f.name)
          end
        end

        vim.schedule(function()
          vim.ui.select(folder_names, { prompt = "Move to folder:" }, function(choice)
            if not choice then
              return
            end
            applescript.move_note(note.id, choice, function(move_err)
              if move_err then
                vim.notify("Move failed: " .. move_err, vim.log.levels.ERROR)
                return
              end
              vim.notify("Note moved to " .. choice, vim.log.levels.INFO)
              vim.defer_fn(function()
                M._render_tree(state, config)
              end, 500)
            end)
          end)
        end)
      end)
    end,

    --- Refresh tree (R).
    ["refresh"] = function(state)
      M._render_tree(state, config)
    end,
  }
end

return M
