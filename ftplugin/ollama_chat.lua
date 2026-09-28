-- ftplugin/ollama_chat.lua
-- This runs for every buffer with :set filetype=ollama_chat

local bufnr = vim.api.nvim_get_current_buf()

-- folding for think block, not for code
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldenable = true
vim.opt_local.foldlevel = 0
vim.opt_local.foldexpr = "v:lua.OllamaFold(v:lnum)"
vim.opt_local.foldtext = "v:lua.OllamaFoldText()"

-- Cache fence/think state per line to avoid O(n^2) scans in the foldexpr.
-- Keyed by buffer, invalidated whenever that buffer changes.
local fold_caches = {}

local function compute_states(buf)
	local cache = fold_caches[buf]
	if not cache then
		cache = { seq = -1, states = {}, valid = false }
		fold_caches[buf] = cache
	end
	local seq = vim.api.nvim_buf_get_changedtick(buf)
	if cache.valid and cache.seq == seq then
		return cache.states
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local states = {}
	local fence_open = false
	local think_depth = 0
	for i, line in ipairs(lines) do
		-- a fence marker at line start toggles fence state
		if line:match("^%s*```") then
			fence_open = not fence_open
			states[i] = fence_open and "fence_open" or nil
		elseif fence_open then
			states[i] = "fence_open"
		elseif line:match("^%s*<think>%s*$") then
			think_depth = think_depth + 1
			states[i] = "think_open"
		elseif line:match("^%s*</think>%s*$") and think_depth > 0 then
			think_depth = think_depth - 1
			states[i] = nil
		elseif think_depth > 0 then
			states[i] = "think_open"
		else
			states[i] = nil
		end
	end
	cache.seq = seq
	cache.states = states
	cache.valid = true
	return states
end

local function invalidate_fold_cache(buf)
	local cache = fold_caches[buf]
	if cache then
		cache.valid = false
	end
end

