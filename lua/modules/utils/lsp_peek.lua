local M = {}

local api = vim.api
local methods = vim.lsp.protocol.Methods
local namespace = api.nvim_create_namespace("LspPeek")

local request_sequence = 0
local state = {}

local function empty_state()
	state = {
		active = false,
		closing = false,
		pending = nil,
		origin = nil,
		root = nil,
		current = nil,
		candidate = 1,
		node_count = 0,
		preview_buf = nil,
		preview_win = nil,
		info_buf = nil,
		info_win = nil,
		preview_source = nil,
		preview_tick = nil,
		group = nil,
	}
end

empty_state()

local function valid_win(win)
	return win and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf and api.nvim_buf_is_valid(buf)
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP Peek" })
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function truncate(text, width)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end

	local suffix = "…"
	local result = ""
	for index = 0, vim.fn.strchars(text) - 1 do
		local char = vim.fn.strcharpart(text, index, 1)
		if vim.fn.strdisplaywidth(result .. char .. suffix) > width then
			break
		end
		result = result .. char
	end
	return result .. suffix
end

local function float_layout()
	local columns = vim.o.columns
	local available_lines = vim.o.lines - vim.o.cmdheight
	local info_height = 4
	local width = math.max(30, math.min(100, math.floor(columns * 0.78)))
	width = math.min(width, math.max(1, columns - 4))
	local preview_height = math.min(12, math.max(3, available_lines - info_height - 4))
	local total_height = preview_height + info_height + 4
	local row = math.max(0, math.floor((available_lines - total_height) / 2))
	local col = math.max(0, math.floor((columns - width - 2) / 2))

	return {
		width = width,
		preview_height = preview_height,
		info_height = info_height,
		row = row,
		col = col,
	}
end

local function window_config(row, col, width, height, title, focusable, zindex)
	return {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "single",
		title = title,
		title_pos = "center",
		focusable = focusable,
		zindex = zindex,
	}
end

local function update_layout()
	if not valid_win(state.preview_win) or not valid_win(state.info_win) then
		return
	end

	local layout = float_layout()
	local loading = state.pending and " · loading" or ""
	api.nvim_win_set_config(
		state.preview_win,
		window_config(
			layout.row,
			layout.col,
			layout.width,
			layout.preview_height,
			" LSP Peek" .. loading .. " ",
			true,
			60
		)
	)
	api.nvim_win_set_config(
		state.info_win,
		window_config(
			layout.row + layout.preview_height + 2,
			layout.col,
			layout.width,
			layout.info_height,
			" Definition / References ",
			false,
			61
		)
	)
end

local function save_preview_view()
	if not state.current or not valid_win(state.preview_win) then
		return
	end

	local view = api.nvim_win_call(state.preview_win, vim.fn.winsaveview)
	state.current.selected_candidate = state.candidate
	state.current.views[state.candidate] = {
		lnum = view.lnum,
		col = view.col,
		topline = view.topline,
		leftcol = view.leftcol,
	}
end

