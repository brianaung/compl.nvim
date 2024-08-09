# compl.nvim
A minimal and dependency-free auto-completion plugin built on top of vim's ins-completion mechanism.

## Features
- Asynchronous auto completion with a custom debounce
- Vim's Snippet expansion support
- Ability to apply additional text edits (e.g. auto-imports)
- Dynamic sorting of completion items
- Fuzzy matching capabilities
- Smart text replace when completing the same word after cursor
- Zero flicker when refreshing completion items list
- Info windows

#### Non-goals
- Multiple completion sources
- Fancy popup menu highlights

## Installation
**Using [lazy.nvim](https://github.com/folke/lazy.nvim):**
```lua
{
  "brianaung/compl.nvim",
  opts = {
    -- Default options
	-- fuzzy = false,
	-- completion = {
	-- 	timeout = 100,
	-- },
	-- info = {
	-- 	timeout = 100,
	-- },
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

## ~Similar~ Better alternatives
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
- [mini.completion](https://github.com/echasnovski/mini.completion)
- [coq_nvim](https://github.com/ms-jpq/coq_nvim)
- [nvim-lsp-compl](https://github.com/mfussenegger/nvim-lsp-compl)