-- Only fold <think>...</think>; never fold inside ``` fenced blocks
_G.OllamaFold = function(lnum)
	-- Resolve the buffer from the window the folds are computed for, not
	-- from the "current" one: the foldexpr can run while a different
	-- buffer/window is focused (e.g. asking from a code tab).
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	local states = compute_states(buf)
	local state = states[lnum]
	local lines = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)
	local line = lines[1] or ""

	-- Never fold anything inside fenced code blocks
	if state == "fence_open" then
		return 0
	end

	-- Fold only <think>...</think> blocks (level 1)
	if line:match("^%s*<think>%s*$") then
		return ">1" -- start fold at level 1
	end
	if line:match("^%s*</think>%s*$") then
		return "<1" -- end fold
	end
	if state == "think_open" then
		return "=" -- keep previous level (stays at 1 while inside)
		-- Alternatively: return 1
	end

	-- Everything else: no folding
	return 0
end

-- Re-apply fold options for every window that shows this buffer: new
-- windows (e.g. reopening via :OllamaChat -> tab sbuffer) don't inherit
-- window-local fold options.  Think blocks stay collapsed by default.
local function setup_window_folds(win)
	pcall(vim.api.nvim_set_option_value, "foldmethod", "expr", { win = win })
	pcall(vim.api.nvim_set_option_value, "foldenable", true, { win = win })
	pcall(vim.api.nvim_set_option_value, "foldexpr", "v:lua.OllamaFold(v:lnum)", { win = win })
	pcall(vim.api.nvim_set_option_value, "foldtext", "v:lua.OllamaFoldText()", { win = win })
	-- Default to collapsed, but preserve folds the user opened (za):
	-- entering/leaving the window must not contract them again.
	pcall(vim.api.nvim_set_option_value, "foldlevel", 0, { win = win })
	pcall(vim.api.nvim_win_call, win, function()
		for open_st in pairs(_G.OllamaOpenFolds or {}) do
			vim.cmd("silent! " .. open_st .. "foldopen")
		end
	end)
end

local group = vim.api.nvim_create_augroup("OllamaChatWinFolds", { clear = true })
vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
	group = group,
	buffer = bufnr,
	callback = function()
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
				pcall(setup_window_folds, w)
			end
		end
	end,
})

-- Folds the user opened manually in this buffer, by start line; kept in
-- sync by the plugin core on every display rewrite.  Window-enter setup
-- reopens these so tab changes never contract them.
_G.OllamaOpenFolds = {}

-- Cursor-follow folding: moving the cursor into a collapsed think block
-- expands it; moving out collapses it again.  Folds opened this way are
-- tracked in _G.OllamaCursorFolds so the plugin core does not mistake
-- them for user-opened folds (which must stay open).  Folds the user
-- toggled open with za are recorded in _G.OllamaOpenFolds and are never
-- auto-closed.
if _G.OllamaCursorFolds == nil then
	_G.OllamaCursorFolds = {}
end
local last_inside = nil

-- Start line of the fold containing `row`, or -1 if none.
local function fold_start_of(row)
	local fs = vim.fn.foldclosed(row)
	if fs ~= -1 then
		-- cursor sits inside a closed fold (its header line included)
		return fs
	end
	if vim.fn.foldlevel(row) == 0 then
		return -1
	end
	-- Inside an open fold: walk up to its start line.
	local l = row
	while l > 1 and vim.fn.foldlevel(l - 1) >= vim.fn.foldlevel(l) do
		l = l - 1
	end
	return l
end

local function close_cursor_fold(st)
	-- Only close folds that were opened by cursor-follow, not ones the
	-- user toggled open manually (recorded in _G.OllamaOpenFolds).
	if (_G.OllamaOpenFolds or {})[st] then
		return
	end
	if vim.fn.foldclosed(st) == -1 then
		vim.cmd("silent! " .. st .. "foldclose")
	end
end

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
	group = group,
	buffer = bufnr,
	callback = function()
		local win = vim.api.nvim_get_current_win()
		if vim.api.nvim_win_get_buf(win) ~= bufnr then
			return
		end
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local fs = fold_start_of(row)
		if fs == -1 then
			if last_inside then
				close_cursor_fold(last_inside)
				_G.OllamaCursorFolds[last_inside] = nil
				last_inside = nil
			end
			return
		end
		if fs == last_inside then
			return
		end
		-- entering a different fold: close the previous cursor-opened one
		if last_inside then
			close_cursor_fold(last_inside)
			_G.OllamaCursorFolds[last_inside] = nil
		end
		if vim.fn.foldclosed(fs) ~= -1 then
			-- collapsed: open it and remember it was cursor-opened
			_G.OllamaCursorFolds[fs] = true
			vim.cmd("silent! " .. fs .. "foldopen")
		end
		last_inside = fs
	end,
})

_G.OllamaFoldText = function()
	local lnum = vim.v.foldstart
	local lines = vim.v.foldend - lnum + 1
	return ("+-- 🤔 thinking (%d lines) --------------------------------"):format(lines)
end

-- ---------- Alias table: fence tag -> syntax file basename (no .vim) ----------
local OLLAMA_SYNTAX_ALIASES = {
	-- JS/TS/React
	js = "javascript",
	node = "javascript",
	mjs = "javascript",
	cjs = "javascript",
	jsx = "javascript",
	javascriptreact = "javascriptreact",
	ts = "typescript",
	tsx = "typescript",
	typescriptreact = "typescriptreact",

	-- C-family
	["c"] = "c",
	["c++"] = "cpp",
	cpp = "cpp",
	cc = "cpp",
	hpp = "cpp",
	["objective-c"] = "objc",
	["objective-c++"] = "objcpp",
	["obj-c"] = "objc",
	["obj-c++"] = "objcpp",
	csharp = "cs",
	["c#"] = "cs",

	-- Shells
	shell = "sh",
	sh = "sh",
	bash = "bash",
	zsh = "zsh",
	fish = "fish",

	-- Config/markup
	md = "markdown",
	markdown = "markdown",
	yml = "yaml",
	yaml = "yaml",
	json = "json",
	jsonc = "json",
	toml = "toml",
	ini = "dosini",
	conf = "conf",
	xml = "xml",
	html = "html",
	htm = "html",
	css = "css",
	scss = "scss",
	sass = "sass",
	less = "less",

	-- Infra
	docker = "dockerfile",
	dockerfile = "dockerfile",
	nginx = "nginx",
	tf = "terraform",
	terraform = "terraform",
	hcl = "hcl",

	-- Data/query
	sql = "sql",
	graphql = "graphql",
	gql = "graphql",
	proto = "proto",
	protobuf = "proto",
	csv = "csv",

	-- Languages
	lua = "lua",
	python = "python",
	py = "python",
	ruby = "ruby",
	rb = "ruby",
	perl = "perl",
	php = "php",
	go = "go",
	rust = "rust",
	rs = "rust",
	zig = "zig",
	java = "java",
	kotlin = "kotlin",
	kt = "kotlin",
	swift = "swift",
	objc = "objc",
	objcpp = "objcpp",
	r = "r",
	haskell = "haskell",
	hs = "haskell",
	ocaml = "ocaml",
	caml = "ocaml",
	clojure = "clojure",
	scala = "scala",
	julia = "julia",
	dart = "dart",

	-- Scripting/automation
	make = "make",
	makefile = "make",
	cmake = "cmake",
	powershell = "ps1",
	ps = "ps1",
	ps1 = "ps1",

	-- Misc
	vim = "vim",
	vimscript = "vim",
	regex = "regexp",
	regexp = "regexp",
}

-- Escape a string for literal use inside a Vim regex
local function vim_regex_escape(s)
	return (s:gsub("([\\.^$~%[%]*+?(){}|])", "\\%1"))
end

-- Map fence tag -> canonical syntax name (no .vim)
local function resolve_lang(tag)
	if not tag or tag == "" then
		return nil
	end
	tag = tag:lower()
	tag = tag:match("^([%w%+%-%_%.#]+)") or tag
	return OLLAMA_SYNTAX_ALIASES[tag] or tag
end

-- Build/update fenced-code syntax per buffer
local function ollama_update_fenced_syntax()
	-- gather unique canonical languages in this buffer
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local found, order = {}, {}
	for _, line in ipairs(lines) do
		local raw = line:match("^%s*```%s*([%w%+%-%_%.#]+)")
		if raw then
			local canon = resolve_lang(raw)
			if canon and not found[canon] then
				found[canon] = true
				table.insert(order, canon)
			end
		end
	end

	-- clear previously created regions/clusters
	if type(vim.b.ollama_fence_langs) == "table" then
		for _, old in ipairs(vim.b.ollama_fence_langs) do
			vim.cmd("silent! syntax clear OllamaCodeBlock_" .. old)
			vim.cmd("silent! syntax clear OllamaCode_" .. old)
		end
	end
	vim.cmd("silent! syntax cluster OllamaAllCode contains=NONE")
	vim.cmd("highlight def link OllamaCodeFence Special")

	-- plain (untagged) fenced block: single-line command
	vim.cmd(
		"silent! syntax clear OllamaCodeBlock_plain | "
			.. "syntax region OllamaCodeBlock_plain matchgroup=OllamaCodeFence "
			.. "start='^\\s*```\\s*$' end='^\\s*```\\s*$' keepend containedin=ALL contains=NONE"
	)
	vim.cmd("syntax cluster OllamaAllCode add=OllamaCodeBlock_plain")

	for _, lang in ipairs(order) do
		-- Only include syntax files that exist on the runtimepath; the tag
		-- is also validated against a safe charset above, so this cannot
		-- inject arbitrary ex commands.
		local have_file = #vim.fn.globpath(vim.o.runtimepath, "syntax/" .. lang .. ".vim", true) > 0
		local esc = vim_regex_escape(lang)

		if have_file then
			-- Work around the b:current_syntax guard in syntax files.
			-- Use vim.b directly: script-local (s:) variables are not shared
			-- between separate vim.cmd() calls.
			local prev_syn = vim.b.current_syntax
			vim.b.current_syntax = nil
			vim.cmd("syntax include @OllamaCode_" .. lang .. " syntax/" .. lang .. ".vim")
			if prev_syn then
				vim.b.current_syntax = prev_syn
			else
				vim.b.current_syntax = nil
			end
		end

		-- One-line :syntax region to avoid backslash continuation issues in Lua cmd()
		local start_pat = "^\\s*```\\s*\\%(" .. esc .. "\\)\\%(\\s\\+.*\\)\\=$"
		local end_pat = "^\\s*```\\s*$"
		local contains = have_file and ("@OllamaCode_" .. lang) or "NONE"

		local region_cmd = "syntax region OllamaCodeBlock_"
			.. lang
			.. " matchgroup=OllamaCodeFence"
			.. " start='"
			.. start_pat
			.. "'"
			.. " end='"
			.. end_pat
			.. "'"
			.. " keepend containedin=ALL contains="
			.. contains

		vim.cmd(region_cmd)
		vim.cmd("syntax cluster OllamaAllCode add=OllamaCodeBlock_" .. lang)
	end

	vim.b.ollama_fence_langs = order
end

-- Debounce the (relatively expensive) syntax refresh so streaming
-- responses don't re-run it on every single TextChanged tick.
local refresh_timer = nil
local function schedule_fenced_syntax_refresh()
	if refresh_timer then
		refresh_timer:close()
		refresh_timer = nil
	end
	refresh_timer = vim.defer_fn(function()
		refresh_timer = nil
		if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "ollama_chat" then
			ollama_update_fenced_syntax()
		end
	end, 200)
end

-- buffer-local autocommands only for this chat buffer
do
	local grp = vim.api.nvim_create_augroup("OllamaFencedSyntax", { clear = false })
	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		group = grp,
		buffer = bufnr,
		callback = function()
			invalidate_fold_cache(bufnr)
			schedule_fenced_syntax_refresh()
		end,
	})
