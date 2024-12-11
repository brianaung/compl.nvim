local util = require "compl.util"

local M = {}
_G.Compl = {}

M._opts = {
	completion = {
		timeout = 100,
		fuzzy = false,
	},
	info = {
		enable = true,
		timeout = 100,
	},
	snippet = {
		enable = false,
		paths = {},
	},
}

M._ctx = {
	cursor = nil,
	pending_requests = {},
	cancel_pending = function()
		for _, cancel_fn in ipairs(M._ctx.pending_requests) do
			pcall(cancel_fn)
		end
		M._ctx.pending_requests = {}
	end,
	completed_records = {},
}

M._completion = {
	timer = vim.uv.new_timer(),
	responses = {},
}

M._info = {
	timer = vim.uv.new_timer(),
	bufnr = 0,
	winids = {},
	close_windows = function()
		for idx, winid in ipairs(M._info.winids) do
			if pcall(vim.api.nvim_win_close, winid, false) then
				M._info.winids[idx] = nil
			end
		end
	end,
}

M._snippet = {
	client_id = nil,
	items = {},
}

function M.setup(opts)
	if vim.fn.has "nvim-0.10" ~= 1 then
		vim.notify("compl.nvim: Requires nvim-0.10 or higher.", vim.log.levels.ERROR)
		return
	end

	-- apply and validate settings
	M._opts = vim.tbl_deep_extend("force", M._opts, opts or {})
	vim.validate {
		["completion"] = { M._opts.completion, "t" },
		["completion.timeout"] = { M._opts.completion.timeout, "n" },
		["completion.fuzzy"] = { M._opts.completion.fuzzy, "b" },
		["info"] = { M._opts.info, "t" },
		["info.enable"] = { M._opts.info.enable, "b" },
		["info.timeout"] = { M._opts.info.timeout, "n" },
		["snippet"] = { M._opts.snippet, "t" },
		["snippet.enable"] = { M._opts.snippet.enable, "b" },
		["snippet.paths"] = { M._opts.snippet.paths, "t" },
	}

	local group = vim.api.nvim_create_augroup("Compl", { clear = true })

	vim.api.nvim_create_autocmd({ "BufEnter", "LspAttach" }, {
		group = group,
		callback = function(args)
			vim.bo[args.buf].completefunc = "v:lua.Compl.completefunc"
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
		group = group,
		callback = util.debounce(M._completion.timer, M._opts.completion.timeout, M._start_completion),
	})

	vim.api.nvim_create_autocmd("CompleteDone", {
		group = group,
		callback = M._on_completedone,
	})

	vim.api.nvim_create_autocmd({ "InsertLeavePre", "InsertLeave" }, {
		group = group,
		callback = function()
			M._ctx.cancel_pending()

			M._completion.timer:stop()
			M._info.timer:stop()

			M._info.close_windows()
		end,
	})

	if M._opts.info.enable then
		M._info.bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(M._info.bufnr, "Compl:InfoWindow")
		vim.fn.setbufvar(M._info.bufnr, "&buftype", "nofile")

		vim.api.nvim_create_autocmd("CompleteChanged", {
			group = group,
			callback = util.debounce(M._info.timer, M._opts.info.timeout, M._start_info),
		})
	end

	if M._opts.snippet.enable then
		vim.api.nvim_create_autocmd("BufEnter", {
			group = group,
			callback = M._start_snippet,
		})
	end
end

