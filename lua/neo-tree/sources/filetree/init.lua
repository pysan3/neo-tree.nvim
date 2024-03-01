local highlights = require("neo-tree.ui.highlights")
local Path = require("pathlib")
local pathlib_git = require("pathlib.git")
local nio = require("neo-tree.utils.nio_wrapper")
local utils = require("neo-tree.utils")
local fs_scan = require("neo-tree.sources.filesystem.lib.fs_scan")
local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local git = require("neo-tree.git")
local glob = require("neo-tree.sources.filesystem.lib.globtopattern")
local PathTree = require("neo-tree.sources.filetree.path_tree")
local NuiTree = require("nui.tree")

local locals = {} -- Functions exported for test purposes

---@class NeotreeFiletree : NeotreeState
---@field config NeotreeConfig.filesystem
---@field dir PathlibPath
---@field filtered_items NeotreeConfig.filesystem.filtered_items_optimized
local Filetree = setmetatable({
  -- Attributes defined her end
  name = "filetree",
  display_name = " 󰉓 Files ",
  use_libuv_file_watcher = true,
  enable_refresh_on_write = false,
  enable_git_status = true,
  commands = require("neo-tree.sources.filetree.commands"),
  window = {},
  components = require("neo-tree.sources.filesystem.components"),
  renderers = {},
}, {
  __index = require("neo-tree.sources.base"), -- Inherit from base class.
  __call = function(cls, ...)
    return cls.new(...)
  end,
})
Filetree.__index = Filetree

---Create new manager instance or return cache if already created.
---@param config NeotreeConfig.filesystem
---@param id string # id of this state passed from `self.setup`.
---@param dir string|nil
function Filetree.new(config, id, dir)
  local self = setmetatable({
    id = id,
    dir = dir and Path.new(dir) or Path.cwd(),
    config = config,
    position = { is = { restorable = true } }, -- TODO: fuck it
  }, Filetree)
  if not self.dir:is_dir(true) then
    log.error("Filetree (%s) is not a directory. Abort.", self.dir:tostring())
    return
  end
  self:prepare_tree()
  self.tree:add_node(locals.new_node(self.dir, 1))
  self:add_task(function()
    self:fill_tree(nil, 1, nil)
    if self.enable_git_status then
      self:fill_git_state(nil, 1, true)
    end
  end)
  self.filtered_items = locals.purify_filtered_items(config.filtered_items or {})

  -- -- before_render is deprecated. Convert to event system
  -- if config.before_render then ---@diagnostic disable-line
  --   events.subscribe({
  --     event = events.BEFORE_RENDER,
  --     handler = function(state)
  --       if self.id == state.id then
  --         self.config.before_render(state) ---@diagnostic disable-line
  --       end
  --     end,
  --   })
  -- end

  -- if not self.use_libuv_file_watcher and self.enable_refresh_on_write then
  --   events.subscribe({
  --     event = events.VIM_BUFFER_CHANGED,
  --     handler = function(arg)
  --       local afile = arg.afile or "" --[[@as string]]
  --       if utils.is_real_file(afile) and self.path_tree:get(afile) then
  --         nio.run(function()
  --           log.trace("refreshing due to vim_buffer_changed event: ", afile)
  --           pathlib_git.fill_git_state(self.path_tree:get(afile).path)
  --           self:rerender()
  --         end)
  --       else
  --         log.trace("Ignoring vim_buffer_changed event for non-file: ", afile)
  --       end
  --     end,
  --   })
  -- end
  return self
end

