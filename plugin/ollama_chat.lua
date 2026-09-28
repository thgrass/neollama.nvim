-- plugin/ollama_chat.lua
-- Define user commands and wire them to the module

local M = require("ollama_chat")

-- :OllamaChat [model?]
vim.api.nvim_create_user_command("OllamaChat", function(opts)
	M.open_chat_tab(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

-- :OllamaChatClose
vim.api.nvim_create_user_command("OllamaChatClose", function(_)
	M.close_chat()
end, {})

-- :OllamaCancel (stop the active request for the current chat)
vim.api.nvim_create_user_command("OllamaCancel", function(_)
	M.cancel()
end, {})

-- :OllamaAsk {text}
vim.api.nvim_create_user_command("OllamaAsk", function(opts)
	M.ask(opts.args)
end, { nargs = "+" })

-- :OllamaSendSelection (uses current visual selection, or an explicit range)
vim.api.nvim_create_user_command("OllamaSendSelection", function(opts)
	M.send_visual_selection(opts.range ~= nil, opts.line1, opts.line2)
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

-- Clean up session state when a chat buffer goes away, so stale
-- sessions (and their running jobs) do not leak or get reused.
vim.api.nvim_create_augroup("OllamaChatCleanup", { clear = true })
vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
	group = "OllamaChatCleanup",
	callback = function(args)
		M.on_buf_removed(args.buf)
	end,
})
