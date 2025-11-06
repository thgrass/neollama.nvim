-- ftplugin/ollama_chat.lua
-- This runs for every buffer with :set filetype=ollama_chat

vim.cmd("syntax on")

-- folding for think block, not for code
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldenable = true
vim.opt_local.foldlevel = 0
vim.opt_local.foldexpr = "v:lua.OllamaFold(v:lnum)"

-- Re-assert the foldmethod if another plugin o.e. changes it later
do
	local grp = vim.api.nvim_create_augroup("OllamaFoldGuard", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "FileType", "OptionSet" }, {
		group = grp,
		pattern = "*",
		callback = function()
			if vim.bo.filetype == "ollama_chat" and vim.wo.foldmethod ~= "expr" then
				vim.wo.foldmethod = "expr"
				vim.wo.foldexpr = "v:lua.OllamaFold(v:lnum)"
			end
		end,
	})
end

-- Only fold <think>...</think>; never fold inside ``` fenced blocks
_G.OllamaFold = function(lnum)
	-- Detect if current line is inside a triple-backtick fenced code block
	local function inside_fence(ln)
		local fences = 0
		for i = 1, ln do
			local s = vim.fn.getline(i)
			if s:match("^%s*```") then
				fences = (fences + 1) % 2 -- toggle 0/1
			end
		end
		return fences == 1
	end

	-- Detect if current line is inside a <think>...</think> block
	local function inside_think(ln)
		local depth = 0
		for i = 1, ln do
			local s = vim.fn.getline(i)
			if s:match("^%s*<think>%s*$") then
				depth = depth + 1
			elseif s:match("^%s*</think>%s*$") and depth > 0 then
				depth = depth - 1
			end
		end
		return depth > 0
	end

	local line = vim.fn.getline(lnum)

	-- Never fold anything inside fenced code blocks
	if inside_fence(lnum) then
		return 0
	end

	-- Fold only <think>…</think> blocks (level 1)
	if line:match("^%s*<think>%s*$") then
		return ">1" -- start fold at level 1
	end
	if line:match("^%s*</think>%s*$") then
		return "<1" -- end fold
	end
	if inside_think(lnum) then
		return "=" -- keep previous level (stays at 1 while inside)
		-- Alternatively: return 1
	end

	-- Everything else: no folding
	return 0
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
	if not tag or tag == "" then return nil end
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
		"silent! syntax clear OllamaCodeBlock_plain | " ..
		"syntax region OllamaCodeBlock_plain matchgroup=OllamaCodeFence " ..
		"start='^\\s*```\\s*$' end='^\\s*```\\s*$' keepend containedin=ALL contains=NONE"
	)
	vim.cmd("syntax cluster OllamaAllCode add=OllamaCodeBlock_plain")

	-- preserve & restore b:current_syntax across includes
	local prev_syn = vim.b.current_syntax

	for _, lang in ipairs(order) do
		local have_file = #vim.fn.globpath(vim.o.runtimepath, "syntax/" .. lang .. ".vim", true) > 0
		local esc = vim_regex_escape(lang)

		if have_file then
			-- Work around typical guard in syntax files
			vim.cmd("let s:__keep_syn = exists('b:current_syntax') ? b:current_syntax : v:null")
			vim.cmd("unlet! b:current_syntax")
			vim.cmd('syntax include @OllamaCode_' .. lang .. ' syntax/' .. lang .. '.vim')
			vim.cmd([[
        if s:__keep_syn isnot v:null
          let b:current_syntax = s:__keep_syn
        else
          unlet! b:current_syntax
        endif
        unlet s:__keep_syn
      ]])
		end

		-- One-line :syntax region to avoid backslash continuation issues in Lua cmd()
		local start_pat  = "^\\s*```\\s*\\%(" .. esc .. "\\)\\%(" .. "\\s\\+.*" .. "\\)\\=$"
		local end_pat    = "^\\s*```\\s*$"
		local contains   = have_file and ("@OllamaCode_" .. lang) or "NONE"

		local region_cmd = "syntax region OllamaCodeBlock_" .. lang ..
		    " matchgroup=OllamaCodeFence" ..
		    " start='" .. start_pat .. "'" ..
		    " end='" .. end_pat .. "'" ..
		    " keepend containedin=ALL contains=" .. contains

		vim.cmd(region_cmd)
		vim.cmd("syntax cluster OllamaAllCode add=OllamaCodeBlock_" .. lang)
	end

	vim.b.ollama_fence_langs = order
	vim.b.current_syntax = prev_syn
end

-- autocommands to refresh when editing this filetype
do
	local grp = vim.api.nvim_create_augroup("OllamaFencedSyntax", { clear = false })
	vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
		group = grp,
		pattern = "*",
		callback = function()
			if vim.bo.filetype == "ollama_chat" then
				ollama_update_fenced_syntax()
			end
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
