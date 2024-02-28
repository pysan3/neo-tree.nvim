-- This file is for functions that mutate the filesystem.

-- This code started out as a copy from:
-- https://github.com/mhartington/dotfiles
-- and modified to fit neo-tree's api.
-- Permalink: https://github.com/mhartington/dotfiles/blob/7560986378753e0c047d940452cb03a3b6439b11/config/nvim/lua/mh/filetree/init.lua
-- local scan = require("plenary.scandir")
local utils = require("neo-tree.utils")
local inputs = require("neo-tree.ui.inputs")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
-- local Path = require("plenary").path
local nio = require("neo-tree.utils.nio_wrapper")
local Path = require("pathlib")

local M = {}

---Create a new node inside `target_dir`.
M.create_node = nio.wrap(
  ---@param target_dir PathlibPath
  ---@param cwd PathlibPath|nil
  ---@param make_dir boolean|nil # If true, creates a directory.
  ---@param callback function|nil
  ---@return PathlibPath[]|nil
  function(target_dir, cwd, make_dir, callback)
    local rel = cwd and target_dir:relative_to(cwd) or target_dir
    local base = rel:tostring() .. rel.sep_str
    local msg = make_dir and "Enter name for new directory:"
      or "Enter name for new file or directory (dirs end with a " .. rel.sep_str .. "):"
    nio.run(function()
      local destinations = inputs.input_async(msg, base)
      if not destinations then
        return
      end
      local results = {}
      for _, destination in ipairs(utils.brace_expand(destinations)) do
        if not destination or destination == base then
          return
        end
        local is_dir = make_dir or destination:find("[/\\]$")
        ---@type PathlibPath
        local dest = (cwd or Path.cwd()) / destination
        if dest:exists() then
          log.warn("File already exists")
          return
        end
        local suc = false
        if is_dir then
          suc = dest:mkdir(493, true) and true or false
        else
          suc = dest:touch(420, true) and true or false
        end
        if not suc then
          vim.api.nvim_err_writeln(dest.error_msg)
          if not dest:exists() then
            vim.api.nvim_err_writeln("Could not create file " .. destination)
            return
          else
            log.warn("Failed to complete file creation of " .. destination)
          end
        end
        results[#results + 1] = dest
      end
      vim.schedule(function()
        for _, destination in ipairs(results) do
          events.fire_event(events.FILE_ADDED, destination)
        end
        if callback then
          callback(results)
        end
      end)
    end)
  end,
  4,
  { strict = false }
)

---Create a new directory inside `target_dir`.
M.create_directory = nio.wrap(
  ---@param target_dir PathlibPath
  ---@param cwd PathlibPath|nil
  ---@param callback function|nil
  function(target_dir, cwd, callback)
    return M.create_node(target_dir, cwd, true, callback)
  end,
  3,
  { strict = false }
)

local function find_replacement_buffer(for_buf)
  local bufs = vim.api.nvim_list_bufs()
  -- make sure the alternate buffer is at the top of the list
  local alt = vim.fn.bufnr("#")
  if alt ~= -1 and alt ~= for_buf then
    table.insert(bufs, 1, alt)
  end
  -- find the first valid real file buffer
  for _, buf in ipairs(bufs) do
    if buf ~= for_buf then
      local is_valid = vim.api.nvim_buf_is_valid(buf)
      if is_valid then
        local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
        if buftype == "" then
          return buf
        end
      end
    end
  end
  return -1
end

local function clear_buffer(path)
  local buf = utils.find_buffer_by_name(path)
  if buf < 1 then
    return
  end
  local alt = find_replacement_buffer(buf)
  -- Check all windows to see if they are using the buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      -- if there is no alternate buffer yet, create a blank one now
      if alt < 1 or alt == buf then
        alt = vim.api.nvim_create_buf(true, false)
      end
      -- replace the buffer displayed in this window with the alternate buffer
      vim.api.nvim_win_set_buf(win, alt)
    end
  end
  local success, msg = pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not success then
    log.error("Could not clear buffer: ", msg)
  end
end

M.delete_node = nio.wrap(
  ---@param target PathlibPath
  ---@param noconfirm boolean|nil
  ---@param callback function|nil
  ---@return PathlibPath[]
  function(target, noconfirm, callback)
    ---@type PathlibPath[]
    local removed_files = {}
    local return_removed = function()
      if callback then
        return callback(removed_files)
      end
    end
    if not target:exists() then
      log.warn("Could not find delete target: " .. target:tostring())
      return return_removed()
    end
    local msg = string.format("Are you sure you want to delete '%s'?", target:basename())
    if target:is_dir(false) then
      for _ in target:fs_iterdir(false, 1) do
        msg = "WARNING: Dir not empty! " .. msg
        break
      end
    end
    nio.run(function()
      local yes = noconfirm or inputs.confirm_async(msg)
      if not yes then
        return return_removed()
      end
      ---Removes a single file and it's vim buffer.
      ---@param file PathlibPath
      local function unlink_file(file)
        local result = file:unlink()
        nio.scheduler()
        if result then
          clear_buffer(file)
          events.fire_event(events.FILE_DELETED, file)
          table.insert(removed_files, file)
        end
      end
      ---Recursively removes directory with lua.
      ---@param dir PathlibPath
      local function remove_recursive(dir)
        if not dir:is_dir(false) then
          return unlink_file(dir)
        end
        local gather = {}
        for child in dir:fs_iterdir(false, 1) do
          gather[#gather + 1] = nio.run(function()
            return remove_recursive(child)
          end)
        end
        vim.tbl_map(nio.wait, gather)
        table.insert(removed_files, dir)
      end
      if not target:is_dir(false) then
        return return_removed(unlink_file(target))
      end
      local cmd_path = target:cmd_string()
      local suc, output
      if utils.is_windows then
        suc, output = utils.execute_command({ "cmd.exe", "/c", "rmdir", "/s", "/q", cmd_path })
      else
        suc, output = utils.execute_command({ "rm", "-Rf", cmd_path })
      end
      if not suc then
        log.fmt_debug(
          "Could not delete directory '%s' with '%s': %s",
          target,
          utils.is_windows and "rmdir" or "rm",
          table.concat(output, "\n")
        )
        return return_removed(remove_recursive(target))
      end
      table.insert(removed_files, target)
      log.info("Deleted directory ", target:absolute():tostring())
      return return_removed()
    end) ---@diagnostic disable-line
  end,
  3,
  { strict = false }
)

M.delete_nodes = nio.wrap(
  ---Delete files in a batch.
  ---@param paths_to_delete PathlibPath[]
  ---@param callback function|nil
  ---@return PathlibPath[] deleted
  function(paths_to_delete, callback)
    nio.run(function()
      local msg = "Are you sure you want to delete " .. #paths_to_delete .. " items?"
      local confirmed = inputs.confirm_async(msg)
      if not confirmed then
        return callback and callback()
      end
      local deleted = {}
      for _, path in ipairs(paths_to_delete) do
        vim.list_extend(deleted, M.delete_node(path, true))
      end
      if callback then
        callback(deleted)
      end
    end) ---@diagnostic disable-line
  end,
  2,
  { strict = false }
)

---Copy source to destination, but if destination exists or is nil, asks user for a different path.
M.copy_node = nio.wrap(
  ---@param source PathlibPath
  ---@param _destination PathlibPath|nil
  ---@param cwd PathlibPath|nil
  ---@param callback function|nil
  ---@return PathlibPath source
  ---@return PathlibPath|nil destination
  function(source, _destination, cwd, callback)
    callback = callback or function(...) end
    nio.run(function()
      local msg = string.format("Copy %s to:", source:basename())
      local dest = M.callback_on_new_path(_destination or source, cwd, msg)
      if source == dest then
        log.warn("Cannot copy a file/folder to itself.")
        return callback(source, nil)
      end
      dest:parent_assert():mkdir(dest.const.o755, true)
      local success = source:copy(dest)
      if not success then
        log.fmt_error("Could not copy the file(s) from %s to %s:", source, dest, source.error_msg)
        return callback(source, nil)
      end
      return callback(source, dest)
    end) ---@diagnostic disable-line
  end,
  4,
  { strict = false }
)

---Rename all buffers that are related (itself or children) of `old_path`.
---@param bufnr integer|nil # Checks this bufnr. If nil, checks all buffers.
---@param old_path PathlibPath
---@param new_path PathlibPath
local function rename_buffer(bufnr, old_path, new_path)
  if not bufnr then
    nio.scheduler()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      nio.wait(nio.run(function()
        rename_buffer(buf, old_path, new_path)
      end))
    end
    return
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local buf_path = old_path.new(buf_name)
  if not buf_path:is_relative_to(old_path) then
    return false
  end
  local save_to_new_path = vim.api.nvim_get_option_value("modified", { buf = bufnr })
  if save_to_new_path then
    local msg = old_path:tostring() .. " has been modified. Save under new name? (y/n) "
    if inputs.confirm_async(msg) then
      save_to_new_path = true
    else
      nio.scheduler()
      vim.api.nvim_err_writeln(
        "Skipping force save. You'll need to save it with `:w!`"
          .. " when you are ready to force writing with the new name."
      )
    end
  end
  nio.scheduler()
  vim.api.nvim_buf_set_name(bufnr, new_path:tostring())
  if save_to_new_path then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd.write({ bang = true })
    end)
  end
