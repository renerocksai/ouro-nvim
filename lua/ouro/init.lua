-- The Ouro seed: one request, one eval. The model writes the real loop.
local M = {}
_G.ouro = M
local source_file = debug.getinfo(1, "S").source:sub(2)
local client
local log_buffer
local seed_agent
M.default_task = "Build a small chat interface so the user can talk with you in this Neovim. "
  .. "Use a scratch transcript and a prompt buffer with a buffer-local send mapping. "
  .. "Keep conversation history across messages; show errors and usage. "
  .. "Expose ouro.chat_send(text, callback) for sending a message programmatically, "
  .. "with callback(text, error) when the turn finishes. Do not change user config or write files."

function M.log(message)
  if not log_buffer or not vim.api.nvim_buf_is_valid(log_buffer) then
    log_buffer = vim.fn.bufnr("ouro://log")
    if log_buffer == -1 then
      log_buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(log_buffer, "ouro://log")
    end
    vim.bo[log_buffer].filetype = "text"
  end
  vim.api.nvim_buf_set_lines(log_buffer, -1, -1, false, vim.split(tostring(message), "\n", { plain = true }))
  for _, win in ipairs(vim.fn.win_findbuf(log_buffer)) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(log_buffer), 0 })
  end
end

function M.show_log()
  if not log_buffer then M.log("Ouro ready") end
  local current = vim.api.nvim_get_current_buf()
  if current == log_buffer then return end
  if vim.api.nvim_buf_get_name(current) == "" and not vim.bo[current].modified then
    vim.api.nvim_set_current_buf(log_buffer)
  else
    vim.cmd("sbuffer " .. log_buffer)
  end
end

function M.setup(options)
  if client then client.stop() end
  client = require("ouro.transport").new(options, function(event, value)
    M.log(event .. ": " .. (type(value) == "table" and vim.inspect(value) or tostring(value)))
  end)
  M.commands()
  return M
end

function M.prompt(input, callback)
  if not client then M.setup() end
  client.request(input, callback)
end

function M.status() return client and client.status() or {} end
function M.stop() if client then client.stop() end end
function M.reset_budget() if not client then M.setup() end; return client.reset() end

-- Lua chunks execute in _G, exactly where the editor and ouro live.
function M.eval(expression)
  local chunk, err = loadstring(expression, "=ouro-eval")
  if not chunk then return "ERROR: " .. err, false end
  local ok, result = pcall(chunk)
  if not ok then return "ERROR: " .. tostring(result), false end
  return vim.inspect(result), true
end

function M.eval_call(call)
  local ok, args = pcall(vim.json.decode, call.arguments or "")
  local result
  local success = false
  if call.name ~= "eval" then result = "ERROR: unknown tool " .. tostring(call.name)
  elseif not ok or type(args) ~= "table" or type(args.expression) ~= "string" then result = "ERROR: invalid eval arguments"
  else
    M.last_eval = args.expression
    local buffer = vim.fn.bufnr("ouro://last-eval.lua")
    if buffer == -1 then
      buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buffer, "ouro://last-eval.lua")
      vim.bo[buffer].filetype = "lua"
    end
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(args.expression, "\n", { plain = true }))
    result, success = M.eval(args.expression)
  end
  if #result > 12000 then
    local boundary = 12000
    while result:byte(boundary + 1) >= 128 and result:byte(boundary + 1) < 192 do boundary = boundary - 1 end
    result = result:sub(1, boundary) .. "\n[eval result truncated]"
  end
  M.log("eval: " .. result)
  return { type = "function_call_output", call_id = call.call_id, output = result }, success
end

function M.text(response)
  local parts = {}
  for _, item in ipairs(response.output or {}) do
    if item.type == "message" then
      for _, part in ipairs(item.content or {}) do
        if part.type == "output_text" then parts[#parts + 1] = part.text end
        if part.type == "refusal" then parts[#parts + 1] = part.refusal end
      end
    end
  end
  return table.concat(parts, "\n")
end

function M.agent(prompt, callback)
  M.prompt({ { role = "user", content = prompt } }, function(response, err)
    if err then M.log(err); if callback then callback(nil, err) end; return end
    local calls = {}
    for _, item in ipairs(response.output) do
      if item.type == "function_call" then calls[#calls + 1] = item end
    end
    if #calls ~= 1 then
      err = "Bootstrap needs exactly one eval call; got " .. #calls
      M.log(err); if callback then callback(nil, err) end; return
    end
    local valid, args = pcall(vim.json.decode, calls[1].arguments or "")
    if valid and type(args) == "table" then M.bootstrap_code = args.expression end
    local result, success = M.eval_call(calls[1])
    -- Deliberately no feedback request here. The eval must install its own loop.
    if not success then
      M.agent = seed_agent or M.agent
      if callback then callback(nil, result.output) end
    elseif M.agent == seed_agent then
      err = "Bootstrap eval did not replace ouro.agent"
      M.log(err); if callback then callback(nil, err) end
    elseif callback then callback(result.output) end
  end)
end
seed_agent = M.agent

function M.boot(task, callback)
  if M.agent ~= seed_agent then
    local err = "Already bootstrapped; use ouro.agent for another task"
    M.log(err); if callback then callback(nil, err) end; return
  end
  local source = table.concat(vim.fn.readfile(source_file), "\n")
  local prompt = [[You run inside Neovim with LuaJIT (Lua 5.1). Your only tool, eval,
executes a Lua chunk in this running editor. This is your seed source:

]] .. source .. [[

This is a bootstrap: ouro.agent makes ONE request and executes ONE eval for
side effects, discarding its tool result. You will see no result, so do not
explore. In one eval, replace ouro.agent with an ASYNCHRONOUS tool-feedback
loop, then call the replacement with the user's task below. Build the loop
first; let that loop build the UI. Do not call ouro.boot recursively.

Transport contract: ouro.prompt(input_array, callback) calls callback(response,
error) on Neovim's main loop. On error, response is nil: report it and STOP.
Append ALL response.output items to input (including reasoning items), then
append ouro.eval_call(item) for each function_call; each produces a
function_call_output with matching call_id. Re-request until no function calls.
Use ouro.text(response) for final text. Keep history for subsequent user turns.
Do not block/wait in a while loop: continue from callbacks. Have ouro.agent
accept (task, callback) with callback(text, error) at completion. Prevent
overlapping turns; preserve the existing prompt transport and its API budgets.
All global editor APIs and require("ouro") refer to THIS editor process.
Keep the bootstrap compact so it fits 4096 output tokens including reasoning.

User's task:
]] .. (task or M.default_task)
  M.log("Bootstrapping; the model will write and run Lua in this editor.")
  M.show_log()
  seed_agent(prompt, callback)
end

function M.commands()
  local function command(name, fn, opts) vim.api.nvim_create_user_command(name, fn, opts or {}) end
  command("OuroBoot", function(args) M.boot(args.args ~= "" and args.args or nil) end, { nargs = "*" })
  command("OuroStop", M.stop)
  command("OuroStatus", function() vim.notify(vim.inspect(M.status())) end)
  command("OuroResetBudget", function()
    local ok, err = M.reset_budget(); vim.notify(ok and "Ouro API budget reset" or err)
  end)
  command("OuroLog", M.show_log)
  command("OuroCode", function()
    local buffer = vim.fn.bufnr("ouro://last-eval.lua")
    if buffer == -1 then vim.notify("No eval yet") else vim.cmd("sbuffer " .. buffer) end
  end)
end

return M
