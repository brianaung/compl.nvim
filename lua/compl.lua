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
	completion_start = nil,
	completion_generation = 0,
	pending_requests = {},
	cancel_pending = function()
		for _, cancel_fn in ipairs(M._ctx.pending_requests) do
			pcall(cancel_fn)
		end
		M._ctx.pending_requests = {}
	end,
	completion_history = {},
}

M._completion = {
	timer = vim.uv.new_timer(),
	responses = {},
}

local function is_internal_snippet(item)
	return type(item) == "table"
		and type(item.data) == "table"
		and vim.tbl_get(item.data, "compl", "source") == "snippet"
end

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
	client_bufnr = nil,
	items = {},
	filetype = nil,
	generation = 0,
	loading = false,
	cache = {},
}

function M.setup(opts)
	if vim.fn.has "nvim-0.11" ~= 1 then
		vim.notify("compl.nvim: Requires nvim-0.11 or higher.", vim.log.levels.ERROR)
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
		callback = M._debounce(M._completion.timer, M._opts.completion.timeout, M._start_completion),
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
			callback = M._debounce(M._info.timer, M._opts.info.timeout, M._start_info),
		})
	end

	if M._opts.snippet.enable then
		vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
			group = group,
			callback = function(args)
				if args.buf == vim.api.nvim_get_current_buf() then
					M._start_snippet(args.buf)
				end
			end,
		})
		vim.api.nvim_create_user_command("ComplRefreshSnippets", function()
			M.refresh_snippets()
		end, {
			desc = "Reload compl.nvim snippets for the current filetype",
		})
		vim.schedule(function()
			M._start_snippet(vim.api.nvim_get_current_buf())
		end)
	end
end

--- Select the first completion item, or accept the selected item.
---@return string|nil
function M.accept_or_select()
	if vim.fn.pumvisible() == 0 then
		return nil
	end

	local info = vim.fn.complete_info()
	if info.selected == -1 then
		if #(info.items or {}) == 1 then
			return vim.keycode "<C-n>" .. vim.keycode "<C-y>"
		end
		return "<C-n>"
	end
	return "<C-y>"
end