local function source_at_cursor()
	local win = api.nvim_get_current_win()
	local buf = api.nvim_get_current_buf()
	local cursor = api.nvim_win_get_cursor(win)

	if state.active then
		if win ~= state.preview_win or buf ~= state.preview_buf then
			return nil, "Move the cursor into the peek preview first"
		end
		if not valid_buf(state.preview_source) or not api.nvim_buf_is_loaded(state.preview_source) then
			return nil, "The preview source buffer is no longer available"
		end
		if api.nvim_buf_get_changedtick(state.preview_source) ~= state.preview_tick then
			return nil, "The preview source changed; select the candidate again"
		end

		local preview_line = api.nvim_buf_get_lines(state.preview_buf, cursor[1] - 1, cursor[1], false)[1]
		local source_line = api.nvim_buf_get_lines(state.preview_source, cursor[1] - 1, cursor[1], false)[1]
		if preview_line == nil or preview_line ~= source_line then
			return nil, "The preview no longer maps to its source"
		end

		buf = state.preview_source
		cursor[2] = math.min(cursor[2], #source_line)
	end

	if not api.nvim_buf_is_loaded(buf) then
		return nil, "The source buffer is not loaded"
	end

	local line = api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]
	if line == nil then
		return nil, "The cursor is outside the source buffer"
	end

	local label = vim.fn.expand("<cword>")
	if label == "" then
		label = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t") .. ":" .. cursor[1]
	end

	return {
		bufnr = buf,
		uri = vim.uri_from_bufnr(buf),
		changedtick = api.nvim_buf_get_changedtick(buf),
		line = cursor[1] - 1,
		byte_col = math.min(cursor[2], #line),
		line_text = line,
		label = label,
	}
end

local function valid_position(position)
	return type(position) == "table" and type(position.line) == "number" and type(position.character) == "number"
end

local function valid_range(range)
	return type(range) == "table" and valid_position(range.start) and valid_position(range["end"])
end

local function normalize_location(raw, job)
	if type(raw) ~= "table" then
		return nil
	end

	local uri = raw.targetUri or raw.uri
	local selection_range = raw.targetSelectionRange or raw.range or raw.targetRange
	if type(uri) ~= "string" or not valid_range(selection_range) then
		return nil
	end

	return {
		kind = job.kind,
		uri = uri,
		selection_range = selection_range,
		client_id = job.client.id,
		encoding = job.encoding,
		raw = raw,
	}
end

local function collect_locations(pending, job, result)
	if result == nil or result == vim.NIL then
		return
	end

	local locations = vim.islist(result) and result or { result }
	local bucket = pending.results[job.index]
	for _, raw in ipairs(locations) do
		local location = normalize_location(raw, job)
		if location then
			bucket[#bucket + 1] = location
		end
	end
end

local function ordered_candidates(pending)
	local candidates = {}
	local seen = {}

	for index = 1, #pending.jobs do
		for _, candidate in ipairs(pending.results[index]) do
			local range = candidate.selection_range
			local key = table.concat({
				candidate.uri,
				candidate.encoding,
				range.start.line,
				range.start.character,
			}, "\0")
			if not seen[key] then
				seen[key] = true
				candidates[#candidates + 1] = candidate
			end
		end
	end

	return candidates
end

local function stop_timer(pending)
	local timer = pending and pending.timer
	if not timer then
		return
	end
	pending.timer = nil
	if not timer:is_closing() then
		timer:stop()
		timer:close()
	end
end

local function cancel_pending(pending)
	if not pending or pending.finished then
		return
	end
	pending.finished = true
	stop_timer(pending)

	for _, request in pairs(pending.requests) do
		local client = vim.lsp.get_client_by_id(request.client_id)
		if client and client.requests[request.request_id] then
			pcall(client.cancel_request, client, request.request_id)
		end
	end
	pending.requests = {}
end

local render

local function finish_request(pending, status)
	if pending.finished or state.pending ~= pending then
		return
	end

	pending.finished = true
	stop_timer(pending)
	state.pending = nil
	pending.requests = {}

	if status ~= "ok" then
		if state.active then
			update_layout()
			render()
		end
		notify(status == "timeout" and "Peek request timed out" or "Peek request failed", vim.log.levels.WARN)
		return
	end

	local candidates = ordered_candidates(pending)
	if #candidates == 0 or candidates[1].kind ~= "definition" then
		if state.active then
			update_layout()
			render()
		end
		notify("No definition found", vim.log.levels.INFO)
		return
	end
	if
		not valid_buf(pending.source.bufnr)
		or not api.nvim_buf_is_loaded(pending.source.bufnr)
		or vim.uri_from_bufnr(pending.source.bufnr) ~= pending.source.uri
		or api.nvim_buf_get_changedtick(pending.source.bufnr) ~= pending.source.changedtick
	then
		if state.active then
			update_layout()
			render()
		end
		notify("The peek source changed before the response arrived", vim.log.levels.WARN)
		return
	end

	state.node_count = state.node_count + 1
	local node = {
		id = state.node_count,
		label = pending.source.label,
		source = pending.source,
		candidates = candidates,
		parent = pending.parent,
		children = {},
		selected_child = 1,
		selected_candidate = 1,
		views = {},
	}

	if pending.parent then
		pending.parent.children[#pending.parent.children + 1] = node
		pending.parent.selected_child = #pending.parent.children
	else
		state.root = node
	end

	state.current = node
	state.candidate = 1
	state.active = true
	render()
end

local function maybe_finish_request(pending)
	if pending.finished or pending.issuing or pending.remaining ~= 0 or pending.finish_scheduled then
		return
	end

	pending.finish_scheduled = true
	vim.schedule(function()
		pending.finish_scheduled = false
		if state.pending == pending and not pending.finished and pending.remaining == 0 then
			finish_request(pending, "ok")
		end
	end)
end

local function request_node(source, parent)
	if state.pending then
		notify("A peek request is still pending")
		return
	end

	local specs = {
		{ kind = "definition", method = methods.textDocument_definition },
		{ kind = "reference", method = methods.textDocument_references },
	}
	local jobs = {}
	local definition_supported = false
	for _, spec in ipairs(specs) do
		for _, client in ipairs(vim.lsp.get_clients({ bufnr = source.bufnr, method = spec.method })) do
			local encoding = client.offset_encoding
			if encoding == "utf-8" or encoding == "utf-16" or encoding == "utf-32" then
				local params = {
					textDocument = vim.lsp.util.make_text_document_params(source.bufnr),
					position = {
						line = source.line,
						character = vim.str_utfindex(source.line_text, encoding, source.byte_col, false),
					},
				}
				if spec.kind == "reference" then
					params.context = { includeDeclaration = true }
				end
				jobs[#jobs + 1] = {
					index = #jobs + 1,
					kind = spec.kind,
					method = spec.method,
					client = client,
					encoding = encoding,
					params = params,
				}
				if spec.kind == "definition" then
					definition_supported = true
				end
			end
		end
	end

	if not definition_supported then
		notify("No attached LSP supports definitions", vim.log.levels.WARN)
		return
	end

	request_sequence = request_sequence + 1
	local pending = {
		id = request_sequence,
		source = source,
		parent = parent,
		jobs = jobs,
		results = {},
		requests = {},
		remaining = #jobs,
		issuing = true,
		finished = false,
		finish_scheduled = false,
	}
	for index = 1, #jobs do
		pending.results[index] = {}
	end
	state.pending = pending
	if state.active then
		save_preview_view()
		update_layout()
	end

	pending.timer = vim.defer_fn(function()
		pending.timer = nil
		if state.pending == pending and not pending.finished then
			cancel_pending(pending)
			state.pending = nil
			if state.active then
				update_layout()
				render()
			end
			notify("Peek request timed out", vim.log.levels.WARN)
		end
	end, 10000)

	for _, queued_job in ipairs(jobs) do
		local job = queued_job
		local key = job.method .. "\0" .. job.client.id
		local responded = false
		local function handler(err, result)
			if responded then
				return
			end
			responded = true
			pending.requests[key] = nil
			if pending.finished or state.pending ~= pending then
				return
			end

			if not err then
				local ok, collect_error = xpcall(function()
					collect_locations(pending, job, result)
				end, debug.traceback)
				if not ok then
					vim.schedule(function()
						notify(collect_error, vim.log.levels.ERROR)
					end)
				end
			end
			pending.remaining = pending.remaining - 1
			maybe_finish_request(pending)
		end

		local called, sent, request_id =
			pcall(job.client.request, job.client, job.method, job.params, handler, source.bufnr)
		if called and sent then
			if request_id and not responded then
				pending.requests[key] = { client_id = job.client.id, request_id = request_id }
			end
		elseif not responded then
			responded = true
			pending.remaining = pending.remaining - 1
		end
	end

	pending.issuing = false
	maybe_finish_request(pending)
end

local function path_label(uri)
	local ok, filename = pcall(vim.uri_to_fname, uri)
	if not ok then
		return uri
	end
	return vim.fn.fnamemodify(filename, ":~:.")
end

local function position_to_byte(buf, position, encoding)
	local line = api.nvim_buf_get_lines(buf, position.line, position.line + 1, false)[1]
	if line == nil then
		return nil
	end
	local ok, byte = pcall(vim.str_byteindex, line, encoding, position.character, false)
	return ok and byte or nil
end

local function set_preview_keymaps()
	local opts = { buffer = state.preview_buf, silent = true, nowait = true }
	vim.keymap.set("n", "gd", M.open, {
		buffer = state.preview_buf,
		silent = true,
		desc = "lsp peek: through",
	})
	vim.keymap.set("n", "<C-n>", M.next_candidate, vim.tbl_extend("force", opts, { desc = "lsp peek: next candidate" }))
	vim.keymap.set(
		"n",
		"<C-p>",
		M.previous_candidate,
		vim.tbl_extend("force", opts, { desc = "lsp peek: previous candidate" })
	)
	vim.keymap.set("n", "<M-h>", M.parent, vim.tbl_extend("force", opts, { desc = "lsp peek: parent" }))
	vim.keymap.set("n", "<M-l>", M.child, vim.tbl_extend("force", opts, { desc = "lsp peek: child" }))
	vim.keymap.set(
		"n",
		"<M-k>",
		M.previous_sibling,
		vim.tbl_extend("force", opts, { desc = "lsp peek: previous sibling" })
	)
	vim.keymap.set("n", "<M-j>", M.next_sibling, vim.tbl_extend("force", opts, { desc = "lsp peek: next sibling" }))
	vim.keymap.set("n", "<M-CR>", M.jump, vim.tbl_extend("force", opts, { desc = "lsp peek: jump" }))
	vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "lsp peek: close" }))
	vim.keymap.set("n", "<Esc>", M.close, opts)
end

local function ensure_ui()
	if valid_win(state.preview_win) and valid_win(state.info_win) then
		return
	end

	state.preview_buf = api.nvim_create_buf(false, true)
	state.info_buf = api.nvim_create_buf(false, true)
	for _, buf in ipairs({ state.preview_buf, state.info_buf }) do
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].undolevels = -1
	end
	vim.b[state.preview_buf].lsp_peek_role = "preview"
	vim.b[state.info_buf].lsp_peek_role = "info"
	set_preview_keymaps()

	local layout = float_layout()
	state.preview_win = api.nvim_open_win(
		state.preview_buf,
		true,
		window_config(layout.row, layout.col, layout.width, layout.preview_height, " LSP Peek ", true, 60)
	)
	state.info_win = api.nvim_open_win(
		state.info_buf,
		false,
		window_config(
			layout.row + layout.preview_height + 2,
			layout.col,
			layout.width,
			layout.info_height,
			" Definition / References ",
			false,
			61
		)
	)

	vim.wo[state.preview_win].number = true
	vim.wo[state.preview_win].relativenumber = false
	vim.wo[state.preview_win].cursorline = true
	vim.wo[state.preview_win].wrap = false
	vim.wo[state.preview_win].signcolumn = "no"
	vim.wo[state.info_win].wrap = false
	vim.wo[state.info_win].cursorline = false
	vim.wo[state.info_win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"

	state.group = api.nvim_create_augroup("LspPeekUi", { clear = true })
	api.nvim_create_autocmd("VimResized", {
		group = state.group,
		callback = update_layout,
	})
	api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		callback = function(args)
			local closed = tonumber(args.match)
			if not state.closing and (closed == state.preview_win or closed == state.info_win) then
				vim.schedule(M.close)
			end
		end,
	})
