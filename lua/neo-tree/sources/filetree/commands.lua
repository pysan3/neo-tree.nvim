-- This file should contain all commands meant to be used by mappings.

local cc = require("neo-tree.sources.common.commands")
local fs = require("neo-tree.sources.filesystem")
local utils = require("neo-tree.utils")
local filter = require("neo-tree.sources.filesystem.lib.filter")
local renderer = require("neo-tree.ui.renderer")
local log = require("neo-tree.log")
local nio = require("neo-tree.utils.nio_wrapper")

---A table to register sync and async functions.
---@class NeotreeFiletreeCommands : NeotreeCommonCommands
local M = setmetatable({}, {
  __index = cc,
})
M.__index = M
---@class NeotreeFiletreeCommands
M.async = {}
---@class NeotreeFiletreeCommands
M.wrap1 = {}
---@class NeotreeFiletreeCommands
M.wrap2 = {}
---@class NeotreeFiletreeCommands
M.wrap3 = {}
---@class NeotreeFiletreeCommands
M.wrap4 = {}
---@class NeotreeFiletreeCommands
M.wrap5 = {}
---@class NeotreeFiletreeCommands
M.wrap6 = {}
---@class NeotreeFiletreeCommands
M.wrap7 = {}
---@class NeotreeFiletreeCommands
M.wrap8 = {}
---@class NeotreeFiletreeCommands
M.wrap9 = {}

local refresh = function(state)
  error("TODO: V4 refactor: not implemented")
  fs._navigate_internal(state, nil, nil, nil, false)
end

local redraw = function(state)
  renderer.redraw(state)
end

---Refresh the tree when something went wrong or is not updating correctly.
---@param state NeotreeFiletree
M.async.refresh = function(state)
  error("WIP: move this to source:refresh()")
  state:explicitly_save(true)
  -- TODO: make sure all parents of each dir is also scanned <2024-03-14, pysan3>
  for _, node_id in ipairs(vim.tbl_keys(state.explicitly_opened_directories)) do
    state:fill_tree(node_id, 1)
  end
  state:explicitly_restore(true)
  renderer.redraw(state)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                  Filesystem Operations                  │
--          ╰─────────────────────────────────────────────────────────╯

---Add a new node; create new file.
---@param state NeotreeFiletree
M.async.add = function(state)
  local add_result, folder = cc.add(state)
  for _, dest in ipairs(add_result) do
    assert(dest:exists(), string.format([[Failed to create %s]], dest))
    state:fill_tree(folder:get_id(), 0, dest)
    state:focus_node(dest:tostring())
  end
  redraw(state)
end

---Add a new node; create new directory.
---@param state NeotreeFiletree
M.async.add_directory = function(state)
  local add_result, folder = cc.add_directory(state)
  for _, dest in ipairs(add_result) do
    assert(dest:exists(), string.format([[Failed to create %s]], dest))
    state:fill_tree(folder:get_id(), 0, dest)
    state:focus_node(dest:tostring())
  end
  redraw(state)
end

---Copy a file to a different destination.
---@param state NeotreeFiletree
M.async.copy = function(state)
  local source, destination = cc.copy(state)
  if not source or not destination then
    return
  end
  state:fill_tree(source:parent_assert():tostring(), 0, destination)
  state:focus_node(destination:tostring())
  redraw(state)
end

---Move / rename a file to a different location.
---@param state NeotreeFiletree
M.async.move = function(state)
  local source, destination = cc.move(state)
  if not source or not destination then
    return
  end
  state:modify_tree(function()
    state:remove_node_recursive(source:tostring())
  end)
  state:fill_tree(source:parent_assert():tostring(), 0, destination)
  state:focus_node(destination:tostring())
  redraw(state)
end

---Move / rename a file to a different location.
---@param state NeotreeFiletree
M.async.rename = function(state)
  return M.move(state)
end

