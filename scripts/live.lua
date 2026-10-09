-- Opt-in API smoke test. Run from the project root; it uses real API tokens.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local O = require("ouro").setup({ max_requests = 6, output_budget = 10000 })
local seed = O.agent
local failure
local original_log = O.log
O.log = function(message)
  original_log(message)
  if tostring(message):match("^error:") then failure = tostring(message) end
end
local function wait_for(predicate)
  assert(vim.wait(180000, function() return failure or predicate() end, 20), "Timed out")
  assert(not failure, failure)
end
local ok, err = pcall(function()
  O.boot(nil, function(_, boot_error) failure = boot_error end)
  wait_for(function() return type(O.chat_send) == "function" and not O.status().pending end)
  assert(O.agent ~= seed, "Model did not replace the seed agent")
  local done, reply, turn_error = false
  O.chat_send("Use eval to set ouro.smoke_value = 42 in this editor and return that value. Then reply briefly.", function(text, error)
    done, reply, turn_error = true, text, error
  end)
  wait_for(function() return done end)
  assert(not turn_error, turn_error)
  assert(O.smoke_value == 42, "Model did not mutate the shared Neovim runtime")
  print("Live runtime mutation verified: " .. tostring(reply))
  done = false
  O.chat_send("What value did I just ask you to set? Answer using our conversation history, without tools.", function(text, error)
    done, reply, turn_error = true, text, error
  end)
  wait_for(function() return done end)
  assert(not turn_error, turn_error)
  assert(reply and reply:find("42", 1, true), "Chat did not retain conversation history")
  print("Live conversation history verified")
end)
print("Usage: " .. vim.json.encode(O.status()))
if not ok then print(tostring(err)); O.stop(); vim.cmd("cquit 1") end
