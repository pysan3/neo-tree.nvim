local Path = require("pathlib")
local pathlib_git = require("pathlib.git")
local nio = require("neo-tree.utils.nio_wrapper")
local utils = require("neo-tree.utils")
local fs_scan = require("neo-tree.sources.filesystem.lib.fs_scan")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local git = require("neo-tree.git")
local glob = require("neo-tree.sources.filesystem.lib.globtopattern")
local PathTree = require("neo-tree.sources.filetree.path_tree")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")
local highlights = require("neo-tree.ui.highlights")
local renderer = require("neo-tree.ui.renderer")

---@alias NeotreeStateId string

---@alias NeotreeNodeId string

---@class NeotreeSourceItem
---@field id NeotreeNodeId|nil
---@field line NuiLine|nil
---@field name string|nil
---@field type string|nil
---@field loaded boolean|nil
---@field filtered_by table|nil
---@field extra table|nil
---@field is_nested boolean|nil
---@field skip_node boolean|nil
---@field skip_in_search boolean|nil
---@field is_empty_with_hidden_root boolean|nil
---@field is_reveal_target boolean|nil
---@field stat uv.aliases.fs_stat_table|nil
---@field stat_provider function|nil
---@field is_link boolean|nil
---@field link_to NeotreePathString|nil
---@field path NeotreePathString|nil
---@field ext string|nil
---@field search_pattern string|nil
---@field level integer|nil
---@field is_last_child boolean|nil
---@field children NeotreeSourceItem[]|nil
---@field pathlib PathlibPath

local locals = {} -- Functions exported for test purposes

---@class NeotreeStateSortInfo
---@field name string|NeotreeSortName # Algorithm name
---@field func NeotreeTypes.sort_function # Sort function
---@field reverse boolean # Whether the sort result should be reversed
---@field one_time boolean|nil # If true, this algorithm will be forgotten when overwritten by other sort function.
---@field force boolean|nil # Force run the sort
---@field __previous NeotreeStateSortInfo|nil # Previous sort method.

---@class NeotreeStateRenderArgs
---@field longest_node integer # Width required to show the longest node.
---@field in_pre_render boolean
---@field remaining_cols integer
---@field group_empty_with string|nil
---@field visual_depth table<NeotreeNodeId, integer>
---@field skipped_nodes table<NeotreeNodeId, string>

---@class NeotreeState
---@field id string # A unique id that represents this state instance.
---@field config NeotreeConfig.source_config
---@field dir PathlibPath # Focused directory. May be ignored in some sources but must be set.
---@field bufnr integer|nil # Buffer this state is attached to.
---@field winid integer|nil # Window id set by manager. Do not trust or change this value.
---@field cursor_update_by_user boolean|nil # Set to true when user moves the cursor during navigation / redraw.
---@field current_position NeotreeWindowPosition # READONLY. Set by manager before `self:navigate`.
---@field position table # See `ui/renderer.lua > position`
---@field scope NeotreeStateScope|nil # Scope of this state.
---@field clipboard table<string, { action: "copy"|"cut" }>|nil # A table which contains the clipboard state.
---@field _workers table<string, nio.tasks.Task[]|{ index: integer, done: integer }>|nil
---@field tree NuiTree|nil # Cache NuiTree if possible.
---@field _tree_lock nio.control.Semaphore|nil
---@field _tree_in_search boolean|nil # True if tree is in search mode.
---@field focused_node string|nil # Node id of focused node if any.
---@field sort_info NeotreeStateSortInfo|nil
---@field render_context NeotreeStateRenderArgs|table # State used in tree.prepare_node(item).
---@field explicitly_opened_directories NeotreeNodeId[]|nil # List that contains all explicitly opened directories.
local Source = setmetatable({
  -- Attributes defined here will be shared across all instances of Manager
  -- Think it as a class attribute, and put caches, const values here.

  name = "state_base_class",
  display_name = "  Invalid ",
  commands = {},
  window = {},
  components = {},
  renderers = {},
  sort_info = { -- default sort method
    func = require("neo-tree.sources.base.sort").pre_defined.id_alphabet,
    name = "id_alphabet",
    reverse = false,
  },
}, {
  __call = function(cls, ...)
    return cls.new(...)
  end,
})
Source.__index = Source

---Create new manager instance or return cache if already created.
---@param config NeotreeConfig.source_config
---@param id string # id of this state passed from `self.setup`.
---@param dir string|nil
function Source.new(config, id, dir)
  local self = setmetatable({
    id = Source.name .. (id or ""),
    config = config,
    dir = dir and Path.new(dir) or Path.cwd(),
    position = { is = { restorable = true } },
  }, Source)
  return self
