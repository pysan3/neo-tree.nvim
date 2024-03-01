local vim = vim
local Input = require("nui.input")
local popups = require("neo-tree.ui.popups")
local utils = require("neo-tree.utils")
local nio = require("neo-tree.utils.nio_wrapper")

local M = {}

local should_use_popup_input = function()
  local nt = require("neo-tree")
  return utils.get_value(nt.config, "use_popups_for_input", true, false)
end

M.show_input = function(input, callback)
  local config = require("neo-tree").config
  input:mount()

  if config.enable_normal_mode_for_inputs and input.prompt_type ~= "confirm" then
    vim.schedule(function()
      vim.cmd("stopinsert")
    end)
  end

  input:map("i", "<esc>", function()
    vim.cmd("stopinsert")
    if not config.enable_normal_mode_for_inputs or input.prompt_type == "confirm" then
      input:unmount()
    end
  end, { noremap = true })

  input:map("n", "<esc>", function()
    input:unmount()
  end, { noremap = true })

  input:map("n", "q", function()
    input:unmount()
  end, { noremap = true })

  input:map("i", "<C-w>", "<C-S-w>", { noremap = true })

  local event = require("nui.utils.autocmd").event
  input:on({ event.BufLeave, event.BufDelete }, function()
    input:unmount()
    if callback then
      callback()
    end
  end, { once = true })
end

M.input = function(message, default_value, callback, options, completion)
  if should_use_popup_input() then
    local popup_options = popups.popup_options(message, 10, options)

    local input = Input(popup_options, {
      prompt = " ",
      default_value = default_value,
      on_submit = callback,
    })

    M.show_input(input)
  else
    local opts = {
      prompt = message .. "\n",
      default = default_value,
    }
    if vim.opt.cmdheight:get() == 0 then
      -- NOTE: I really don't know why but letters before the first '\n' is not rendered execpt in noice.nvim
      --       when vim.opt.cmdheight = 0 <2023-10-24, pysan3>
      opts.prompt = "Neo-tree Popup\n" .. opts.prompt
    end
    if completion then
      opts.completion = completion
    end
    vim.ui.input(opts, callback)
  end
end

---Async function to prompt using `vim.ui.input` or `NuiInput` to user.
M.input_async = nio.wrap(
  ---@param message string
  ---@param default_value string
  ---@param options any
  ---@param completion any
  ---@param callback function|nil
  ---@return string
  function(message, default_value, options, completion, callback)
    vim.schedule(function()
      M.input(message, default_value, callback, options, completion)
    end) ---@diagnostic disable-line
  end,
  5,
  {}
)

---Prompt a `vim.fn.confirm` to select between yes or no.
---@param message string
---@param callback function|nil
---@return boolean
M.confirm = function(message, callback)
  callback = callback or function(_) end
  if should_use_popup_input() then
    local popup_options = popups.popup_options(message, 10)

    local input = Input(popup_options, {
      prompt = " y/n: ",
      on_close = function()
        callback(false)
      end,
      on_submit = function(value)
        callback(value == "y" or value == "Y")
      end,
    })

    input.prompt_type = "confirm"
    M.show_input(input)
  else
    callback(vim.fn.confirm(message, "&Yes\n&No") == 1)
  end ---@diagnostic disable-line
end

---Async function to prompt a `vim.fn.confirm` to select between yes or no.
M.confirm_async = nio.wrap(M.confirm, 2, {})

return M
