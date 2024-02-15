local M = {
  _has_nio = nil,
  ---@module "nio"
  nio = nil,
}

function M.check_nio_install()
  if M._has_nio == nil then
    M._has_nio, M.nio = pcall(_G.require, "nio")
  end
  return not not M._has_nio
end

function M.run(func)
  if not M.check_nio_install() then
    return func()
  else
    return M.nio.run(func)
  end
end

function M.wrap(func, argc, opts)
  if not M.check_nio_install() then
    return func
  else
    return M.nio.wrap(func, argc or 0, opts)
  end
end

function M.create(func, argc)
  if not M.check_nio_install() then
    return func
  else
    return M.nio.wrap(func, argc or 0)
  end
end

---Wait all tasks in `array`
---@param array nio.tasks.Task[]
---@param from integer|nil # Index of first task in `array`. Default: 1.
---@param to integer|nil # Index of last task in `array`. Default: #array.
function M.wait_all(array, from, to)
  if not M.check_nio_install() then
    return #array
  else
    local i = from or 1
    if i < 1 then
      print(debug.traceback("wait_all invalid start index"))
    end
    while array[i] do
      array[i]:wait()
      array[i] = nil
      i = i + 1
      if to ~= nil and i > to then
        break
      end
    end
    return i - 1
  end
end

---Cancel all tasks in `array` and run just the last task.
---@param array nio.tasks.Task[]
---@param from integer|nil # Index of first task in `array`. Default: 1.
---@param to integer|nil # Index of last task in `array`. Default: #array.
function M.wait_last_only(array, from, to)
  if not M.check_nio_install() then
    return #array
  else
    from = from or 1
    -- if not to then
    --   -- wait for a while until all tasks are registerd.
    --   -- checks the length of array each n seconds, where n grows proportional to the number of piled up tasks.
    --   -- when there's no more tasks added since last check, the very last task is waited.
    --   local last_diff = #array - from
    --   while true do
    --     if last_diff > 1 then
    --       M.sleep(last_diff * 1000)
    --     end
    --     local diff = #array - from
    --     if diff > last_diff then
    --       last_diff = diff
    --     else
    --       break
    --     end
    --   end
    -- end
    to = to or #array
    local last_success_index = from
    for i = from, to do
      if i == to then
        array[i]:wait()
      else
        array[i]:cancel()
      end
      last_success_index = i
      array[i] = nil
    end
    return last_success_index
  end
end

function M.current_task()
  if not M.check_nio_install() then
    return false
  end
  if not M.nio.current_task then
    M.nio.current_task = function() ---@diagnostic disable-line
      return require("nio.tasks").current_task()
    end
  end
  return M.nio.current_task()
end

---@return nio.control.Semaphore
function M.semaphore(value)
  if not M.check_nio_install() then
    return {
      acquire = function() end,
      release = function() end,
      with = function(cb)
        cb()
      end,
    }
  else
    return require("nio.control").semaphore(value)
  end
end

function M.sleep(ms)
  if not M.check_nio_install() then
    -- cannot sleep.
  else
    return M.nio.sleep(ms)
  end
end

function M.elapsed(log, start)
  vim.print(
    string.format([[%.3f nio %s : ]], os.clock() - start, M.current_task() and "true " or "false")
      .. log
  )
end

return M