function M._start_completion()
	M._ctx.cancel_pending()

	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))
	local line = vim.api.nvim_get_current_line()
	local before_char = line:sub(col, col)

	if
		-- No LSP clients
		not next(vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/completion" })
		-- Not a normal buffer
		or vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= ""
		-- Item is selected
		or vim.fn.complete_info()["selected"] ~= -1
		-- Cursor is at the beginning
		or col == 0
		-- Char before cursor is a whitespace
		or vim.fn.match(before_char, "\\s") ~= -1
		-- Context didn't change
		or vim.deep_equal(M._ctx.cursor, { row, col })
	then
		M._ctx.cursor = { row, col }
		-- Do not trigger completion
		return
	end
	M._ctx.cursor = { row, col }

	-- Make a request to get completion items
	local position_params = util.make_position_params()
	local cancel_fn = vim.lsp.buf_request_all(bufnr, "textDocument/completion", position_params, function(responses)
		-- Apply itemDefaults to completion item as per the LSP specs:
		--
		-- "In many cases the items of an actual completion result share the same
		-- value for properties like `commitCharacters` or the range of a text
		-- edit. A completion list can therefore define item defaults which will
		-- be used if a completion item itself doesn't specify the value.
		--
		-- If a completion list specifies a default value and a completion item
		-- also specifies a corresponding value the one from the item is used."
		vim.iter(pairs(responses))
			:filter(function(_, response)
				return (not response.err) and response.result and response.result.itemDefaults
			end)
			:each(function(_, response)
				local itemDefaults = response.result.itemDefaults
				local items = response.result.items or response.result or {}
				vim.iter(ipairs(items)):each(function(_, item)
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
				end)
			end)
		M._completion.responses = responses

		if vim.fn.mode() == "i" then
			vim.api.nvim_feedkeys(vim.keycode "<C-x><C-u>", "m", false)
		end
	end)
	table.insert(M._ctx.pending_requests, cancel_fn)
end

function _G.Compl.completefunc(findstart, base)
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
		for _, response in pairs(M._completion.responses) do
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
	local matches = {}
	for client_id, response in pairs(M._completion.responses) do
		if not response.err and response.result then
			local items = response.result.items or response.result or {}

			for _, item in pairs(items) do
				local text = item.filterText
					or (vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or "")
				if M._opts.completion.fuzzy then
					local fuzzy = vim.fn.matchfuzzy({ text }, base)
					if vim.startswith(text, base:sub(1, 1)) and (base == "" or next(fuzzy)) then
						table.insert(matches, { client_id, item })
					end
				else
					if vim.startswith(text, base) then
						table.insert(matches, { client_id = client_id, item = item })
					end
				end
				-- Add an extra custom field to mark exact matches
				item.exact = text == base
			end
		end
	end

	-- Sorting is done with multiple fallbacks.
	-- If it fails to find diff in each stage, it will then fallback to the next stage.
	-- https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/config/compare.lua
	table.sort(matches, function(a, b)
		a, b = a.item, b.item

		-- Sort by exact matches
		if a.exact ~= b.exact then
			return a.exact or false -- nil should return false
		end

		-- Sort by recency
		local a_ts = M._ctx.completed_records[a.label] or -1
		local b_ts = M._ctx.completed_records[b.label] or -1
		if a_ts ~= b_ts then
			return a_ts > b_ts
		end

		-- Sort by ordinal value of 'kind'.
		-- Exceptions: 'Snippet' are ranked highest, and 'Text' are ranked lowest
		if a.kind ~= b.kind then
			if not a.kind then
				return false
			end
			if not b.kind then
				return true
			end
			local a_kind = vim.lsp.protocol.CompletionItemKind[a.kind]
			local b_kind = vim.lsp.protocol.CompletionItemKind[b.kind]
			if a_kind == "Snippet" then
				return true
			end
			if b_kind == "Snippet" then
				return false
			end
			if a_kind == "Text" then
				return false
			end
			if b_kind == "Text" then
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
		if a.sortText ~= b.sortText then
			if not a.sortText then
				return false
			end
			if not b.sortText then
				return true
			end
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

	return vim.iter(ipairs(matches))
		:map(function(_, match)
			local item = match.item
			local client_id = match.client_id
			local kind = vim.lsp.protocol.CompletionItemKind[item.kind] or "Unknown"
			local word
			if kind == "Snippet" then
				word = item.label or ""
			else
				word = vim.tbl_get(item, "textEdit", "newText") or item.insertText or item.label or ""
			end
			local word_to_be_replaced = line:sub(col + 1, col + vim.fn.strwidth(word))
			local replace = word_to_be_replaced == word
			return {
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
			}
		end)
		:totable()
end

function M._start_info()
	M._info.close_windows()
	M._ctx.cancel_pending()

	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if not next(completion_item) then
		return
	end

	local client = vim.lsp.get_client_by_id(lsp_data.client_id)
	if not client then
		return
	end

	-- get resolved item only if item does not already contain documentation
	if completion_item.documentation then
		M._open_info_window(completion_item)
	else
		local ok, request_id = client.request("completionItem/resolve", completion_item, function(err, result)
			if not err and result.documentation then
				M._open_info_window(result)
			end
		end)
		if ok then
			local cancel_fn = function()
				if client then
					client.cancel_request(request_id)
				end
			end
			table.insert(M._ctx.pending_requests, cancel_fn)
		end
	end
end

function M._open_info_window(item)
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

	local lines = vim.lsp.util.convert_input_to_markdown_lines(input) or {}
	local pumpos = vim.fn.pum_getpos() or {}

	if next(lines) and next(pumpos) then
		-- Convert lines into syntax highlighted regions and set it in the buffer
		vim.lsp.util.stylize_markdown(M._info.bufnr, lines)

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
		local line_range = vim.api.nvim_buf_get_lines(M._info.bufnr, 0, -1, false)
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

		table.insert(M._info.winids, vim.api.nvim_open_win(M._info.bufnr, false, win_opts))
	end
end

function M._on_completedone()
	M._info.close_windows()

	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if not next(completion_item) then
		return
	end
	M._ctx.completed_records[completion_item.label] = vim.uv.now()

	local client = vim.lsp.get_client_by_id(lsp_data.client_id)
	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))

	-- Update context cursor so completion is not triggered right after complete done.
	M._ctx.cursor = { row, col }

	if not client then
		return
	end

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
	if next(edits) then
		vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
	else
		-- TODO fix bug
		-- Reproduce:
		-- 1. Insert newline(s) right after completing an item without exiting insert mode.
		-- 2. Undo changes.
		-- Result: Completed item is not removed without the undo changes.
		local ok, request_id = client.request("completionItem/resolve", completion_item, function(err, result)
			edits = (not err) and (result.additionalTextEdits or {}) or {}
			if next(edits) then
				vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
			end
		end)
		if ok then
			local cancel_fn = function()
				if client then
					client.cancel_request(request_id)
				end
			end
			table.insert(M._ctx.pending_requests, cancel_fn)
		end
	end
