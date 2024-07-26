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

M.opts = {
	fuzzy = false,
	completion = {
		timeout = 100,
	},
	info = {
		timeout = 200,
	},
}

M.context = {
	cursor = nil,
	pending_requests = {},
}

M.completion = {
	timer = vim.uv.new_timer(),
	responses = {},
}

M.info = {
	timer = vim.uv.new_timer(),
	bufnr = 0,
	winids = {},
}

function M.setup(opts)
	if vim.fn.has "nvim-0.10" ~= 1 then
		vim.notify("compl.nvim requires nvim-0.10 or higher. ", vim.log.levels.ERROR)
		return
	end

	-- apply user configuration options
	opts = opts or {}
	M.opts = vim.tbl_deep_extend("force", M.opts, opts)

	-- ensure the user provides correct configs
	vim.validate {
		["fuzzy"] = { M.opts.fuzzy, "b" },
		["completion"] = { M.opts.completion, "t" },
		["completion.timeout"] = { M.opts.completion.timeout, "n" },
		["info"] = { M.opts.info, "t" },
		["info.timeout"] = { M.opts.info.timeout, "n" },
	}

	_G.Completefunc = M.completefunc

	M.info.bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(M.info.bufnr, "Compl:InfoWindow")
	vim.fn.setbufvar(M.info.bufnr, "&buftype", "nofile")

	au({ "BufEnter", "LspAttach" }, function(e)
		vim.bo[e.buf].completefunc = "v:lua.Completefunc"
	end, "Set completion function.")

	au(
		{ "TextChangedI", "TextChangedP" },
		debounce(M.completion.timer, M.opts.completion.timeout, M.start_completion),
		"Trigger auto completion."
	)

	au(
		"CompleteChanged",
		debounce(M.info.timer, M.opts.info.timeout, M.start_info),
		"Show extra documentation info in a separate window."
	)

	au(
		"CompleteDonePre",
		M.on_completedonepre,
		"Additional text edits and commands to run after insert mode completion is done."
	)

	au("InsertLeavePre", function()
		M.close_info()
	end, "Close any opened info windows when leaving insert mode.")
end

function M.start_completion()
	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))
	local line = vim.api.nvim_get_current_line()
	local before_char = line:sub(col, col + 1)

	-- Cancel pending completion requests
	for _, cancel in ipairs(M.context.pending_requests) do
		cancel()
	end
	M.context.pending_requests = {}

	-- stylua: ignore start
	-- Stop completion in these scenarios
	-- Context didn't change
	if vim.deep_equal(M.context.cursor, { row, col }) then return end
	-- if it does, it needs to be updated immediately after
	M.context.cursor = { row, col }

	-- No LSP client
	if not has_lsp_clients(bufnr) then return end

	-- Not a normal buffer
	if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then return end

	-- Not in insert mode
	if vim.fn.mode() ~= "i" then return end

	-- Halfway a mapping
	if vim.fn.state "m" == "m" then return end

	-- Item is selected
	if vim.fn.complete_info()["selected"] ~= -1 then return end

	-- Cursor is at the beginning
	if col == 0 then return end

	-- Char before cursor is a whitespace
	if vim.fn.match(before_char, "\\s") ~= -1 then return end
	-- stylua: ignore end

	-- Make a request to get completion items
	local position_params = vim.lsp.util.make_position_params()
	table.insert(
		M.context.pending_requests,
		vim.lsp.buf_request_all(bufnr, "textDocument/completion", position_params, function(responses)
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

			-- Trigger completefunc (add insert mode check again since this callback is async)
			if vim.fn.mode() == "i" then
				vim.api.nvim_feedkeys(vim.keycode "<C-x><C-u>", "m", false)
			end
		end)
	)
end