---Create new manager instance or return cache if already created.
---@param config NeotreeConfig.filesystem
---@param global_config NeotreeConfig
function Filetree.setup(config, global_config)
  Filetree.use_libuv_file_watcher = config.use_libuv_file_watcher or true
  Filetree.enable_refresh_on_write = global_config.enable_refresh_on_write
  Filetree.share_state_among_tabs = global_config.share_state_among_tabs
  Filetree.enable_git_status = global_config.enable_git_status

  -- Configure event handlers for file changes
  if not Filetree.use_libuv_file_watcher then
    for _, tree in pairs(PathTree.path_lookup) do
      tree.path:unregister_watcher()
    end
  end

  -- --Configure event handlers for cwd changes
  -- if config.bind_to_cwd then
  --   events.subscribe({
  --     event = events.VIM_DIR_CHANGED,
  --     handler = function()
  --       -- TODO: Rerender with new cwd
  --       -- wrap(manager.dir_changed),
  --     end,
  --   })
  -- end

  -- --Configure event handlers for lsp diagnostic updates
  -- if global_config.enable_diagnostics then
  --   manager.subscribe(M.name, {
  --     event = events.VIM_DIAGNOSTIC_CHANGED,
  --     handler = wrap(manager.diagnostics_changed),
  --   })
  -- end

  -- --Configure event handlers for modified files
  -- if global_config.enable_modified_markers then
  --   manager.subscribe(M.name, {
  --     event = events.VIM_BUFFER_MODIFIED_SET,
  --     handler = wrap(manager.opened_buffers_changed),
  --   })
  -- end

  -- if global_config.enable_opened_markers then
  --   for _, event in ipairs({ events.VIM_BUFFER_ADDED, events.VIM_BUFFER_DELETED }) do
  --     manager.subscribe(M.name, {
  --       event = event,
  --       handler = wrap(manager.opened_buffers_changed),
  --     })
  --   end
  -- end

  -- -- Configure event handler for follow_current_file option
  -- if config.follow_current_file.enabled then
  --   manager.subscribe(M.name, {
  --     event = events.VIM_BUFFER_ENTER,
  --     handler = function(args)
  --       if utils.is_real_file(args.afile) then
  --         M.follow()
  --       end
  --     end,
  --   })
  -- end
end

---Prepare for render. And write to buffer.
---@param dir PathlibPath # Directory to work with. Mostly `cwd`.
---@param path_to_reveal PathlibPath|nil # Reveal and focus on this file on startup.
---@param window_width { width: integer, strict: boolean } # Default window width.
---@param manager NeotreeManager # Call `manager.done(self, request_window_width)` after buffer is ready.
---@param failed_args table # Optional args that map be passed from a different state on fail.
function Filetree:navigate(dir, path_to_reveal, window_width, manager, failed_args)
  if dir:absolute() ~= self.dir then
    local new_id = self.name .. self.dir:tostring()
    local reason = string.format("dir %s is not supported.", dir) -- If new_id is nil, this reason will be reported to the user.
    return manager:fail(reason, new_id, self, dir, path_to_reveal, window_width, failed_args)
  elseif not self.dir:is_dir(true) then
    local reason = string.format("Dir %s does not exist.", self.dir)
    return manager:fail(reason, nil, self, dir, path_to_reveal, window_width, failed_args)
  end
  if path_to_reveal then
    self:add_task(function()
      self:fill_tree(nil, 0, path_to_reveal)
    end)
  end
  log.time_it("start filetree:navigate")
  self:prepare_rendar_args(window_width, not window_width.strict)
  self:wait_all_tasks("fill_git_state")
  log.time_it("fill_git_state finished")
  self:wait_all_tasks()
  log.time_it("all_tasks finished")
  -- TODO: local group_with = self.config.group_empty_dirs and Path.sep_str or nil
  -- local request_window_width = self:show_nodes(nil, self.tree, nil, group_with)
  self:show_nodes(nil, self.tree, nil, nil)
  if path_to_reveal then
    self:focus_node(path_to_reveal:tostring())
  end
  nio.wait(nio.run(function()
    self:redraw(manager)
  end, function(success, err)
    -- callback: called right after the above async function is finished.
    log.time_it(string.format("self:redraw: fail: %s, err: %s", not success, err))
  end))
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                     Filesystem Scan                     │
--          ╰─────────────────────────────────────────────────────────╯

