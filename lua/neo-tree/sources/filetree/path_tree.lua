local Path = require("pathlib")
local pathlib_git = require("pathlib.git")
local nio = require("neo-tree.utils.nio_wrapper")
local utils = require("neo-tree.utils")
local fs_scan = require("neo-tree.sources.filesystem.lib.fs_scan")
local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local manager = require("neo-tree.sources.manager")
local git = require("neo-tree.git")
local glob = require("neo-tree.sources.filesystem.lib.globtopattern")
local NuiTree = require("nui.tree")

local locals = {} -- Functions exported for test purposes

---@class NeotreePathNodeData
---@field pathlib PathlibPath
---@field dir_scanned boolean

---@alias NeotreePathNode NuiTree.Node|NeotreePathNodeData

---@class NeotreePathTree : NuiTree.Node, NeotreePathNodeData
local PathTree = setmetatable({
  ---@type table<PathlibString, NeotreePathTree>
  path_lookup = {},
}, getmetatable(NuiTree.Node({}, {})))
PathTree.__index = PathTree

---Insert a new entry of `path` into the tree.
---@param path PathlibPath
function PathTree.new(path)
  path:to_absolute() -- All entries must be absolute paths
  local s = path:tostring()
  if not PathTree.path_lookup[s] then
    ---@type any
    local node = setmetatable(
      NuiTree.Node({
        path = path,
        dir_scanned = false,
      }, {}),
      PathTree
    )
    PathTree.path_lookup[s] = node
    if path:is_symlink() then
      PathTree.path_lookup[path:realpath():tostring()] = node
    end
  end
  return PathTree.path_lookup[s]
end

---Search for PathTree
---@param s PathlibPath|PathlibString|nil
---@return NeotreePathTree|nil
function PathTree:get(s)
  if not s then
    return nil
  end
  if type(s) == "table" then
    s = tostring(s)
  end
  return self.path_lookup[s]
end

---Get PathTree list of children
---@return NeotreePathTree[]
function PathTree:get_children()
  local res = {}
  for _, t in ipairs(self.children) do
    local child = self:get(t)
    if child then
      res[#res + 1] = child
    end
  end
  return res
end

---Update path.git_status for all known paths.
function PathTree:fill_git_state()
  pathlib_git.fill_git_state(self:get_path_list())
end

---@param self NeotreePathTree
---@return PathlibPath[]
function PathTree:get_path_list()
  local res, res_index = {}, 0
  local queue = { self }
  local q_index, max_index = 1, 1
  while max_index >= q_index do
    local t = queue[q_index]
    for _, child in ipairs(t:get_children()) do
      max_index = max_index + 1
      queue[max_index] = self:get(child.path)
    end
    res_index = res_index + 1
    res[res_index] = t.path
    queue[q_index] = nil
    q_index = q_index + 1
  end
  return res
end

---@param depth integer|nil # Depth to dig into. If nil, goes all the way.
function PathTree:fill_path_tree(depth)
  if depth ~= nil and depth < 0 then
    return
  end
  if not self.dir_scanned then
    if self.path:is_dir(true) then
      for path in self.path:fs_iterdir(false, 1) do
        local tree = self.new(path)
        self.children[#self.children + 1] = path:tostring()
        if path:is_dir(true) then
          tree:fill_path_tree(depth and depth - 1)
        else
          tree.dir_scanned = true
        end
      end
    end
    self.dir_scanned = true
  end
end

---Unallocate paths registered in this tree.
function PathTree:free()
  self.path_lookup[self.path:tostring()] = nil
  if self.path:is_symlink() then
    self.path_lookup[self.path:realpath():tostring()] = nil
  end
  self.path:unregister_watcher()
  for _, child in ipairs(self:get_children()) do
    child:free()
  end
end

---Free children if file does not exist.
function PathTree:scan_children_exists()
  for _, child in ipairs(self:get_children()) do
    if not child.path:exists() then
      child:free()
    end
  end
end

---@class NeotreeSourceItem.bak
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

---Convert a PathTree to NeotreeSourceItem
---@param depth integer
---@param path_to_reveal PathlibPath|nil # Reveal and focus on this file on startup.
function PathTree:into_source_items(depth, path_to_reveal)
  local stat = self.path:stat(false)
  local stat_type = stat and stat.type
  local git_state = self.path.git_state or {}
  local item = {
    id = self.path:tostring(), -- string|nil
    name = self.path:basename(), -- string|nil
    type = stat_type, -- string|nil
    loaded = self.dir_scanned, -- boolean|nil
    filtered_by = {}, -- TODO: table|nil
    extra = {}, -- TODO: table|nil
    is_nested = false, -- TODO: boolean|nil
    skip_node = false, -- boolean|nil
    is_reveal_target = self.path == path_to_reveal, -- boolean|nil
    stat = stat, -- uv.aliases.fs_stat_table|nil
    stat_provider = "", -- function|nil
    path = self.path:tostring(), -- NeotreePathString|nil
    ext = self.path:suffix(), -- string|nil
    search_pattern = "", -- TODO: string|nil
    level = depth, -- integer|nil
    children = {},
  }
  item.is_empty_with_hidden_root = self.path:is_dir(true)
    and #self.children == 0
    and git_state.ignored
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
    item.is_link = true
    item.link_to = self.path:realpath():tostring()
  end
  local workers = { index = #self.children, done = 0 }
  for index, child in ipairs(self:get_children()) do
    workers[index] = nio.run(function()
      item.children[index] = child:into_source_items(depth + 1, path_to_reveal)
    end)
  end
  nio.wait_all(workers)
  return item
end

---Convert a PathTree to NeotreeSourceItem
---@param depth integer
---@param path_to_reveal PathlibPath|nil # Reveal and focus on this file on startup.
function PathTree:into_source_items2(depth, path_to_reveal)
  local stat = self.path:stat(false)
  local stat_type = stat and stat.type
  local git_state = self.path.git_state or {}
  local item = {
    id = self.path:tostring(), -- string|nil
    name = self.path:basename(), -- string|nil
    type = stat_type, -- string|nil
    loaded = self.dir_scanned, -- boolean|nil
    filtered_by = {}, -- TODO: table|nil
    extra = {}, -- TODO: table|nil
    -- is_nested = false, -- TODO: boolean|nil
    skip_node = false, -- boolean|nil
    -- is_reveal_target = self.path == path_to_reveal, -- boolean|nil
    stat = stat, -- uv.aliases.fs_stat_table|nil
    -- stat_provider = "", -- function|nil
    -- path = self.path:tostring(), -- NeotreePathString|nil
    -- ext = self.path:suffix(), -- string|nil
    -- search_pattern = "", -- TODO: string|nil
    level = depth, -- integer|nil
    children = {},
  }
  -- item.is_empty_with_hidden_root = self.path:is_dir(true)
  --   and #self.children == 0
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
  -- if stat_type == "symlink" then
  --   item.is_link = true
  --   item.link_to = self.path:realpath():tostring()
  -- end
  for index, child in ipairs(self:get_children()) do
    item.children[index] = child:into_source_items(depth + 1, path_to_reveal)
  end
  return item
end

return PathTree, locals
