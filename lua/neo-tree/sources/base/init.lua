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
local ui_rndr = require("neo-tree.ui.renderer")
local renderer = require("neo-tree.ui.renderer")

---@alias NeotreeStateId string

---@class NeotreeSourceItem
---@field id string|nil
---@field line NuiLine|nil
---@field name string|nil
---@field type string|nil
---@field loaded boolean|nil
---@field filtered_by table|nil
---@field extra table|nil
---@field is_nested boolean|nil
---@field skip_node boolean|nil
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

---@class NeotreeStateRenderArgs
---@field longest_node integer # Width required to show the longest node.
---@field in_pre_render boolean
---@field remaining_cols integer
---@field strict boolean

---@class NeotreeState
---@field id string # A unique id that represents this state instance.
---@field config NeotreeConfig.source_config
---@field dir PathlibPath # Focused directory. May be ignored in some sources but must be set.
---@field bufnr integer|nil # Buffer this state is attached to.
---@field cursor_update_by_user boolean|nil # Set to true when user moves the cursor during navigation / redraw.
---@field current_position NeotreeWindowPosition # READONLY. Set by manager before `self:navigate`.
---@field position table # See `ui/renderer.lua > position`
---@field scope NeotreeStateScope|nil # Scope of this state.
---@field _workers table<string, nio.tasks.Task[]|{ index: integer, done: integer }>|nil
---@field tree NuiTree|nil # Cache NuiTree if possible.
---@field _tree_lock nio.control.Semaphore|nil
---@field focused_node string|nil # Node id of focused node if any.
---@field render_args NeotreeStateRenderArgs|table # State used in tree.prepare_node(item).
local Source = setmetatable({
  -- Attributes defined here will be shared across all instances of Manager
  -- Think it as a class attribute, and put caches, const values here.

  name = "state_base_class",
  display_name = "  Invalid ",
  commands = {},
  window = {},
  components = {},
  renderers = {},
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
end

---Prepare for render. And write to buffer.
---@param dir PathlibPath # Directory to work with. Mostly `cwd`.
---@param path_to_reveal PathlibPath|nil # Reveal and focus on this file on startup.
---@param window_width { width: integer, strict: boolean } # Default window width.
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
  -- local should_auto_expand = self.window.auto_expand_width and state.current_position ~= "float"
  -- local should_pre_render = should_auto_expand or state.current_position == "current"
  -- if not self.window.auto_expand_width then
  --   window_width.strict = true
  -- end
  self:prepare_rendar_args(window_width, not window_width.strict)
  local items = {}
  self:show_nodes(items, self.tree, nil, self.config.group_empty_dirs and Path.sep_str or nil)
end

---Redraw the tree without relaoding from the source.
---@param manager NeotreeManager # Call done when you are done.
---@param request_window_width integer|nil
---@param curpos NeotreeCursorPos|nil
function Source:redraw(manager, request_window_width, curpos)
  nio.elapsed("inside source:redraw", manager.__timer_start)
  self:add_task(
    function()
      nio.elapsed("inside add_task", manager.__timer_start)
      if self.focused_node then
        self:focus_node(self.focused_node)
        nio.elapsed("is focused node", manager.__timer_start)
      end
      self._tree_lock.acquire()
      nio.elapsed("inside modify_tree", manager.__timer_start)
      vim.schedule(function()
        renderer.position.save(self)
        nio.elapsed("position save: " .. vim.inspect(self.position), manager.__timer_start)
        self:render_tree(self.tree)
        nio.elapsed("after render_tree", manager.__timer_start)
        self._tree_lock.release()
      end)
      self:modify_tree(function()
        nio.elapsed("tree recaptured", manager.__timer_start)
      end)
    end,
    "render_tree",
    function(success)
      if not success then
        vim.schedule(function()
          vim.print("render_tree failed")
        end)
      end
      self._tree_lock.release()
    end
  )
  nio.run(function()
    nio.elapsed("start watching for render_tree", manager.__timer_start)
    self:wait_only_last_task("render_tree")
    nio.elapsed("last render_tree task done", manager.__timer_start)
    if self.focused_node and not curpos then
      local node, linenr = self.tree:get_node(self.focused_node)
      nio.elapsed("is curpos and get node", manager.__timer_start)
      nio.elapsed("focused_node: " .. (self.focused_node or nil), manager.__timer_start)
      if node and linenr then
        curpos = { lnum = linenr, col = string.len(node.indent or "") }
        nio.elapsed(
          string.format(
            [[node: %s, linenr: %s, curpos: %s]],
            node:get_id(),
            linenr,
            vim.inspect(curpos)
          ),
          manager.__timer_start
        )
        self.focused_node = nil
        nio.elapsed("curpos found", manager.__timer_start)
      end
    end
    manager:done(self, request_window_width or self.render_args.longest_node, curpos)
  end)
end

function Source:focus_node(node_id)
  self:modify_tree(function(tree)
    local node, linenr = self.tree:get_node(node_id)
    if not node then
      log.error("node %s not found.", node_id)
      self.focused_node = node_id
    end
    if not linenr then
      locals.expand_to_node(tree, node)
      self.focused_node = node_id
    end
  end)
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

---Assign `source_items` to `tree` and render at `self.bufnr`.
---@param source_items NeotreeSourceItem[]|nil # If all are NuiNodes already, uses them directly.
---@param tree NuiTree
---@param parent_id string|nil # Insert items as children of this parent. If nil, inserts to root.
---Separator to compose nodes into one line if node has exactly one child.
---If nil, does not group dirs.
---@param group_empty_with string|nil
---@return integer request_window_width
function Source:show_nodes(source_items, tree, parent_id, group_empty_with)
  local parent_level = 0 -- default when `parent_id` is not found.
  if parent_id then
    local suc, parent = pcall(tree.get_node, tree, parent_id)
    if suc and parent then
      parent_level = parent:get_depth()
    end
  end
  local visibility = {}
  ---@diagnostic disable start
  -- HACK: Special code to work with filesystem source, and keep backwards compatibility.
  if self.config.filtered_items then
    visibility.all_files = self.config.filtered_items.visible
    visibility.in_empty_folder = self.config.filtered_items.force_visible_in_empty_folder
  end
  ---@diagnostic disable end
  local expanded_node_ids = locals.get_node_id_list(tree, parent_id, function(node)
    -- return node:is_expanded()
    return node.pathlib:is_dir(true)
  end)
  -- draw the given nodes
  if source_items and #source_items > 0 then
    local nodes = locals.convert(source_items, visibility, parent_level, group_empty_with)
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

---Render tree to `self.bufnr`
---@param tree NuiTree
---@param linenr_start integer|nil # Line number to start rendering from. Defaults to 1 (top line).
---@return integer request_window_width
function Source:render_tree(tree, linenr_start)
  tree.bufnr = self.bufnr -- double check bufnr is set correctly
  local old_longest_node = self.render_args.longest_node
  if self.render_args.in_pre_render then
    tree:render(linenr_start)
    self.render_args.in_pre_render = false
    -- if old_longest_node >= self.render_args.longest_node then
    --   -- Current tree fits into the width. No need to rerender.
    --   return old_longest_node
    -- end
  end
  tree:render(linenr_start)
  return self.render_args.longest_node
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

---@param window_width { width: integer, strict: boolean } # Default window width.
---@param do_pre_render boolean|nil # Whether to pre_render to find longest node for auto_expand.
function Source:prepare_rendar_args(window_width, do_pre_render)
  self.render_args = {
    in_pre_render = do_pre_render or false,
    remaining_cols = window_width.width,
    longest_node = window_width.width,
    strict = window_width.strict,
  }
end

---Create a NuiLine from data of each NuiTree.Node
---@param item NuiTreeNode|NeotreeSourceItem
---@return NuiLine|nil
function Source:prepare_node(item)
  if item.skip_node then
    if item.is_empty_with_hidden_root then
      local line = NuiLine()
      line:append("(empty folder)", highlights.MESSAGE)
      return line
    else
      return nil
    end
  end
  -- reuse cache if exists and not during pre_render mode
  if not self.render_args.in_pre_render and item.line then
    local _ = item.line
    item.line = nil
    if item.wanted_width and item.wanted_width <= self.render_args.longest_node then
      return _
    end
  end
  -- Generate line using `NeotreeComponent` in `self.renderers`.
  local line = NuiLine()
  local renderer = self.config.renderers[item.type]
  if not renderer then
    line:append(item.type .. ": ", "Comment")
    line:append(item.name)
    return line
  end
  item.wanted_width = 0
  local remaining_cols = self.render_args.remaining_cols
  local should_pad = false
  for _, component in ipairs(renderer) do
    if component.enabled ~= false then
      local datas, wanted_width = ui_rndr.render_component(component, item, self, self.render_args)
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
  if item.wanted_width > self.render_args.longest_node then
    vim.print(string.format([[line:content(): %s]], vim.inspect(line:content())))
    vim.print(string.format([[item.wanted_width: %s]], vim.inspect(item.wanted_width)))
    vim.print(
      string.format(
        [[self.render_args.in_pre_render: %s]],
        vim.inspect(self.render_args.in_pre_render)
      )
    )
  end
  if self.render_args.in_pre_render then
    item.line = line
    if item.wanted_width > self.render_args.longest_node then
      self.render_args.longest_node = item.wanted_width
    end
  else
    item.line = nil
  end
  return line
end

---Run callback with a mutex to `self.tree` so it is safe to modify.
---@param cb fun(tree: NuiTree)
function Source:modify_tree(cb)
  if not self._tree_lock then
    self._tree_lock = nio.semaphore(1)
  end
  self._tree_lock.acquire()
  cb(self.tree)
  print("================================")
  print(debug.traceback("CB done"))
  print("================================")
  self._tree_lock.release()
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

---Return a list that contains all nodes in the tree recursively.
-- WARNING: Don't forget to free the list afterwards, or it may lead to memory leaks.
-- You may want to use `locals.get_node_id_list` instead.
---@param tree NuiTree
---@param parent_id string|nil
---@param filter_func (fun(node: NuiTreeNode): boolean)|nil # Filter out node if this func returns false.
function locals.get_node_list(tree, parent_id, filter_func)
  ---@type NuiTreeNode[]
  local nodes = tree:get_nodes(parent_id)
  local index, max_index = 1, #nodes
  while index <= max_index do
    local node = nodes[index]
    if node:has_children() then
      local children = tree:get_nodes(nodes[index])
      for i, child in ipairs(children) do
        if filter_func and filter_func(child) then
          max_index = max_index + 1
          nodes[max_index] = child
        end
      end
    end
    index = index + 1
  end
  return nodes
end

---Return a list that contains all node ids in the tree recursively.
---@param tree NuiTree
---@param parent_id string|nil
---@param filter_func (fun(node: NuiTreeNode): boolean)|nil # Filter out node if this func returns false.
function locals.get_node_id_list(tree, parent_id, filter_func)
  ---@type NuiTreeNode[]
  local nodes = tree:get_nodes(parent_id)
  ---@type string[]
  local res = {}
  local index, max_index = 1, #nodes
  while index <= max_index do
    local node = nodes[index]
    res[index] = node:get_id()
    if node:has_children() then
      local children = tree:get_nodes(nodes[index])
      for i, child in ipairs(children) do
        if filter_func and filter_func(child) then
          max_index = max_index + 1
          nodes[max_index] = child
        end
      end
    end
    index = index + 1
  end
  return res
end

---@param source_items NeotreeSourceItem[]|NuiTreeNode[]|nil
---@param visibility { all_files: boolean|nil, in_empty_folder: boolean|nil }
---@param level integer # Node depth from root (=1).
---Separator to compose nodes into one line if node has exactly one child.
---If nil, does not group dirs.
---@param group_empty_with string|nil
---@deprecated TODO: Move this function to a proper location (eg utils).
function locals.convert(source_items, visibility, level, group_with)
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
      local children = locals.convert(item.children, visibility, level + 1, group_with)
      -- Group empty dirs
      -- This code is simple since node is not registered to the tree yet.
      if group_with and children and #children == 1 and children[1].type == "directory" then
        nodeData = children[1]
        nodeData.name = item.name .. group_with .. children[1].name
        children = nil
      end
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

function Source:i_am_a_valid_source()
  -- `Source` is an example. All child classes will be valid neo-tree source
  return self.name ~= Source.name
end

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
  _batch[_batch.index] = nio.run(func, cb or function() end)
  return _batch[_batch.index]
end

---@param until_now boolean|nil # If true, only waits tasks registered until this function was called. Otherwise, waits for all tasks registered throughout the instance.
---@param batch_name string|nil # Unique name for batch. If nil, refers to global task list.
function Source:wait_all_tasks(until_now, batch_name)
  batch_name = batch_name or "__global_workers"
  if not self._workers or not self._workers[batch_name] then
    return
  end
  local _batch = self._workers[batch_name]
  local wait_until = until_now and _batch.index or nil
  -- Block exec until other setups is completed
  local done = nio.wait_all(_batch, _batch.done + 1, wait_until)
  if done > _batch.done then
    _batch.done = done
  end
end

---@param batch_name string|nil # Unique name for batch. If nil, refers to global task list.
function Source:wait_only_last_task(batch_name)
  batch_name = batch_name or "__global_workers"
  if not self._workers or not self._workers[batch_name] then
    return
  end
  local _batch = self._workers[batch_name]
  -- Block exec until other setups is completed
  local done = nio.wait_last_only(_batch, _batch.done + 1)
  if done > _batch.done then
    _batch.done = done
  end
end

return Source, locals
