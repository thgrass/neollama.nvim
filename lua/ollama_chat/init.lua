-- Interface/chat with an Ollama server using 'curl'.

local M = {}

-- Config with defaults
local config = {
	server_url = "http://127.0.0.1:11434",
	model = "deepcoder:14b",
	stream = true,
	timeout = 0,

	system_prompts = {
		default = "",
		python = "",
		lua = "",
	},
	user_prompts = {
		welcome = "",
		help_explain = "",
		help_debug = "",
	},
}

local function merge_prompts(into, from)
	if type(from) ~= "table" then
		return
	end
	for k, v in pairs(from) do
		if type(into[k]) == "table" and type(v) == "table" then
			merge_prompts(into[k], v)
		else
			into[k] = v
		end
	end
end

-- Setup: merge user options into config (tables merged recursively)
function M.setup(opts)
	if opts then
		merge_prompts(config, opts)
	end
end

-- Sessions keyed by chat buffer number
local sessions = {}

-- Last chat buffer that was opened or used, so we can fall back to it
local last_active_chat = nil

local function is_chat_buffer(buf)
	local ok = pcall(vim.api.nvim_buf_get_var, buf, "ollama_chat")
	return ok
end

local function get_current_chat_buf()
	local buf = vim.api.nvim_get_current_buf()
	if is_chat_buffer(buf) then
		last_active_chat = buf
		return buf
	end
	-- If not in chat, try the last used chat buffer
	if last_active_chat and vim.api.nvim_buf_is_valid(last_active_chat) then
		return last_active_chat
	end
	for chat_buf, _ in pairs(sessions) do
		if vim.api.nvim_buf_is_valid(chat_buf) then
			return chat_buf
		end
	end
	return nil
end

-- Notify an error instead of raising a raw error when no chat exists
local function no_chat_error()
	vim.notify("No active Ollama chat buffer. Run :OllamaChat to start one.", vim.log.levels.ERROR)
end

local function ensure_modifiable(buf, fn)
	local prev = vim.bo[buf].modifiable
	if not prev then
		vim.bo[buf].modifiable = true
	end

	fn()

	if not prev then
		vim.bo[buf].modifiable = false
	end
end

local function append_lines(buf, items)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
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

local function new_session(buf, model)
	return {
		buf = buf,
		model = model or config.model,
		added_buffers = {}, -- list of bufnrs
		messages = {}, -- chat history for /api/chat
		job_id = nil, -- active curl job, if any
	}
end

-- Create a new chat in a tab or reopen a closed chat buffer
function M.open_chat_tab(model)
	local name = "Ollama Chat"
	local existing = vim.fn.bufnr(name)

	-- reopen existing
	if existing ~= -1 then
		vim.cmd("tab sbuffer " .. existing)
		local buf = existing

		-- make sure we have a session for this buffer
		if not sessions[buf] then
			sessions[buf] = new_session(buf, model)
		elseif model then
			-- allow overriding model when reopening
			sessions[buf].model = model
		end

		-- create new
	else
		vim.cmd("tabnew")
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_name(buf, name)

		-- use new-style option API (buffer-local)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].swapfile = false
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].filetype = "ollama_chat" -- custom ft in ftplugin/ollama_chat.lua
		vim.bo[buf].modifiable = false

		vim.api.nvim_buf_set_var(buf, "ollama_chat", 1)

		sessions[buf] = new_session(buf, model)

		append_lines(buf, {
			"# Ollama Chat",
			"Model: " .. sessions[buf].model,
			"",
		})
	end

	last_active_chat = vim.api.nvim_get_current_buf()
end

-- Close a chat tab and destroy its chat buffer
function M.close_chat()
	local chat = "Ollama Chat"

	local bufnr = vim.fn.bufnr(chat)
	if bufnr == -1 then
		vim.notify("No '" .. chat .. "' buffer found", vim.log.levels.INFO)
		return
	end

	-- Stop any active request for this chat
	local sess = sessions[bufnr]
	if sess and sess.job_id then
		pcall(vim.fn.jobstop, sess.job_id)
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

	sessions[bufnr] = nil
	if last_active_chat == bufnr then
		last_active_chat = nil
	end
end

