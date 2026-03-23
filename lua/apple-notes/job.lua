--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Shared async shell-out utility.
---
--- Wraps vim.fn.jobstart with stdout/stderr buffering, timeout support,
--- and structured error handling. Used by db.lua, applescript.lua, and
--- converter.lua to avoid repeating the same jobstart boilerplate.
---
--- Lifecycle:
---   start → stdout buffered → stderr buffered → on_exit → callback
---
--- @module apple-notes.job
local M = {}

--- Run an external command asynchronously.
---
--- @param cmd string[] The command and arguments to execute
--- @param opts? { input?: string, timeout?: number } Options:
---   - input: string to write to stdin (for pandoc conversion)
---   - timeout: milliseconds before killing the job (default: 30000)
--- @param callback fun(err: string|nil, result: string) Called on completion
--- @return number job_id The job ID from vim.fn.jobstart
function M.run(cmd, opts, callback)
  opts = opts or {}
  local timeout = opts.timeout or 30000
  local stdout_chunks = {}
  local stderr_chunks = {}
  local timer = nil

  local ok, job_id = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout_chunks = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr_chunks = data
      end
    end,
    on_exit = function(_, code)
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end

      local stdout = table.concat(stdout_chunks, "\n"):gsub("\n$", "")
      local stderr = table.concat(stderr_chunks, "\n"):gsub("\n$", "")

      vim.schedule(function()
        if code ~= 0 then
          callback(stderr ~= "" and stderr or ("Command failed with exit code " .. code), nil)
        else
          callback(nil, stdout)
        end
      end)
    end,
  })

  if not ok then
    local err_msg = tostring(job_id)
    if err_msg:match("is not executable") then
      err_msg = string.format("'%s' is not installed or not on $PATH", cmd[1])
    end
    vim.schedule(function()
      callback(err_msg, nil)
    end)
    return -1
  end

  if job_id <= 0 then
    vim.schedule(function()
      callback("Failed to start command: " .. table.concat(cmd, " "), nil)
    end)
    return job_id
  end

  -- Write stdin if provided (for pandoc)
  if opts.input then
    vim.fn.chansend(job_id, opts.input)
    vim.fn.chanclose(job_id, "stdin")
  end

  -- Timeout handling
  timer = vim.loop.new_timer()
  timer:start(timeout, 0, function()
    vim.fn.jobstop(job_id)
    timer:close()
    timer = nil
    vim.schedule(function()
      callback("Command timed out after " .. timeout .. "ms", nil)
    end)
  end)

  return job_id
end

return M
