-- lua/ollama_chat/init.lua
-- Interface/chat with an ollama server using 'curl'.

local M = {}

-- Config with defaults
local config = {
	server_url = "http://127.0.0.1:11434",
	model = "deepcoder:14b",
	stream = false, -- not implemented (always false in /api/generate)
}

-- Sessions keyed by chat buffer number
local sessions = {}

-- Utility: shallow copy
local function tbl_copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = v end
	return o
end

-- Setup
function M.setup(opts)
	if opts then
		for k, v in pairs(opts) do config[k] = v end
	end
end

-- Helpers to manage chat buffers
local function is_chat_buf(bufnr)
	return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_var(bufnr, "ollama_chat") == 1
end

local function get_current_chat_buf()
	local buf = vim.api.nvim_get_current_buf()
	local ok = pcall(function() return vim.api.nvim_buf_get_var(buf, "ollama_chat") end)
	if ok then
		return buf
	end
	-- If not in chat, try last used chat buffer
	for chat_buf, _ in pairs(sessions) do
		if vim.api.nvim_buf_is_valid(chat_buf) then
			return chat_buf
		end
	end
	error("No active Ollama chat buffer. Run :OllamaChat to start one.")
end

local function ensure_modifiable(buf, fn)
	local mod = vim.api.nvim_buf_get_option(buf, "modifiable")
	if not mod then vim.api.nvim_buf_set_option(buf, "modifiable", true) end
	fn()
	if not mod then vim.api.nvim_buf_set_option(buf, "modifiable", false) end
end

local function append_lines(buf, items)
	-- Flatten and split any multiline strings into pure lines
	local safe = {}
	for _, it in ipairs(items) do
		if it == nil then
			table.insert(safe, "")
		else
			local s = type(it) == "string" and it or tostring(it)
			-- keep empty lines; plain split avoids pattern magic
			local parts = vim.split(s, "\n", { plain = true })
			vim.list_extend(safe, parts)
		end
	end

	ensure_modifiable(buf, function()
		local last = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, last, last, false, safe)
	end)

	if vim.api.nvim_get_current_buf() == buf then
		local last = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(0, { last, 0 })
	end
end

local function normalize_empty(buf)
	if vim.api.nvim_buf_line_count(buf) == 1 then
		local l = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
		if l == "" or l == nil then
			return
		end
	end
end

-- Create a new chat in a tab or reopen a closed chat buffer
function M.open_chat_tab(model)
	--
	local name = "Ollama Chat"

	-- reopen existing
	if vim.fn.bufnr(name) ~= -1 then
		vim.cmd("tab sbuffer " .. vim.fn.bufnr(name))
		-- create new
	else
		vim.cmd("tabnew")
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_name(buf, name)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_option(buf, "swapfile", false)
		vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
		vim.api.nvim_buf_set_option(buf, "filetype", "ollama_chat") -- custom filetype defined in ftplugin/ollama_chat.lua
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		--vim.api.nvim_buf_set_option(buf, "diagnostic", false)
		vim.api.nvim_buf_set_var(buf, "ollama_chat", 1)

		sessions[buf] = {
			buf = buf,
			model = model or config.model,
			added_buffers = {}, -- list of bufnrs
		}

		append_lines(buf, {
			"# Ollama Chat",
			"Model: " .. sessions[buf].model,
			"",
		})
	end
end

-- Close a chat tab and destroy its chat buffer
function close_chat()
	local chat = "Ollama Chat"

	local bufnr = vim.fn.bufnr(chat)
	if bufnr == -1 then
		vim.notify("No '" .. chat .. "' buffer found", vim.log.levels.INFO)
		return
	end

	-- Close all windows that show this buffer
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == bufnr then
			-- force=true so it will close even if there are changes, adjust if you like
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	-- Now delete the buffer itself
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true }) -- like :bwipeout
	end
end

vim.api.nvim_create_user_command("OllamaChatClose", function()
	close_chat()
end, {})