-- Get or create a session for the current chat buffer
local function session_for_current_chat()
	local buf = get_current_chat_buf()
	if not buf then
		return nil
	end
	local sess = sessions[buf]
	if not sess then
		sessions[buf] = new_session(buf)
		sess = sessions[buf]
	end
	return sess
end

-- Stop the active request for the current chat, if any
function M.cancel()
	local sess = session_for_current_chat()
	if not sess then
		return
	end
	if sess.job_id then
		pcall(vim.fn.jobstop, sess.job_id)
		sess.job_id = nil
		append_lines(sess.buf, { "_Request cancelled_", "" })
	else
		vim.notify("Ollama: no active request", vim.log.levels.INFO)
	end
end

-- Clean up a session when its buffer is wiped/unloaded.
-- Exposed so the plugin file can wire it to autocmds.
function M.on_buf_removed(buf)
	local sess = sessions[buf]
	if sess and sess.job_id then
		pcall(vim.fn.jobstop, sess.job_id)
	end
	sessions[buf] = nil
	if last_active_chat == buf then
		last_active_chat = nil
	end
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
				table.insert(
					pieces,
					string.format(
						"<<FILE: %s>>\n%s",
						name ~= "" and name or ("[No Name " .. b .. "]"),
						table.concat(lines, "\n")
					)
				)
			end
		end
		table.insert(pieces, "") -- blank line
	end
	table.insert(pieces, prompt_text)
	return table.concat(pieces, "\n")
end

local function system_prompt_for(invoke_ft)
	local ft_prompt = invoke_ft and config.system_prompts[invoke_ft]
	local prompt = (ft_prompt and ft_prompt ~= "") and ft_prompt or config.system_prompts.default
	return prompt ~= "" and prompt or nil
end

local function build_messages(sess, prompt_text, invoke_ft)
	local messages = {}
	local sys = system_prompt_for(invoke_ft)
	if sys then
		table.insert(messages, { role = "system", content = sys })
	end
	for _, m in ipairs(sess.messages) do
		table.insert(messages, m)
	end
	table.insert(messages, { role = "user", content = prompt_text })
	return messages
end

-- HTTP call via curl using jobstart, piped stdin.  In streaming mode,
-- this function yields partial responses as they arrive.
--
-- on_line(line) is called once per complete JSON line from the server.
-- on_exit(code, stderr) is always called exactly once at the end.
local function http_request(payload, on_line, on_exit)
	local url = (config.server_url or "http://127.0.0.1:11434") .. "/api/chat"

	local cmd = {
		"curl",
		"-s", -- Quiet mode: suppress progress meter
		"-N", -- Disable stdout buffering
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"--connect-timeout",
		"10",
		url,
		"--data-binary",
		"@-",
	}
	if config.timeout and config.timeout > 0 then
		table.insert(cmd, "--max-time")
		table.insert(cmd, tostring(config.timeout))
	end

	local stderr_chunks = {}
	-- Buffer partial lines across stdout callbacks; only complete
	-- lines are decoded as JSON, the remainder is kept for later.
	local pending = ""

	local job_id = vim.fn.jobstart(cmd, {
		stdin = "pipe",
		-- Do not buffer stdout/stderr; deliver chunks as soon as they arrive
		stdout_buffered = false,
		stderr_buffered = false,

		on_stdout = function(_, data, _)
			if not data or #data == 0 then
				return
			end
			pending = pending .. table.concat(data, "\n")
			-- Split into complete lines; the last element may be
			-- incomplete, so keep it pending.
			local lines = vim.split(pending, "\n", { plain = true })
			pending = table.remove(lines) or ""
			for _, line in ipairs(lines) do
				if line ~= "" then
					on_line(line)
				end
			end
		end,

		on_stderr = function(_, data, _)
			if data then
				local chunk = table.concat(data, "\n")
				if #chunk > 0 then
					table.insert(stderr_chunks, chunk)
				end
			end
		end,

		on_exit = function(_, code)
			local err = #stderr_chunks > 0 and table.concat(stderr_chunks, "\n") or nil
			on_exit(code, err)
		end,
	})

	if job_id <= 0 then
		on_exit(job_id, "Failed to start curl")
		return
	end

	-- After writing the payload, close the stdin channel to signal end-of-input.
	vim.api.nvim_chan_send(job_id, payload)
	if vim.fn.chanclose then
		pcall(vim.fn.chanclose, job_id, "stdin")
	end

	return job_id
