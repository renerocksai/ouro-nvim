-- Deterministic runtime/transport integration tests; no network or API spend.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local T = require("ouro.transport")
local O = require("ouro")
local original_system = vim.system
local original_key = vim.env.OPENAI_API_KEY
vim.env.OPENAI_API_KEY = "test-private-key"
local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ": " .. tostring(err)) end
  passed = passed + 1
  print("ok " .. name)
end
local function await(fn)
  local done, response, err = false
  fn(function(r, e) done, response, err = true, r, e end)
  assert(vim.wait(2000, function() return done end, 5), "callback timed out")
  return response, err
end
local function mock_response(response, status, exit_code)
  vim.system = function(argv, options, callback)
    assert(not table.concat(argv, " "):find("test-private-key", 1, true), "secret in argv")
    assert(options.stdin:find("test-private-key", 1, true), "missing authorization")
    callback({ code = exit_code or 0, stdout = vim.json.encode(response) .. "\n" .. (status or "200") })
    return { kill = function() end }
  end
end
local function completed(output, tokens)
  -- Real Responses objects contain error:null; vim.json.decode maps it to vim.NIL.
  return { status = "completed", error = vim.NIL, output = output or {}, usage = { input_tokens = 10, output_tokens = tokens or 10 } }
end

test("Lua eval shares Neovim runtime and replaces functions", function()
  local text, ok = O.eval("ouro.probe = function() return vim.api.nvim_get_current_buf() end; return ouro.probe()")
  assert(ok and tonumber(text) == vim.api.nvim_get_current_buf())
  local _, syntax = O.eval("not valid lua")
  local _, runtime = O.eval("error('boom')")
  assert(not syntax and not runtime)
end)
test("tool calls yield matched outputs including errors", function()
  local result = O.eval_call({ name = "eval", call_id = "call-a", arguments = '{"expression":"return 7"}' })
  assert(result.type == "function_call_output" and result.call_id == "call-a" and result.output == "7")
  assert(O.eval_call({ name = "eval", call_id = "b", arguments = "bad" }).output:find("ERROR"))
  assert(O.eval_call({ name = "unknown", call_id = "c" }).output:find("unknown tool"))
end)
test("Tool-result truncation preserves UTF-8", function()
  local result = O.eval_call({ name = "eval", call_id = "unicode", arguments = vim.json.encode({ expression = "return string.rep('é', 7000)" }) })
  assert(result.output:find("truncated"))
  local valid = pcall(vim.str_utfindex, result.output, "utf-32", #result.output, true)
  assert(valid, "truncated result is not valid UTF-8")
end)
test("Requests schema, accounting, and no credentials in argv", function()
  local captured
  mock_response(completed({ { type = "message", content = { { type = "output_text", text = "hello" } } } }, 12))
  local fake = vim.system
  vim.system = function(argv, options, callback)
    captured = options.stdin
    return fake(argv, options, callback)
  end
  local client = T.new()
  local response, err = await(function(cb) client.request({ { role = "user", content = "hi" } }, cb) end)
  assert(not err and O.text(response) == "hello")
  assert(captured:find("gpt-6.1-sol", 1, true) and captured:find("reasoning.encrypted_content", 1, true))
  assert(client.status().requests == 1 and client.status().output_tokens == 12 and client.status().input_tokens == 10)
end)
test("Budget stops additional requests and can explicitly reset", function()
  mock_response(completed({}, 280))
  local client = T.new({ max_requests = 1, output_budget = 500 })
  await(function(cb) client.request({}, cb) end)
  local response, err = await(function(cb) client.request({}, cb) end)
  assert(not response and err:find("budget exhausted"))
  assert(client.status().requests == 1)
  assert(client.reset())
  assert(client.status().requests == 0)
end)
test("Refuse oversized input and missing credentials before HTTP", function()
  local client = T.new({ max_input_bytes = 2 })
  local _, err = await(function(cb) client.request({ "oversized" }, cb) end)
  assert(err:find("max_input_bytes") and client.status().requests == 0)
  vim.env.OPENAI_API_KEY = nil
  client = T.new({ env_file = "/tmp/ouro-does-not-exist.env" })
  _, err = await(function(cb) client.request({}, cb) end)
  assert(err:find("OPENAI_API_KEY"))
  vim.env.OPENAI_API_KEY = "test-private-key"
end)
test("Literal dotenv parsing supports export and quotes", function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "export OPENAI_API_KEY='test-private-key' # comment" }, path)
  vim.env.OPENAI_API_KEY = nil
  mock_response(completed())
  local _, err = await(function(cb) T.new({ env_file = path }).request({}, cb) end)
  vim.fn.delete(path)
  vim.env.OPENAI_API_KEY = "test-private-key"
  assert(not err)
