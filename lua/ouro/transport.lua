-- Host plumbing only. The model, not this module, writes the agent loop.
local M = {}
local defaults = {
  model = "gpt-6.1-sol", reasoning_effort = "medium",
  max_requests = 8, max_output_tokens = 4096, output_budget = 12000,
  max_input_bytes = 100000, timeout = 120, env_file = ".env",
}

local function api_key(path)
  local key = vim.env.OPENAI_API_KEY
  if key and key ~= "" then return key end
  if vim.fn.filereadable(path) == 0 then return nil end
  -- Read one literal value, never source arbitrary shell code from .env.
  for _, line in ipairs(vim.fn.readfile(path)) do
    local value = line:match("^%s*export%s+OPENAI_API_KEY%s*=%s*(.-)%s*$")
      or line:match("^%s*OPENAI_API_KEY%s*=%s*(.-)%s*$")
    if value then
      local quote = value:sub(1, 1)
      if quote == '"' or quote == "'" then
        value = value:match("^" .. quote .. "(.-)" .. quote .. "%s*#?.*$")
      else
        value = value:gsub("%s+#.*$", "")
      end
      if value and value ~= "" then return value end
    end
  end
end

local function config_quote(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"')
    :gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

function M.new(options, emit)
  local opts = vim.tbl_extend("force", defaults, options or {})
  for _, name in ipairs({ "max_requests", "max_output_tokens", "output_budget", "max_input_bytes", "timeout" }) do
    assert(type(opts[name]) == "number" and opts[name] > 0 and opts[name] % 1 == 0, name .. " must be a positive integer")
  end
  assert(opts.reasoning_effort == "medium" or opts.reasoning_effort == "high", "reasoning_effort must be medium or high")
  local stats = { requests = 0, input_tokens = 0, output_tokens = 0, stopped = false }
  local active
  local client = {}
  emit = emit or function() end

  function client.status()
    local snapshot = vim.deepcopy(stats)
    snapshot.pending = active ~= nil
    return snapshot
  end

  function client.reset()
    if active then return nil, "A request is still running" end
    stats = { requests = 0, input_tokens = 0, output_tokens = 0, stopped = false }
    return true
  end

  function client.request(input, callback)
    assert(type(callback) == "function", "prompt needs a callback(response, error)")
    local function reject(err) vim.schedule(function() callback(nil, err) end) end
    if active then reject("A request is already running"); return end
    if stats.stopped then reject("Stopped; use :OuroResetBudget to continue"); return end
    local remaining = opts.output_budget - stats.output_tokens
    if stats.requests >= opts.max_requests or remaining < 256 then
      reject("API budget exhausted; use :OuroStatus or :OuroResetBudget"); return
    end
    local ok, encoded_input = pcall(vim.json.encode, input)
    if not ok then reject("Input is not JSON serializable"); return end
    if #encoded_input > opts.max_input_bytes then reject("Input exceeds max_input_bytes; start a shorter conversation"); return end
    local key = api_key(opts.env_file)
    if not key then reject("Set OPENAI_API_KEY or put it in " .. opts.env_file); return end
    if key:find('[\r\n]') then reject("Invalid API key"); return end
    if vim.fn.executable("curl") ~= 1 then reject("curl is required"); return end

    local body = vim.json.encode({
      model = opts.model, reasoning = { effort = opts.reasoning_effort },
      max_output_tokens = math.min(opts.max_output_tokens, remaining),
      store = false, include = { "reasoning.encrypted_content" },
      parallel_tool_calls = false,
      instructions = "You run inside Neovim. Your eval tool executes Lua chunks in this editor's shared runtime. "
        .. "Use the existing ouro.prompt transport, respect its budgets, handle errors, and keep the UI responsive. "
        .. "Never read or display credentials. Be concise.",
      tools = { {
        type = "function", name = "eval", description = "Execute a Lua chunk in this running Neovim. Use return for results.",
        strict = true, parameters = {
          type = "object", properties = { expression = { type = "string" } },
          required = { "expression" }, additionalProperties = false,
        },
      } },
      input = input,
    })
    -- Credentials and JSON go over stdin, never argv or a temporary file.
    local config = "url = \"https://api.openai.com/v1/responses\"\n"
      .. "header = " .. config_quote("Authorization: Bearer " .. key) .. "\n"
      .. "header = \"Content-Type: application/json\"\n"
      .. "data = " .. config_quote(body) .. "\n"
    stats.requests = stats.requests + 1
    emit("request", { number = stats.requests, model = opts.model })
    local ticket = { callback = callback }
    active = ticket
    local function finish(response, err)
      if active ~= ticket then return end
      active = nil
      emit(err and "error" or "response", err or client.status())
      callback(response, err)
    end
    local launched, job = pcall(vim.system, {
      "curl", "-q", "--silent", "--show-error", "--connect-timeout", "15",
      "--max-time", tostring(opts.timeout), "--write-out", "\n%{http_code}", "--config", "-",
    }, { stdin = config, text = true }, function(result)
      vim.schedule(function()
        if active ~= ticket then return end
        if result.code ~= 0 then
          finish(nil, "HTTP transport failed (curl exit " .. result.code .. ")"); return
        end
        local raw, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)%s*$")
        local decoded, response = pcall(vim.json.decode, raw or "")
        if not decoded or type(response) ~= "table" then finish(nil, "Invalid API JSON response"); return end
        local usage = response.usage or {}
        stats.input_tokens = stats.input_tokens + (tonumber(usage.input_tokens) or 0)
        stats.output_tokens = stats.output_tokens + (tonumber(usage.output_tokens) or 0)
        if status ~= "200" or (response.error ~= nil and response.error ~= vim.NIL) then
          local message = type(response.error) == "table" and response.error.message or "request failed"
          -- API errors can echo supplied values; remove the credential defensively.
          message = tostring(message):gsub(vim.pesc(key), "[redacted]")
          finish(nil, "OpenAI HTTP " .. tostring(status) .. ": " .. message); return
        end
        if response.status ~= "completed" then
          finish(nil, "Response " .. tostring(response.status) .. "; no partial Lua executed (check output limit)"); return
        end
        if type(response.output) ~= "table" then finish(nil, "API response has no output array"); return end
        finish(response)
      end)
    end)
    if launched then ticket.job = job else vim.schedule(function() finish(nil, "Could not start curl") end) end
  end

  function client.stop()
    stats.stopped = true
    local ticket = active
    active = nil
    if ticket then
      if ticket.job then ticket.job:kill(15) end
      vim.schedule(function() ticket.callback(nil, "Stopped by user") end)
    end
  end
  return client
end

return M
