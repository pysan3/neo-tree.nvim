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
    return cls.new(cls, ...)
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
  }, Filetree)
  if not self.dir:is_dir(true) then
    log.error("Filetree (%s) is not a directory. Abort.", self.dir:tostring())
    return
  end
  self:prepare_tree()
  self.tree:add_node(locals.new_node(self.dir, 0))
  self:add_task(function()
    self:fill_tree(nil, 1, nil)
    -- if self.enable_git_status then
    --   self:fill_git_state(false)
    -- end
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

  -- fill in rest of the tree async
  if nio.check_nio_install() then
    nio.run(function()
      -- TODO: Call this incrementally.
      -- self:fill_tree(nil, nil, nil)
      -- if self.enable_git_status then
      --   self:fill_git_state(true)
      -- end
    end)
  end
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
  -- local should_auto_expand = self.window.auto_expand_width and state.current_position ~= "float"
  -- local should_pre_render = should_auto_expand or state.current_position == "current"
  -- if not self.window.auto_expand_width then
  --   window_width.strict = true
  -- end
  if not path_to_reveal then
    -- if self.dir:basename() == "linux" then
    --   path_to_reveal = self.dir
    --     / "drivers/gpu/drm/nouveau/include/nvrm/535.113.01/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073specific.h"
    -- else
    --   path_to_reveal = self.dir / "lua/neo-tree/sources/document_symbols/lib/client_filters.lua"
    -- end
  end
  if path_to_reveal then
    self:add_task(function()
      self:fill_tree(nil, 0, path_to_reveal)
    end)
  end
  nio.elapsed("start", manager.__timer_start)
  self:prepare_rendar_args(window_width, not window_width.strict)
  nio.elapsed([[prepare_rendar_args]], manager.__timer_start)
  self:wait_all_tasks()
  nio.elapsed([[wait_all_tasks]], manager.__timer_start)
  -- TODO: local group_with = self.config.group_empty_dirs and Path.sep_str or nil
  -- local request_window_width = self:show_nodes(nil, self.tree, nil, group_with)
  self:show_nodes(nil, self.tree, nil, nil)
  nio.elapsed([[show_nodes]], manager.__timer_start)
  if path_to_reveal then
    self:focus_node(path_to_reveal:tostring())
  end
  self:redraw(manager)
  nio.elapsed([[redraw]], manager.__timer_start)
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

---Update path.git_status for all known paths.
function Filetree:fill_git_state()
  local paths = {}
  for _, node in pairs(self.tree.nodes.by_id) do
    table.insert(paths, node.pathlib)
  end
  pathlib_git.fill_git_state(paths)
end

function locals.new_node(path, level)
  -- TODO: Cache results.
  local stat = path:stat(false)
  local stat_type = stat and stat.type
  local git_state = path.git_state or {}
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

---Fill tree until depth.
---@param parent_id string|nil # The node id of where to start from. If nil, uses the root node.
---@param depth integer|nil # Depth to dig into. If nil, goes all the way.
---@param reveal_path PathlibPath|nil # Ignores depth limit and digs until this path.
function Filetree:fill_tree(parent_id, depth, reveal_path)
  self:modify_tree(function(tree)
    local skip_dir = function(dir)
      local node = tree:get_node(dir:tostring())
      return node and node.loaded
    end
    local cwd_len = self.dir:len()
    if depth and reveal_path then
      local old_depth = depth
      local reveal_string = reveal_path:absolute():tostring()
      depth = math.max(depth, reveal_path:len() - cwd_len)
      local __old_skip_dir = skip_dir
      skip_dir = function(dir)
        if vim.startswith(reveal_string, dir:tostring()) then
          return false
        end
        return dir:len() - cwd_len >= old_depth or __old_skip_dir(dir)
      end
    end
    if self.config.scan_mode == "deep" then
      local old_depth = depth
      depth = nil
      local __old_skip_dir = skip_dir
      skip_dir = function(dir)
        for child in dir:fs_iterdir(false, 1) do
          local name = child:basename()
          if
            self.config.filtered_items.never_show[name]
            or utils.is_filtered_by_pattern(
              self.config.filtered_items.never_show_by_pattern,
              child:tostring(),
              name
            )
          then
          else
            return true
          end
        end
        return dir:len() - cwd_len >= old_depth or __old_skip_dir(dir)
      end
    end
    local tasks_name = string.format("fill_tree-%s-%s", depth, reveal_path)
    ---@type table<string, NuiTree.Node[]> # { parent_id: [nodes to be added] }
    local nodes = vim.defaulttable()
    local root = tree:get_node(parent_id or self.dir:tostring())
    if root and not root.loaded then
      for path in root.pathlib:fs_iterdir(false, depth, skip_dir) do
        self:add_task(function()
          local node = tree:get_node(path:tostring())
          if not node then
            node = locals.new_node(path, path:len() - cwd_len)
            local _parent = node.pathlib:parent_assert():tostring()
            table.insert(nodes[_parent], node)
          end
          node.is_reveal_target = reveal_path and path == reveal_path or false
        end, tasks_name)
      end
    end
    self:wait_all_tasks(false, tasks_name)
    local keys = vim.tbl_keys(nodes)
    table.sort(keys, function(a, b)
      return a:len() < b:len()
    end)
    for _, key in ipairs(keys) do
      tree:set_nodes(nodes[key], key)
      local node = tree:get_node(key)
      -- node.loaded = true
    end
  end) -- release tree lock
  if self.use_libuv_file_watcher then
    self:modify_tree(function(tree)
      local node_table = tree.nodes.by_id --[[@as table<any, NeotreeSourceItem>]]
      for _, node in pairs(node_table) do
        self:assign_file_watcher(node.pathlib)
      end
    end)
  end
end

function Filetree:visualize_tree(id, indent)
  local nodes = self.tree:get_nodes(id)
  for _, node in ipairs(nodes) do
    print(string.rep(" ", node:get_depth() * (indent or 2)) .. node.name)
    self:visualize_tree(node:get_id(), indent)
  end
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

---A helper function to assign file watcher to rerender on file update to `pathlib`.
---@param pathlib PathlibPath
function Filetree:assign_file_watcher(pathlib)
  pathlib:register_watcher(self.id .. "luv_filewatcher", function(_p, args)
    vim.print(string.format([[_p: %s]], _p))
    local dir = args.dir
    args.dir = nil
    vim.print(string.format([[args (except dir): %s]], vim.inspect(args)))
    args.dir = dir
    vim.print(string.format([[args.dir: %s]], args.dir))
    if args.events.change then
      -- file has been modified
    end
    if args.events.rename and _p:basename() == args.filename then -- file has been removed
      self:modify_tree(function(_tree)
        local removed = _tree:remove_node(_p:tostring())
        removed.pathlib:unregister_watcher()
        self:visualize_tree()
      end)
    elseif args.events.rename and _p == args.dir then -- file has been added
      self:modify_tree(function(_tree)
        local new_path = _p:child(args.filename)
        self:assign_file_watcher(new_path)
        local new_node = locals.new_node(new_path, new_path:len() - self.dir:len())
        _tree:add_node(new_node, _p:tostring())
      end)
    end
    renderer.redraw(self)
    -- events.fire_event(events.FS_EVENT, { afile = _p:tostring() })
  end)
end

---Expands or collapses the current node.
---comment
---@param _node NuiTreeNode|nil # If nil, uses root node.
---@param path_to_reveal PathlibPath|nil
---@param skip_redraw boolean|nil # Rerenders the tree when everything is done.
function Filetree:toggle_directory(_node, path_to_reveal, skip_redraw)
  local timer = os.clock()
  if not _node then
    _node = self.tree:get_node()
    nio.elapsed("no node, get node at line.", timer)
  end
  if not _node or _node.type ~= "directory" then
    return
  end
  ---@type NuiTreeNode|NeotreeSourceItem
  local node = _node
  self.explicitly_opened_directories = self.explicitly_opened_directories or {}
  if node.loaded == false then
    nio.elapsed("node.loaded = false", timer)
    self:fill_tree(node:get_id(), 1, path_to_reveal)
    nio.elapsed("self:fill_tree", timer)
  end
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
      nio.elapsed("is path_to_reveal", timer)
      self:focus_node(path_to_reveal:tostring())
      nio.elapsed("self:focus_node", timer)
      return renderer.redraw(self)
    end
    if updated and not skip_redraw then
      nio.elapsed("has an update", timer)
      return renderer.redraw(self)
    end
  end
end

return Filetree, locals