end

---Calculate the state id that should be used with the given `args`.
---@param args NeotreeManagerSearchArgs
function Source.calculate_state_id(args)
  return args.dir or ""
end

function Source:free_mem()
  -- Deconstructor
  -- Eg clear cache etc.
  local event_ids = {
    "__follow_current_file_",
  }
  for _, prefix in ipairs(event_ids) do
    events.destroy_event({ id = prefix .. self.id })
  end
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                 Draw and Navigate Tree                  │
--          ╰─────────────────────────────────────────────────────────╯

---Prepare for render. And write to buffer.
---@param dir PathlibPath # Directory to work with. Mostly `cwd`.
---@param path_to_reveal PathlibPath|nil # Reveal and focus on this file on startup.
---@param window_width integer # Default window width.
---@param manager NeotreeManager # Call `manager.done(self, request_window_width)` after buffer is ready.
---@param failed_args table # Optional args that map be passed from a different state on fail.
function Source:navigate(dir, path_to_reveal, window_width, manager, failed_args)
  if false then -- Any reason this state cannot handle the navigate request.
    local new_id = "new" -- Point to the state.id that should be able to handle this request.
    local reason = string.format("dir %s is not supported.", dir) -- If new_id is nil, this reason will be reported to the user.
    failed_args.memory = "whatever" -- Set any additional options that will be passed to the next `new_state:navigate`
    return manager:fail(reason, new_id, self, dir, path_to_reveal, window_width, failed_args)
  end
  if not self.bufnr then
    self.bufnr = vim.api.nvim_create_buf(false, false)
  end
  local items = {} -- fill in the items here.
  self:show_nodes(items, self.tree, nil, nil)
  if path_to_reveal then
    self:focus_node(path_to_reveal:tostring())
  end
  nio.run(function()
    self:redraw(manager, window_width)
  end, function(success, err)
    -- callback: called right after the above async function is finished.
    log.time_it(string.format("self:redraw: fail: %s, err: %s", not success, err))
  end)
end

---Redraw the tree without relaoding from the source.
---@param manager NeotreeManager # Call done when you are done.
---@param window_width integer # Default window width.
---@param curpos NeotreeCursorPos|nil
function Source:redraw(manager, window_width, curpos)
  local acquired = false
  self:cancel_all_tasks("render_tree")
  -- start new render
  self:add_task(
    function()
      if self.focused_node then
        self:focus_node(self.focused_node)
        log.time_it("focused_node:", self.focused_node)
      else
        log.time_it("no focus node")
      end
      local group_with = self.config.group_empty_dirs and Path.sep_str or nil
      self:prepare_rendar_args(window_width, self.window.auto_expand_width, group_with)
      self._tree_lock.acquire()
      acquired = true
      log.time_it("tree mutex acquired")
      nio.scheduler()
      renderer.position.save(self)
      self.cursor_update_by_user = false
      self:start_cursor_monitor()
      self:render_tree(self.tree)
      log.time_it("render_tree done")
      if self.focused_node and not curpos then
        local node, linenr = self.tree:get_node(self.focused_node)
        if node and linenr then
          curpos = { lnum = linenr, col = string.len(node.indent or "") }
          local _msg = "focus node: %s, linenr: %s, curpos: %s"
          log.fmt_trace(_msg, node:get_id(), linenr, vim.inspect(curpos))
        end
      else
        log.time_it("no focus node:", self.focused_node)
        log.time_it("no focus node:", curpos)
      end
      manager:done(self, self.render_context.longest_node, curpos)
    end,
    "render_tree",
    function(success)
      log.time_it(string.format("%s redraw success: %s, acquired: %s", self.id, success, acquired))
      if success then
        self.focused_node = nil
      end
      return acquired and self._tree_lock.release()
    end
  )
end

---Render tree to `self.bufnr`
---@param tree NuiTree
---@param linenr_start integer|nil # Line number to start rendering from. Defaults to 1 (top line).
---@return integer request_window_width
function Source:render_tree(tree, linenr_start)
  tree.bufnr = self.bufnr -- double check bufnr is set correctly
  local old_longest_node = self.render_context.longest_node
  if self.render_context.in_pre_render then
    tree:render(linenr_start)
    self.render_context.in_pre_render = false
    if old_longest_node >= self.render_context.longest_node then
      -- Current tree fits into the width. No need to rerender.
      log.time_it("tree fits length in pre_render:", old_longest_node)
      return old_longest_node
    else
      self.render_context.remaining_cols = self.render_context.longest_node
      log.time_it("not enough length. rerender:", self.render_context.remaining_cols)
    end
  end
  tree:render(linenr_start)
  return self.render_context.longest_node
