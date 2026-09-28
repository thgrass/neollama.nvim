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
end, {
	nargs = "?",
	complete = function(arg_lead, cmd_line, cursor_pos)
		return M.model_completion(arg_lead, cmd_line, cursor_pos)
	end,
})

-- :OllamaModels (pick an installed model interactively)
vim.api.nvim_create_user_command("OllamaModels", function(_)
	M.select_model()
end, {})

-- :OllamaPull {model} (pull a model, progress shown in chat)
vim.api.nvim_create_user_command("OllamaPull", function(opts)
	M.pull_model(opts.args)
end, { nargs = 1 })

-- :OllamaOptions [key=value?] (show or set request options)
vim.api.nvim_create_user_command("OllamaOptions", function(opts)
	M.cmd_options(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

-- :OllamaInsert [code?] (insert last response at cursor; code-only if arg given)
vim.api.nvim_create_user_command("OllamaInsert", function(opts)
	M.insert_last_response(opts.args ~= "")
end, {
	nargs = "?",
	complete = function()
		return { "code" }
	end,
})

-- :OllamaReplace [code?] (replace visual selection with last response)
vim.api.nvim_create_user_command("OllamaReplace", function(opts)
	M.replace_visual_selection_with_response(opts.args ~= "")
end, {
	nargs = "?",
	complete = function()
		return { "code" }
	end,
})

-- :OllamaAskCtx {text} (ask with the symbol under cursor / visible range as context)
vim.api.nvim_create_user_command("OllamaAskCtx", function(opts)
	M.ask_with_context(opts.args)
end, { nargs = "+" })

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
