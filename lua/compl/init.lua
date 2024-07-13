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
end

function M.start_completion()
	if
		vim.fn.pumvisible() ~= 0
		or vim.fn.state "m" == "m"
		or vim.api.nvim_get_option_value("buftype", { buf = 0 }) ~= ""
	then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
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
	-- Get completion items
	if M.completion.status == "DONE" then
		local bufnr = vim.api.nvim_get_current_buf()
		local position_params = vim.lsp.util.make_position_params()

		M.completion.status = "SENT"
		vim.lsp.buf_request_all(bufnr, "textDocument/completion", position_params, function(responses)
			M.completion.status = "RECEIVED"

			--[[
				Apply itemDefaults to completion item according to the LSP specs:

				"In many cases the items of an actual completion result share the same
				value for properties like `commitCharacters` or the range of a text
				edit. A completion list can therefore define item defaults which will
				be used if a completion item itself doesn't specify the value.

				If a completion list specifies a default value and a completion item
				also specifies a corresponding value the one from the item is used.

				Servers are only allowed to return default values if the client
				signals support for this via the `completionList.itemDefaults`
				capability."
			--]]
			for _, response in pairs(responses) do
				if response.err or not response.result then
					goto continue
				end

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
				::continue::
			end

			M.completion.responses = responses
			M.start_completion()
		end)

		return findstart == 1 and -3 or {}
	end

	-- Find completion start
	if findstart == 1 then
		-- Get server start
		for _, response in pairs(M.completion.responses) do
			if response.err or not response.result then
				goto continue
			end

			local items = response.result.items or response.result or {}
			for _, item in pairs(items) do
				-- https://github.com/echasnovski/mini.completion/blob/main/lua/mini/completion.lua#L1306
				if type(item.textEdit) == "table" then
					local range = type(item.textEdit.range) == "table" and item.textEdit.range or item.textEdit.insert
					return range.start.character
				end
			end

			::continue::
		end

		-- Fallback to client start
		local _, col = unpack(vim.api.nvim_win_get_cursor(0))
		local line = vim.api.nvim_get_current_line()
		return vim.fn.match(line:sub(1, col), "\\k*$")
	end

	M.completion.status = "DONE"

	-- Process and find completion words
	local words = {}
	for client_id, response in pairs(M.completion.responses) do
		if response.err or not response.result then
			goto continue
		end

		local items = response.result.items or response.result or {}
		if vim.tbl_isempty(items) then
			goto continue
		end

		local matches = {}
		for _, item in pairs(items) do
			local text = item.filterText
				or (vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or "")
			if vim.startswith(text, base:sub(1, 1)) and next(vim.fn.matchfuzzy({ text }, base)) then
				table.insert(matches, item)
			end
		end

		table.sort(matches, function(a, b)
			return (a.sortText or a.label) < (b.sortText or b.label)
		end)

		for _, item in ipairs(matches) do
			local kind = vim.lsp.protocol.CompletionItemKind[item.kind] or "Unknown"
			local word
			if kind == "Snippet" then
				word = item.label or ""
			else
				word = vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or ""
			end
			table.insert(words, {
				word = word,
				abbr = item.label,
				kind = kind,
				icase = 1,
				dup = 1,
				empty = 1,
				user_data = {
					nvim = { lsp = { completion_item = item, client_id = client_id } },
				},
			})
		end

		::continue::
	end

	return words
end

return M