-- Get or create a session for current chat buffer
local function session_for_current_chat()
	local buf = get_current_chat_buf()
	local sess = sessions[buf]
	if not sess then
		sessions[buf] = { buf = buf, model = config.model, added_buffers = {} }
		sess = sessions[buf]
	end
	return sess
end

-- Build a prompt including added buffer contexts
local function build_prompt_with_context(sess, prompt_text)
	local pieces = {}
	if sess.added_buffers and #sess.added_buffers > 0 then
		table.insert(pieces, "Context from added buffers:")
		for _, b in ipairs(sess.added_buffers) do
			if vim.api.nvim_buf_is_valid(b) then
				local name = vim.api.nvim_buf_get_name(b)
				local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
				table.insert(pieces,
					string.format("<<FILE: %s>>\n%s",
						name ~= "" and name or ("[No Name " .. b .. "]"),
						table.concat(lines, "\n")))
			end
		end
		table.insert(pieces, "") -- blank line
	end
	table.insert(pieces, prompt_text)
	return table.concat(pieces, "\n")
end

-- HTTP call via curl using jobstart, piped stdin
local function http_generate(sess, prompt_text, on_done)
	local url = (config.server_url or "http://127.0.0.1:11434") .. "/api/generate"

	local payload_tbl = {
		model = sess.model or config.model,
		prompt = prompt_text,
		stream = false,
	}
	local payload = vim.fn.json_encode(payload_tbl)

	local stdout_chunks, stderr_chunks = {}, {}

	local cmd = {
		"curl",
		"-sS", "-f", -- quiet but fail on HTTP 4xx/5xx
		"-X", "POST",
		"-H", "Content-Type: application/json",
		url,
		"--data-binary", "@-", -- read JSON body from stdin
	}

	local job_id = vim.fn.jobstart(cmd, {
		stdin = "pipe",
		stdout_buffered = true,
		stderr_buffered = true,

		on_stdout = function(_, data, _)
			if data and #data > 0 then
				table.insert(stdout_chunks, table.concat(data, "\n"))
			end
		end,

		on_stderr = function(_, data, _)
			if data and #data > 0 then
				table.insert(stderr_chunks, table.concat(data, "\n"))
			end
		end,

		on_exit = function(_, code, _)
			local out = table.concat(stdout_chunks, "")
			local err = table.concat(stderr_chunks, "")

			if code ~= 0 then
				-- curl -f: on 4xx/5xx it sets nonzero exit and puts a message on stderr
				local msg = err ~= "" and err or out
				msg = msg:gsub("%s+$", "")
				on_done(nil, ("HTTP error (curl exit %d): %s"):format(code, msg))
				return
			end

			if out == "" then
				on_done(nil, "Empty response from Ollama")
				return
			end

			local ok, decoded = pcall(vim.fn.json_decode, out)
			if not ok or type(decoded) ~= "table" then
				on_done(nil, "Failed to parse JSON from Ollama: " .. out)
				return
			end

			on_done(decoded.response or "", nil)
		end,
	})

	if job_id <= 0 then
		on_done(nil, "Failed to start curl process. Is curl installed?")
		return
	end

	-- send JSON payload via stdin
	vim.fn.chansend(job_id, payload)
	vim.fn.chanclose(job_id, "stdin")
end

-- Ask raw text "text" in current chat
function M.ask(text)
	if not text or text == "" then
		vim.notify("Ollama: empty prompt", vim.log.levels.WARN)
		return
	end
	local sess = session_for_current_chat()
	append_lines(sess.buf, { "**User:** " .. text, "" })

	local full_prompt = build_prompt_with_context(sess, text)

	http_generate(sess, full_prompt, function(reply, err)
		if err then
			append_lines(sess.buf, { "**Error:** " .. err, "" })
			return
		end
		append_lines(sess.buf, { "**Ollama:**", reply or "", "" })
	end)
end

