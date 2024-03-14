--This file should contain all commands meant to be used by mappings.

local vim = vim
local fs_actions = require("neo-tree.sources.filesystem.lib.fs_actions")
local fs = require("neo-tree.sources.base.lib.fs_actions")
local utils = require("neo-tree.utils")
local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local inputs = require("neo-tree.ui.inputs")
local popups = require("neo-tree.ui.popups")
local log = require("neo-tree.log")
local help = require("neo-tree.sources.common.help")
local Preview = require("neo-tree.sources.common.preview")
local async = require("plenary.async")
local node_expander = require("neo-tree.sources.common.node_expander")
local Path = require("pathlib")
local nio = require("neo-tree.utils.nio_wrapper")

---Gets the node parent folder
---@param state NeotreeState to look for nodes
---@return NuiTreeNode|nil node
local function get_folder_node(state)
  local node = state.tree:get_node()
  local last_id = node and node:get_id()

  while node do
    local insert_as_local = state.config.insert_as
    local insert_as_global = state.window.insert_as
    local use_parent = insert_as_global == "sibling"
    use_parent = insert_as_local and insert_as_local == "sibling"

    local is_open_dir = node.type == "directory" and (node:is_expanded() or node.empty_expanded)
    if use_parent and not is_open_dir then
      return state.tree:get_node(node:get_parent_id())
    end

    if node.type == "directory" then
      return node
    end

    local parent_id = node:get_parent_id()
    if not parent_id or parent_id == last_id then
      return node
    else
      last_id = parent_id
      node = state.tree:get_node(parent_id)
    end
  end
end

---The using_root_directory is used to decide what part of the filename to show
-- the user when asking for a new filename to e.g. create, copy to or move to.
---@param state NeotreeState # The state of the source
---@return string # The root path from which the relative source path should be taken
local function get_using_root_directory(state)
  -- default to showing only the basename of the path
  local root_dir = get_folder_node(state)
  local using_root_directory = root_dir and root_dir:get_id()
  local show_path = state.config.show_path
  if show_path == "absolute" then
    using_root_directory = ""
  elseif show_path == "relative" then
    using_root_directory = state.dir:tostring()
  elseif show_path ~= nil and show_path ~= "none" then
    log.warn(
      'A neo-tree mapping was setup with a config.show_path option with invalid value: "'
        .. show_path
        .. '", falling back to its default: nil/"none"'
    )
  end
  return tostring(using_root_directory)
end

---A table to register sync and async functions.
---@class NeotreeCommonCommands
---@field __additional_command_regex string[]|nil
local M = setmetatable({}, {
  __index = function(tbl, key)
    if key == "call" then
      rawset(tbl, "call", function(cb, ...)
        if cb then
          cb(...)
        else
          return ...
        end
      end)
      return tbl.call
    end
    return nil
  end,
})
M.__index = M
---@class NeotreeCommonCommands
M.nowrap = {}
---@class NeotreeCommonCommands
M.wrap1 = {}
---@class NeotreeCommonCommands
M.wrap2 = {}
---@class NeotreeCommonCommands
M.wrap3 = {}
---@class NeotreeCommonCommands
M.wrap4 = {}
---@class NeotreeCommonCommands
M.wrap5 = {}
---@class NeotreeCommonCommands
M.wrap6 = {}
---@class NeotreeCommonCommands
M.wrap7 = {}
---@class NeotreeCommonCommands
M.wrap8 = {}
---@class NeotreeCommonCommands
M.wrap9 = {}

---Add a new file or dir at the current node
---@param state NeotreeState The state of the source
---@param callback function|nil # The callback to call when the command is done. Called with the parent node as the argument.
---@return PathlibPath[] create
---@return NuiTreeNode parent
M.wrap2.add = function(state, callback)
  local node = get_folder_node(state)
  assert(node, "Failed to find current focused node.")
  local add_cb = function(paths)
    return M.call(callback, paths or {}, node)
  end
  return fs.create_node(node.pathlib, state.dir, false, add_cb) or {}, node
end

