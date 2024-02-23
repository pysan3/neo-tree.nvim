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

function M.run(func, cb)
  if not M.check_nio_install() then
    return func()
  else
    local here = debug.traceback("Run created here:")
    return M.nio.run(func, cb or function(suc, err)
      if not suc then
        vim.print("Nio task FAILED: set at " .. here, "called with " .. err)
      end
    end)
  end
end

function M.wait(task)
  if not M.check_nio_install() or task == nil then
    return task
  else
    return task.wait()
  end
end

---@generic T
---@param func T
---@param argc integer|nil
---@param opts { strict: boolean }|nil
---@return T
function M.wrap(func, argc, opts)
  if not M.check_nio_install() then
    return func
  else
    return M.nio.wrap(func, argc or 0, opts)
  end
end

function M.scheduler()
  if M.check_nio_install() then
    return M.nio.scheduler()
  end
end

function M.create(func, argc)
  if not M.check_nio_install() then
    return func
  else
    return M.nio.wrap(func, argc or 0)
  end
end

function M.execute_command(cmd, input)
  local process, err_msg = M.nio.process.run({
    cmd = cmd[1],
    args = { unpack(cmd, 2) },
  })
  if not process then
    return false, { err_msg }
  end
  for i, value in ipairs(input or {}) do
    local err = process.stdin.write(value .. "\n")
    assert(
      not err,
      ([[ERROR cmd: '%s', input(%s): '%s', error: %s]]):format(
        table.concat(cmd, " "),
        i,
        value,
        err
      )
    )
  end
  process.stdin.close()
  if process.result() == 0 then
    return true, vim.split(process.stdout.read() or "", "\n", { plain = true, trimempty = false })
  else
    return false, {}
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

---Cancel all tasks in `array`
---@param array nio.tasks.Task[]
---@param from integer|nil # Index of first task in `array`. Default: 1.
---@param to integer|nil # Index of last task in `array`. Default: #array.
function M.cancel_all(array, from, to)
  if not M.check_nio_install() then
    return #array
  else
    local i = from or 1
    if i < 1 then
      print(debug.traceback("wait_all invalid start index"))
    end
    while array[i] do
      array[i]:cancel()
      array[i] = nil
      i = i + 1
      if to ~= nil and i > to then
        break
      end
    end
    return i - 1
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

---Log elapsed time with its message.
---@param log string
---@param start number
function M.elapsed(log, start)
  vim.print(
    string.format([[%.3f nio %s : ]], os.clock() - start, M.current_task() and "true " or "false")
      .. log
  )
end

return M
