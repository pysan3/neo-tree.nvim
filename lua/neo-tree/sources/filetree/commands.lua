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
M.nowrap = {}
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
  fs._navigate_internal(state, nil, nil, nil, false)
end

local redraw = function(state)
  renderer.redraw(state)
end

M.nowrap.add = function(state)
  local add_result, folder = cc.add(state)
  for _, dest in ipairs(add_result) do
    assert(dest:exists(), string.format([[Failed to create %s]], dest))
    state:fill_tree(folder:get_id(), 0, dest)
    state:focus_node(dest:tostring())
  end
  renderer.redraw(state)
end

M.nowrap.add_directory = function(state)
  local add_result, folder = cc.add_directory(state)
  for _, dest in ipairs(add_result) do
    assert(dest:exists(), string.format([[Failed to create %s]], dest))
    state:fill_tree(folder:get_id(), 0, dest)
    state:focus_node(dest:tostring())
  end
  renderer.redraw(state)
end

M.nowrap.clear_filter = function(state)
  fs.reset_search(state, true)
end

M.nowrap.copy = function(state)
  cc.copy(state, utils.wrap(fs.focus_destination_children, state))
end

---Marks node as copied, so that it can be pasted somewhere else.
M.nowrap.copy_to_clipboard = function(state)
  cc.copy_to_clipboard(state, utils.wrap(redraw, state))
end

M.nowrap.copy_to_clipboard_visual = function(state, selected_nodes)
  cc.copy_to_clipboard_visual(state, selected_nodes, utils.wrap(redraw, state))
end

---Marks node as cut, so that it can be pasted (moved) somewhere else.
M.nowrap.cut_to_clipboard = function(state)
  cc.cut_to_clipboard(state, utils.wrap(redraw, state))
end

M.nowrap.cut_to_clipboard_visual = function(state, selected_nodes)
  cc.cut_to_clipboard_visual(state, selected_nodes, utils.wrap(redraw, state))
end

M.nowrap.move = function(state)
  cc.move(state, utils.wrap(fs.focus_destination_children, state))
end

---Pastes all items from the clipboard to the current directory.
M.nowrap.paste_from_clipboard = function(state)
  cc.paste_from_clipboard(state, utils.wrap(fs.show_new_children, state))
end

---@param state NeotreeFiletree
M.nowrap.delete = function(state)
  local deleted = cc.delete(state)
  log.debug(string.format([[#deleted: %s, %s]], #deleted, deleted))
  state:modify_tree(function()
    for _, path in ipairs(deleted) do
      state:remove_node_recursive(path:tostring())
    end
  end)
  renderer.redraw(state)
end

---Delete items from tree. Only compatible with file system trees.
---@param state NeotreeFiletree
---@param selected_nodes NuiTreeNode[]
M.nowrap.delete_visual = function(state, selected_nodes)
  local deleted = cc.delete_visual(state, selected_nodes)
  log.debug(string.format([[#deleted: %s, %s]], #deleted, deleted))
  state:modify_tree(function()
    for _, path in ipairs(deleted) do
      state:remove_node_recursive(path:tostring())
    end
  end)
  renderer.redraw(state)
end

M.nowrap.expand_all_nodes = function(state, node)
  if node == nil then
    node = state.tree:get_node(state.path)
  end
  cc.expand_all_nodes(state, node, fs.prefetcher)
end

---Shows the filter input, which will filter the tree.
M.nowrap.filter_as_you_type = function(state)
  filter.show_filter(state, true)
end

---Shows the filter input, which will filter the tree.
M.nowrap.filter_on_submit = function(state)
  filter.show_filter(state, false)
end

---Shows the filter input in fuzzy finder mode.
M.nowrap.fuzzy_finder = function(state)
  filter.show_filter(state, true, true)
end

---Shows the filter input in fuzzy finder mode.
M.nowrap.fuzzy_finder_directory = function(state)
  filter.show_filter(state, true, "directory")
end

---Shows the filter input in fuzzy sorter
M.nowrap.fuzzy_sorter = function(state)
  filter.show_filter(state, true, true, true)
end

---Shows the filter input in fuzzy sorter with only directories
M.nowrap.fuzzy_sorter_directory = function(state)
  filter.show_filter(state, true, "directory", true)
end

---Navigate up one level.
M.nowrap.navigate_up = function(state)
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

M.nowrap.next_git_modified = function(state)
  focus_next_git_modified(state, false)
end

M.nowrap.prev_git_modified = function(state)
  focus_next_git_modified(state, true)
end

M.nowrap.open = function(state)
  cc.open(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_split = function(state)
  cc.open_split(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_rightbelow_vs = function(state)
  cc.open_rightbelow_vs(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_leftabove_vs = function(state)
  cc.open_leftabove_vs(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_vsplit = function(state)
  cc.open_vsplit(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_tabnew = function(state)
  cc.open_tabnew(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_drop = function(state)
  cc.open_drop(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.open_tab_drop = function(state)
  cc.open_tab_drop(state, utils.wrap(fs.toggle_directory, state))
end

M.nowrap.open_with_window_picker = function(state)
  cc.open_with_window_picker(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.split_with_window_picker = function(state)
  cc.split_with_window_picker(state, utils.wrap(fs.toggle_directory, state))
end
M.nowrap.vsplit_with_window_picker = function(state)
  cc.vsplit_with_window_picker(state, utils.wrap(fs.toggle_directory, state))
end

M.nowrap.refresh = refresh

M.nowrap.rename = function(state)
  cc.rename(state, utils.wrap(refresh, state))
end

M.nowrap.set_root = function(state)
  local tree = state.tree
  local node = tree:get_node()
  if node.type == "directory" then
    if state.search_pattern then
      fs.reset_search(state, false)
    end
    fs._navigate_internal(state, node.id, nil, nil, false)
  end
end

---Toggles whether hidden files are shown or not.
M.nowrap.toggle_hidden = function(state)
  state.filtered_items.visible = not state.filtered_items.visible
  log.info("Toggling hidden files: " .. tostring(state.filtered_items.visible))
  refresh(state)
end

---Toggles whether the tree is filtered by gitignore or not.
M.nowrap.toggle_gitignore = function(state)
  log.warn("`toggle_gitignore` has been removed, running toggle_hidden instead.")
  M.toggle_hidden(state)
end

---@param state NeotreeFiletree
M.nowrap.toggle_node = function(state)
  cc.toggle_node(state, function(node)
    state:toggle_directory(node, node.pathlib, false)
  end)
end

M:_add_common_commands()

return M:_compile()