end)
test("HTTP errors are redacted; incomplete responses never execute", function()
  mock_response({ error = { message = "invalid test-private-key" } }, "401")
  local _, err = await(function(cb) T.new().request({}, cb) end)
  assert(err:find("401") and not err:find("test-private-key", 1, true))
  mock_response({ status = "incomplete", output = {}, usage = { output_tokens = 4096 } })
  local client = T.new()
  _, err = await(function(cb) client.request({}, cb) end)
  assert(err:find("no partial Lua executed") and client.status().output_tokens == 4096)
  mock_response({}, "000", 28)
  _, err = await(function(cb) T.new().request({}, cb) end)
  assert(err:find("curl exit 28"))
end)
test("Stop cancels callbacks once, blocks new calls and suppresses stale responses", function()
  local complete, killed, calls = nil, false, 0
  vim.system = function(_, _, cb) complete = cb; return { kill = function() killed = true end } end
  local client = T.new()
  client.request({}, function(response, err) calls = calls + 1; assert(not response and err == "Stopped by user") end)
  assert(not client.reset())
  client.stop()
  complete({ code = 0, stdout = vim.json.encode(completed()) .. "\n200" })
  vim.wait(20, function() return false end)
  assert(killed and calls == 1)
  local _, err = await(function(cb) client.request({}, cb) end)
  assert(err:find("Stopped"))
end)
test("Failed bootstrap reports error and permits retry after partial mutation", function()
  local seed = O.agent
  mock_response(completed({ { type = "function_call", name = "eval", call_id = "fail", arguments = vim.json.encode({ expression = "ouro.agent = function() end; error('boot failed')" }) } }))
  O.setup()
  local response, err = await(function(cb) O.boot("test", cb) end)
  assert(not response and err:find("boot failed"))
  assert(O.agent == seed)
  mock_response(completed({ { type = "function_call", name = "eval", call_id = "invalid", arguments = "bad-json" } }))
  response, err = await(function(cb) O.boot("test", cb) end)
  assert(not response and err:find("invalid eval arguments"))
  mock_response(completed({ { type = "function_call", name = "eval", call_id = "noop", arguments = '{"expression":"return 42"}' } }))
  response, err = await(function(cb) O.boot("test", cb) end)
  assert(not response and err:find("did not replace"))
end)
test("Single eval bootstrap installs a loop; only generated loop sends feedback", function()
  local requests = 0
  local reasoning = { type = "reasoning", id = "reasoning-1", encrypted_content = "encrypted-test", summary = {} }
  local generated = [[
    ouro.agent = function(task, callback)
      local input = { { role = "user", content = task } }
      local function step()
        ouro.prompt(input, function(response, err)
          if err then callback(nil, err); return end
          local calls = {}
          for _, item in ipairs(response.output) do
            input[#input+1] = item
            if item.type == "function_call" then calls[#calls+1] = item end
          end
          if #calls == 0 then callback(ouro.text(response)); return end
          for _, call in ipairs(calls) do input[#input+1] = ouro.eval_call(call) end
          step()
        end)
      end
      step()
    end
    ouro.agent("test task", function(text, err) ouro.test_done = text; ouro.test_error = err end)
  ]]
  vim.system = function(_, options, cb)
    requests = requests + 1
    local response
    if requests == 1 then
      response = completed({ { type = "function_call", name = "eval", call_id = "boot", arguments = vim.json.encode({ expression = generated }) } })
    elseif requests == 2 then
      response = completed({ reasoning, { type = "function_call", name = "eval", call_id = "probe", arguments = '{"expression":"ouro.live_probe = 99; return ouro.live_probe"}' } })
    else
      assert(options.stdin:find("encrypted-test", 1, true), "reasoning lost")
      assert(options.stdin:find("function_call_output", 1, true), "feedback lost")
      assert(options.stdin:find("probe", 1, true), "call ID lost")
      response = completed({ { type = "message", content = { { type = "output_text", text = "finished" } } } })
    end
    cb({ code = 0, stdout = vim.json.encode(response) .. "\n200" })
    return { kill = function() end }
  end
  O.setup()
  O.boot("test task")
  assert(vim.wait(2000, function() return O.test_done ~= nil end, 5))
  assert(O.test_done == "finished" and not O.test_error and O.live_probe == 99 and requests == 3)
end)
vim.system = original_system
vim.env.OPENAI_API_KEY = original_key
print(passed .. " tests passed")
