# neollama.nvim
# EARLY DEVELOPMENT VERSION/PLAYGROUND. USE AT OWN RISK!!

A minimal Neovim plugin (Lua) to chat with a local **Ollama** instance in a dedicated chat tab, send visual selections, entire buffers, or a set of added buffers to the model, and keep read-only chat history in that tab.

## Features
- `:OllamaChat [model]` — open a new chat **tab** with a read-only chat buffer.
- `:OllamaAsk {text}` — send a one-off prompt to the current chat session.
- `:OllamaChatClose` — close the chat tab and destroy its buffer.
- `:OllamaCancel` — stop the active request for the current chat.
- `:OllamaSendSelection` — send the current **visual selection** (or an explicit `[range]`) as context/prompt.
- `:OllamaSendBuffer` — send the **entire current buffer** content.
- `:OllamaAddBuffer` — add the **current buffer** to the session's context list.
- `:OllamaClearAddedBuffers` — clear the context buffer list for the session.
- `:OllamaSendAddedBuffers` — send the **concatenated contents** of all added buffers.
- `:OllamaModel [model]` — set/get model name for the **current chat** (with completion of installed models).
- `:OllamaModels` — pick an installed model interactively (queried from the server).
- `:OllamaPull {model}` — pull a model from the Ollama registry; progress is shown in the chat.
- `:OllamaOptions [key=value]` — show or set request options (e.g. `temperature=0.2`, `num_ctx=8192`) for the current chat.
- `:OllamaInsert [code]` — insert the last response at the cursor (only its first code block with `code`).
- `:OllamaReplace [code]` — replace the last visual selection with the last response (only its first code block with `code`).
- `:OllamaAskCtx {text}` — ask with automatic context: the symbol under the cursor (via built-in treesitter, nvim-treesitter, or LSP document symbols) or the visible window range.
- `:OllamaSetServer {url}` — change the server URL (default: `http://127.0.0.1:11434`).

> The chat buffer is **read-only**; you interact using commands. History remains visible within the tab.  
> This plugin uses external `curl` to call Ollama's HTTP API (`/api/chat`), either streamed to neovim or not (set in config with `stream=true|false`).  
> The full conversation history is sent with each request, so the model remembers previous exchanges in the session.

## Requirements
- Neovim 0.8+
- A running Ollama server (default: `http://127.0.0.1:11434`)
- `curl` available on your system

## Installation

### Lazy.nvim
```lua
{
  "thgrass/neollama.nvim",
  config = function()
    require("ollama_chat").setup({
      server_url = "http://127.0.0.1:11434",
      model = "llama3.1",
      stream = true,
      timeout = 0, -- seconds; 0 = no timeout
      options = { temperature = 0.7, num_ctx = 8192 }, -- Ollama request options
      system_prompts = {
        default = "You are a helpful coding assistant.",
        python = "You are a Python expert. Answer concisely.",
      },
    })
  end,
}
```

### Packer.nvim
```lua
use({
  "thgrass/neollama.nvim",
  config = function()
    require("ollama_chat").setup({})
  end,
})
```

Or install manually by copying this folder into your neovim `runtimepath`.

## Usage

- Start a chat tab:
  ```vim
  :OllamaChat          " start with default model
  :OllamaChat mistral  " start with model mistral
  ```

- Ask something directly:
  ```vim
  :OllamaAsk What is the time complexity of quicksort?
  ```

- Stop a running request (e.g. a long or hung generation):
  ```vim
  :OllamaCancel
  ```

- From another buffer, send the current **visual** selection:
  - Select text in Visual mode, then:
    ```vim
    :OllamaSendSelection
    ```
  - Or use an explicit range:
    ```vim
    :5,12OllamaSendSelection
    ```

- Send the **entire buffer**:
  ```vim
  :OllamaSendBuffer
  ```

- Build a multi-file context:
  ```vim
  :OllamaAddBuffer           " run in buffers you want to add
  :OllamaSendAddedBuffers    " send all added buffers together
  :OllamaClearAddedBuffers   " clear the list
  ```

- Change model for the current chat:
  ```vim
  :OllamaModel mistral      " set model to mistral  
  :OllamaModel              " prints current model
  ```

- Apply the last answer to your code:
  ```vim
  :OllamaInsert         " insert the last full response at the cursor
  :OllamaInsert code    " insert only the first fenced code block
  :'<,'>OllamaReplace   " replace the visual selection with the last response
  :OllamaReplace code   " replace it with only the first code block
  ```

- Ask about the code you are looking at, without adding buffers manually:
  ```vim
  :OllamaAskCtx what does this function do?
  ```
  The enclosing function/class under the cursor is detected via built-in treesitter
  (no plugin needed), then [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
  if installed, then LSP document symbols; as a last resort the visible window range is used.

- Tune the model per chat:
  ```vim
  :OllamaOptions temperature=0.2
  :OllamaOptions num_ctx=8192
  :OllamaOptions          " show effective options
  ```

- Manage models without leaving the editor:
  ```vim
  :OllamaModels          " pick from installed models
  :OllamaPull llama3.1   " pull a new model, progress in the chat
  ```

- Change server URL:
  ```vim
  :OllamaSetServer http://localhost:11434
  ```

- Close Chat Tab & Destroy Chat Buffer:
  ```vim
  :OllamaChatClose
  ```

## Configuration options

| Option | Default | Description |
| --- | --- | --- |
| `server_url` | `http://127.0.0.1:11434` | Ollama server base URL |
| `model` | `deepcoder:14b` | Default model |
| `stream` | `true` | Stream responses token by token |
| `timeout` | `0` | Request timeout in seconds (`0` = unlimited) |
| `options` | `{}` | Default Ollama request options (e.g. `temperature`, `num_ctx`, `top_p`, `seed`); per-session overrides via `:OllamaOptions` |
| `system_prompts.default` | `""` | System prompt used when the invoking buffer has no specific prompt |
| `system_prompts.<filetype>` | `""` | System prompt used when asking from a buffer of that filetype |

`system_prompts` entries are matched against the **filetype of the buffer you invoke the command from**, falling back to `default` when unset.

## TODO
- Add support for model prompts and other variables.
- Improve support for programming tasks.
- ...

## License
MIT
