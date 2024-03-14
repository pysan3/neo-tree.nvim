local NuiSplit = require("nui.split")
local buf_storage = require("nui.utils.buf_storage")
local utils = require("nui.utils")

---@class NeotreeCurrentWin.internal : nui_split_internal
---@field last_buf integer|nil

---@class NeotreeCurrentWin : NuiSplit
---@field private _ NeotreeCurrentWin.internal
local M = NuiSplit:extend("NeotreeCurrentWin") ---@diagnostic disable-line

function M:_open_window()
  if self.winid or not self.bufnr then
    return
  end

  self.winid = vim.api.nvim_get_current_win()
  self._.last_buf = vim.api.nvim_get_current_buf()

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

  self.winid = nil
end

function M:_buf_destroy()
  if self.bufnr then
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      utils._.clear_namespace(self.bufnr, self.ns_id)

      if not self._.pending_quit then
        if self.bufnr == vim.api.nvim_get_current_buf() then
          local last_buf = self._.last_buf
          if not last_buf or not vim.api.nvim_buf_is_loaded(last_buf) then
            last_buf = vim.fn.bufnr("$")
          end
          if last_buf == -1 or not vim.fn.bufexists(last_buf) then
            vim.cmd("bp")
          else
            vim.api.nvim_set_current_buf(last_buf)
          end
        end
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
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