---Add a new file or dir at the current node
---@param state NeotreeFiletree The state of the source
---@param callback function|nil # The callback to call when the command is done. Called with the parent node as the argument.
---@return PathlibPath[] create
---@return NuiTreeNode parent
M.wrap2.add_directory = function(state, callback)
  local node = get_folder_node(state)
  assert(node, "Failed to find current focused node.")
  local add_cb = function(paths)
    return M.call(callback, paths or {}, node)
  end
  return fs.create_directory(node.pathlib, state.dir, add_cb) or {}, node
end

---Expand all nodes
---@param state table The state of the source
---@param node table A node to expand
---@param prefetcher table|nil an object with two methods `prefetch(state, node)` and `should_prefetch(node) => boolean`
M.nowrap.expand_all_nodes = function(state, node, prefetcher)
  error("DEPRECATED: WIP")
  log.debug("Expanding all nodes under " .. node:get_id())
  if prefetcher == nil then
    prefetcher = node_expander.default_prefetcher
  end

  renderer.position.set(state, nil)

  local task = function()
    node_expander.expand_directory_recursively(state, node, prefetcher)
  end
  async.run(task, function()
    log.debug("All nodes expanded - redrawing")
    renderer.redraw(state)
  end)
end

M.nowrap.close_node = function(state, callback)
  local tree = state.tree
  local node = tree:get_node()
  local parent_node = tree:get_node(node:get_parent_id())
  local target_node

  if node:has_children() and node:is_expanded() then
    target_node = node
  else
    target_node = parent_node
  end

  local root = tree:get_nodes()[1]
  local is_root = target_node:get_id() == root:get_id()

  if target_node and target_node:has_children() and not is_root then
    target_node:collapse()
    renderer.redraw(state)
    renderer.focus_node(state, target_node:get_id())
    if
      state.explicitly_opened_directories
      and state.explicitly_opened_directories[target_node:get_id()]
    then
      state.explicitly_opened_directories[target_node:get_id()] = false
    end
  end
end

M.nowrap.close_all_subnodes = function(state)
  local tree = state.tree
  local node = tree:get_node()
  local parent_node = tree:get_node(node:get_parent_id())
  local target_node

  if node:has_children() and node:is_expanded() then
    target_node = node
  else
    target_node = parent_node
  end

  renderer.collapse_all_nodes(tree, target_node:get_id())
  renderer.redraw(state)
  renderer.focus_node(state, target_node:get_id())
  if
    state.explicitly_opened_directories
    and state.explicitly_opened_directories[target_node:get_id()]
  then
    state.explicitly_opened_directories[target_node:get_id()] = false
  end
end

M.nowrap.close_all_nodes = function(state)
  state.explicitly_opened_directories = {}
  renderer.collapse_all_nodes(state.tree)
  renderer.redraw(state)
end

M.nowrap.close_window = function(state)
  renderer.close(state)
end

M.nowrap.toggle_auto_expand_width = function(state)
  if state.window.position == "float" then
    return
  end
  state.window.auto_expand_width = state.window.auto_expand_width == false
  local width = utils.resolve_width(state.window.width)
  if not state.window.auto_expand_width then
    if (state.window.last_user_width or width) >= vim.api.nvim_win_get_width(0) then
      state.window.last_user_width = width
    end
    vim.api.nvim_win_set_width(0, state.window.last_user_width or width)
    state.win_width = state.window.last_user_width
  end
  renderer.redraw(state)
end

---Toggle copy state of a node in `state.clipboard`.
---@param state NeotreeState
---@param node NuiTreeNode
local copy_node_to_clipboard = function(state, node)
  state.clipboard = state.clipboard or {}
  local existing = state.clipboard[node.id]
  if existing and existing.action == "copy" then
    state.clipboard[node.id] = nil
  else
    state.clipboard[node.id] = { action = "copy", node = node }
    log.info("Copied " .. node.name .. " to clipboard")
  end
end

---Marks node as copied, so that it can be pasted somewhere else.
---@param state NeotreeState
---@param callback function|nil
M.wrap2.copy_to_clipboard = function(state, callback)
  local node = state.tree:get_node()
  if not node or node.type == "message" then
    return
  end
  copy_node_to_clipboard(state, node)
  return M.call(callback)
end

---Marks nodes as copied, so that it can be pasted somewhere else.
---@param state NeotreeState
---@param selected_nodes NuiTreeNode[]
---@param callback function|nil
M.wrap3.copy_to_clipboard_visual = function(state, selected_nodes, callback)
  for _, node in ipairs(selected_nodes) do
    if node.type ~= "message" then
      copy_node_to_clipboard(state, node)
    end
  end
  return M.call(callback)
