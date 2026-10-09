# ouro-nvim

An agent that grows its own harness inside Neovim.

Inspired by **Dominik Tornow's [Ouro. The Last Harness](https://x.com/i/article/2108102766837092353)**
([original X post](https://x.com/DominikTornow/status/2108224785918439600)).
This project ports the concept from his [Emacs/Lisp Ouro repository](https://github.com/dtornow/ouro)
to Neovim/Lua. Credit for the one-prompt, one-eval bootstrap idea belongs to Dominik.

Neovim **is** the runtime. The seed makes one OpenAI request and executes one
Lua chunk in the running editor. That chunk replaces `ouro.agent` with a real
agent loop, then invokes it with your task. The model builds the loop, the
chat interface, and any extensions itself. No external agent process, Lua
interpreter, or prewritten chat loop sits behind the editor.

## Run

Requires Neovim 0.10+ and `curl` (tested on Neovim 0.12.5).
Clone the project:

```sh
git clone https://github.com/renerocksai/ouro-nvim.git
cd ouro-nvim
```

Set `OPENAI_API_KEY` in your environment or copy `.env.example` to `.env`
and replace the placeholder:

```dotenv
OPENAI_API_KEY=your-key-here
```

From this directory:

```sh
nvim -u NONE -c 'luafile boot.lua' -c OuroBoot
```

Bootstrap opens a progress log immediately. The model first replaces the seed's
one-shot agent with an asynchronous Lua loop, then uses that loop to create a
chat with a transcript, prompt buffer, and send mapping. This may take several
requests. Because the model writes that UI, its layout and bindings
can vary between boots. Look for instructions in the generated buffers.
The verified chat used **Ctrl-S** to send from the lower prompt buffer, in
normal or insert mode. Use **Ctrl-W, j/k** to move between split windows.

Start a new Neovim to grow another runtime from the seed. Nothing is generated
until you run `:OuroBoot`.

For a different initial task:

```vim
:OuroBoot Create a scratch buffer listing the open buffers, and a command to refresh it.
```

Use `:OuroLog` to see request progress, eval results, and API usage.
`:OuroCode` opens the most recently evaluated Lua. The initial bootstrap
source is also available as `require('ouro').bootstrap_code`.

## Install as a local plugin

For example, with lazy.nvim (set the key in your environment):

```lua
{
  'renerocksai/ouro-nvim',
  config = function()
    require('ouro').setup()
  end,
}
```

Loading the plugin does not call the API. Run `:OuroBoot` when you want it to
bootstrap. To invoke the grown agent directly:

```lua
require('ouro').agent('Inspect the current buffer', function(text, err)
  vim.notify(err or text)
end)
```

The default chat task also requests `ouro.chat_send(text, callback)` for
programmatic chat turns. That function becomes available after the generated
chat has been installed.

## Commands

| Command | Action |
| --- | --- |
| `:OuroBoot [task]` | Bootstrap the model-written agent; default task creates chat |
| `:OuroLog` | Show request progress, eval results, and errors |
| `:OuroCode` | Inspect the last evaluated Lua chunk |
| `:OuroStatus` | Show request count, token usage, and whether HTTP is pending |
| `:OuroStop` | Cancel pending HTTP and block further requests |
| `:OuroResetBudget` | Reset API counters and allow further requests |

## API limits

The default transport uses the [OpenAI Responses API](https://developers.openai.com/api/docs/guides/function-calling)
with `gpt-6.1-sol` and medium reasoning. Requests use `store = false`; the
generated loop carries complete response output, including encrypted
reasoning, into follow-up requests.

```lua
require('ouro').setup({
  model = 'gpt-6.1-sol',
  reasoning_effort = 'medium', -- or 'high'
  max_requests = 8,           -- includes bootstrap and failed attempts
  max_output_tokens = 4096,   -- per request, including reasoning
  output_budget = 12000,     -- cumulative output tokens for this session
  max_input_bytes = 100000,   -- bounds serialized input per request
  timeout = 120,             -- seconds per HTTP request
  env_file = '.env',
})
```

`:OuroStatus` shows cumulative requests and input/output tokens.
`:OuroStop` cancels the pending HTTP request and blocks further requests.
`:OuroResetBudget` explicitly resets these counters and resumes the transport.
There are no automatic retries. Incomplete responses are counted but their
partial code is never evaluated. API output limits include reasoning, so a
complex bootstrap may need a larger per-request limit.

Bootstrap and chat share the same session budget. The verified bootstrap used
six requests, leaving two of the default eight for conversation. When the
allowance is exhausted, press **Esc** and run `:OuroResetBudget` to deliberately
start a new allowance. Conversation history is retained.

Input tokens are reported, not limited by a tokenizer. Histories are resent
on each request and billed again. The request count and input byte limit bound
that growth; the output budget is not a dollar-spend limit.

## How it works

`lua/ouro/init.lua` exposes a shared `ouro` module/global with `prompt`, `eval`,
`eval_call`, `text`, and a one-shot `agent`. Its source is included in the
bootstrap prompt. `lua/ouro/transport.lua` supplies asynchronous HTTP,
credentials, usage accounting, and cancellation. It contains no agent loop.

The generated loop continues from callbacks, so requests do not block the
editor. Lua chunks run via `loadstring` and `pcall` in the same process as
Neovim: they can inspect buffers, redefine `ouro.agent`, add commands, and
use all of `vim.api`, `vim.fn`, and `vim.uv`. Errors become tool results for
the generated loop to handle.

This shares the original experiment's trust model: evaluated Lua has your
editor's filesystem and process access. API limits govern the supplied
transport; they cannot stop arbitrary generated Lua from blocking the editor
or replacing the transport. Use a disposable editor/workspace for experiments.
`:OuroStop` cancels HTTP, not a currently executing infinite Lua loop.

Generated code lives in this Neovim session. Save a buffer or source explicitly
if you want to retain it; the seed does not silently edit your configuration.

## Troubleshooting

- **Waiting at startup:** the progress log shows the current request. Use
  `:OuroStatus` to check `pending`; the default HTTP timeout is 120 seconds.
- **HTTP 503:** the service is overloaded. Retry `:OuroBoot` if the seed has
  not yet been replaced. If the grown agent failed during setup, start a fresh
  editor for a new bootstrap.
- **Missing API key:** set `OPENAI_API_KEY` or check the selected `.env` file.
  `boot.lua` reads `.env` next to itself; plugin `setup()` defaults to the
  current working directory's `.env`.
- **Budget exhausted:** run `:OuroResetBudget` to continue deliberately.
- **Incomplete response:** no partial Lua runs. A larger `max_output_tokens`
  setting may be needed, especially with high reasoning effort.

## Verify

```sh
bash scripts/test.sh
```

The deterministic tests make no API calls. They cover same-process eval,
bootstrap replacement and generated feedback, reasoning replay, errors,
UTF-8 result truncation, credentials, limits, and cancellation.

An opt-in smoke test boots a model-written chat, asks it to mutate a Lua value
inside Neovim, then checks conversation history. This uses real API tokens,
with at most six requests and 10,000 output tokens:

```sh
nvim --headless -u NONE -c 'luafile scripts/live.lua' -c 'qa!'
```

Live verification succeeded in Neovim 0.12.5: `gpt-6.1-sol` installed its
own asynchronous Lua loop, built transcript/prompt buffers, and responded
to a message sent through the generated Ctrl-S mapping. Initial attempts
returned HTTP 503; a later successful response exposed and helped fix
JSON `error: null` handling in the transport.

The stock-Python version is a separate project, `ouro-python`, using a Python
interpreter as its runtime instead of an editor.
