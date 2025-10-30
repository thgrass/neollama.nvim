-- plugin/ollama_chat.lua
-- Define user commands and wire them to the module

local M = require("ollama_chat")

-- :OllamaChat [model?]
vim.api.nvim_create_user_command("OllamaChat", function(opts)
  M.open_chat_tab(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

-- :OllamaAsk {text}
vim.api.nvim_create_user_command("OllamaAsk", function(opts)
  M.ask(opts.args)
end, { nargs = "+" })

-- :OllamaSendSelection (uses current visual selection)
vim.api.nvim_create_user_command("OllamaSendSelection", function(_)
  M.send_visual_selection()
end, { range = true })

-- :OllamaSendBuffer (send entire buffer)
vim.api.nvim_create_user_command("OllamaSendBuffer", function(_)
  M.send_current_buffer()
end, {})

-- :OllamaAddBuffer (add current buffer to context)
vim.api.nvim_create_user_command("OllamaAddBuffer", function(_)
  M.add_current_buffer()
end, {})

-- :OllamaClearAddedBuffers
vim.api.nvim_create_user_command("OllamaClearAddedBuffers", function(_)
  M.clear_added_buffers()
end, {})

-- :OllamaSendAddedBuffers
vim.api.nvim_create_user_command("OllamaSendAddedBuffers", function(_)
  M.send_added_buffers()
end, {})

-- :OllamaModel [model?] (print or set model for current chat)
vim.api.nvim_create_user_command("OllamaModel", function(opts)
  M.cmd_model(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

-- :OllamaSetServer {url}
vim.api.nvim_create_user_command("OllamaSetServer", function(opts)
  M.set_server_url(opts.args)
end, { nargs = 1 })
