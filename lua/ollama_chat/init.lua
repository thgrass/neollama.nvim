-- Interface/chat with an ollama server using 'curl'.

local M = {}

-- Config with defaults
local config = {
	server_url = "http://127.0.0.1:11434",
	model = "deepcoder:14b",
	stream = true,

	system_prompts = {
		default = "",
		python = "",
		lua = ""
	},
	user_prompts = {
		welcome = "",
		help_explain = "",
		help_debug = ""
	},
}

-- Sessions keyed by chat buffer number
local sessions = {}

-- Setup
function M.setup(opts)
	if opts then
		for k, v in pairs(opts) do config[k] = v end
	end
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
			sessions[buf] = {
				buf = buf,
				model = model or config.model,
				added_buffers = {},
			}
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
		vim.bo[buf].buftype    = "nofile"
		vim.bo[buf].swapfile   = false
		vim.bo[buf].bufhidden  = "hide"
		vim.bo[buf].filetype   = "ollama_chat" -- custom ft in ftplugin/ollama_chat.lua
		vim.bo[buf].modifiable = false

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
function M.close_chat()
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
	M.close_chat()
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

-- HTTP call via curl using jobstart, piped stdin.  In streaming mode,
-- this function yields partial responses as they arrive.
local function http_generate(prompt_text, on_done)
	local url = (config.server_url or "http://127.0.0.1:11434") .. "/api/generate"

	-- Build the JSON payload.  The `stream` flag is passed through to enable or disable
	-- incremental output from the server.
	local payload_tbl = {
		model = config.model,
		prompt = prompt_text,
		stream = config.stream,
	}
	local payload = vim.fn.json_encode(payload_tbl)

	-- We'll accumulate stderr in case of errors and stream stdout chunks to the callback.
	local stdout_chunks, stderr_chunks = {}, {}

	-- Curl command for the POST request.  The -N flag disables buffering so that
	-- partial responses are flushed immediately.  We read the request body from
	-- stdin via `@-`.
	local cmd = {
		"curl",
		"-s", -- Quiet mode: suppress progress meter
		"-N", -- Disable stdout buffering
		"-X", "POST",
		"-H", "Content-Type: application/json",
		url,
		"--data-binary", "@-",
	}

	local job_id = vim.fn.jobstart(cmd, {
		stdin = "pipe",
		-- Do not buffer stdout/stderr; deliver chunks as soon as they arrive
		stdout_buffered = false,
		stderr_buffered = false,

		on_stdout = function(_, data, _)
			-- `data` is a list of partial lines.  Concatenate and emit non-empty chunks.
			if data then
				local chunk = table.concat(data, "\n")
				if #chunk > 0 then
					table.insert(stdout_chunks, chunk)
					on_done(chunk, nil)
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

		on_exit = function()
			-- If there were any stderr messages, surface them as an error.  Otherwise,
			-- no further action is needed because stdout has already been streamed.
			if #stderr_chunks > 0 then
				on_done(nil, table.concat(stderr_chunks, ""))
			end
		end,
	})

	-- Send the payload to the job's stdin.  Use `nvim_chan_send` (or chansend)
	-- instead of the unavailable `job_send`.  After writing the payload, close
	-- the stdin channel to signal end-of-input.
	vim.api.nvim_chan_send(job_id, payload)
	-- Closing the stdin stream flushes the request body.  Without this, curl would
	-- block waiting for more input.
	if vim.fn.chanclose then
		-- chanclose() is available in newer Neovim versions
		pcall(vim.fn.chanclose, job_id, "stdin")
	end
end

-- Ask raw text "text" in current chat
M.ask = function(text, on_done)
	-- Always obtain the session for current buffer
	local sess = session_for_current_chat()

	-- Echo the user's question in the chat buffer when interactive
	if not on_done then
		append_lines(sess.buf, { "**User:** " .. text, "" })
	end

	-- Build the full prompt including any added buffer context
	local full_prompt = build_prompt_with_context(sess, text)

	-- Accumulate the streaming response.  We'll parse each JSON message and
	-- append only the `response` tokens.  We update the display incrementally
	-- to provide streaming feedback.  When `done` is true, a blank line is
	-- appended and any callback is invoked with the full response.
	local response_accum = ""
	-- Track where the assistant output starts (0-based index) and how many
	-- buffer lines we've written, so we can update them in-place.
	local assist_start_line = nil
	local assist_line_count = 0
	-- Helper to update the buffer display based on the current response
	local function update_display(final)
		-- Split accumulated response into lines to preserve newline boundaries.
		local content_lines = vim.split(response_accum, "\n", { plain = true })
		if #content_lines == 0 then content_lines = { "" } end
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
				vim.api.nvim_buf_set_lines(buf, assist_start_line, assist_start_line + assist_line_count,
					false, lines)
			end)
			assist_line_count = #lines
		end
		if final then
			append_lines(buf, { "" })
		end
	end

	http_generate(full_prompt, function(chunk, err)
		if err then
			append_lines(sess.buf, { "**Error:** " .. err, "" })
			if on_done then on_done(nil, err) end
			return
		end
		if not chunk or #chunk == 0 then return end
		local finished = false
		for line in string.gmatch(chunk, "[^\n]+") do
			local ok, obj = pcall(vim.fn.json_decode, line)
			if ok and type(obj) == "table" then
				if obj.response and obj.response ~= vim.NIL then
					response_accum = response_accum .. obj.response
				end
				if obj.done then
					finished = true
				end
			end
		end
		-- Update display after processing the batch.  If finished, append blank line.
		update_display(finished)
		if finished then
			if on_done then on_done(response_accum, nil) end
			response_accum = ""
			assist_start_line = nil
			assist_line_count = 0
		end
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
