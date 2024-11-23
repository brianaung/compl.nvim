# compl.nvim
A minimal and **dependency-free** auto-completion plugin built on top of Vim's ins-completion mechanism.

## Features
- **Asynchronous completion** with customizable debounce for fast, responsive suggestions.
- **Native snippet expansion** integration with Neovim’s built-in snippet system.
- Support for **VS Code style custom snippets** by [internally running a minimal LSP server](#using-vs-code-style-custom-snippets), seamlessly integrating snippet items into the existing completion workflow.
- Ability to apply **additional text edits** (e.g., auto-imports) during completion.
- **Rich documentation** in an info window for better context and understanding.
- **Zero flicker** when refreshing the completion list, ensuring a smooth and seamless experience.
- **Dynamic sorting** of completion items in multiple steps, improving relevance and accuracy.
- **Fuzzy matching** for flexible, quick word completion, even with partial inputs.
- **Smart word replacement** for completing repeated words after the cursor, saving time and effort.

#### Planned Features
- Ability to add custom completion sources (not aiming to be compatible with `nvim-cmp`'s sources).
- Display of signature help for functions and methods.

#### Design Philosophy
Focused on minimalism and performance, without the overhead of complex configurations or external dependencies. Therefore, supporting non-native features such as popup menus with fancy colors/highlights, etc., is a non-goal.

## Installation
**Using [lazy.nvim](https://github.com/folke/lazy.nvim):**
```lua
{
  "brianaung/compl.nvim",
  opts = {
    -- Default options (no need to set them again)
    completion = {
      fuzzy = false,
      timeout = 100,
    },
    info = {
      timeout = 100,
    },
    snippet = {
      enable = false,
      paths = {},
    },
  },
}
```

## Recommended VIM Options
```lua
-- A set of options for better completion experience. See `:h completeopt`
vim.opt.completeopt = { "menuone", "noselect", "noinsert" }

-- Hides the ins-completion-menu messages. See `:h shm-c`
vim.opt.shortmess:append "c"
```

## Custom Keymaps
By default, this plugin follows ins-completion mappings (See `:h ins-completion-menu`, `:h popupmenu-keys`). However, they can be easily remapped.

Below are some recipes using the `vim.keymap.set()` interface. See `:h vim.keymap.set()`.

**Accept completion using `<CR>`**
```lua
vim.keymap.set("i", "<CR>", function()
  if vim.fn.complete_info()["selected"] ~= -1 then return "<C-y>" end
  if vim.fn.pumvisible() ~= 0 then return "<C-e><CR>" end
  return "<CR>"
end, { expr = true })
```

**Change selection using `<Tab>` and `<Shift-Tab>`**
```lua
vim.keymap.set("i", "<Tab>", function()
  if vim.fn.pumvisible() ~= 0 then return "<C-n>" end
  return "<Tab>"
end, { expr = true })

vim.keymap.set("i", "<S-Tab>", function()
  if vim.fn.pumvisible() ~= 0 then return "<C-p>" end
  return "<S-Tab>"
end, { expr = true })
```

**Snippet jumps**
```lua
vim.keymap.set({ "i", "s" }, "<C-k>", function()
  if vim.snippet.active { direction = 1 } then
    return "<cmd>lua vim.snippet.jump(1)<cr>"
  end
end, { expr = true })

vim.keymap.set({ "i", "s" }, "<C-j>", function()
  if vim.snippet.active { direction = -1 } then
    return "<cmd>lua vim.snippet.jump(-1)<cr>"
  end
end, { expr = true })
```

## Using VS Code style custom snippets
You can seamlessly integrate custom snippets into your existing completion workflow without any additional dependencies. Snippets from the specified paths are parsed and formatted into appropriate LSP responses, and are passed into a lightweight internal LSP server, which then returns them as completion items when Neovim's LSP client sends a `textDocument/completion` request.

### Example: Using Friendly Snippets
To use a collection of snippets such as those provided in [rafamadriz/friendly-snippets](https://github.com/rafamadriz/friendly-snippets), install it as a dependency and point to the location of its `package.json` manifest file. Here's how to configure it using `lazy.nvim`:

```lua
{
  "brianaung/compl.nvim",
  dependencies = {
    "rafamadriz/friendly-snippets"
  },
  opts = {
    -- ...
    snippet = {
      enable = true,
      paths = {
	vim.fn.stdpath "data" .. "/lazy/friendly-snippets",
	-- You can include more paths that contains the package.json manifest for your custom snippets. See below for defining your own snippets.
      },
    },
    -- ...
  },
}
```

### Defining Your Own Snippets
If you'd like to define your own snippets for a specific language, you can create a JSON file with your snippets following this [syntax](https://code.visualstudio.com/docs/editor/userdefinedsnippets#_create-your-own-snippets).

You’ll then need to create a [`package.json` manifest](https://code.visualstudio.com/api/references/contribution-points#contributes.snippets) that will describe how to retrieve snippets for each filetype.
- `language`: The language in the manifest should match the filetype used by Neovim (e.g., `vim.bo.filetype`).
- `path`: Provide the file path to your snippet JSON file.

#### References
- https://zignar.net/2022/10/26/testing-neovim-lsp-plugins/#a-in-process-lsp-server
- https://www.reddit.com/r/neovim/comments/1g1x0v3/hacking_native_snippets_into_lsp_for_builtin/?rdt=41546

## Similar alternatives
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
- [mini.completion](https://github.com/echasnovski/mini.completion)
- [coq_nvim](https://github.com/ms-jpq/coq_nvim)
- [nvim-lsp-compl](https://github.com/mfussenegger/nvim-lsp-compl)