end

---Toggle cut state of a node in `state.clipboard`.
---@param state NeotreeState
---@param node NuiTreeNode
local cut_node_to_clipboard = function(state, node)
  state.clipboard = state.clipboard or {}
  local existing = state.clipboard[node.id]
  if existing and existing.action == "cut" then
    state.clipboard[node.id] = nil
  else
    state.clipboard[node.id] = { action = "cut", node = node }
    log.info("Cut " .. node.name .. " to clipboard")
  end
end

---Marks node as cut, so that it can be pasted (moved) somewhere else.
---@param state NeotreeState
---@param callback function|nil
M.wrap2.cut_to_clipboard = function(state, callback)
  local node = state.tree:get_node()
  if not node or node.type == "message" then
    return
  end
  cut_node_to_clipboard(state, node)
  return M.call(callback)
end

---Marks nodes as cut, so that it can be pasted somewhere else.
---@param state NeotreeState
---@param selected_nodes NuiTreeNode[]
---@param callback function|nil
M.wrap3.cut_to_clipboard_visual = function(state, selected_nodes, callback)
  for _, node in ipairs(selected_nodes) do
    if node.type ~= "message" then
      cut_node_to_clipboard(state, node)
    end
  end
  return M.call(callback)
end

--------------------------------------------------------------------------------
-- Git commands
--------------------------------------------------------------------------------

M.nowrap.git_add_file = function(state)
  local node = state.tree:get_node()
  if node.type == "message" then
    return
  end
  local path = node:get_id()
  local cmd = { "git", "add", path }
  vim.fn.system(cmd)
  events.fire_event(events.GIT_EVENT)
end

M.nowrap.git_add_all = function(state)
  local cmd = { "git", "add", "-A" }
  vim.fn.system(cmd)
  events.fire_event(events.GIT_EVENT)
end