-- Helpers to capture visual selection text from the current buffer, tab & multibyte safe
local function get_visual_selection_text()
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	local srow, scol = s[2] - 1, s[3] - 1 -- 0-based start (inclusive)
	local erow, ecol = e[2] - 1, e[3] -- 0-based end (exclusive)
	if srow < 0 or erow < 0 then return nil end
	if erow < srow or (erow == srow and ecol < scol) then
		srow, erow, scol, ecol = erow, srow, ecol, scol
	end
	local parts = vim.api.nvim_buf_get_text(0, srow, scol, erow, ecol, {})
	if not parts or #parts == 0 then return nil end
	return table.concat(parts, "\n")
end

-- Send current visual selection to chat
function M.send_visual_selection()
	local text = get_visual_selection_text()
	if not text or text == "" then
		vim.notify("Ollama: no visual selection detected", vim.log.levels.WARN)
		return
	end
	local sess = session_for_current_chat()
	local name = vim.api.nvim_buf_get_name(0)
	local prompt = string.format("Analyze the following selection from file: %s\n\n%s",
		name ~= "" and name or "[No Name]", text)
	M.ask(prompt)
end

-- Send current entire buffer contents
function M.send_current_buffer()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local name = vim.api.nvim_buf_get_name(0)
	local prompt = string.format("Analyze the following buffer from file: %s\n\n%s",
		name ~= "" and name or "[No Name]", table.concat(lines, "\n"))
	M.ask(prompt)
end

-- Maintain a list of "added buffers" per chat session
function M.add_current_buffer()
	local sess = session_for_current_chat()
	local cur = vim.api.nvim_get_current_buf()
	-- Avoid adding the chat buffer itself
	if cur == sess.buf then
		vim.notify("Ollama: cannot add the chat buffer as context", vim.log.levels.WARN)
		return
	end
	-- Prevent duplicates
	for _, b in ipairs(sess.added_buffers) do
		if b == cur then
			vim.notify("Ollama: buffer already added", vim.log.levels.INFO)
			return
		end
	end
	table.insert(sess.added_buffers, cur)
	local name = vim.api.nvim_buf_get_name(cur)
	append_lines(sess.buf,
		{ ("_Added buffer to context:_ %s"):format(name ~= "" and name or ("[No Name " .. cur .. "]")), "" })
end

function M.clear_added_buffers()
	local sess = session_for_current_chat()
	sess.added_buffers = {}
	append_lines(sess.buf, { "_Cleared added buffers context_", "" })
end

function M.send_added_buffers()
	local sess = session_for_current_chat()
	if not sess.added_buffers or #sess.added_buffers == 0 then
		vim.notify("Ollama: no added buffers. Use :OllamaAddBuffer first.", vim.log.levels.WARN)
		return
	end

	local pieces = { "Analyze the following set of files:" }
	for _, b in ipairs(sess.added_buffers) do
		if vim.api.nvim_buf_is_valid(b) then
			local name = vim.api.nvim_buf_get_name(b)
			local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
			table.insert(pieces,
				string.format("<<FILE: %s>>\n%s", name ~= "" and name or ("[No Name " .. b .. "]"),
					table.concat(lines, "\n")))
		end
	end
	local prompt = table.concat(pieces, "\n\n")
	M.ask(prompt)
end

-- Set or print model for current session
function M.cmd_model(new_model)
	local sess = session_for_current_chat()
	if not new_model or new_model == "" then
		append_lines(sess.buf, { ("_Current model:_ %s"):format(sess.model), "" })
		return
	end
	sess.model = new_model
	append_lines(sess.buf, { ("_Switched model to:_ %s"):format(sess.model), "" })
end

function M.set_server_url(url)
	if not url or url == "" then
		vim.notify("Ollama: server URL cannot be empty", vim.log.levels.ERROR)
		return
	end
	config.server_url = url
	local sess = nil
	-- try to log change in current chat if exists
	local ok = pcall(function() sess = session_for_current_chat() end)
	if ok and sess and sess.buf then
		append_lines(sess.buf, { ("_Server URL set to:_ %s"):format(url), "" })
	else
		vim.notify("Ollama: server URL set to " .. url, vim.log.levels.INFO)
	end
end

return M