end

-- Ask raw text "text" in current chat
M.ask = function(text, on_done)
	local sess = session_for_current_chat()
	if not sess then
		no_chat_error()
		if on_done then
			on_done(nil, "No active Ollama chat buffer")
		end
		return
	end

	-- Only one request at a time per session; cancel any previous one.
	if sess.job_id then
		vim.fn.jobstop(sess.job_id)
		sess.job_id = nil
		append_lines(sess.buf, { "_Request cancelled_", "" })
	end

	-- Echo the user's question in the chat buffer when interactive
	if not on_done then
		append_lines(sess.buf, { "**User:** " .. text, "" })
	end

	-- Build the full prompt including any added buffer context
	local full_prompt = build_prompt_with_context(sess, text)
	local invoke_ft = vim.bo[0].filetype
	local messages = build_messages(sess, full_prompt, invoke_ft)

	local payload_tbl = {
		model = sess.model or config.model,
		messages = messages,
		stream = config.stream,
	}
	local payload = vim.fn.json_encode(payload_tbl)

	-- Accumulate the streaming response.  We parse each JSON message and
	-- append only the `message.content` tokens.  We update the display
	-- incrementally to provide streaming feedback.  When `done` is true,
	-- the full exchange is appended to the session history.
	local response_accum = ""
	-- Track where the assistant output starts (0-based index) and how many
	-- buffer lines we've written, so we can update them in-place.
	local assist_start_line = nil
	local assist_line_count = 0
	local finished = false
	-- Helper to update the buffer display based on the current response
	local function update_display(final)
		if not vim.api.nvim_buf_is_valid(sess.buf) then
			return
		end
		-- Split accumulated response into lines to preserve newline boundaries.
		local content_lines = vim.split(response_accum, "\n", { plain = true })
		if #content_lines == 0 then
			content_lines = { "" }
		end
		-- Build the displayed lines: a header on its own line, followed by the
		-- content lines.  This keeps tags like <think> on their own lines, so
		-- folding logic in the ftplugin works properly.
		local lines = { "**Ollama:**" }
		for _, l in ipairs(content_lines) do
			table.insert(lines, l)
		end
		local buf = sess.buf
		if not assist_start_line then
			assist_start_line = vim.api.nvim_buf_line_count(buf)
			append_lines(buf, lines)
			assist_line_count = #lines
		else
			-- Temporarily make the buffer modifiable to update lines in-place.
			ensure_modifiable(buf, function()
				vim.api.nvim_buf_set_lines(
					buf,
					assist_start_line,
					assist_start_line + assist_line_count,
					false,
					lines
				)
			end)
			assist_line_count = #lines
		end
		if final then
			append_lines(buf, { "" })
		end
	end

	local function finish(err)
		sess.job_id = nil
		-- Only touch the display if some content was already shown
		if response_accum ~= "" or assist_start_line then
			update_display(err == nil)
		end
		if err then
			append_lines(sess.buf, { "**Error:** " .. err, "" })
			if on_done then
				on_done(nil, err)
			end
			return
		end
		-- Only keep exchanges that produced a response
		if response_accum ~= "" then
			table.insert(sess.messages, { role = "user", content = full_prompt })
			table.insert(sess.messages, { role = "assistant", content = response_accum })
		end
		if on_done then
			on_done(response_accum, nil)
		end
		response_accum = ""
	end

	local job
	job = http_request(payload, function(line)
		-- Ignore late frames from a job that was cancelled or superseded
		if sess.job_id ~= job then
			return
		end
		local ok, obj = pcall(vim.fn.json_decode, line)
		if ok and type(obj) == "table" then
			if obj.error then
				finished = true
				finish(obj.error)
				if sess.job_id then
					vim.fn.jobstop(sess.job_id)
					sess.job_id = nil
				end
				return
			end
			local content = obj.message and obj.message.content
			if content and content ~= vim.NIL then
				response_accum = response_accum .. content
				update_display(false)
			end
			if obj.done then
				finished = true
				finish(nil)
			end
		end
	end, function(code, stderr)
		-- Ignore late exit from a job that was cancelled or superseded
		if sess.job_id ~= job or finished then
			return
		end
		if code ~= 0 then
			local msg = "curl exited with code " .. code
			if stderr and stderr ~= "" then
				msg = msg .. ": " .. stderr
			end
			finish(msg)
			return
		end
		finish(nil)
	end)
	if job then
		sess.job_id = job
	else
		sess.job_id = nil
	end
