-- Interface/chat with an Ollama server using 'curl'.

local M = {}

-- Config with defaults
local config = {
	server_url = "http://127.0.0.1:11434",
	model = "deepcoder:14b",
	stream = true,
	-- Hard cap on a whole request, in seconds (curl --max-time).
	-- 0 disables it. Streaming responses that exceed this are aborted.
	timeout = 300,

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

	-- Default Ollama request options, sent as the `options` field of
	-- /api/chat.  Values here are merged with per-session overrides.
	-- See https://github.com/ollama/ollama/blob/main/docs/modelfile.md
	-- for all available options.
	options = {},
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
		options = {}, -- per-session overrides of config.options
		last_response = nil, -- last completed assistant response text
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

-- Get or create a session for the current chat buffer; never opens a chat
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

-- Like session_for_current_chat, but automatically opens a chat when none
-- exists yet. Returns to the previous window so commands invoked from a code
-- buffer keep working on that buffer. Callers that depend on the current
-- buffer/window (selections, cursor context) must capture that state first.
local function session_for_current_chat_auto()
	local sess = session_for_current_chat()
	if sess then
		return sess
	end
	local prev_win = vim.api.nvim_get_current_win()
	M.open_chat_tab()
	sess = session_for_current_chat()
	if vim.api.nvim_win_is_valid(prev_win) then
		pcall(vim.api.nvim_set_current_win, prev_win)
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
	local sess
	if on_done then
		sess = session_for_current_chat()
	else
		sess = session_for_current_chat_auto()
	end
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

	-- Merge config-level options with per-session overrides
	local opts = {}
	for k, v in pairs(config.options or {}) do
		opts[k] = v
	end
	for k, v in pairs(sess.options or {}) do
		opts[k] = v
	end

	local payload_tbl = {
		model = sess.model or config.model,
		messages = messages,
		stream = config.stream,
	}
	if next(opts) ~= nil then
		payload_tbl.options = opts
	end
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
			sess.last_response = response_accum
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
				sess.job_id = nil
				return
			end
		end
	end, function(code, stderr)
		-- Ignore late exit from a job that was cancelled or superseded
		if sess.job_id ~= job or finished then
			return
		end
		if code ~= 0 then
			local msg = "curl exited with code " .. code
			if code == 28 then
				msg = "request timed out (config.timeout)"
			elseif stderr and stderr ~= "" then
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
	local sess = session_for_current_chat_auto()
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
	local sess = session_for_current_chat_auto()
	if not sess then
		no_chat_error()
		return
	end
	sess.added_buffers = {}
	append_lines(sess.buf, { "_Cleared added buffers context_", "" })
end

function M.send_added_buffers()
	local sess = session_for_current_chat_auto()
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
	local sess = session_for_current_chat_auto()
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

-- ===== Code actions: apply the last response to buffers =====

-- Extract the first fenced code block from a response; returns the
-- code inside the fences (without the fences) or nil.
function M.extract_code_block(response)
	if not response then
		return nil
	end
	local lines = vim.split(response, "\n", { plain = true })
	local inside = false
	local code = {}
	for _, l in ipairs(lines) do
		if inside then
			if l:match("^%s*```") then
				-- closing fence
				if #code > 0 then
					return table.concat(code, "\n")
				end
				inside = false -- empty block, keep looking
			else
				table.insert(code, l)
			end
		elseif l:match("^%s*```") then
			inside = true
		end
	end
	return nil
end

-- Get the last completed assistant response for the current chat.
-- code_only=true returns just the first fenced code block.
function M.get_last_response(code_only)
	local sess = session_for_current_chat()
	if not sess then
		return nil
	end
	local resp = sess.last_response
	if resp and code_only then
		resp = M.extract_code_block(resp)
	end
	return resp
end

-- Insert the last response at the cursor position of the current buffer.
-- code_only=true inserts only the first fenced code block.
function M.insert_last_response(code_only)
	if is_chat_buffer(vim.api.nvim_get_current_buf()) then
		vim.notify("Ollama: move to a target buffer first", vim.log.levels.WARN)
		return
	end
	local text = M.get_last_response(code_only)
	if not text or text == "" then
		vim.notify("Ollama: no response to insert yet", vim.log.levels.WARN)
		return
	end
	local pos = vim.api.nvim_win_get_cursor(0)
	local lines = vim.split(text, "\n", { plain = true })
	local indent = vim.api.nvim_get_current_line():match("^(%s*)")
	if indent ~= "" then
		for i, l in ipairs(lines) do
			if l ~= "" then
				lines[i] = indent .. l
			end
		end
	end
	vim.api.nvim_buf_set_lines(0, pos[1], pos[1], false, lines)
	vim.api.nvim_win_set_cursor(0, { pos[1] + #lines, 0 })
	vim.cmd([[normal! ==]]) -- reindent inserted lines if an indentexpr exists
end

-- Replace the last visual selection with the last response.
-- code_only=true replaces with only the first fenced code block.
-- The change is undoable with |u|.
function M.replace_visual_selection_with_response(code_only)
	if is_chat_buffer(vim.api.nvim_get_current_buf()) then
		vim.notify("Ollama: move to a target buffer first", vim.log.levels.WARN)
		return
	end
	local text = M.get_last_response(code_only)
	if not text or text == "" then
		vim.notify("Ollama: no response to apply yet", vim.log.levels.WARN)
		return
	end
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	if not s or s[2] <= 0 then
		vim.notify("Ollama: no visual selection to replace", vim.log.levels.WARN)
		return
	end
	local lines = vim.split(text, "\n", { plain = true })
	-- Normalize marks: if they are in reverse order, swap them
	local srow, scol = s[2] - 1, s[3] - 1
	local erow, ecol = e[2] - 1, e[3]
	if erow < srow or (erow == srow and ecol < scol) then
		srow, erow, scol, ecol = erow, srow, ecol, scol
	end
	-- For a charwise visual selection, keep text before/after the
	-- selection on the first/last lines.  Clamp column values to the
	-- line length: visual selections to end-of-line are encoded as
	-- col 2147483647, which would overflow the arithmetic below.
	local first = vim.api.nvim_buf_get_lines(0, srow, srow + 1, false)[1] or ""
	local last = vim.api.nvim_buf_get_lines(0, erow, erow + 1, false)[1] or ""
	local before = first:sub(1, math.min(scol, #first))
	local after = last:sub(math.min(ecol + 1, #last + 1))
	local new_lines = {}
	for i, l in ipairs(lines) do
		if i == 1 then
			new_lines[i] = before .. l
		elseif i == #lines then
			new_lines[i] = l .. after
		else
			new_lines[i] = l
		end
	end
	if #lines == 1 then
		new_lines[1] = before .. lines[1] .. after
	end
	vim.api.nvim_buf_set_lines(0, srow, erow + 1, false, new_lines)
	vim.api.nvim_win_set_cursor(0, { srow + #new_lines, 0 })
end

-- ===== Smarter context: symbol under cursor or visible window =====

-- Build context text around the cursor, using the best source available:
--   1. Built-in treesitter: the enclosing named definition (works with any
--      installed parser, no plugin required)
--   2. nvim-treesitter (optional plugin): same idea via its utils
--   3. LSP documentSymbol: the deepest symbol containing the cursor
--   4. Fallback: the visible window range
-- Substrings that identify definition-like node types across
-- tree-sitter grammars (Lua patterns have no alternation, so we
-- check each one explicitly).
local TS_SYMBOL_TYPES = { "function", "method", "class", "struct", "definition", "declaration" }

local function is_symbol_node(t)
	for _, s in ipairs(TS_SYMBOL_TYPES) do
		if t:find(s, 1, true) then
			return true
		end
	end
	return false
end

local function ts_node_text(buf, node)
	local sr, sc, er, ec = node:range()
	if er <= sr and ec <= sc then
		return nil
	end
	local text = table.concat(vim.api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), "\n")
	if text == "" then
		return nil
	end
	return text
end

local function context_from_builtin_ts(buf)
	-- vim.treesitter.get_node returns nil until the buffer has been parsed;
	-- ensure a parser exists and a parse has happened before querying the node.
	local ok_parser, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok_parser or not parser then
		return nil
	end
	pcall(parser.parse, parser)
	local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf })
	if not ok or not node then
		-- try the older API name
		local pos = vim.api.nvim_win_get_cursor(0)
		local ok2, node2 =
			pcall(vim.treesitter.get_node_at_pos, buf, pos[1] - 1, pos[2], { ignore_injections = false })
		if not ok2 then
			return nil
		end
		node = node2
	end
	while node do
		local okt, t = pcall(node.type, node)
		if okt and is_symbol_node(t) then
			local text = ts_node_text(buf, node)
			if text then
				return text, "symbol (treesitter)"
			end
		end
		local okp, parent = pcall(node.parent, node)
		if not okp then
			return nil
		end
		node = parent
	end
	return nil
end

local function context_from_plugin_ts(buf)
	local ok_ts, ts_utils = pcall(require, "nvim-treesitter.ts_utils")
	if not ok_ts or type(ts_utils.get_node_at_cursor) ~= "function" then
		return nil
	end
	local ok_node, node = pcall(ts_utils.get_node_at_cursor)
	if not ok_node or not node then
		return nil
	end
	while node do
		local t = node:type()
		if is_symbol_node(t) then
			local text = ts_node_text(buf, node)
			if text then
				return text, "symbol (treesitter)"
			end
		end
		node = node:parent()
	end
	return nil
end

-- Deepest LSP documentSymbol whose range contains the cursor row.
local function context_from_lsp(buf, row)
	local clients = {}
	if vim.lsp.get_clients then
		clients = vim.lsp.get_clients({ bufnr = buf })
	elseif vim.lsp.get_active_clients then
		clients = vim.lsp.get_active_clients({ bufnr = buf })
	end
	if #clients == 0 then
		return nil
	end
	local params = { textDocument = vim.lsp.util.make_text_document_params() }
	local results = vim.lsp.buf_request_sync(buf, "textDocument/documentSymbol", params, 2000)
	if not results then
		return nil
	end
	local best = nil -- { name, start_row, end_row, depth }
	local function walk(symbols, depth)
		for _, s in ipairs(symbols or {}) do
			local range = s.range or (s.location and s.location.range)
			if range then
				local sr, er = range.start.line, range["end"].line
				if row >= sr and row <= er then
					if not best or depth > best.depth then
						best = { name = s.name or "?", start_row = sr, end_row = er, depth = depth }
					end
					walk(s.children, depth + 1)
				end
			end
		end
	end
	for _, res in pairs(results) do
		if res.result then
			walk(res.result, 1)
		end
	end
	if not best then
		return nil
	end
	local text =
		table.concat(vim.api.nvim_buf_get_lines(buf, best.start_row, best.end_row + 1, false), "\n")
	if text == "" then
		return nil
	end
	return text, ("symbol %s (lsp)"):format(best.name)
end

local function build_cursor_context()
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1

	local text, desc = context_from_builtin_ts(buf)
	if not text then
		text, desc = context_from_plugin_ts(buf)
	end
	if not text then
		local ok_lsp, t2, d2 = pcall(context_from_lsp, buf, row)
		if ok_lsp then
			text, desc = t2, d2
		end
	end
	if text then
		return text, desc
	end

	-- Fallback: visible window range
	local win = vim.api.nvim_get_current_win()
	local top = vim.fn.line("w0", win)
	local bot = vim.fn.line("w$", win)
	if top > 0 and bot >= top then
		local wtext = table.concat(vim.api.nvim_buf_get_lines(buf, top - 1, bot, false), "\n")
		return wtext, ("lines %d-%d"):format(top, bot)
	end
	return nil, nil
end

-- Ask with automatic context: the symbol under the cursor (treesitter)
-- or the visible window range, without manually adding buffers.
function M.ask_with_context(text)
	if is_chat_buffer(vim.api.nvim_get_current_buf()) then
		-- Already in the chat: behave like a plain ask
		M.ask(text)
		return
	end
	-- Capture context from the current buffer before a chat may be opened,
	-- since opening one switches windows.
	local ctx, ctx_desc = build_cursor_context()
	local name = vim.api.nvim_buf_get_name(0)
	local fname = name ~= "" and name or "[No Name]"
	local prompt
	if ctx then
		prompt =
			string.format("Context (%s from file %s):\n\n%s\n\nQuestion: %s", ctx_desc, fname, ctx, text)
	else
		prompt = text
	end
	M.ask(prompt)
end

-- ===== Model management =====

-- GET /api/tags: return the list of installed model names to callback.
function M.list_models(on_done)
	local url = (config.server_url or "http://127.0.0.1:11434") .. "/api/tags"
	local cmd = {
		"curl",
		"-s",
		"--connect-timeout",
		"10",
		url,
	}
	local out = {}
	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if data then
				for _, l in ipairs(data) do
					table.insert(out, l)
				end
			end
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				vim.notify("Ollama: could not reach server (" .. code .. ")", vim.log.levels.ERROR)
				on_done(nil)
				return
			end
			local ok, obj = pcall(vim.fn.json_decode, table.concat(out, "\n"))
			if not ok or type(obj) ~= "table" or not obj.models then
				vim.notify("Ollama: unexpected /api/tags response", vim.log.levels.ERROR)
				on_done(nil)
				return
			end
			local names = {}
			for _, m in ipairs(obj.models) do
				table.insert(names, m.name)
			end
			table.sort(names)
			on_done(names)
		end,
	})
end

-- Interactive model picker: shows installed models via /api/tags and
-- switches the current chat to the chosen one.
function M.select_model()
	local sess = session_for_current_chat_auto()
	if not sess then
		no_chat_error()
		return
	end
	M.list_models(function(names)
		if not names or #names == 0 then
			return
		end
		vim.ui.select(names, { prompt = "Select model:" }, function(choice)
			if not choice then
				return
			end
			M.cmd_model(choice)
		end)
	end)
end

-- Cache of installed model names for command completion, refreshed
-- lazily with a TTL so completion stays responsive.
local model_names_cache = nil
local model_names_cache_time = 0
local MODEL_CACHE_TTL = 60 -- seconds

local function refresh_model_cache()
	local now = os.time()
	if model_names_cache and (now - model_names_cache_time) < MODEL_CACHE_TTL then
		return model_names_cache
	end
	M.list_models(function(names)
		if names then
			model_names_cache = names
			model_names_cache_time = now
		end
	end)
	return model_names_cache
end

-- Completion function for :OllamaModel offering installed models.
function M.model_completion(arg_lead, _cmd_line, _cursor_pos)
	local names = refresh_model_cache() or {}
	local matches = {}
	for _, n in ipairs(names) do
		if n:find(arg_lead, 1, true) == 1 then
			table.insert(matches, n)
		end
	end
	return matches
end

-- POST /api/pull: pull a model, streaming progress into the chat.
function M.pull_model(name)
	if not name or name == "" then
		vim.notify("Ollama: model name required (e.g. :OllamaPull llama3.1)", vim.log.levels.ERROR)
		return
	end
	local sess = session_for_current_chat_auto()
	if not sess then
		no_chat_error()
		return
	end
	local url = (config.server_url or "http://127.0.0.1:11434") .. "/api/pull"
	local payload = vim.fn.json_encode({ model = name, stream = true })
	local cmd = {
		"curl",
		"-s",
		"-N",
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
	append_lines(sess.buf, { ("_Pulling model:_ %s"):format(name), "" })
	local pending = ""
	local last_status = nil
	local job = vim.fn.jobstart(cmd, {
		stdin = "pipe",
		stdout_buffered = false,
		on_stdout = function(_, data)
			if not data or #data == 0 then
				return
			end
			pending = pending .. table.concat(data, "\n")
			local lines = vim.split(pending, "\n", { plain = true })
			pending = table.remove(lines) or ""
			for _, line in ipairs(lines) do
				if line ~= "" then
					local ok, obj = pcall(vim.fn.json_decode, line)
					if ok and type(obj) == "table" and obj.status then
						if obj.status ~= last_status then
							last_status = obj.status
							append_lines(sess.buf, { ("  %s"):format(obj.status) })
						end
					end
				end
			end
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				append_lines(sess.buf, { ("**Error:** pull failed (curl code %s)"):format(code), "" })
			else
				append_lines(sess.buf, { ("_Pulled model:_ %s"):format(name), "" })
			end
		end,
	})
	if job > 0 then
		vim.api.nvim_chan_send(job, payload)
		pcall(vim.fn.chanclose, job, "stdin")
	end
end

-- ===== Model options (temperature, num_ctx, ...) =====

-- Set a per-session request option, e.g. temperature=0.2, num_ctx=8192.
-- With no argument, prints all effective options for the session.
function M.cmd_options(arg)
	local sess = session_for_current_chat_auto()
	if not sess then
		no_chat_error()
		return
	end
	if not arg or arg == "" then
		local effective = {}
		for k, v in pairs(config.options or {}) do
			effective[k] = v
		end
		for k, v in pairs(sess.options) do
			effective[k] = v
		end
		local keys = {}
		for k in pairs(effective) do
			table.insert(keys, k)
		end
		table.sort(keys)
		local items = { "_Effective request options:_" }
		for _, k in ipairs(keys) do
			table.insert(items, ("  %s = %s"):format(k, tostring(effective[k])))
		end
		if #keys == 0 then
			table.insert(items, "  (none set)")
		end
		table.insert(items, "")
		append_lines(sess.buf, items)
		return
	end
	local key, raw = arg:match("^(%S+)%s*=%s*(.+)$")
	if not key then
		vim.notify("Ollama: expected key=value (e.g. temperature=0.2)", vim.log.levels.ERROR)
		return
	end
	-- Accept numbers, true/false, and bare strings
	local value
	if raw:match("^%-?%d+%.?%d*$") then
		value = tonumber(raw)
	elseif raw == "true" then
		value = true
	elseif raw == "false" then
		value = false
	else
		value = raw
	end
	sess.options[key] = value
	append_lines(sess.buf, { ("_Set option:_ %s = %s"):format(key, tostring(value)), "" })
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