function M.completefunc(findstart, base)
	local line = vim.api.nvim_get_current_line()
	local winnr = vim.api.nvim_get_current_win()
	local _, col = unpack(vim.api.nvim_win_get_cursor(winnr))

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
		return vim.fn.match(line:sub(1, col), "\\k*$")
	end

	-- Process and find completion words
	local words = {}
	for client_id, response in pairs(M.completion.responses) do
		if not response.err and response.result then
			local items = response.result.items or response.result or {}

			local matches = {}
			for _, item in pairs(items) do
				local text = item.filterText
					or (vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or "")
				if M.opts.fuzzy then
					local fuzzy = vim.fn.matchfuzzy({ text }, base)
					if vim.startswith(text, base:sub(1, 1)) and (base == "" or next(fuzzy)) then
						table.insert(matches, item)
					end
				else
					if vim.startswith(text, base) then
						table.insert(matches, item)
					end
				end
				-- Add an extra custom field to mark exact matches
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

				local word_to_be_replaced = line:sub(col + 1, col + vim.fn.strwidth(word))
				local replace = word_to_be_replaced == word

				table.insert(words, {
					word = replace and "" or word,
					equal = 1, -- we will do the filtering ourselves
					abbr = item.label,
					kind = kind,
					icase = 1,
					dup = 1,
					empty = 1,
					user_data = {
						nvim = {
							lsp = {
								completion_item = item,
								client_id = client_id,
								replace = replace and word or "",
							},
						},
					},
				})
			end
		end
	end

	return words
end

function M.start_info()
	M.close_info()

	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if vim.tbl_isempty(completion_item) then
		return
	end

	local client = vim.lsp.get_client_by_id(lsp_data.client_id)

	-- get resolved item only if item does not already contain documentation
	if completion_item.documentation then
		M.show_info(completion_item)
	else
		client.request("completionItem/resolve", completion_item, function(err, result)
			if not err and result.documentation then
				M.show_info(result)
			end
		end)
	end
end

function M.show_info(item)
	local detail = item.detail or ""

	local documentation
	if type(item.documentation) == "string" then
		documentation = item.documentation or ""
	else
		documentation = vim.tbl_get(item.documentation or {}, "value") or ""
	end

	if documentation == "" and detail == "" then
		return
	end

	local input
	if detail == "" then
		input = documentation
	elseif documentation == "" then
		input = detail
	else
		input = detail .. "\n" .. documentation
	end

	local lines = vim.lsp.util.convert_input_to_markdown_lines(input)
	local pumpos = vim.fn.pum_getpos()

	if not vim.tbl_isempty(lines) and not vim.tbl_isempty(pumpos) then
		-- Convert lines into syntax highlighted regions and set it in the buffer
		vim.lsp.util.stylize_markdown(M.info.bufnr, lines)

		local pum_left = pumpos.col - 1
		local pum_right = pumpos.col + pumpos.width + (pumpos.scrollbar and 1 or 0)
		local space_left = pum_left
		local space_right = vim.o.columns - pum_right

		-- Choose the side to open win
		local anchor, col, space = "NW", pum_right, space_right
		if space_right < space_left then
			anchor, col, space = "NE", pum_left, space_left
		end

		-- Calculate width (can grow to full space) and height
		local line_range = vim.api.nvim_buf_get_lines(M.info.bufnr, 0, -1, false)
		local width, height = vim.lsp.util._make_floating_popup_size(line_range, { max_width = space })

		local win_opts = {
			relative = "editor",
			anchor = anchor,
			row = pumpos.row,
			col = col,
			width = width,
			height = height,
			focusable = false,
			style = "minimal",
			border = "none",
		}

		table.insert(M.info.winids, vim.api.nvim_open_win(M.info.bufnr, false, win_opts))
	end
end

function M.close_info()
	for idx, winid in ipairs(M.info.winids) do
		if pcall(vim.api.nvim_win_close, winid, false) then
			M.info.winids[idx] = nil
		end
	end
end

function M.on_completedonepre()
	M.close_info()

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
		local replace = vim.tbl_get(lsp_data, "replace") or ""
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, col + vim.fn.strwidth(replace) })
	end

	-- Expand snippets
	if kind == "Snippet" then
		pcall(vim.api.nvim_buf_set_text, bufnr, row - 1, col - vim.fn.strwidth(completed_word), row - 1, col, { "" })
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, col - vim.fn.strwidth(completed_word) })
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
				vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
			end
		end)
	end
end

return M
