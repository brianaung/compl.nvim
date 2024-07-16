local vim = vim
local unpack = unpack

local function au(event, callback, desc)
	vim.api.nvim_create_autocmd(event, {
		group = vim.api.nvim_create_augroup("Compl", { clear = false }),
		callback = callback,
		desc = desc,
	})
end

local function debounce(timer, timeout, callback)
	return function(...)
		local argv = { ... }
		timer:start(timeout, 0, function()
			timer:stop()
			vim.schedule_wrap(callback)(unpack(argv))
		end)
	end
end

local function has_lsp_clients(bufnr)
	local clients = vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/completion" }
	return #clients ~= 0
end

local M = {}

M.completion = {
	timer = vim.uv.new_timer(),
	timeout = 100,
	status = "DONE",
	responses = {},
}

function M.setup()
	if vim.fn.has "nvim-0.10" ~= 1 then
		vim.notify("compl.nvim requires nvim-0.10 or higher. ", vim.log.levels.ERROR)
		return
	end

	_G.Completefunc = M.completefunc

	au({ "BufEnter", "LspAttach" }, function(e)
		vim.bo[e.buf].completefunc = "v:lua.Completefunc"
	end, "Set completion function.")

	au(
		"InsertCharPre",
		debounce(M.completion.timer, M.completion.timeout, M.start_completion),
		"Trigger auto completion."
	)

	au(
		"CompleteDonePre",
		M.on_completedonepre,
		"Additional text edits and commands to run after insert mode completion is done."
	)
end

function M.start_completion()
	local bufnr = vim.api.nvim_get_current_buf()
	if
		vim.fn.pumvisible() ~= 0
		or vim.fn.state "m" == "m"
		or vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= ""
	then
		return
	end

	if has_lsp_clients(bufnr) then
		vim.api.nvim_feedkeys(vim.keycode "<C-x><C-u>", "m", false)
	else
		vim.api.nvim_feedkeys(vim.keycode "<C-x><C-n>", "m", false)
	end
end