function M._start_completion()
	M._ctx.cancel_pending()
	M._ctx.completion_generation = M._ctx.completion_generation + 1
	local generation = M._ctx.completion_generation

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
	local request_tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local request_cursor = { row, col }

	-- Make a request to get completion items
	local position_params = function(client, _)
		return vim.lsp.util.make_position_params(0, client.offset_encoding)
	end
	local cancel_fn = vim.lsp.buf_request_all(bufnr, "textDocument/completion", position_params, function(responses)
		if
			generation ~= M._ctx.completion_generation
			or not vim.api.nvim_buf_is_valid(bufnr)
			or vim.api.nvim_get_current_buf() ~= bufnr
			or vim.api.nvim_buf_get_changedtick(bufnr) ~= request_tick
			or not vim.deep_equal(request_cursor, vim.api.nvim_win_get_cursor(0))
			or vim.fn.mode() ~= "i"
		then
			return
		end

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
				for _, item in ipairs(items) do
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
		local start
		for _, response in pairs(M._completion.responses) do
			if not response.err and response.result then
				local items = response.result.items or response.result or {}
				for _, item in pairs(items) do
					-- Get server start (if completion item has text edits)
					-- https://github.com/echasnovski/mini.completion/blob/main/lua/mini/completion.lua#L1306
					if type(item.textEdit) == "table" then
						local range = type(item.textEdit.range) == "table" and item.textEdit.range
							or item.textEdit.insert
						start = range.start.character
						break
					end
				end
			end
			if start then
				break
			end
		end

		-- Fallback to client start (if completion item does not provide text edits)
		start = start or vim.fn.match(line:sub(1, col), "\\k*$")
		M._ctx.completion_start = start
		return start
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
						table.insert(matches, { client_id = client_id, item = item })
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

		-- Sort by frecency
		local a_score = M._frecency(M._ctx.completion_history[a.label])
		local b_score = M._frecency(M._ctx.completion_history[b.label])
		if a_score ~= b_score then
			return a_score > b_score
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
			local is_snippet = is_internal_snippet(item) or kind == "Snippet"
			local word
			if is_snippet then
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
							start = is_internal_snippet(item) and M._ctx.completion_start or nil,
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

	-- Only perform side effects on intentional completion accepts
	local reason = vim.tbl_get(vim.v.event, "reason")
	if reason ~= "accept" then
		return
	end

	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if not next(completion_item) then
		return
	end

	local completion_label = completion_item.label or ""
	M._ctx.completion_history[completion_label] = {
		frequency = (vim.tbl_get(M._ctx.completion_history, completion_label, "frequency") or 0) + 1,
		accepted_at = vim.uv.now(),
	}

	local internal_snippet = is_internal_snippet(completion_item)
	if internal_snippet then
		local snippet = completion_item.insertText or completion_item.label
		if type(snippet) ~= "string" or snippet == "" then
			return
		end

		local completed_item = vim.v.completed_item or {}
		local completed_word = completed_item.word or ""
		local replace = vim.tbl_get(lsp_data, "replace") or ""
		local bufnr = vim.api.nvim_get_current_buf()
		local winnr = vim.api.nvim_get_current_win()
		local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))
		local start_col = lsp_data.start or math.max(col - #completed_word, 0)
		local end_col = col
		if completed_word == "" then
			end_col = end_col + #replace
		end
		local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
		end_col = math.min(end_col, #line)
		start_col = math.max(math.min(start_col, end_col), 0)

		if end_col > start_col then
			local removed = pcall(vim.api.nvim_buf_set_text, bufnr, row - 1, start_col, row - 1, end_col, { "" })
			if not removed then
				return
			end
		end
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, start_col })
		pcall(vim.snippet.expand, snippet)
		local expanded_row, expanded_col = unpack(vim.api.nvim_win_get_cursor(winnr))
		M._ctx.cursor = { expanded_row, expanded_col }
		return
	end

	local client = vim.lsp.get_client_by_id(lsp_data.client_id)
	if not client then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))

	-- Update context cursor so completion is not triggered right after complete done.
	M._ctx.cursor = { row, col }

	local completed_item = vim.v.completed_item or {}
	local completed_word = completed_item.word or ""
	local kind = vim.lsp.protocol.CompletionItemKind[completion_item.kind] or "Unknown"

	-- No words were inserted since it is a duplicate, so set cursor to end of duplicate word
	if completed_word == "" then
		local replace = vim.tbl_get(lsp_data, "replace") or ""
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, col + #replace })
	end

	-- Expand LSP-provided snippets using the existing behavior.
	if kind == "Snippet" then
		pcall(vim.api.nvim_buf_set_text, bufnr, row - 1, col - #completed_word, row - 1, col, { "" })
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, col - #completed_word })
		vim.snippet.expand(vim.tbl_get(completion_item, "textEdit", "newText") or completion_item.insertText or "")
	end

	-- Apply additionalTextEdits
	local edits = completion_item.additionalTextEdits or {}
	if next(edits) then
		vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
	else
		local ok, request_id = client.request("completionItem/resolve", completion_item, function(err, result)
			edits = (not err) and (result and result.additionalTextEdits or {}) or {}
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

local function snippet_matches_filetype(language, filetype)
	if language == nil or language == "all" then
		return true
	end
	if type(language) == "table" then
		return vim.iter(language):any(function(value)
			return value == "all" or value == filetype
		end)
	end
	return language == filetype
end

local function append_snippet_items(items, snippet_data)
	for _, snippet in pairs(snippet_data or {}) do
		if type(snippet) == "table" then
			local body = type(snippet.body) == "table" and table.concat(snippet.body, "\n") or snippet.body
			local prefixes = type(snippet.prefix) == "table" and snippet.prefix or { snippet.prefix }
			if type(body) == "string" and body ~= "" then
				for _, prefix in ipairs(prefixes) do
					if type(prefix) == "string" and prefix ~= "" then
						table.insert(items, {
							detail = "snippet",
							label = prefix,
							filterText = prefix,
							sortText = prefix,
							kind = vim.lsp.protocol.CompletionItemKind.Snippet,
							documentation = {
								value = snippet.description,
								kind = vim.lsp.protocol.MarkupKind.Markdown,
							},
							insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
							insertText = body,
							data = { compl = { source = "snippet" } },
						})
					end
				end
			end
		end
	end
end

function M._start_snippet(bufnr)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or (bufnr or vim.api.nvim_get_current_buf())
	if not vim.api.nvim_buf_is_valid(bufnr) or not M._opts.snippet.enable then
		return
	end

	local filetype = vim.bo[bufnr].filetype
	local current_client = M._snippet.client_id and vim.lsp.get_client_by_id(M._snippet.client_id)
	if
		M._snippet.filetype == filetype
		and (
			(M._snippet.loading and M._snippet.client_bufnr == bufnr)
			or (current_client and M._snippet.client_bufnr == bufnr)
		)
	then
		return
	end

	local generation = M._snippet.generation + 1
	M._snippet.generation = generation
	M._snippet.filetype = filetype

	local cached = M._snippet.cache[filetype]
	if cached then
		M._snippet.loading = false
		M._snippet.items = cached
		M._start_snippet_server(cached, bufnr)
		return
	end

	local items = {}
	M._snippet.items = items
	M._snippet.loading = true
	-- Start with an empty table and fill it asynchronously. The server keeps
	-- this table by reference, so requests made while loading see no stale
	-- snippets from the previous filetype.
	M._start_snippet_server(items, bufnr)

	local pending = 0
	local function is_current()
		return generation == M._snippet.generation
	end

	local function finish_one()
		pending = pending - 1
		if pending > 0 or not is_current() then
			return
		end
		vim.schedule(function()
			if
				generation ~= M._snippet.generation
				or M._snippet.client_bufnr ~= bufnr
				or not vim.api.nvim_buf_is_valid(bufnr)
				or vim.bo[bufnr].filetype ~= filetype
			then
				return
			end
			M._snippet.cache[filetype] = items
			M._snippet.loading = false
		end)
	end

	local function parse_snippet_data(snippet_data)
		if is_current() then
			append_snippet_items(items, snippet_data)
		end
	end

	for _, root in ipairs(M._opts.snippet.paths) do
		pending = pending + 1
		local manifest_path = root .. "/package.json"
		M._async_read_json(manifest_path, function(manifest_data)
			if is_current() then
				local contributions = manifest_data and manifest_data.contributes and manifest_data.contributes.snippets
					or {}
				for _, contribution in ipairs(contributions) do
					if type(contribution) == "table" and snippet_matches_filetype(contribution.language, filetype) then
						pending = pending + 1
						local snippet_path = vim.fn.resolve(root .. "/" .. contribution.path)
						M._async_read_json(snippet_path, function(snippet_data)
							parse_snippet_data(snippet_data)
							finish_one()
						end)
					end
				end
			end
			finish_one()
		end)
	end

	if pending == 0 then
		M._snippet.cache[filetype] = items
		M._snippet.loading = false
	end
end

function M.refresh_snippets()
	M._snippet.cache = {}
	M._snippet.filetype = nil
	M._snippet.loading = false
	M._start_snippet(vim.api.nvim_get_current_buf())
end

function M._start_snippet_server(items, bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if M._snippet.client_id then
		local client = vim.lsp.get_client_by_id(M._snippet.client_id)
		if client then
			pcall(function()
				client:stop(true)
			end)
		end
		M._snippet.client_id = nil
		M._snippet.client_bufnr = nil
	end

	local generation = M._snippet.generation
	local ok, client_id, start_err = pcall(vim.lsp.start, {
		name = "compl_snippets_" .. tostring(bufnr) .. "_" .. tostring(generation),
		cmd = M._make_lsp_server {
			isIncomplete = false,
			items = items,
		},
	}, { bufnr = bufnr })
	if ok and client_id then
		M._snippet.client_id = client_id
		M._snippet.client_bufnr = bufnr
		return
	end

	M._snippet.loading = false
	local message = start_err or "could not start snippet client"
	vim.schedule(function()
		vim.notify("compl.nvim: " .. message, vim.log.levels.WARN)
	end)
end

function M._debounce(timer, timeout, callback)
	return function(...)
		local argv = { ... }
		timer:start(timeout, 0, function()
			timer:stop()
			vim.schedule_wrap(callback)(unpack(argv))
		end)
	end
end

-- https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/path.lua#L755
function M._async_read(file, callback)
	vim.uv.fs_open(file, "r", 438, function(err_open, fd)
		if err_open or not fd then
			return callback(nil, err_open or "could not open file")
		end

		vim.uv.fs_fstat(fd, function(err_fstat, stat)
			if err_fstat or not stat then
				vim.uv.fs_close(fd, function()
					callback(nil, err_fstat or "could not stat file")
				end)
				return
			end

			if stat.type ~= "file" then
				vim.uv.fs_close(fd, function()
					callback("", nil)
				end)
				return
			end

			vim.uv.fs_read(fd, stat.size, 0, function(err_read, data)
				vim.uv.fs_close(fd, function(err_close)
					if err_read then
						return callback(nil, err_read)
					end
					if err_close then
						return callback(nil, err_close)
					end
					callback(data, nil)
				end)
			end)
		end)
	end)
end

function M._async_read_json(file, callback)
	M._async_read(file, function(buffer, read_err)
		vim.schedule(function()
			if read_err then
				return callback(nil, read_err)
			end

			local success, data = pcall(vim.json.decode, buffer or "")
			if not success or not data then
				vim.notify(string.format("compl.nvim: Could not decode json file %s", file), vim.log.levels.ERROR)
				return callback(nil, "could not decode json")
			end
			callback(data, nil)
		end)
	end)
end

function M._make_lsp_server(completion_items)
	return function(dispatchers)
		local closing = false
		local srv = {}

		function srv.request(method, params, callback)
			if method == "initialize" then
				callback(nil, {
					capabilities = {
						completionProvider = true, -- the server has to provide completion support (true or pass options table)
					},
				})
			elseif method == "textDocument/completion" then
				callback(nil, completion_items)
			elseif method == "shutdown" then
				callback(nil, nil)
			end
			return true, 1
		end

		function srv.notify(method, params)
			if method == "exit" and not closing then
				closing = true
				dispatchers.on_exit(0, 15)
			end
		end

		function srv.is_closing()
			return closing
		end

		function srv.terminate()
			if not closing then
				closing = true
				dispatchers.on_exit(0, 15)
			end
		end

		return srv
	end
end

function M._frecency(entry)
	if not entry then
		return 0
	end
	local age_in_ms = vim.uv.now() - entry.accepted_at
	local half_life = 10 * 60 * 1000 -- 10mins
	return entry.frequency * 100 * math.exp(-math.log(2) * age_in_ms / half_life)
end

return M