---Update path.git_status for all known paths under `parent_id` lazily.
---@async
---@param parent_id string|nil # If nil, runs against all root nodes (each root node is processed separately).
---@param depth integer|nil # 1 to scan a single folder without digging into grandchildren. Nil will go all the way.
---@param wait boolean|nil # If true, send all paths at once and wait for all to finish. If falsy, add update request to queue.
function Filetree:fill_git_state(parent_id, depth, wait)
  if parent_id == nil then
    local roots = self.tree:get_nodes()
    if roots then
      for _, root in ipairs(roots) do
        self:fill_git_state(root:get_id(), depth, wait)
      end
    end
    return
  end
  -- Accumulate all node.pathlib under `parent_id` with BFS.
  local paths, queue = {}, require("neo-tree.utils.array").string()
  queue:pushright(parent_id)
  local root = self.tree:get_node(queue:peek(1))
  local root_depth = root and root:get_depth()
  while queue:len() > 0 do
    local node = self.tree:get_node(queue:popleft())
    if node then
      table.insert(paths, node.pathlib)
      if not depth or (node:get_depth() - root_depth < depth) then
        queue:extend(unpack(node:get_child_ids()))
      end
    end
  end
  log.time_it("fill_git_state: #paths:", #paths)
  if wait then
    pathlib_git.fill_git_state(paths)
  else
    for _, path in ipairs(paths) do
      pathlib_git.request_git_status_update(path)
      self:add_task(function()
        path.git_status.is_set.wait()
      end, "fill_git_state")
    end
  end
end

---Fill tree until depth.
---@async
---@param parent_id string|nil # The node id of where to start from. If nil, uses the root node.
---@param depth integer|nil # Depth to dig into. If nil, goes all the way.
---@param reveal_path PathlibPath|nil # Ignores depth limit and digs until this path.
function Filetree:fill_tree(parent_id, depth, reveal_path)
  -- TODO: Split this function as it is too long.
  self:modify_tree(function(tree)
    local scan_root = tree:get_node(parent_id or self.dir:tostring())
    if not scan_root then
      return
    end
    parent_id = scan_root:get_id()
    local scan_root_depth = scan_root:get_depth() - 1 -- we want parent_node to be 0
    -- Scan root's absolute path length. Compared against scanned items to calculate depth.
    local scan_root_len = self.dir:len() + scan_root_depth
    local reveal_node = reveal_path and tree:get_node(reveal_path:tostring())
    if reveal_node and depth and reveal_path and reveal_path:len() - scan_root_len >= depth then
      log.time_it("skip fill_tree: reveal_path found")
      return -- reveal target already exists.
    end
    local opts = locals.skipfun_default(scan_root_len, depth, tree)
    if opts.depth and reveal_path then
      opts = locals.skipfun_reveal_parent(scan_root_len, opts.depth, reveal_path, opts.skip_dir)
    end
    if self.config.scan_mode == "deep" then
      opts = locals.skipfun_scan_deep(self.config.filtered_items, opts.skip_dir)
    end
    if opts.skip_dir(scan_root.pathlib) then
      local msg = "skip fill_tree: skip scan_root (root: %s, depth: %s, reveal: %s, loaded: %s)"
      log.time_it(string.format(msg, scan_root:get_id(), opts.depth, reveal_path, scan_root.loaded))
      return -- scan_root is already opts.skip_dir(scan_root) == true.
    end
    ---@type table<string, NuiTree.Node[]> # { parent_id: [nodes to be added] }
    local nodes = vim.defaulttable()
    local tasks_name = string.format("fill_tree-%s-%s-%s", parent_id, depth, reveal_path)
    log.time_it("fill_tree start scan:", tasks_name)
    for path in scan_root.pathlib:fs_iterdir(false, opts.depth, opts.skip_dir) do
      self:add_task(function()
        local node = tree:get_node(path:tostring())
        if not node then
          local _parent = path:parent_assert():tostring()
          node = locals.new_node(path, path:len() - scan_root_len + scan_root_depth + 1) -- level starts from 1
          table.insert(nodes[_parent], node)
        end
        node.is_reveal_target = reveal_path and path == reveal_path or false
      end, tasks_name)
    end
    self:wait_all_tasks(tasks_name, false)
    log.time_it("fill_tree end scan:", tasks_name)
    local keys = vim.tbl_keys(nodes)
    table.sort(keys, function(a, b)
      return a:len() < b:len()
    end)
    local added_nodes = 0
    for _, key in ipairs(keys) do
      for _, node in ipairs(nodes[key]) do
        tree:add_node(node, key)
      end
      added_nodes = added_nodes + #nodes[key]
      local parent = tree:get_node(key)
      if parent then
        -- TODO: Implement a method to sort children here. No need to deep-sort any more.
        -- if self.sort_function then
        --   table.sort(parent._child_ids, function(a, b)
        --     return self.sort_function(tree, parent:get_id(), a, b)
        --   end)
        -- end
        if parent:has_children() then
          local child_ids = parent:get_child_ids()
          local child_len = #child_ids
          for index, child_id in ipairs(child_ids) do
            local _n = tree:get_node(child_id)
            _n.is_last_child = index == child_len
          end
        end
        parent.loaded = true
      end
    end
    log.time_it("fill_tree added nodes:", added_nodes)
    if self.enable_git_status then
      self:fill_git_state(parent_id, opts.depth, true)
      log.time_it("fill_tree request git_state:", added_nodes)
    end
    if self.use_libuv_file_watcher then
      local node_table = tree.nodes.by_id --[[@as table<any, NeotreeSourceItem>]]
      for _, node in pairs(node_table) do
        self:assign_file_watcher(node.pathlib)
      end
    end
  end)
end

function locals.skipfun_default(scan_root_len, depth, tree)
  return {
    depth = depth,
    skip_dir = function(dir)
      if dir:len() - scan_root_len > depth - 1 then
        -- needs to scan more than direct children
        return false
      end
      local dir_node = tree:get_node(dir:tostring())
      return dir_node and dir_node.loaded
    end,
  }
end

function locals.skipfun_reveal_parent(scan_root_len, depth, reveal_path, fallback)
  local reveal_string = reveal_path:absolute():tostring()
  local new_depth = math.max(depth, reveal_path:len() - scan_root_len)
  return {
    depth = new_depth,
    skip_dir = function(dir)
      local dir_string = dir:tostring()
      if reveal_string:len() < dir_string:len() and vim.startswith(reveal_string, dir_string) then
        return false
      end
      return fallback(dir)
    end,
  }
end

function locals.skipfun_scan_deep(filtered_items_config, fallback)
  return {
    depth = nil,
    skip_dir = function(dir)
      for child in dir:fs_iterdir(false, 1) do
        local name = child:basename()
        if
          filtered_items_config.never_show[name]
          or utils.is_filtered_by_pattern(
            filtered_items_config.never_show_by_pattern,
            child:tostring(),
            name
          )
        then
        else
          return true
        end
      end
      return fallback(dir)
    end,
  }
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                        Commands                         │
--          ╰─────────────────────────────────────────────────────────╯

---Expands or collapses the current node.
---comment
---@param _node NuiTreeNode|nil # If nil, uses root node.
---@param path_to_reveal PathlibPath|nil
---@param skip_redraw boolean|nil # Rerenders the tree when everything is done.
function Filetree:toggle_directory(_node, path_to_reveal, skip_redraw)
  if not _node then
    _node = self.tree:get_node()
  end
  if not _node or _node.type ~= "directory" then
    log.time_it("_node not a directory ", _node and _node.id, _node and _node.type)
    return
  end
  ---@type NuiTreeNode|NeotreeSourceItem
  local node = _node
  log.time_it("valid node:", node.id)
  self.explicitly_opened_directories = self.explicitly_opened_directories or {}
  self:fill_tree(node:get_id(), 1, path_to_reveal)
  if node:has_children() then
    local updated = false
    if node:is_expanded() then
      updated = node:collapse()
      self.explicitly_opened_directories[node:get_id()] = false
    else
      updated = node:expand()
      self.explicitly_opened_directories[node:get_id()] = true
    end
    if path_to_reveal then
      self:focus_node(path_to_reveal:tostring())
      updated = true
    end
    if updated and not skip_redraw then
      return renderer.redraw(self)
    end
  end
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                      File Watcher                       │
--          ╰─────────────────────────────────────────────────────────╯

---A helper function to assign file watcher to rerender on file update to `pathlib`.
---@param pathlib PathlibPath
function Filetree:assign_file_watcher(pathlib)
  pathlib:register_watcher(self.id .. "luv_filewatcher", function(_p, args)
    -- -- vim.print(string.format([[_p: %s]], _p))
    -- -- local dir = args.dir
    -- -- args.dir = nil
    -- -- vim.print(string.format([[args (except dir): %s]], vim.inspect(args)))
    -- -- args.dir = dir
    -- -- vim.print(string.format([[args.dir: %s]], args.dir))
    -- local do_redraw = false
    -- if args.events.change then -- file has been modified
    -- end
    -- if args.events.rename and _p:basename() == args.filename then -- file has been removed
    --   self:modify_tree(function()
    --     local removed = self:remove_node_recursive(_p:tostring())
    --     do_redraw = removed and true or false
    --   end)
    -- elseif args.events.rename and _p == args.dir then -- file has been added
    --   self:modify_tree(function(_tree)
    --     local new_path = _p:child(args.filename)
    --     if not _tree:get_node(new_path:tostring()) then
    --       self:assign_file_watcher(new_path)
    --       local new_node = locals.new_node(new_path, new_path:len() - self.dir:len())
    --       _tree:add_node(new_node, _p:tostring())
    --       do_redraw = true
    --     end
    --   end)
    -- end
    -- if do_redraw then
    --   renderer.redraw(self)
    -- end
    -- -- events.fire_event(events.FS_EVENT, { afile = _p:tostring() })
  end)
end

function Filetree:remove_node_recursive(node_id)
  ---@type NuiTreeNode|NeotreeSourceItem|nil
  local node = self.tree:get_node(node_id)
  if not node then
    return false
  end
  if node:has_children() then
    for _, child_id in ipairs(node:get_child_ids()) do
      self:remove_node_recursive(child_id)
    end
  end
  node.pathlib:unregister_watcher()
  node.pathlib = nil
  return self.tree:remove_node(node_id) and true or false
end

---Update `self.tree` on a file rename.
---@param tree NuiTree
---@param parent PathlibPath # Parent directory
---@param filename string # Basename of the new filename.
function locals.update_tree_rename(tree, parent, filename)
  local parent_node = tree:get_node(parent:tostring())
  if not parent_node then
    log.warn("Unknown path updated. " .. parent:tostring())
    return
  end
  for _, child in ipairs(tree:get_nodes(parent:tostring())) do
    if not child.pathlib:exists() then
      tree:remove_node(child:get_id())
    end
  end
  local new = locals.new_node(parent:child(filename), parent_node.level + 1)
  tree:add_node(new, parent:tostring())
end

--          ╭─────────────────────────────────────────────────────────╮
--          │                        Utilities                        │
--          ╰─────────────────────────────────────────────────────────╯

function locals.new_node(path, level)
  -- TODO: Cache results.
  local stat = path:stat(false)
  local stat_type = stat and stat.type
  local git_state = path.git_state
  local item = {
    pathlib = path,
    id = path:tostring(), -- string|nil
    name = path:basename(), -- string|nil
    type = stat_type, -- string|nil
    loaded = false, -- boolean|nil
    filtered_by = {}, -- TODO: table|nil
    extra = {}, -- TODO: table|nil
    is_nested = false, -- TODO: boolean|nil
    skip_node = false, -- boolean|nil
    stat = stat, -- uv.aliases.fs_stat_table|nil
    stat_provider = "", -- function|nil
    path = path:tostring(), -- NeotreePathString|nil
    ext = path:suffix(), -- string|nil
    search_pattern = "", -- TODO: string|nil
    level = level, -- integer|nil
    children = {},
  }
  -- TODO: how should I implement this.
  -- item.is_empty_with_hidden_root = path:is_dir(true)
  --   and #children == 0
  --   and git_state.ignored
  item.filtered_by = { -- TODO: ./lua/neo-tree/sources/common/file-items.lua > create_item
    never_show = false,
    always_show = true,
    name = false,
    pattern = false,
    dotfiles = false,
    hidden = false,
    gitignored = false,
    show_gitignored = false,
  }
  if stat_type == "symlink" then
    local real_path = path:realpath()
    item.is_link = true
    item.link_to = real_path:tostring()
    item.link_type = (real_path:stat(false) or {}).type
  end
  return NuiTree.Node(item, {})
end

---Optimize filtered items
---@param filtered_items NeotreeConfig.filesystem.filtered_items
function locals.purify_filtered_items(filtered_items)
  ---@type any
  local res = filtered_items
  ---@cast res NeotreeConfig.filesystem.filtered_items_optimized
  for _, file in ipairs(filtered_items.hide_by_name or {}) do
    res.hide_by_name[file] = true
  end
  for _, file in ipairs(filtered_items.always_show or {}) do
    res.always_show[file] = true
  end
  for _, file in ipairs(filtered_items.never_show or {}) do
    res.never_show[file] = true
  end
  for index, value in ipairs(filtered_items.hide_by_pattern or {}) do
    res.hide_by_pattern[index] = glob.globtopattern(value)
  end
  for index, value in ipairs(filtered_items.never_show_by_pattern or {}) do
    res.never_show_by_pattern[index] = glob.globtopattern(value)
  end
  return res
end

return Filetree, locals
