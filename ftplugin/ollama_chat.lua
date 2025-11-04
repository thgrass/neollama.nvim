-- ftplugin/ollama_chat.lua
-- This runs for every buffer with :set filetype=ollama_chat

vim.cmd("syntax on")

--  Define syntax rules 
vim.cmd([[
  " Heading lines: 
  syntax match OllamaHeading /^# .*$/

  " Model line: "Model: .."
  syntax match OllamaModel /^Model: .*$/

  " <think> ... </think> block (multi-line)
  " hide only the tags
  syntax region OllamaThinkBlock
        \ start=+<think>+
        \ end=+</think>+
        \ concealends
        \ keepend

  " USER BLOCK:
  " from a line starting with "**User:**" up to the next **User:** or **Ollama:** or EOF
  syntax region OllamaUser
        \ start=/^\*\*User:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend

  " OLLAMA BLOCK:
  " from a line starting with "**Ollama:**" up to the next **User:** or **Ollama:** or EOF
  syntax region OllamaAssistant
        \ start=/^\*\*Ollama:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend
        \ contains=OllamaThinkBlock
]])

--  Define highlight groups (colors/style) 

vim.api.nvim_set_hl(0, "OllamaUser", {
  bold = true,
})

vim.api.nvim_set_hl(0, "OllamaAssistant", {
})

vim.api.nvim_set_hl(0, "OllamaThinkBlock", {
  italic = true,
})

vim.api.nvim_set_hl(0, "OllamaHeading", {
  bold = true,
  underline = true,
})

-- Theme-friendly highlighting: just link to existing groups

vim.api.nvim_set_hl(0, "OllamaUser",      { link = "Identifier" })

vim.api.nvim_set_hl(0, "OllamaAssistant", { link = "Statement"  })

vim.api.nvim_set_hl(0, "OllamaModel",     { link = "Comment"    })

vim.api.nvim_set_hl(0, "OllamaThinkBlock",{ link = "Comment"    })

vim.api.nvim_set_hl(0, "OllamaHeading"   ,{ link = "Special"    })