end

---Move source to destination, but if destination exists or is nil, asks user for a different path.
M.move_node = nio.wrap(
  ---@param source PathlibPath
  ---@param _destination PathlibPath|nil
  ---@param cwd PathlibPath|nil
  ---@param callback function|nil
  ---@return PathlibPath source
  ---@return PathlibPath|nil destination
  function(source, _destination, cwd, callback)
    callback = callback or function(...) end
    nio.run(function()
      local msg = string.format("move %s to:", source:basename())
      local dest = M.callback_on_new_path(_destination or source, cwd, msg)
      if source == dest then
        log.warn("Cannot move a file/folder to itself.")
        return callback(source, nil)
      end
      dest:parent_assert():mkdir(dest.const.o755, true)
      local success = source:move(dest)
      if not success then
        log.fmt_error("Could not move the file(s) from %s to %s:", source, dest, source.error_msg)
        return callback(source, nil)
      end
      rename_buffer(nil, source, dest)
      return callback(source, dest)
    end) ---@diagnostic disable-line
  end,
  4,
  { strict = false }
)

---Checks if `new_path` does not exist and run callback. If file already exists, asks user again for a different path.
M.callback_on_new_path = nio.wrap(
  ---@param new_path PathlibPath
  ---@param cwd PathlibPath|nil
  ---@param first_message string|nil # Message to popup to user. Shows `... already exists.` from the second time.
  ---@param callback function|nil
  ---@return PathlibPath unique_path
  function(new_path, cwd, first_message, callback)
    cwd = cwd or new_path:parent_assert()
    nio.run(function()
      local first_iteration = true
      while new_path:exists() do
        local name = new_path:relative_to(cwd, false)
        local name_string = tostring(name or new_path:basename())
        local message = first_iteration and first_message
          or name_string .. " already exists. Please enter a new name: "
        local input = inputs.input_async(message, name_string)
        new_path = cwd / input
        first_iteration = false
      end
      return callback and callback(new_path)
    end) ---@diagnostic disable-line
  end,
  4,
  { strict = false }
)

return M