end

-- Helpers to capture visual selection text from the current buffer, tab & multibyte safe
-- When the command was invoked with an explicit range, use those whole lines;
-- otherwise fall back to the last visual selection marks.
local function get_visual_selection_text(has_range, line1, line2)
	if has_range then
		local srow = line1 - 1
		local erow = line2 - 1
		if erow < srow then
			srow, erow = erow, srow
		end
		local parts = vim.api.nvim_buf_get_text(0, srow, 0, erow, -1, {})
		if not parts or #parts == 0 then
			return nil
		end
		return table.concat(parts, "\n")
	end

	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	local srow, scol = s[2] - 1, s[3] - 1 -- 0-based start (inclusive)
	local erow, ecol = e[2] - 1, e[3] -- 0-based end (exclusive)
	if srow < 0 or erow < 0 then
		return nil
	end
	if erow < srow or (erow == srow and ecol < scol) then
		srow, erow, scol, ecol = erow, srow, ecol, scol
	end
	local parts = vim.api.nvim_buf_get_text(0, srow, scol, erow, ecol, {})
	if not parts or #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

-- Send current visual selection to chat
function M.send_visual_selection(has_range, line1, line2)
	local text = get_visual_selection_text(has_range, line1, line2)
	if not text or text == "" then
		vim.notify("Ollama: no visual selection detected", vim.log.levels.WARN)
		return
	end
	local name = vim.api.nvim_buf_get_name(0)
	local prompt = string.format(
		"Analyze the following selection from file: %s\n\n%s",
		name ~= "" and name or "[No Name]",
		text
	)

	M.ask(prompt)
end

-- Send current entire buffer contents
function M.send_current_buffer()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local name = vim.api.nvim_buf_get_name(0)
	local prompt = string.format(
		"Analyze the following buffer from file: %s\n\n%s",
		name ~= "" and name or "[No Name]",
		table.concat(lines, "\n")
	)
	M.ask(prompt)
end

-- Maintain a list of "added buffers" per chat session
function M.add_current_buffer()
	local sess = session_for_current_chat()
	if not sess then
		no_chat_error()
		return
	end
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
	append_lines(sess.buf, {
		("_Added buffer to context:_ %s"):format(name ~= "" and name or ("[No Name " .. cur .. "]")),
		"",
	})
end

function M.clear_added_buffers()
	local sess = session_for_current_chat()
	if not sess then
		no_chat_error()
		return
	end
	sess.added_buffers = {}
	append_lines(sess.buf, { "_Cleared added buffers context_", "" })
end

function M.send_added_buffers()
	local sess = session_for_current_chat()
	if not sess then
		no_chat_error()
		return
	end
	if not sess.added_buffers or #sess.added_buffers == 0 then
		vim.notify("Ollama: no added buffers. Use :OllamaAddBuffer first.", vim.log.levels.WARN)
		return
	end

	local pieces = { "Analyze the following set of files:" }
	for _, b in ipairs(sess.added_buffers) do
		if vim.api.nvim_buf_is_valid(b) then
			local name = vim.api.nvim_buf_get_name(b)
			local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
			table.insert(
				pieces,
				string.format(
					"<<FILE: %s>>\n%s",
					name ~= "" and name or ("[No Name " .. b .. "]"),
					table.concat(lines, "\n")
				)
			)
		end
	end
	local prompt = table.concat(pieces, "\n\n")
	M.ask(prompt)
end

-- Set or print model for current session
function M.cmd_model(new_model)
	local sess = session_for_current_chat()
	if not sess then
		no_chat_error()
		return
	end
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
	local sess = session_for_current_chat()
	if sess and vim.api.nvim_buf_is_valid(sess.buf) then
		append_lines(sess.buf, { ("_Server URL set to:_ %s"):format(url), "" })
	else
		vim.notify("Ollama: server URL set to " .. url, vim.log.levels.INFO)
	end
end

return M
