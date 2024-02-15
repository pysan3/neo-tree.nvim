--This file should have all functions that are in the public api and either set
--or read the state of this source.

local vim = vim
local utils = require("neo-tree.utils")
local renderer = require("neo-tree.ui.renderer")
local items = require("neo-tree.sources.buffers.lib.items")
local events = require("neo-tree.events")
local manager = require("neo-tree.sources.manager")
local git = require("neo-tree.git")
local Path = require("pathlib")

---@class NeotreeBuffers : NeotreeState
---@field config NeotreeConfig.buffers
---@field dir PathlibPath
local M = setmetatable({
  -- Attributes defined her end
  name = "buffers",
  display_name = " 󰈚 Buffers ",
  commands = require("neo-tree.sources.buffer.commands"),
  window = {},
  components = require("neo-tree.sources.buffer.components"),
  renderers = {},
}, {
  __index = require("neo-tree.sources.base"), -- Inherit from base class.
  __call = function(cls, ...)
    return cls.new(cls, ...)
  end,
})
M.__index = M

---Create new manager instance or return cache if already created.
---@param config NeotreeConfig.buffers
---@param id string # id of this state passed from `self.setup`.
---@param dir string|nil
function M.new(config, id, dir)
  local self = setmetatable({
    id = id,
    dir = dir and Path.new(dir) or Path.cwd(),
    config = config,
  }, M)
  if not self.dir:is_dir(true) then
    require("neo-tree.log").error("Buffers (%s) is not a directory. Abort.", self.dir:tostring())
    return
  end
end

local wrap = function(func)
  return utils.wrap(func, M.name)
end

local get_state = function()
  return manager.get_state(M.name)
end

local follow_internal = function()
  if vim.bo.filetype == "neo-tree" or vim.bo.filetype == "neo-tree-popup" then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local path_to_reveal = manager.get_path_to_reveal(true) or tostring(bufnr)

  local state = get_state()
  if state.current_position == "float" then
    return false
  end
  if not state.path then
    return false
  end
  local window_exists = renderer.window_exists(state)
  if window_exists then
    local node = state.tree and state.tree:get_node()
    if node then
      if node:get_id() == path_to_reveal then
        -- already focused
        return false
      end
    end
    renderer.focus_node(state, path_to_reveal, true)
  end
end

M.follow = function()
  if vim.fn.bufname(0) == "COMMIT_EDITMSG" then
    return false
  end
  utils.debounce("neo-tree-buffer-follow", function()
    return follow_internal()
  end, 100, utils.debounce_strategy.CALL_LAST_ONLY)
end

local buffers_changed_internal = function()
  for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
    local state = manager.get_state(M.name, tabid)
    if state.path and renderer.window_exists(state) then
      items.get_opened_buffers(state)
      if state.follow_current_file.enabled then
        follow_internal()
      end
    end
  end
end

---Calld by autocmd when any buffer is open, closed, renamed, etc.
M.buffers_changed = function()
  utils.debounce(
    "buffers_changed",
    buffers_changed_internal,
    100,
    utils.debounce_strategy.CALL_LAST_ONLY
  )
end

---Navigate to the given path.
---@param path PathlibPath|nil Path to navigate to. If empty, will navigate to the cwd.
M.navigate = function(state, path, path_to_reveal, window_width, manager, failed_args)
  state.dirty = false
  if path and path:absolute() ~= state.dir then
    local new_id = state.name .. state.dir:tostring()
    local reason = string.format("dir %s is not supported.", path) -- If new_id is nil, this reason will be reported to the user.
    return manager:fail(reason, new_id, state, path, path_to_reveal, window_width, failed_args)
  end
  if path_to_reveal then
    renderer.position.set(state, path_to_reveal)
  end

  items.get_opened_buffers(state)
  manager:done(state, nil)
end

---Configures the plugin, should be called before the plugin is used.
---@param config table Configuration table containing any keys that the user
--wants to change from the defaults. May be empty to accept default values.
M.setup = function(config, global_config)
  --Configure events for before_render
  if config.before_render then
    --convert to new event system
    manager.subscribe(M.name, {
      event = events.BEFORE_RENDER,
      handler = function(state)
        local this_state = get_state()
        if state == this_state then
          config.before_render(this_state)
        end
      end,
    })
  elseif global_config.enable_git_status then
    manager.subscribe(M.name, {
      event = events.BEFORE_RENDER,
      handler = function(state)
        local this_state = get_state()
        if state == this_state then
          state.git_status_lookup = git.status(state.git_base)
        end
      end,
    })
    manager.subscribe(M.name, {
      event = events.GIT_EVENT,
      handler = M.buffers_changed,
    })
  end

  local refresh_events = {
    events.VIM_BUFFER_ADDED,
    events.VIM_BUFFER_DELETED,
  }
  if global_config.enable_refresh_on_write then
    table.insert(refresh_events, events.VIM_BUFFER_CHANGED)
  end
  for _, e in ipairs(refresh_events) do
    manager.subscribe(M.name, {
      event = e,
      handler = function(args)
        if args.afile == "" or utils.is_real_file(args.afile) then
          M.buffers_changed()
        end
      end,
    })
  end

  if config.bind_to_cwd then
    manager.subscribe(M.name, {
      event = events.VIM_DIR_CHANGED,
      handler = wrap(manager.dir_changed),
    })
  end

  if global_config.enable_diagnostics then
    manager.subscribe(M.name, {
      event = events.STATE_CREATED,
      handler = function(state)
        state.diagnostics_lookup = utils.get_diagnostic_counts()
      end,
    })
    manager.subscribe(M.name, {
      event = events.VIM_DIAGNOSTIC_CHANGED,
      handler = wrap(manager.diagnostics_changed),
    })
  end

  --Configure event handlers for modified files
  if global_config.enable_modified_markers then
    manager.subscribe(M.name, {
      event = events.VIM_BUFFER_MODIFIED_SET,
      handler = wrap(manager.opened_buffers_changed),
    })
  end

  -- Configure event handler for follow_current_file option
  if config.follow_current_file.enabled then
    manager.subscribe(M.name, {
      event = events.VIM_BUFFER_ENTER,
      handler = M.follow,
    })
    manager.subscribe(M.name, {
      event = events.VIM_TERMINAL_ENTER,
      handler = M.follow,
    })
  end
end

return M