end

local function render_preview(candidate)
	state.preview_source = nil
	state.preview_tick = nil
	local uri_ok, source_buf = pcall(vim.uri_to_bufnr, candidate.uri)
	if not uri_ok then
		set_lines(state.preview_buf, { "Unable to load preview: " .. candidate.uri })
		notify("Could not load " .. candidate.uri, vim.log.levels.ERROR)
		return false
	end
	if not api.nvim_buf_is_loaded(source_buf) then
		local ok = pcall(vim.fn.bufload, source_buf)
		if not ok or not api.nvim_buf_is_loaded(source_buf) then
			set_lines(state.preview_buf, { "Unable to load preview: " .. candidate.uri })
			notify("Could not load " .. candidate.uri, vim.log.levels.ERROR)
			return false
		end
	end

	local client = vim.lsp.get_client_by_id(candidate.client_id)
	if client and not vim.lsp.buf_is_attached(source_buf, client.id) then
		pcall(vim.lsp.buf_attach_client, source_buf, client.id)
	end

	local lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
	set_lines(state.preview_buf, lines)
	local filetype = vim.bo[source_buf].filetype
	if vim.bo[state.preview_buf].filetype ~= filetype then
		vim.bo[state.preview_buf].filetype = filetype
	end
	set_preview_keymaps()

	state.preview_source = source_buf
	state.preview_tick = api.nvim_buf_get_changedtick(source_buf)
	vim.b[state.preview_buf].lsp_peek_source = source_buf
	vim.b[state.preview_buf].lsp_peek_node = state.current.id

	api.nvim_buf_clear_namespace(state.preview_buf, namespace, 0, -1)
	local start = candidate.selection_range.start
	local finish = candidate.selection_range["end"]
	local start_byte = position_to_byte(source_buf, start, candidate.encoding) or 0
	local end_byte = position_to_byte(source_buf, finish, candidate.encoding)
	local line_count = api.nvim_buf_line_count(state.preview_buf)
	local start_row = math.max(0, math.min(start.line, line_count - 1))
	local end_row = math.max(start_row, math.min(finish.line, line_count - 1))
	if end_byte then
		pcall(api.nvim_buf_set_extmark, state.preview_buf, namespace, start_row, start_byte, {
			end_row = end_row,
			end_col = end_byte,
			hl_group = "LspReferenceText",
			priority = 200,
		})
	end

	local target_cursor = { start_row + 1, start_byte }
	api.nvim_win_set_cursor(state.preview_win, target_cursor)
	local saved = state.current.views[state.candidate]
	if saved then
		local topline = math.max(1, math.min(saved.topline, line_count))
		local cursor_row = math.max(1, math.min(saved.lnum, line_count))
		local cursor_line = api.nvim_buf_get_lines(state.preview_buf, cursor_row - 1, cursor_row, false)[1] or ""
		api.nvim_win_call(state.preview_win, function()
			vim.fn.winrestview({
				lnum = cursor_row,
				col = math.max(0, math.min(saved.col, #cursor_line)),
				topline = topline,
				leftcol = saved.leftcol,
			})
		end)
	else
		api.nvim_win_call(state.preview_win, function()
			vim.cmd("normal! zz")
		end)
	end
	return true
end

local function history_line()
	local current = state.current
	local ancestors = {}
	local node = current.parent
	while node do
		table.insert(ancestors, 1, node)
		node = node.parent
	end

	local parts = {}
	for _, ancestor in ipairs(ancestors) do
		parts[#parts + 1] = ancestor.label
		parts[#parts + 1] = #ancestor.children > 1 and "<" or "->"
	end
	parts[#parts + 1] = "[" .. current.label .. "]"
	node = current
	while #node.children > 0 do
		parts[#parts + 1] = #node.children > 1 and "<" or "->"
		node = node.children[node.selected_child]
		parts[#parts + 1] = node.label
	end

	return ("(%d/%d) %s"):format(state.candidate, #current.candidates, table.concat(parts, " "))
end

local function render_info()
	local node = state.current
	local total = #node.candidates
	local first = math.max(1, state.candidate - 1)
	first = math.min(first, math.max(1, total - 2))
	local lines = {}

	for offset = 0, 2 do
		local index = first + offset
		local candidate = node.candidates[index]
		if candidate then
			local position = candidate.selection_range.start
			local label = ("(%s) %s %d:%d"):format(
				candidate.kind,
				path_label(candidate.uri),
				position.line + 1,
				position.character + 1
			)
			lines[#lines + 1] = truncate(label, float_layout().width)
		else
			lines[#lines + 1] = ""
		end
	end
	lines[4] = truncate(history_line(), float_layout().width)
	set_lines(state.info_buf, lines)

	api.nvim_buf_clear_namespace(state.info_buf, namespace, 0, -1)
	api.nvim_buf_set_extmark(state.info_buf, namespace, state.candidate - first, 0, {
		line_hl_group = "Visual",
		priority = 200,
	})
	api.nvim_buf_set_extmark(state.info_buf, namespace, 3, 0, {
		line_hl_group = "CursorLine",
		priority = 100,
	})
end

render = function()
	if not state.active or not state.current then
		return
	end

	ensure_ui()
	update_layout()
	render_preview(state.current.candidates[state.candidate])
	render_info()
	if valid_win(state.preview_win) then
		api.nvim_set_current_win(state.preview_win)
	end
end

local function move_to_node(node)
	if not state.current or not node or node == state.current then
		return
	end
	save_preview_view()
	state.current = node
	state.candidate = node.selected_candidate or 1
	render()
end

local function same_source(left, right)
	return left and right and left.uri == right.uri and left.line == right.line and left.byte_col == right.byte_col
end

function M.open()
	if
		state.active
		and (api.nvim_get_current_win() ~= state.preview_win or api.nvim_get_current_buf() ~= state.preview_buf)
	then
		if valid_win(state.preview_win) and valid_buf(state.preview_buf) then
			api.nvim_set_current_win(state.preview_win)
		else
			notify("The peek preview is no longer available", vim.log.levels.WARN)
		end
		return
	end

	local source, err = source_at_cursor()
	if not source then
		notify(err, vim.log.levels.WARN)
		return
	end
	if state.current then
		for index, child in ipairs(state.current.children) do
			if same_source(child.source, source) then
				state.current.selected_child = index
				move_to_node(child)
				return
			end
		end
	end

	if not state.active then
		state.origin = {
			win = api.nvim_get_current_win(),
			buf = api.nvim_get_current_buf(),
			cursor = api.nvim_win_get_cursor(0),
		}
	end
	request_node(source, state.active and state.current or nil)
end

function M.next_candidate()
	if not state.current or state.candidate >= #state.current.candidates then
		return
	end
	save_preview_view()
	state.candidate = state.candidate + 1
	state.current.selected_candidate = state.candidate
	render()
end

function M.previous_candidate()
	if not state.current or state.candidate <= 1 then
		return
	end
	save_preview_view()
	state.candidate = state.candidate - 1
	state.current.selected_candidate = state.candidate
	render()
end

function M.parent()
	if state.current then
		move_to_node(state.current.parent)
	end
end

function M.child()
	if state.current and #state.current.children > 0 then
		move_to_node(state.current.children[state.current.selected_child])
	elseif state.current then
		move_to_node(nil)
	end
end

local function move_sibling(delta)
	if not state.current or not state.current.parent then
		move_to_node(nil)
		return
	end

	local parent = state.current.parent
	local count = #parent.children
	if count < 2 then
		move_to_node(nil)
		return
	end
	parent.selected_child = ((parent.selected_child - 1 + delta) % count) + 1
	move_to_node(parent.children[parent.selected_child])
end

function M.previous_sibling()
	move_sibling(-1)
end

function M.next_sibling()
	move_sibling(1)
end

function M.jump()
	if not state.current then
		return
	end
	local candidate = state.current.candidates[state.candidate]
	local raw = candidate.raw
	local encoding = candidate.encoding
	M.close()
	vim.lsp.util.show_document(raw, encoding, { focus = true, reuse_win = true })
end

function M.close()
	if state.closing then
		return
	end
	state.closing = true
	cancel_pending(state.pending)

	local origin = state.origin
	local preview_win = state.preview_win
	local info_win = state.info_win
	local preview_buf = state.preview_buf
	local info_buf = state.info_buf
	local group = state.group

	if group then
		pcall(api.nvim_del_augroup_by_id, group)
	end
	for _, win in ipairs({ info_win, preview_win }) do
		if valid_win(win) then
			pcall(api.nvim_win_close, win, true)
		end
	end
	for _, buf in ipairs({ info_buf, preview_buf }) do
		if valid_buf(buf) then
			pcall(api.nvim_buf_delete, buf, { force = true })
		end
	end

	empty_state()
	if origin and valid_win(origin.win) then
		pcall(api.nvim_set_current_win, origin.win)
	end
end

function M.status()
	return {
		active = state.active,
		pending = state.pending ~= nil,
		node_count = state.node_count,
		current_node = state.current and state.current.id or nil,
		parent_node = state.current and state.current.parent and state.current.parent.id or nil,
		children = state.current and #state.current.children or 0,
		candidate = state.current and state.candidate or nil,
		candidate_count = state.current and #state.current.candidates or 0,
		preview_win = state.preview_win,
		info_win = state.info_win,
		preview_buf = state.preview_buf,
		preview_source = state.preview_source,
	}
end

return M