---Delete a file or folder.
---@param state NeotreeFiletree
M.async.delete = function(state)
  local deleted = cc.delete(state)
  log.debug(string.format([[#deleted: %s, %s]], #deleted, deleted))
  state:modify_tree(function()
    for _, path in ipairs(deleted) do
      state:remove_node_recursive(path:tostring())
    end
  end)
  redraw(state)
end

---Delete items from tree. Only compatible with file system trees.
---@param state NeotreeFiletree
---@param selected_nodes NuiTreeNode[]
M.async.delete_visual = function(state, selected_nodes)
  local deleted = cc.delete_visual(state, selected_nodes)
  log.debug(string.format([[#deleted: %s, %s]], #deleted, deleted))
  state:modify_tree(function()
    for _, path in ipairs(deleted) do
      local suc = state:remove_node_recursive(path:tostring())
      log.time_it(string.format("delte_visual: delete '%s' -> %s", path, suc))
    end
  end)
  redraw(state)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                  Clipboard Operations                   │
--          ╰─────────────────────────────────────────────────────────╯

---Marks node as copied, so that it can be pasted somewhere else.
M.async.copy_to_clipboard = function(state)
  cc.copy_to_clipboard(state, utils.wrap(redraw, state))
end

M.async.copy_to_clipboard_visual = function(state, selected_nodes)
  cc.copy_to_clipboard_visual(state, selected_nodes, utils.wrap(redraw, state))
end

---Marks node as cut, so that it can be pasted (moved) somewhere else.
M.async.cut_to_clipboard = function(state)
  cc.cut_to_clipboard(state, utils.wrap(redraw, state))
end

M.async.cut_to_clipboard_visual = function(state, selected_nodes)
  cc.cut_to_clipboard_visual(state, selected_nodes, utils.wrap(redraw, state))
end

---Pastes all items from the clipboard to the current directory.
---@param state NeotreeFiletree
M.async.paste_from_clipboard = function(state)
  local dest_folder, destinations = cc.paste_from_clipboard(state)
  destinations = destinations or {}
  log.time_it("paste_from_clipboard", dest_folder and dest_folder:get_id(), #destinations)
  if dest_folder then
    for _, destination in ipairs(destinations) do
      state:fill_tree(dest_folder:get_id(), 1, destination)
    end
    state:focus_node(destinations[1] and destinations[1]:tostring())
    redraw(state)
  end
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                     Node Operations                     │
--          ╰─────────────────────────────────────────────────────────╯

---@param state NeotreeFiletree
M.async.open = function(state)
  cc.open(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_split = function(state)
  cc.open_split(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_rightbelow_vs = function(state)
  cc.open_rightbelow_vs(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_leftabove_vs = function(state)
  cc.open_leftabove_vs(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_vsplit = function(state)
  cc.open_vsplit(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_tabnew = function(state)
  cc.open_tabnew(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_drop = function(state)
  cc.open_drop(state, utils.wrap(state.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.open_tab_drop = function(state)
  cc.open_tab_drop(state, utils.wrap(state.toggle_directory, state))
end

---@param state NeotreeFiletree
M.async.open_with_window_picker = function(state)
  error("TODO: V4 refactor: not implemented")
  cc.open_with_window_picker(state, utils.wrap(fs.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.split_with_window_picker = function(state)
  error("TODO: V4 refactor: not implemented")
  cc.split_with_window_picker(state, utils.wrap(fs.toggle_directory, state))
end
---@param state NeotreeFiletree
M.async.vsplit_with_window_picker = function(state)
  error("TODO: V4 refactor: not implemented")
  cc.vsplit_with_window_picker(state, utils.wrap(fs.toggle_directory, state))
end

---Open or close a node when it is expandable. Does nothing otherwise.
---@param state NeotreeFiletree
M.async.toggle_node = function(state)
  cc.toggle_node(state, function(node)
    state:toggle_directory(node, node.pathlib, false)
  end)
end

---Toggles whether hidden files are shown or not.
M.async.toggle_hidden = function(state)
  error("TODO: V4 refactor: not implemented")
  state.filtered_items.visible = not state.filtered_items.visible
  log.info("Toggling hidden files: " .. tostring(state.filtered_items.visible))
  refresh(state)
end

---Toggles whether the tree is filtered by gitignore or not.
M.async.toggle_gitignore = function(state)
  error("TODO: V4 refactor: not implemented")
  log.warn("`toggle_gitignore` has been removed, running toggle_hidden instead.")
  M.toggle_hidden(state)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                    Search Operations                    │
--          ╰─────────────────────────────────────────────────────────╯

---Clear searched result.
---@param state NeotreeState
M.async.clear_filter = function(state)
  state:search_end()
end

---Shows the filter input, which will filter the tree.
M.async.filter_as_you_type = function(state)
  error("TODO: V4 refactor: not implemented")
  filter.show_filter(state, true)
end

---Shows the filter input, which will filter the tree.
M.async.filter_on_submit = function(state)
  error("TODO: V4 refactor: not implemented")
  filter.show_filter(state, false)
end

---Shows the filter input in fuzzy finder mode.
M.async.fuzzy_finder = function(state)
  error("TODO: V4 refactor: not implemented")
  filter.show_filter(state, true, true)
end

---Shows the filter input in fuzzy finder mode.
M.async.fuzzy_finder_directory = function(state)
  error("TODO: V4 refactor: not implemented")
  filter.show_filter(state, true, "directory")
end

---Shows the filter input in fuzzy sorter
---@param state NeotreeFiletree
M.async.fuzzy_sorter = function(state)
  filter.show_filter(state, true, true, true)
end

---Shows the filter input in fuzzy sorter with only directories
M.async.fuzzy_sorter_directory = function(state)
  error("TODO: V4 refactor: not implemented")
  filter.show_filter(state, true, "directory", true)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                     Git Operations                      │
--          ╰─────────────────────────────────────────────────────────╯

local focus_next_git_modified = function(state, reverse)
  local node = state.tree:get_node()
  local current_path = node:get_id()
  local g = state.git_status_lookup
  if not utils.truthy(g) then
    return
  end
  local paths = { current_path }
  for path, status in pairs(g) do
    if path ~= current_path and status and status ~= "!!" then
      --don't include files not in the current working directory
      if utils.is_subpath(state.path, path) then
        table.insert(paths, path)
      end
    end
  end
  local sorted_paths = utils.sort_by_tree_display(paths)
  if reverse then
    sorted_paths = utils.reverse_list(sorted_paths)
  end

  local is_file = function(path)
    local success, stats = pcall(vim.loop.fs_stat, path)
    return (success and stats and stats.type ~= "directory")
  end

  local passed = false
  local target = nil
  for _, path in ipairs(sorted_paths) do
    if target == nil and is_file(path) then
      target = path
    end
    if passed then
      if is_file(path) then
        target = path
        break
      end
    elseif path == current_path then
      passed = true
    end
  end

  local existing = state.tree:get_node(target)
  if existing then
    renderer.focus_node(state, target)
  else
    fs.navigate(state, state.path, target, nil, false) ---@diagnostic disable-line
  end
end

M.async.next_git_modified = function(state)
  error("TODO: V4 refactor: not implemented")
  focus_next_git_modified(state, false)
end

M.async.prev_git_modified = function(state)
  error("TODO: V4 refactor: not implemented")
  focus_next_git_modified(state, true)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                     Tree Operations                     │
--          ╰─────────────────────────────────────────────────────────╯

---Navigate up one level.
M.async.navigate_up = function(state)
  error("TODO: V4 refactor: not implemented")
  local parent_path, _ = utils.split_path(state.path)
  if not utils.truthy(parent_path) then
    return
  end
  local path_to_reveal = nil
  local node = state.tree:get_node()
  if node then
    path_to_reveal = node:get_id()
  end
  if state.search_pattern then
    fs.reset_search(state, false)
  end
  log.debug("Changing directory to:", parent_path)
  fs._navigate_internal(state, parent_path, path_to_reveal, nil, false)
end

M.async.set_root = function(state)
  error("TODO: V4 refactor: not implemented")
  local tree = state.tree
  local node = tree:get_node()
  if node.type == "directory" then
    if state.search_pattern then
      fs.reset_search(state, false)
    end
    fs._navigate_internal(state, node.id, nil, nil, false)
  end
end

M:_add_common_commands()

return M:_compile()