M.nowrap.git_commit = function(state, and_push)
  local width = vim.fn.winwidth(0) - 2
  local row = vim.api.nvim_win_get_height(0) - 3
  local popup_options = {
    relative = "win",
    position = {
      row = row,
      col = 0,
    },
    size = width,
  }

  inputs.input("Commit message: ", "", function(msg)
    local cmd = { "git", "commit", "-m", msg }
    local title = "git commit"
    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 or (#result > 0 and vim.startswith(result[1], "fatal:")) then
      popups.alert("ERROR: git commit", result)
      return
    end
    if and_push then
      title = "git commit && git push"
      cmd = { "git", "push" }
      local result2 = vim.fn.systemlist(cmd)
      table.insert(result, "")
      for i = 1, #result2 do
        table.insert(result, result2[i])
      end
    end
    events.fire_event(events.GIT_EVENT)
    popups.alert(title, result)
  end, popup_options)
end

M.nowrap.git_commit_and_push = function(state)
  M.git_commit(state, true)
end

M.nowrap.git_push = function(state)
  inputs.confirm("Are you sure you want to push your changes?", function(yes)
    if yes then
      local result = vim.fn.systemlist({ "git", "push" })
      events.fire_event(events.GIT_EVENT)
      popups.alert("git push", result)
    end
  end)
end

M.nowrap.git_unstage_file = function(state)
  local node = state.tree:get_node()
  if node.type == "message" then
    return
  end
  local path = node:get_id()
  local cmd = { "git", "reset", "--", path }
  vim.fn.system(cmd)
  events.fire_event(events.GIT_EVENT)
end

M.nowrap.git_revert_file = function(state)
  local node = state.tree:get_node()
  if node.type == "message" then
    return
  end
  local path = node:get_id()
  local cmd = { "git", "checkout", "HEAD", "--", path }
  local msg = string.format("Are you sure you want to revert %s?", node.name)
  inputs.confirm(msg, function(yes)
    if yes then
      vim.fn.system(cmd)
      events.fire_event(events.GIT_EVENT)
    end
  end)
end

--------------------------------------------------------------------------------
-- END Git commands
--------------------------------------------------------------------------------

M.nowrap.next_source = function(state)
  local sources = require("neo-tree").config.sources
  local sources = require("neo-tree").config.source_selector.sources
  local next_source = sources[1]
  for i, source_info in ipairs(sources) do
    if source_info.source == state.name then
      next_source = sources[i + 1]
      if not next_source then
        next_source = sources[1]
      end
      break
    end
  end

  require("neo-tree.command").execute({
    source = next_source.source,
    position = state.current_position,
    action = "focus",
  })
end

M.nowrap.prev_source = function(state)
  local sources = require("neo-tree").config.sources
  local sources = require("neo-tree").config.source_selector.sources
  local next_source = sources[#sources]
  for i, source_info in ipairs(sources) do
    if source_info.source == state.name then
      next_source = sources[i - 1]
      if not next_source then
        next_source = sources[#sources]
      end
      break
    end
  end

  require("neo-tree.command").execute({
    source = next_source.source,
    position = state.current_position,
    action = "focus",
  })
end

local function set_sort(state, label)
  local sort = state.sort or { label = "Name", direction = -1 }
  if sort.label == label then
    sort.direction = sort.direction * -1
  else
    sort.label = label
    sort.direction = -1
  end
  state.sort = sort
end

M.nowrap.order_by_created = function(state)
  set_sort(state, "Created")
  state.sort_field_provider = function(node)
    local stat = utils.get_stat(node)
    return stat.birthtime and stat.birthtime.sec or 0
  end
  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.order_by_modified = function(state)
  set_sort(state, "Last Modified")
  state.sort_field_provider = function(node)
    local stat = utils.get_stat(node)
    return stat.mtime and stat.mtime.sec or 0
  end
  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.order_by_name = function(state)
  set_sort(state, "Name")
  state.sort_field_provider = nil
  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.order_by_size = function(state)
  set_sort(state, "Size")
  state.sort_field_provider = function(node)
    local stat = utils.get_stat(node)
    return stat.size or 0
  end
  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.order_by_type = function(state)
  set_sort(state, "Type")
  state.sort_field_provider = function(node)
    return node.ext or node.type
  end
  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.order_by_git_status = function(state)
  set_sort(state, "Git Status")

  state.sort_field_provider = function(node)
    local git_status_lookup = state.git_status_lookup or {}
    local git_status = git_status_lookup[node.path]
    if git_status then
      return git_status
    end

    if node.filtered_by and node.filtered_by.gitignored then
      return "!!"
    else
      return ""
    end
  end

  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.order_by_diagnostics = function(state)
  set_sort(state, "Diagnostics")

  state.sort_field_provider = function(node)
    local diag = state.diagnostics_lookup or {}
    local diagnostics = diag[node.path]
    if not diagnostics then
      return 0
    end
    if not diagnostics.severity_number then
      return 0
    end
    -- lower severity number means higher severity
    return 5 - diagnostics.severity_number
  end

  require("neo-tree.sources.manager").refresh(state.name)
end

M.nowrap.show_debug_info = function(state)
  print(vim.inspect(state))
end

M.nowrap.show_file_details = function(state)
  local node = state.tree:get_node()
  if node.type == "message" then
    return
  end
  local stat = utils.get_stat(node)
  local left = {}
  local right = {}
  table.insert(left, "Name")
  table.insert(right, node.name)
  table.insert(left, "Path")
  table.insert(right, node:get_id())
  table.insert(left, "Type")
  table.insert(right, node.type)
  if stat.size then
    table.insert(left, "Size")
    table.insert(right, utils.human_size(stat.size))
    table.insert(left, "Created")
    table.insert(right, os.date("%Y-%m-%d %I:%M %p", stat.birthtime.sec))
    table.insert(left, "Modified")
    table.insert(right, os.date("%Y-%m-%d %I:%M %p", stat.mtime.sec))
  end

  local lines = {}
  for i, v in ipairs(left) do
    local line = string.format("%9s: %s", v, right[i])
    table.insert(lines, line)
  end

  popups.alert("File Details", lines)
end

---Pastes all items from the clipboard to the current directory.
---@param state NeotreeState
---@param callback function|nil
---@return NuiTreeNode|nil folder # Node where the files were pasted to. Nil when failed.
---@return PathlibPath[]|nil destinations # List of new paths.
M.nowrap.paste_from_clipboard = function(state, callback)
  if not state.clipboard then
    return M.call(callback)
  end
  local folder_node = get_folder_node(state)
  local folder_id = folder_node and folder_node:get_id()
  if not folder_node or not folder_id then
    log.error("Could not find focused directory.")
    return M.call(callback)
  end
  ---@type PathlibPath
  local folder = folder_node.pathlib
  local paths = vim.tbl_keys(state.clipboard)
  table.sort(paths, function(a, b)
    -- sort shortest paths first to operate on parent nodes first.
    return string.len(a) < string.len(b)
  end)
  local destinations = {} -- remember the last pasted file
  for _, node_id in ipairs(paths) do
    local item = state.clipboard[node_id]
    state.clipboard[node_id] = nil
    local node = state.tree:get_node(node_id)
    local _dest
    if not node then
    elseif item.action == "copy" then
      _, _dest = fs.copy_node(node.pathlib, folder / node.name)
    elseif item.action == "cut" then
      _, _dest = fs.move_node(node.pathlib, folder / node.name)
    end
    if _dest then
      table.insert(destinations, _dest)
    end
  end
  state.clipboard = nil
  return M.call(callback, folder_node, destinations)
end

---Copies a node to a new location, using typed input.
---@param state NeotreeState # The state of the source
---@param callback function|nil
---@return PathlibPath|nil source # nil if source not found (operated on `node.type == "message"` etc).
---@return PathlibPath|nil destination # nil if copy failed.
M.wrap2.copy = function(state, callback)
  local tree = state.tree
  local node = tree and tree:get_node()
  if not node then
    return nil
  end
  if node.type == "message" then
    return nil
  end
  local using_root_directory = Path(get_using_root_directory(state))
  return fs.copy_node(node.pathlib, nil, using_root_directory, callback)
end

---Moves a node to a new location, using typed input.
---@param state NeotreeState # The state of the source
---@param callback function|nil
---@return PathlibPath|nil source # nil if source not found (operated on `node.type == "message"` etc).
---@return PathlibPath|nil destination # nil if move failed.
M.wrap2.move = function(state, callback)
  local tree = state.tree
  local node = tree and tree:get_node()
  if not node then
    return nil
  end
  if node.type == "message" then
    return nil
  end
  local using_root_directory = Path(get_using_root_directory(state))
  return fs.move_node(node.pathlib, nil, using_root_directory, callback)
end

---Delete items from tree. Only compatible with file system trees.
---@param state NeotreeState
---@param callback function|nil # The callback to call when the command is done. Called with the parent node as the argument.
---@return PathlibPath[]
M.wrap2.delete = function(state, callback)
  local node = state.tree:get_node()
  if node and (node.type == "file" or node.type == "directory") then
    return fs.delete_node(node.pathlib, false, callback)
  else
    log.warn("The `delete` command can only be used on files and directories.")
    return M.call(callback, {})
  end
end

---Delete items from tree. Only compatible with file system trees.
---@param state NeotreeState
---@param selected_nodes NuiTreeNode[]
---@param callback function|nil # The callback to call when the command is done. Called with the parent node as the argument.
M.wrap3.delete_visual = function(state, selected_nodes, callback)
  log.time_it("delete_visual")
  local paths_to_delete = {}
  for _, node in pairs(selected_nodes) do
    if node.type == "file" or node.type == "directory" then
      table.insert(paths_to_delete, node.pathlib)
    end
  end
  return fs.delete_nodes(paths_to_delete, callback)
end

M.nowrap.preview = function(state)
  Preview.show(state)
end

M.nowrap.revert_preview = function()
  Preview.hide()
end
--
-- Multi-purpose function to back out of whatever we are in
M.nowrap.cancel = function(state)
  if Preview.is_active() then
    Preview.hide()
  else
    if state.current_position == "float" then
      renderer.close_all_floating_windows()
    end
  end
end

M.nowrap.toggle_preview = function(state)
  Preview.toggle(state)
end

M.nowrap.focus_preview = function()
  Preview.focus()
end

---Expands or collapses the current node.
---@param state NeotreeState
---@param toggle_directory fun(node: NuiTree.Node)
M.nowrap.toggle_node = function(state, toggle_directory)
  log.time_it("common toggle_node")
  local node = state.tree:get_node()
  if not node or not utils.is_expandable(node) then
    log.time_it("not expandable")
    return
  end
  if node.type == "directory" and toggle_directory then
    log.time_it("do toggle_directory")
    toggle_directory(node)
  elseif node:has_children() then
    local updated = false
    if node:is_expanded() then
      updated = node:collapse()
    else
      updated = node:expand()
    end
    if updated then
      renderer.redraw(state)
    end
  end
end

---Expands or collapses the current node.
M.nowrap.toggle_directory = function(state, toggle_directory)
  local tree = state.tree
  local node = tree:get_node()
  if node.type ~= "directory" then
    return
  end
  M.toggle_node(state, toggle_directory)
end

---Open file or directory
---@param state table The state of the source
---@param open_cmd string The vim command to use to open the file
---@param toggle_directory function The function to call to toggle a directory
---open/closed
local open_with_cmd = function(state, open_cmd, toggle_directory, open_file)
  local tree = state.tree
  local success, node = pcall(tree.get_node, tree)
  if node.type == "message" then
    return
  end
  if not (success and node) then
    log.debug("Could not get node.")
    return
  end

  local function open()
    M.revert_preview()
    local path = node.path or node:get_id()
    local bufnr = node.extra and node.extra.bufnr
    if node.type == "terminal" then
      path = node:get_id()
    end
    if type(open_file) == "function" then
      open_file(state, path, open_cmd, bufnr)
    else
      utils.open_file(state, path, open_cmd, bufnr)
    end
    local extra = node.extra or {}
    local pos = extra.position or extra.end_position
    if pos ~= nil then
      vim.api.nvim_win_set_cursor(0, { (pos[1] or 0) + 1, pos[2] or 0 })
      vim.api.nvim_win_call(0, function()
        vim.cmd("normal! zvzz") -- expand folds and center cursor
      end)
    end
  end

  local config = state.config or {}
  if node.type ~= "directory" and config.no_expand_file ~= nil then
    log.warn("`no_expand_file` options is deprecated, move to `expand_nested_files` (OPPOSITE)")
    config.expand_nested_files = not config.no_expand_file
  end
  if node.type == "directory" then
    M.toggle_node(state, toggle_directory)
  elseif node:has_children() and config.expand_nested_files and not node:is_expanded() then
    M.toggle_node(state, toggle_directory)
  else
    open()
  end
end

---Open file or directory in the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open = function(state, toggle_directory)
  open_with_cmd(state, "e", toggle_directory)
end

---Open file or directory in a split of the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_split = function(state, toggle_directory)
  open_with_cmd(state, "split", toggle_directory)
end

---Open file or directory in a vertical split of the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_vsplit = function(state, toggle_directory)
  open_with_cmd(state, "vsplit", toggle_directory)
end

---Open file or directory in a right below vertical split of the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_rightbelow_vs = function(state, toggle_directory)
  open_with_cmd(state, "rightbelow vs", toggle_directory)
end

---Open file or directory in a left above vertical split of the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_leftabove_vs = function(state, toggle_directory)
  open_with_cmd(state, "leftabove vs", toggle_directory)
end

---Open file or directory in a new tab
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_tabnew = function(state, toggle_directory)
  open_with_cmd(state, "tabnew", toggle_directory)
end

---Open file or directory or focus it if a buffer already exists with it
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_drop = function(state, toggle_directory)
  open_with_cmd(state, "drop", toggle_directory)
end

---Open file or directory in new tab or focus it if a buffer already exists with it
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.nowrap.open_tab_drop = function(state, toggle_directory)
  open_with_cmd(state, "tab drop", toggle_directory)
end

---Rename a node to a new location, using typed input.
---@param state NeotreeState # The state of the source
---@param callback function|nil
---@return PathlibPath|nil source # nil if source not found (operated on `node.type == "message"` etc).
---@return PathlibPath|nil destination # nil if move failed.
M.wrap2.rename = function(state, callback)
  error("DEPRECATED: use `move` instead.")
  local tree = state.tree
  local node = tree and tree:get_node()
  if not node then
    return nil
  end
  if node.type == "message" then
    return nil
  end
  local using_root_directory = Path(get_using_root_directory(state))
  return fs.move_node(node.pathlib, nil, using_root_directory, callback)
end

---Marks potential windows with letters and will open the give node in the picked window.
---@param state table The state of the source
---@param path string The path to open
---@param cmd string Command that is used to perform action on picked window
local use_window_picker = function(state, path, cmd)
  local success, picker = pcall(require, "window-picker")
  if not success then
    print(
      "You'll need to install window-picker to use this command: https://github.com/s1n7ax/nvim-window-picker"
    )
    return
  end
  local events = require("neo-tree.events")
  local event_result = events.fire_event(events.FILE_OPEN_REQUESTED, {
    state = state,
    path = path,
    open_cmd = cmd,
  }) or {}
  if event_result.handled then
    events.fire_event(events.FILE_OPENED, path)
    return
  end
  local picked_window_id = picker.pick_window()
  if picked_window_id then
    vim.api.nvim_set_current_win(picked_window_id)
    local result, err = pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(path))
    if result or err == "Vim(edit):E325: ATTENTION" then
      -- fixes #321
      vim.api.nvim_buf_set_option(0, "buflisted", true)
      events.fire_event(events.FILE_OPENED, path)
    else
      log.error("Error opening file:", err)
    end
  end
end

---Marks potential windows with letters and will open the give node in the picked window.
M.nowrap.open_with_window_picker = function(state, toggle_directory)
  open_with_cmd(state, "edit", toggle_directory, use_window_picker)
end

---Marks potential windows with letters and will open the give node in a split next to the picked window.
M.nowrap.split_with_window_picker = function(state, toggle_directory)
  open_with_cmd(state, "split", toggle_directory, use_window_picker)
end

---Marks potential windows with letters and will open the give node in a vertical split next to the picked window.
M.nowrap.vsplit_with_window_picker = function(state, toggle_directory)
  open_with_cmd(state, "vsplit", toggle_directory, use_window_picker)
end

M.nowrap.show_help = function(state)
  local title = state.config and state.config.title or nil
  local prefix_key = state.config and state.config.prefix_key or nil
  help.show(state, title, prefix_key)
end

---Adds all missing common commands to the given module
---@deprecated Use `self:_add_parent_commands(pattern)` instead.
---@param pattern string? A pattern specifying which commands to add, nil to add all
function M:_add_common_commands(pattern)
  -- for name, func in pairs(M.sync) do
  --   if
  --     type(name) == "string"
  --     and not to_source_command_module[name]
  --     and (not pattern or name:find(pattern))
  --     and not name:find("^_")
  --   then
  --     to_source_command_module[name] = func
  --   end
  -- end
  self:_add_parent_commands(pattern)
end

---Adds all missing common commands to the given module
---@param pattern string? A pattern specifying which commands to add, nil to add all
function M:_add_parent_commands(pattern)
  if not self.__additional_command_regex then
    self.__additional_command_regex = {}
  end
  table.insert(self.__additional_command_regex, pattern or ".*")
end

function M:_copy_from_parent()
  if self == M then
    return
  end
  local function name_in_regex_list(name)
    if self.__additional_command_regex == nil then
      return false
    end
    for _, regex in ipairs(self.__additional_command_regex) do
      if string.find(name, regex) then
        return true
      end
    end
  end
  local meta_t = getmetatable(self).__index
  for _, key in ipairs(vim.tbl_keys(meta_t)) do
    if not vim.startswith(key, "_") then
      if name_in_regex_list(key) then
        self[key] = meta_t[key]
      else
        self[key] = nil
        -- self[key] = function()
        --   local e = "Command '%s' is not available. Please revisit the document or submit an issue."
        --   log.error(string.format(e, key))
        -- end
      end
    end
  end
end

function M:_compile()
  self:_copy_from_parent()
  for name, func in pairs(self.nowrap) do
    self[name] = func
  end
  self.nowrap = nil
  local keys = vim.tbl_filter(function(key)
    return vim.startswith(key, "wrap") and (pcall(tonumber, key:sub(string.len("wrap") + 1)))
  end, vim.tbl_keys(self))
  for _, args in ipairs(keys) do
    local argc = tonumber(args:sub(string.len("wrap") + 1))
    for name, func in pairs(self[args] or {}) do
      self[name] = require("neo-tree.utils.nio_wrapper").wrap(func, argc, { strict = true })
    end
    self[args] = nil
  end
  return self
end

return M:_compile()
