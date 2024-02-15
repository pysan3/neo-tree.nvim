local NuiSplit = require("nui.split")
local buf_storage = require("nui.utils.buf_storage")
local utils = require("nui.utils")

---@class nt_current_internal : nui_split_internal
---@field prev_buf integer|nil

---@class NeotreeCurrentWin : NuiSplit
---@field private _ nt_current_internal
local M = NuiSplit.static.extend(NuiSplit, "NeotreeCurrentWin") ---@diagnostic disable-line

function M:_get_prev_buf()
  local new_buf = self._.prev_buf
  if new_buf and vim.api.nvim_buf_is_valid(new_buf) then
    return new_buf
  end
  new_buf = vim.fn.bufnr("#")
  if new_buf >= 1 then
    return new_buf
  end
  return vim.api.nvim_create_buf(true, false)
end

function M:_open_window()
  if self.winid or not self.bufnr then
    return
  end

  self._.prev_buf = vim.api.nvim_get_current_buf()
  self.winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(self.winid, self.bufnr)

  if self._.enter then
    vim.api.nvim_set_current_win(self.winid)
  end

  utils._.set_win_options(self.winid, self._.win_options)
end

function M:_close_window()
  if not self.winid then
    return
  end

  if vim.api.nvim_win_is_valid(self.winid) and not self._.pending_quit then
    vim.api.nvim_win_set_buf(self.winid, self:_get_prev_buf())
  end

  self.winid = nil
end

function M:_buf_destroy()
  if self.bufnr then
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      utils._.clear_namespace(self.bufnr, self.ns_id)

      if not self._.pending_quit then
        vim.api.nvim_win_set_buf(self.winid, self:_get_prev_buf())
        -- TODO: No need to delete the buffer? Test it out.
        -- vim.api.nvim_buf_delete(self.bufnr, { force = true })
      end
    end

    buf_storage.cleanup(self.bufnr)

    self.bufnr = nil
  end
end

function M:hide()
  -- Hide is not possible with current.
  return self:unmount()
end

---@alias NeotreeCurrentWin.constructor fun(options: nui_split_options): NeotreeCurrentWin
---@type NeotreeCurrentWin|NeotreeCurrentWin.constructor
local NeotreeCurrentWin = M

return NeotreeCurrentWin