end

---@param ns_id integer|nil # Highlight namespace id. If nil, uses neo-tree's default namespace.
---@param prepare_node_func (fun(node: NuiTree.Node): NuiLine[])|nil # Prepare node function. Defaults to `Source.prepare_node`
function Source:prepare_tree(ns_id, prepare_node_func)
  if not self.bufnr then
    self.bufnr = vim.api.nvim_create_buf(false, false)
  end
  if not self.tree then
    self.tree = NuiTree({
      ns_id = ns_id or highlights.ns_id,
      bufnr = self.bufnr,
      get_node_id = function(node)
        return node.id
      end,
      prepare_node = prepare_node_func or function(data)
        return self:prepare_node(data)
      end,
    })
  end
end

---@param window_width integer # Default window width.
---@param do_pre_render boolean|nil # Whether to pre_render to find longest node for auto_expand.
---@param group_empty_with string|nil
function Source:prepare_rendar_args(window_width, do_pre_render, group_empty_with)
  self.render_context = {
    longest_node = window_width,
    in_pre_render = do_pre_render or false,
    remaining_cols = window_width,
    group_empty_with = group_empty_with,
    visual_depth = {},
    skipped_nodes = {},
  }
end

---Create a NuiLine from data of each NuiTree.Node
---@param item NuiTreeNode|NeotreeSourceItem
---@return NuiLine|nil
function Source:prepare_node(item)
  if item.skip_node or (self._tree_in_search and item.skip_in_search) then
    if item.is_empty_with_hidden_root then
      local line = NuiLine()
      line:append("(empty folder)", highlights.MESSAGE)
      return line
    else
      return nil
    end
  end
  local parent_id = item:get_parent_id()
  local parent_depth = parent_id and self.render_context.visual_depth[parent_id] or 0
  if self.render_context.group_empty_with then
    if
      parent_depth > 0 -- skip root dir from being grouped
      and item.type == "directory"
      and locals.node_group_with_dirs(self.tree, item:get_id(), self._tree_in_search)
    then
      self.render_context.visual_depth[item:get_id()] = parent_depth
      local skipped_parents = self.render_context.skipped_nodes[parent_id] or ""
      self.render_context.skipped_nodes[parent_id or ""] = nil
      self.render_context.skipped_nodes[item:get_id()] = skipped_parents
        .. item.name
        .. self.render_context.group_empty_with
      return nil
    end
  end
  self.render_context.visual_depth[item:get_id()] = parent_depth + 1
  -- Generate line using `NeotreeComponent` in `self.renderers`.
  local line = NuiLine()
  local rndr = self.config.renderers[item.type]
  if not rndr then
    line:append(item.type .. ": ", "Comment")
    line:append(item.name)
    return line
  end
  item.wanted_width = 0
  local remaining_cols = self.render_context.remaining_cols
  local should_pad = false
  for _, component in ipairs(rndr) do
    if component.enabled ~= false then
      local datas, wanted_width = renderer.render_component(component, item, self, remaining_cols)
      if datas then
        local actual_width = 0
        for _, data in ipairs(datas) do
          if data.text then
            local padding = ""
            if should_pad and #data.text and data.text:sub(1, 1) ~= " " and not data.no_padding then
              padding = " "
            end
            data.text = padding .. data.text
            should_pad = data.text:sub(#data.text) ~= " " and not data.no_next_padding
            actual_width = actual_width + vim.api.nvim_strwidth(data.text)
            line:append(data.text, data.highlight)
            remaining_cols = remaining_cols - vim.fn.strchars(data.text)
          end
        end
        item.wanted_width = item.wanted_width + (wanted_width or actual_width)
      end
    end
  end
  if self.render_context.in_pre_render and item.wanted_width > self.render_context.longest_node then
    self.render_context.longest_node = item.wanted_width
  end
  return line
end

---Check if node does not have any children or all children are `node.skip_node`.
---@param tree NuiTree
---@param node_id NeotreeNodeId
function locals.node_is_empty(tree, node_id)
  local node = tree:get_node(node_id)
  if not node or not node:has_children() then
    return true
  end
  local count = 0
  for _, child in ipairs(tree:get_nodes(node_id)) do
    if not child.skip_node then
      if count > 0 then
        return false
      end
      count = count + 1
    end
  end
  return true
end

---Check if node has single child that is not `node.skip_node`, group_with_dirs.
---@param tree NuiTree
---@param node_id NeotreeNodeId
---@param in_search boolean # Tree is in search mode.
function locals.node_group_with_dirs(tree, node_id, in_search)
  local node = tree:get_node(node_id)
  if not node or not node:has_children() then
    return false
  end
  local count, is_dir = 0, false
  for _, child in ipairs(tree:get_nodes(node_id)) do
    if not child.skip_node and not (in_search and child.skip_in_search) then
      count = count + 1
      is_dir = child.type == "directory"
      if count > 1 then
        return false
      end
    end
  end
  return count == 1 and is_dir
end

---Assign `source_items` to `tree` and render at `self.bufnr`.
---@param source_items NeotreeSourceItem[]|nil # If all are NuiNodes already, uses them directly.
---@param tree NuiTree
---@param parent_id string|nil # Insert items as children of this parent. If nil, inserts to root.
---Separator to compose nodes into one line if node has exactly one child.
---If nil, does not group dirs.
---@return integer request_window_width
function Source:show_nodes(source_items, tree, parent_id)
  local parent_level = 0 -- default when `parent_id` is not found.
  if parent_id then
    local suc, parent = pcall(tree.get_node, tree, parent_id)
    if suc and parent then
      parent_level = parent:get_depth()
    end
  end
  local visibility = {}
  -- HACK: Special code to work with filesystem source, and keep backwards compatibility.
  ---@diagnostic disable start
  if self.config.filtered_items then
    visibility.all_files = self.config.filtered_items.visible
    visibility.in_empty_folder = self.config.filtered_items.force_visible_in_empty_folder
  end
  ---@diagnostic disable end
  local expanded_node_ids = locals.get_node_id_list(tree, "bfs", parent_id, function(node)
    return node:is_expanded()
  end)
  -- draw the given nodes
  if source_items and #source_items > 0 then
    local nodes = locals.convert(source_items, visibility, parent_level)
    local success, msg = pcall(tree.set_nodes, tree, nodes, parent_id)
    if not success then
      log.error("Error setting nodes: ", msg)
      log.error(vim.inspect(tree:get_nodes()))
    end
  end
  for _, node_id in ipairs(expanded_node_ids) do
    local node = tree:get_node(node_id)
    if node then
      node:expand()
    end
  end
  -- Always expand top level
  for _, node in ipairs(tree:get_nodes(parent_id)) do
    node.loaded = true
    node:expand()
  end
end

function Source:start_cursor_monitor()
  vim.api.nvim_create_autocmd("CursorMoved", {
    once = true,
    desc = "Neo-tree: monitor cursor movement from user.",
    buffer = self.bufnr,
    callback = function()
      if vim.api.nvim_get_current_buf() == self.bufnr then
        self.cursor_update_by_user = true
      end
    end,
  })
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                       Modify Tree                       │
--          ╰─────────────────────────────────────────────────────────╯

---Fill tree until depth.
---@async
---@param parent_id string|nil # The node id of where to start from. If nil, uses the root node.
---@param depth integer|nil # Depth to dig into. If nil, goes all the way.
---@param reveal_path PathlibPath|nil # Ignores depth limit and digs until this path.
function Source:fill_tree(parent_id, depth, reveal_path)
  error("Not Implemented")
end

---Run callback with a mutex to `self.tree` so it is safe to modify.
---@generic T
---@param cb fun(tree: NuiTree): T|nil
---@return T|nil
function Source:modify_tree(cb)
  if not self._tree_lock then
    self._tree_lock = nio.semaphore(1)
  end
  self._tree_lock.acquire()
  local result = { pcall(cb, self.tree) }
  self._tree_lock.release()
  if not result[1] then
    error(unpack(result, 2))
  end
  return unpack(result, 2)
end

---Try to focus node with `node_id`.
---@param node_id string|nil # If nil, does nothing.
function Source:focus_node(node_id)
  if node_id == nil then
    return
  end
  if not vim.startswith(node_id, self.dir:tostring()) then
    return nil
  end
  self:modify_tree(function(tree)
    local node, linenr = self.tree:get_node(node_id)
    if node and not linenr then
      locals.expand_to_node(tree, node)
      self.focused_node = node_id
    end
  end)
  self.focused_node = node_id
end

function locals.expand_to_node(tree, node)
  if node == nil then
    return
  end
  local parent_id = node:get_parent_id()
  if parent_id then
    local parent = tree:get_node(parent_id)
    locals.expand_to_node(tree, parent)
    parent:expand()
  end
end

---Filter items and separate into 2 tables: `visible` and `hidden`.
---@param source_items NeotreeSourceItem[]
---@param no_hide boolean|nil
function locals.remove_filtered(source_items, no_hide)
  local visible = {}
  local hidden = {}
  for _, child in ipairs(source_items) do
    local fby = child.filtered_by
    if type(fby) == "table" and not child.is_reveal_target then
      if not fby.never_show then
        if no_hide or child.is_nested or fby.always_show then
          table.insert(visible, child)
        elseif fby.name or fby.pattern or fby.dotfiles or fby.hidden then
          table.insert(hidden, child)
        elseif fby.show_gitignored and fby.gitignored then
          table.insert(visible, child)
        else
          table.insert(hidden, child)
        end
      end
    else
      table.insert(visible, child)
    end
  end
  return visible, hidden
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                          Node                           │
--          ╰─────────────────────────────────────────────────────────╯

---Remember to explicitly expand a node.
---@param node_id NeotreeNodeId|nil
function Source:explicitly_expand(node_id)
  local node = node_id and self.tree:get_node(node_id)
  if not node_id or not node then
    return
  end
  self.explicitly_opened_directories = self.explicitly_opened_directories or {}
  self.explicitly_opened_directories[node_id] = true
  return node:expand()
end

---Remember to explicitly collapse a node.
---@param node_id NeotreeNodeId|nil
function Source:explicitly_collapse(node_id)
  self.explicitly_opened_directories = self.explicitly_opened_directories or {}
  self.explicitly_opened_directories[node_id or ""] = nil
  local node = node_id and self.tree:get_node(node_id)
  if not node_id or not node then
    return
  end
  return node:collapse()
end

---Register all expanded nodes as explicitly opened.
---@param reset boolean # Reset memory and forget about previous data.
function Source:explicitly_save(reset)
  self.explicitly_opened_directories = not reset and self.explicitly_opened_directories or {}
  for _, node in ipairs(locals.get_node_list(self.tree, "bfs")) do
    if node:is_expanded() then
      self.explicitly_opened_directories[node:get_id()] = true
    else
      self.explicitly_opened_directories[node:get_id()] = nil
    end
  end
end

---Restore all explicitly opened directories.
---@param explicitly_collapse boolean # Force collapse all nodes that are not explicitly opened.
function Source:explicitly_restore(explicitly_collapse)
  if not self.explicitly_opened_directories then
    return
  end
  for _, node in ipairs(locals.get_node_list(self.tree, "bfs")) do
    if self.explicitly_opened_directories[node:get_id()] then
      node:expand()
    elseif explicitly_collapse then
      node:collapse()
    end
  end
end

---Return a list that contains all nodes in the tree recursively.
-- WARNING: Don't forget to free the list afterwards, or it may lead to memory leaks.
-- You may want to use `locals.get_node_id_list` instead.
--
---@param tree NuiTree
---@param parent_id string|nil
---@param filter_func (fun(node: NuiTreeNode): boolean)|nil # Exclude node and its children if this func returns false.
function locals.get_node_table(tree, parent_id, filter_func)
  ---@type table<string, NuiTreeNode>
  local result = {}
  local queue = tree:get_nodes(parent_id)
  local index, max_index = 1, #queue
  while index <= max_index do
    local node = queue[index]
    local node_id = node:get_id()
    queue[index] = nil
    result[node_id] = node
    if node:has_children() then
      local children = tree:get_nodes(node_id)
      for i, child in ipairs(children) do
        if not filter_func or filter_func(child) then
          max_index = max_index + 1
          queue[max_index] = child
        end
      end
    end
    index = index + 1
  end
  return result
end

---Return a list that contains all nodes in the tree recursively.
-- WARNING: Don't forget to free the list afterwards, or it may lead to memory leaks.
-- You may want to use `locals.get_node_id_list` instead.
--
---@param tree NuiTree
---@param algo "bfs"|"dfs" # Breadth first / depth first search
---@param parent_id string|nil
---@param filter_func (fun(node: NuiTreeNode): boolean)|nil # Filter out node if this func returns false.
function locals.get_node_list(tree, algo, parent_id, filter_func)
  local array = require("neo-tree.utils.array").tree_node(unpack(tree:get_nodes(parent_id)))
  local push_func = algo == "dfs" and array.pushleft or array.pushright -- "bfs": queue, "dfs": stack
  ---@type NuiTreeNode[]
  local result = {}
  while array:len() > 0 do
    local node = array:popleft()
    table.insert(result, node)
    if node:has_children() then
      local children = tree:get_nodes(node:get_id())
      local child_length = #children
      for i = 1, child_length do
        local child = algo == "dfs" and children[child_length - i + 1] or children[i] -- push in reverse with "dfs"
        if not filter_func or filter_func(child) then
          push_func(array, child)
        end
      end
    end
  end
  return result
end

---Return a list that contains all node ids in the tree recursively.
---@param tree NuiTree
---@param algo "bfs"|"dfs" # Breadth first / depth first search
---@param parent_id string|nil
---@param filter_func (fun(node: NuiTreeNode): boolean)|nil # Filter out node if this func returns false.
function locals.get_node_id_list(tree, algo, parent_id, filter_func)
  local array = require("neo-tree.utils.array").tree_node(unpack(tree:get_nodes(parent_id)))
  local push_func = algo == "dfs" and array.pushleft or array.pushright -- "bfs": queue, "dfs": stack
  ---@type NeotreeNodeId[]
  local result = {}
  while array:len() > 0 do
    local node = array:popleft()
    table.insert(result, node:get_id())
    if node:has_children() then
      local children = tree:get_nodes(node:get_id())
      local child_length = #children
      for i = 1, child_length do
        local child = algo == "dfs" and children[child_length - i + 1] or children[i] -- push in reverse with "dfs"
        if not filter_func or filter_func(child) then
          push_func(array, child)
        end
      end
    end
  end
  return result
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                       Alter Tree                        │
--          ╰─────────────────────────────────────────────────────────╯

---Deep sort the tree with algorithm. Caches previous sort algorithm so result can be reused when called with
---same algorithm once again.
---When the algorithm is different from previous, deep sort in performed and previous sort is cleared.
---@param algorithm_name string # Give a unique name of the sorting algorithm.
---@param opts NeotreeStateSortInfo # Additional opts for sorting.
---@param sort_function fun(a: NuiTreeNode, b: NuiTreeNode): boolean
---@overload fun(self: NeotreeState, algorithm_name: NeotreeSortName, opts: NeotreeStateSortInfo) # Use pre-defined functions.
function Source:sort_tree(algorithm_name, opts, sort_function)
  local reverse = opts.reverse and true or false
  if not sort_function then
    local pre_defined = require("neo-tree.sources.base.sort").pre_defined
    assert(pre_defined[algorithm_name], algorithm_name .. " is not found in pre-defined.")
    sort_function = pre_defined[algorithm_name]
  end
  local task_name = "__sort_tree_" .. algorithm_name
  if not self.sort_info or self.sort_info.name ~= algorithm_name or opts.force then
    -- deep sort tree
    self:modify_tree(function(tree)
      local node_table = locals.get_node_table(tree)
      for _, node in pairs(node_table) do
        if node:has_children() then
          self:add_task(function()
            self.sort_node(node, node_table, sort_function, reverse)
          end, task_name)
        end
      end
      self:wait_all_tasks(task_name)
    end)
  elseif self.sort_info.name == algorithm_name and self.sort_info.reverse ~= reverse then
    -- reverse tree
    self:modify_tree(function(tree)
      local node_table = locals.get_node_table(tree)
      for _, node in pairs(node_table) do
        if node:has_children() then
          self:add_task(function()
            local n, m = #node._child_ids, #node._child_ids / 2
            for i = 1, m do
              node._child_ids[i], node._child_ids[n - i + 1] =
                node._child_ids[n - i + 1], node._child_ids[i]
            end
          end, task_name)
        end
      end
      self:wait_all_tasks(task_name)
    end)
  elseif self.sort_info.force then
    -- identical but force is true. retry with force enabled
    opts.force = true
    return self:sort_tree(algorithm_name, opts, sort_function)
  else
    return -- identical, do nothing
  end
  self:wait_all_tasks(task_name)
  local prev = self.sort_info
  if self.sort_info and self.sort_info.one_time then
    prev = self.sort_info.__previous
  end
  self.sort_info = {
    name = algorithm_name,
    func = sort_function,
    reverse = reverse,
    one_time = opts.one_time,
    __previous = prev,
  }
end

---Go back to previous sort method.
---The result is not cached, so this will require a deep sort anyways.
function Source:sort_tree_previous()
  local prev = self.sort_info and self.sort_info.__previous or getmetatable(self).sort_info
  if not prev then
    return
  end
  self.sort_info = prev.__previous
  local opts = { reverse = prev.reverse, force = true, one_time = true }
  return self:sort_tree(prev.name, opts, prev.func)
end

---@param node NuiTreeNode
---@param child_lookup table<string, NuiTreeNode>
---@param func NeotreeTypes.sort_function
---@param reverse boolean
function Source.sort_node(node, child_lookup, func, reverse)
  reverse = not not reverse
  table.sort(node._child_ids, function(a, b)
    if not child_lookup[a] or not child_lookup[b] then
      return (not not child_lookup[a]) ~= reverse
    else
      return func(child_lookup[a], child_lookup[b], reverse)
    end
  end)
end

---Initiate a search. Filter down the nodes using external binary if needed, else return all nodes.
---@param term string # User input separated with spaces.
---@param use_fzy boolean # Use fzy to sort results. If false, `term` are treated as glob search and result is not sorted.
---@param file_types NeotreeFindFileTypes|nil
function Source:find_tree(term, use_fzy, file_types)
  assert(false, "WIP")
end

---Execute a search inside the tree.
---@param manager NeotreeManager # Call done when you are done.
---@param window_width integer # Default window width.
---@param term string # User input separated with spaces.
---@param use_fzy boolean # Use fzy to sort results. If false, `term` are treated as glob search and result is not sorted.
---@param file_types NeotreeFindFileTypes|nil
function Source:search_tree(manager, window_width, term, use_fzy, file_types)
  if self.fzy_sort_result_scores and self.fzy_sort_result_scores.__process then
    pcall(self.fzy_sort_result_scores.__process.signal, 15)
    self.fzy_sort_result_scores.__process.result()
  end
  self.fzy_sort_result_scores = {}
  self:find_tree(term, use_fzy, file_types)
  log.time_it("find_tree", term)
  local sort_func = require("neo-tree.sources.base.sort").constructor.by_lookuptable_backpropagate(
    self.fzy_sort_result_scores,
    self.dir.sep_str,
    true
  )
  log.time_it("sort_func", term)
  self:sort_tree("search_tree " .. term, { reverse = true, one_time = true }, sort_func)
  log.time_it("sort_tree", term)
  -- change `node.skip_in_search` and find first file to focus
  local first_node_id = nil
  for _, node in ipairs(locals.get_node_list(self.tree, "dfs")) do
    local score = self.fzy_sort_result_scores[node:get_id()]
    node.skip_in_search = not score or score <= 0
    if not first_node_id and not node.skip_in_search and node.type == "file" then
      first_node_id = node:get_id()
    end
  end
  self:focus_node(first_node_id)
  self:redraw(manager, window_width)
  log.time_it("redraw_tree", term)
end

function Source:search_end()
  self._tree_in_search = false
  if self.sort_info and vim.startswith(self.sort_info.name, "search_tree ") then
    local curpos = vim.api.nvim_win_get_cursor(self.winid)
    local focused_node = self.tree:get_node(curpos[1]) -- get node of cursor line
    self:explicitly_restore(true)
    self:sort_tree_previous()
    self:focus_node(focused_node and focused_node:get_id()) -- and focus it.
  end
  renderer.redraw(self)
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                         Locals                          │
--          ╰─────────────────────────────────────────────────────────╯

---@param source_items NeotreeSourceItem[]|NuiTreeNode[]|nil
---@param visibility { all_files: boolean|nil, in_empty_folder: boolean|nil }
---@param level integer # Node depth from root (=1).
---Separator to compose nodes into one line if node has exactly one child.
---If nil, does not group dirs.
---@deprecated TODO: Move this function to a proper location (eg utils).
function locals.convert(source_items, visibility, level)
  if not source_items then
    return source_items
  end
  ---@type NuiTreeNode[]
  local nodes = {}
  local visible, hidden = locals.remove_filtered(source_items, visibility.all_files)
  if #visible == 0 and visibility.in_empty_folder then
    source_items = hidden
  else
    source_items = visible
  end
  local total_length = #source_items
  for i, item in ipairs(source_items) do
    if item.__name ~= "NuiTree.Node" then
      ---@cast item NeotreeSourceItem
      local nodeData = {
        id = item.id,
        name = item.name,
        type = item.type,
        loaded = item.loaded,
        filtered_by = item.filtered_by,
        extra = item.extra,
        is_nested = item.is_nested,
        skip_node = item.skip_node,
        is_empty_with_hidden_root = item.is_empty_with_hidden_root,
        stat = item.stat,
        stat_provider = item.stat_provider,
        -- TODO: The below properties are not universal and should not be here.
        -- Maybe they should be moved to the "extra" field?
        is_link = item.is_link,
        link_to = item.link_to,
        path = item.path,
        ext = item.ext,
        search_pattern = item.search_pattern,
        level = level,
      }
      local children = locals.convert(item.children, visibility, level + 1)
      -- Group empty dirs
      -- This code is simple since node is not registered to the tree yet.
      -- if group_with and children and #children == 1 and children[1].type == "directory" then
      --   nodeData = children[1]
      --   nodeData.name = item.name .. group_with .. children[1].name
      --   children = nil
      -- end
      item = NuiTree.Node(nodeData, children)
    end
    ---@cast item NuiTreeNode
    item.is_last_child = i == total_length
    if item._is_expanded then
      item:expand()
    end
    table.insert(nodes, item)
  end
  if #hidden > 0 then
    -- TODO: Add (n hidden items...)
    assert(false)
  end
  return nodes
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                       Easy Debug                        │
--          ╰─────────────────────────────────────────────────────────╯

function Source:i_am_a_valid_source()
  -- `Source` is an example. All child classes will be valid neo-tree source
  return self.name ~= Source.name
end

function Source:__debug_visualize_tree(id, indent)
  local nodes = self.tree:get_nodes(id)
  for _, node in ipairs(nodes) do
    print(string.rep(" ", node:get_depth() * (indent or 2)) .. node:get_id())
    local g = node.pathlib and node.pathlib.git_state
    local function tf(bool)
      return bool and " true" or "false"
    end
    if g then
      local st = g.state or {}
      local is_set = g.is_ready and g.is_ready.is_set()
      local msg = "set: %s, ignored: %s, state: (c: %s, s: %s)"
      local x = msg:format(tf(is_set), tf(g.ignored), st.change, st.status)
      local skip = node.skip_node and "(skip)" or ""
      print(string.rep(" ", (node:get_depth() + 1) * (indent or 2)) .. x .. skip)
    end
    self:__debug_visualize_tree(node:get_id(), indent)
  end
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                     Task Management                     │
--          ╰─────────────────────────────────────────────────────────╯

---@param func function # Function called as a nio task. Job will be captured to `batch_name` task list.
---@param batch_name string|nil # Unique name for batch. If nil, refers to global task list.
function Source:add_task(func, batch_name, cb)
  if not self._workers then
    self._workers = {}
  end
  batch_name = batch_name or "__global_workers"
  if not self._workers[batch_name] then
    self._workers[batch_name] = { index = 0, done = 0 }
  end
  local _batch = self._workers[batch_name]
  _batch.index = _batch.index + 1
  _batch[_batch.index] = nio.run(func, cb)
  return _batch[_batch.index]
end

---@param batch_name string|nil # Unique name for batch. If nil, refers to global task list.
---@return integer num_tasks # Number of waiting or running tasks.
function Source:has_task(batch_name, cb)
  if not self._workers then
    return 0
  end
  batch_name = batch_name or "__global_workers"
  if not self._workers[batch_name] then
    return 0
  end
  local _batch = self._workers[batch_name]
  return math.max(_batch.index - _batch.done, 0)
end

---@param batch_name string|nil # Unique name for batch. If nil, refers to global task list.
---@param until_now boolean|nil # If true, only waits tasks registered until this function was called. Otherwise, waits for all tasks registered throughout the instance.
function Source:wait_all_tasks(batch_name, until_now)
  batch_name = batch_name or "__global_workers"
  if not self._workers or not self._workers[batch_name] then
    return
  end
  local _batch = self._workers[batch_name]
  local wait_until = until_now and _batch.index or nil
  -- Block exec until other setups is completed
  local done = nio.wait_all(_batch, _batch.done + 1, wait_until)
  if done == _batch.index then
    self._workers[batch_name] = nil
  elseif done > _batch.done then
    _batch.done = done
  end
end

---@param batch_name string|nil # Unique name for batch. If nil, refers to global task list.
function Source:cancel_all_tasks(batch_name)
  batch_name = batch_name or "__global_workers"
  if not self._workers or not self._workers[batch_name] then
    return
  end
  local _batch = self._workers[batch_name]
  -- Block exec until other setups is completed
  local done = nio.cancel_all(_batch, _batch.done + 1)
  if done == _batch.index then
    self._workers[batch_name] = nil
  elseif done > _batch.done then
    _batch.done = done
  end
end

function Source:assign_future_redraw(future)
  if not future or future.is_set() then
    return
  end
  local name = "__future_redraw_" .. tostring(future)
  if self:has_task(name) == 0 then
    nio.run(function()
      self:add_task(function()
        future.wait()
      end, name)
      self:wait_all_tasks(name)
      renderer.redraw(self)
    end)
  end
end

Source.__locals = locals
return Source
