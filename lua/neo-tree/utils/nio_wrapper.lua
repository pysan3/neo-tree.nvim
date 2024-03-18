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

function M.nohup(func)
  if not M.check_nio_install() then
    return func()
  else
    local t = coroutine.create(func)
    vim.schedule(function()
      coroutine.resume(t)
    end)
    return t
  end
end

function M.wait(task)
  if not M.check_nio_install() or task == nil or not M.current_task() then
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
  if M.current_task() then
    return M.nio.scheduler()
  end
end

---Create new nio.process and run it.
---@param cmd string
---@param args string[]
---@return nio.process.Process|nil
---@return string|nil Error
---@overload fun(cmd: string[]): (nio.process.Process|nil, string|nil) # Pass cmd[1] and args = unpack(cmd, 2) instead.
function M.new_process(cmd, args)
  if not M.check_nio_install() then
    return nil, "nio not installed"
  end
  if type(cmd) == "string" then
    return M.nio.process.run({
      cmd = cmd,
      args = args,
    })
  else
    local _cmd = table.remove(cmd, 1)
    return M.nio.process.run({
      cmd = _cmd,
      args = cmd,
    })
  end
end

function M.execute_command(cmd, input)
  local process, err_msg = M.new_process(cmd)
  if not process then
    return false, { err_msg }
  end
  for i, value in ipairs(input or {}) do
    local err = process.stdin.write(value .. "\n")
    local msg = [[ERROR cmd: '%s', input(%s): '%s', error: %s]]
    assert(not err, string.format(msg, table.concat(cmd, " "), i, value, err))
  end
  process.stdin.close()
  if process.result() == 0 then
    return true, vim.split(process.stdout.read() or "", "\n", { plain = true, trimempty = false })
  else
    return false, {}
  end
end

---Execute a command and return an iterable that returns each line of stdout.
---@param process nio.process.Process
---@param input string[]|nil # Lines written to stdin. Each item will be appended with a '\n'.
---@param chunk_size integer|nil # Number of bytes to fetch on each batch.
---@return fun(): string|nil # Iterator
function M.execute_and_readlines(process, input, chunk_size)
  chunk_size = chunk_size or 100
  for i, value in ipairs(input or {}) do
    local err = process.stdin.write(value .. "\n")
    local msg = [[ERROR input(%s): '%s', error: %s]]
    assert(not err, string.format(msg, i, value, err))
  end
  process.stdin.close()
  local buffer = ""
  local function get_one_line()
    local cr = string.find(buffer, "\n")
    if not cr then
      repeat
        local out = process.stdout.read(chunk_size)
        if not out or #out == 0 then
          process.stdout.close()
          return nil
        end
        buffer = buffer .. out
      until string.find(buffer, "\n") ~= nil
      return get_one_line()
    end
    local result = buffer:sub(1, cr - 1)
    buffer = buffer:sub(cr + 1)
    return result
  end
  return get_one_line
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

return M
