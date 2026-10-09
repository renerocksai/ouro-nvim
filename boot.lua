-- Load the seed into this Neovim; :OuroBoot asks the model to grow it.
local file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(file, ":p:h")
vim.opt.runtimepath:prepend(root)
require("ouro").setup({ env_file = root .. "/.env" })