end

function M._start_snippet()
	local filetype = vim.bo.filetype

	local parse_snippet_data = function(snippet_data)
		vim.iter(pairs(snippet_data or {})):each(function(_, snippet)
			local prefixes = type(snippet.prefix) == "table" and snippet.prefix or { snippet.prefix }
			vim.iter(ipairs(prefixes)):each(function(_, prefix)
				table.insert(M._snippet.items, {
					detail = "snippet",
					label = prefix,
					kind = vim.lsp.protocol.CompletionItemKind["Snippet"],
					documentation = {
						value = snippet.description,
						kind = vim.lsp.protocol.MarkupKind.Markdown,
					},
					insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
					insertText = type(snippet.body) == "table" and table.concat(snippet.body, "\n") or snippet.body,
				})
			end)
		end)
	end

	M._snippet.items = {}
	vim.iter(ipairs(M._opts.snippet.paths)):each(function(_, root)
		local manifest_path = table.concat({ root, "package.json" }, util.sep)
		util.async_read_json(manifest_path, function(manifest_data)
			vim.iter(ipairs((manifest_data.contributes and manifest_data.contributes.snippets) or {}))
				:filter(function(_, s)
					if type(s.language) == "table" then
						return vim.iter(ipairs(s.language)):any(function(_, l)
							return l == filetype
						end)
					else
						return s.language == filetype
					end
				end)
				:map(function(_, snippet_contribute)
					return vim.fn.resolve(table.concat({ root, snippet_contribute.path }, util.sep))
				end)
				:each(function(snippet_path)
					util.async_read_json(snippet_path, parse_snippet_data)
				end)
		end)
	end)

	M._start_snippet_server()
end

function M._start_snippet_server()
	if M._snippet.client_id then
		vim.lsp.stop_client(M._snippet.client_id)
		M._snippet.client_id = nil
	end

	M._snippet.client_id = vim.lsp.start {
		name = "compl_snippets",
		cmd = util.make_lsp_server {
			isIncomplete = false,
			items = M._snippet.items,
		},
	}
end

return M