---Finds LSP completion words.
---
---This function fires twice everytime it's called. See :h complete-functions
---- (1) findstart = 1, base = empty -> find the start of text to be completed
---- (2) findstart = 0, base = text located in the first call -> find matches
---
---On 1st call,
---- (1) makes a request to get completion items, leave completion mode, then re-triggers completefunc.
---- (2) skipped, since function call in resetted in (1).
---On 2nd call,
---- (1) no more requests are made, it returns the start of completion.
---- (2) process responses from earlier request, then return a list of words to complete.
---
---@param findstart integer Defines how the function is called
---@param base string The text with which completion items should match
---@return integer|table # A list of matching words
function M.completefunc(findstart, base)
	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))

	-- Get completion items
	if M.completion.status == "DONE" then
		local position_params = vim.lsp.util.make_position_params()

		M.completion.status = "SENT"
		vim.lsp.buf_request_all(bufnr, "textDocument/completion", position_params, function(responses)
			M.completion.status = "RECEIVED"

			-- Apply itemDefaults to completion item as per the LSP specs:
			--
			-- "In many cases the items of an actual completion result share the same
			-- value for properties like `commitCharacters` or the range of a text
			-- edit. A completion list can therefore define item defaults which will
			-- be used if a completion item itself doesn't specify the value.
			--
			-- If a completion list specifies a default value and a completion item
			-- also specifies a corresponding value the one from the item is used."
			for _, response in pairs(responses) do
				if not response.err and response.result then
					local items = response.result.items or response.result or {}
					for _, item in pairs(items) do
						local itemDefaults = response.result.itemDefaults
						if itemDefaults then
							-- https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/completion.lua#L173
							item.insertTextFormat = item.insertTextFormat or itemDefaults.insertTextFormat
							item.insertTextMode = item.insertTextMode or itemDefaults.insertTextMode
							item.data = item.data or itemDefaults.data
							if itemDefaults.editRange then
								local textEdit = item.textEdit or {}
								item.textEdit = textEdit
								textEdit.newText = textEdit.newText or item.textEditText or item.insertText
								if itemDefaults.editRange.start then
									textEdit.range = textEdit.range or itemDefaults.editRange
								elseif itemDefaults.editRange.insert then
									textEdit.insert = itemDefaults.editRange.insert
									textEdit.replace = itemDefaults.editRange.replace
								end
							end
						end
					end
				end
			end

			M.completion.responses = responses
			M.start_completion()
		end)

		return findstart == 1 and -3 or {}
	end

	-- Find completion start
	if findstart == 1 then
		-- Example from: https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/completion.lua#L331
		-- Completion response items may be relative to a position different than `client_start_boundary`.
		-- Concrete example, with lua-language-server:
		--
		-- require('plenary.asy|
		--         ▲       ▲   ▲
		--         │       │   └── cursor_pos:                     20
		--         │       └────── client_start_boundary:          17
		--         └────────────── textEdit.range.start.character: 9
		--                                 .newText = 'plenary.async'
		--                  ^^^
		--                  prefix (We'd remove everything not starting with `asy`,
		--                  so we'd eliminate the `plenary.async` result
		--
		-- We prefer to use the language server boundary if available.
		--
		for _, response in pairs(M.completion.responses) do
			if not response.err and response.result then
				local items = response.result.items or response.result or {}
				for _, item in pairs(items) do
					-- Get server start (if completion item has text edits)
					-- https://github.com/echasnovski/mini.completion/blob/main/lua/mini/completion.lua#L1306
					if type(item.textEdit) == "table" then
						local range = type(item.textEdit.range) == "table" and item.textEdit.range
							or item.textEdit.insert
						return range.start.character
					end
				end
			end
		end

		-- Fallback to client start (if completion item does not provide text edits)
		local line = vim.api.nvim_get_current_line()
		return vim.fn.match(line:sub(1, col), "\\k*$")
	end

	M.completion.status = "DONE"

	-- Process and find completion words
	local words = {}
	for client_id, response in pairs(M.completion.responses) do
		if not response.err and response.result then
			local items = response.result.items or response.result or {}

			local matches = {}
			for _, item in pairs(items) do
				local text = item.filterText
					or (vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or "")
				if vim.startswith(text, base:sub(1, 1)) and next(vim.fn.matchfuzzy({ text }, base)) then
					table.insert(matches, item)
				end
				-- Add extra field to check for exact matches
				item.exact = text == base
			end

			-- Sorting is done with multiple fallbacks.
			-- If it fails to find diff in each stage, it will then fallback to the next stage.
			-- https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/config/compare.lua
			table.sort(matches, function(a, b)
				-- Sort by exact matches
				if a.exact ~= b.exact then
					return a.exact
				end

				-- Sort by ordinal value of 'kind'.
				-- Exceptions: 'Snippet' are ranked highest, and 'Text' are ranked lowest
				if a.kind ~= b.kind then
					if vim.lsp.protocol.CompletionItemKind[a.kind] == "Snippet" then
						return true
					end
					if vim.lsp.protocol.CompletionItemKind[b.kind] == "Snippet" then
						return false
					end
					if vim.lsp.protocol.CompletionItemKind[a.kind] == "Text" then
						return false
					end
					if vim.lsp.protocol.CompletionItemKind[b.kind] == "Text" then
						return true
					end
					local diff = a.kind - b.kind
					if diff < 0 then
						return true
					elseif diff > 0 then
						return false
					end
				end

				-- Sort by lexicographical order of 'sortText'.
				if a.sortText and b.sortText then
					local diff = vim.stricmp(a.sortText, b.sortText)
					if diff < 0 then
						return true
					elseif diff > 0 then
						return false
					end
				end

				-- Sort by length
				return #a.label < #b.label
			end)

			for _, item in ipairs(matches) do
				local kind = vim.lsp.protocol.CompletionItemKind[item.kind] or "Unknown"
				local word
				if kind == "Snippet" then
					word = item.label or ""
				else
					word = vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or ""
				end

				local word_to_be_replaced =
					vim.api.nvim_buf_get_text(bufnr, row - 1, col, row - 1, col + vim.fn.strwidth(word), {})

				table.insert(words, {
					word = vim.list_contains(word_to_be_replaced, word) and "" or word,
					abbr = item.label,
					kind = kind,
					icase = 1,
					dup = 1,
					empty = 1,
					user_data = {
						nvim = {
							lsp = { completion_item = item, client_id = client_id },
							-- keep track of word replace to update cursor pos after completedone
							replaced_word = vim.list_contains(word_to_be_replaced, word) and word or "",
						},
					},
				})
			end
		end
	end

	return words
end

function M.on_completedonepre()
	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if vim.tbl_isempty(completion_item) then
		return
	end

	local client = vim.lsp.get_client_by_id(lsp_data.client_id)
	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))

	local completed_word = vim.v.completed_item.word or ""
	local kind = vim.lsp.protocol.CompletionItemKind[completion_item.kind] or "Unknown"

	-- No words were inserted since it is a duplicate, so set cursor to end of duplicate word
	if completed_word == "" then
		local replaced_word = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "replaced_word") or ""
		vim.api.nvim_win_set_cursor(winnr, { row, col + vim.fn.strwidth(replaced_word) })
	end

	-- Expand snippet only if word is inserted, not replaced
	if kind == "Snippet" and completed_word ~= "" then
		vim.api.nvim_buf_set_text(bufnr, row - 1, col - vim.fn.strwidth(completed_word), row - 1, col, { "" })
		vim.api.nvim_win_set_cursor(winnr, { row, col - vim.fn.strwidth(completed_word) })
		vim.snippet.expand(vim.tbl_get(completion_item, "textEdit", "newText") or completion_item.insertText or "")
	end

	-- Apply additionalTextEdits
	local edits = completion_item.additionalTextEdits or {}
	if not vim.tbl_isempty(edits) then
		vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
	else
		-- TODO fix bug
		-- Reproduce:
		-- 1. Insert newline(s) right after completing an item without exiting insert mode.
		-- 2. Undo changes.
		-- Result: Completed item is not removed without the undo changes.
		client.request("completionItem/resolve", completion_item, function(err, result)
			edits = (not err) and (result.additionalTextEdits or {}) or {}
			if not vim.tbl_isempty(edits) then
				-- vim.cmd [[silent! undojoin]]
				vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
			end
		end)
	end
end

return M