end

-- Listen for line changes directly: TextChanged does not fire for
-- programmatic writes (which is how streamed responses are appended).
do
	local buf_loaded = false
	local function on_lines()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return true
		end
		invalidate_fold_cache(bufnr)
		schedule_fenced_syntax_refresh()
	end
	local function on_loaded()
		if buf_loaded then
			return true
		end
		buf_loaded = true
		invalidate_fold_cache(bufnr)
		schedule_fenced_syntax_refresh()
	end
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function()
			on_lines()
		end,
		on_reload = function()
			on_lines()
		end,
		on_detach = function() end,
	})
	vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
		group = vim.api.nvim_create_augroup("OllamaFencedSyntaxLoad", { clear = true }),
		buffer = bufnr,
		callback = function()
			on_loaded()
		end,
	})
end

-- Base syntax: headings, model line, think/user/assistant blocks
vim.cmd([[
  silent! syntax clear OllamaCodeBlock

  syntax match OllamaHeading /^# .*$/
  syntax match OllamaModel   /^Model: .*$/

  syntax region OllamaThinkBlock
        \ start=+<think>+
        \ end=+</think>+
        \ fold
        \ keepend

  syntax region OllamaUser
        \ start=/^\*\*User:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend

  syntax region OllamaAssistant
        \ start=/^\*\*Ollama:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend
        \ contains=OllamaThinkBlock,@OllamaAllCode
]])

-- Theme-friendly highlights
vim.api.nvim_set_hl(0, "OllamaUser", { link = "Identifier" })
vim.api.nvim_set_hl(0, "OllamaAssistant", { link = "Statement" })
vim.api.nvim_set_hl(0, "OllamaModel", { link = "Comment" })
vim.api.nvim_set_hl(0, "OllamaThinkBlock", { link = "Comment" })
vim.api.nvim_set_hl(0, "OllamaHeading", { link = "Special" })
vim.api.nvim_set_hl(0, "OllamaCodeFence", { link = "Special" })

-- initial syntax build for this buffer
ollama_update_fenced_syntax()
