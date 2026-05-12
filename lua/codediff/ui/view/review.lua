-- Review view engine: render every changed file as one long side-by-side diff.
local M = {}

local config = require("codediff.config")
local compact = require("codediff.ui.view.compact")
local core = require("codediff.ui.core")
local diff_module = require("codediff.core.diff")
local git = require("codediff.core.git")
local inline = require("codediff.ui.inline")
local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")
local render = require("codediff.ui.view.render")
local view_keymaps = require("codediff.ui.view.keymaps")
local welcome_window = require("codediff.ui.view.welcome_window")

local HEADER_WIDTH = 80
local ns_review = vim.api.nvim_create_namespace("codediff-review")
local ns_review_syntax = vim.api.nvim_create_namespace("codediff-review-syntax")
local TREESITTER_PRIORITY = (vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter) or 100
local REVIEW_SYNTAX_PRIORITY = TREESITTER_PRIORITY + 1

local function append_lines(target, lines)
  for _, line in ipairs(lines or {}) do
    table.insert(target, line)
  end
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end

  for index, line in ipairs(left) do
    if right[index] ~= line then
      return false
    end
  end

  return true
end

local function copy_lines(lines)
  return vim.deepcopy(lines or {})
end

local function create_review_buffer(name, editable)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = editable and "acwrite" or "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "codediff-review"
  vim.bo[bufnr].modifiable = editable == true
  vim.bo[bufnr].readonly = editable ~= true
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
  return bufnr
end

local function set_buffer_lines(bufnr, lines)
  local modifiable = vim.bo[bufnr].modifiable
  local readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[bufnr].modifiable = modifiable
  vim.bo[bufnr].readonly = readonly
  vim.bo[bufnr].modified = false
end

local function flatten_status_files(status_result)
  local files = {}

  local function add_group(group, entries)
    for _, entry in ipairs(entries or {}) do
      local file = vim.deepcopy(entry)
      file.group = group
      table.insert(files, file)
    end
  end

  add_group("conflicts", status_result.conflicts)
  add_group("unstaged", status_result.unstaged)
  add_group("staged", status_result.staged)

  return files
end

local function has_staged_entry(status_result, path)
  for _, file in ipairs(status_result.staged or {}) do
    if file.path == path then
      return true
    end
  end
  return false
end

local function has_unstaged_entry(status_result, path)
  for _, file in ipairs(status_result.unstaged or {}) do
    if file.path == path then
      return true
    end
  end
  return false
end

local function empty_source()
  return { kind = "empty" }
end

local function real_source(path)
  return { kind = "real", path = path }
end

local function revision_source(revision, git_root, path)
  return { kind = "revision", revision = revision, git_root = git_root, path = path }
end

local function build_sources(file, context)
  local status = file.status
  local group = file.group or "unstaged"
  local file_path = file.path
  local old_path = file.old_path
  local git_root = context.git_root
  local base_revision = context.base_revision
  local target_revision = context.target_revision
  local abs_path = git_root .. "/" .. file_path

  if group == "conflicts" then
    local ours_position = config.options.diff.conflict_ours_position or "right"
    local original_revision = ours_position == "right" and ":3" or ":2"
    local modified_revision = ours_position == "right" and ":2" or ":3"
    return revision_source(original_revision, git_root, file_path), revision_source(modified_revision, git_root, file_path)
  end

  if base_revision and target_revision and target_revision ~= "WORKING" then
    if status == "A" or status == "??" then
      return empty_source(), revision_source(target_revision, git_root, file_path)
    end
    if status == "D" then
      return revision_source(base_revision, git_root, old_path or file_path), empty_source()
    end
    return revision_source(base_revision, git_root, old_path or file_path), revision_source(target_revision, git_root, file_path)
  end

  if base_revision then
    if status == "A" or status == "??" then
      return empty_source(), real_source(abs_path)
    end
    if status == "D" then
      return revision_source(base_revision, git_root, old_path or file_path), empty_source()
    end
    return revision_source(base_revision, git_root, old_path or file_path), real_source(abs_path)
  end

  if group == "staged" then
    if status == "A" or status == "??" then
      return empty_source(), revision_source(":0", git_root, file_path)
    end
    if status == "D" then
      return revision_source("HEAD", git_root, old_path or file_path), empty_source()
    end
    return revision_source("HEAD", git_root, old_path or file_path), revision_source(":0", git_root, file_path)
  end

  if status == "A" or status == "??" then
    return empty_source(), real_source(abs_path)
  end
  if status == "D" then
    return revision_source(":0", git_root, old_path or file_path), empty_source()
  end

  local original_revision = has_staged_entry(context.status_result, file_path) and ":0" or "HEAD"
  return revision_source(original_revision, git_root, old_path or file_path), real_source(abs_path)
end

local function editable_path_for_source(source, side, file, context)
  if side ~= "modified" then
    return nil
  end

  if source.kind == "real" then
    return source.path
  end

  if
    source.kind == "revision"
    and source.revision == ":0"
    and context
    and not context.base_revision
    and not context.target_revision
    and file.group == "staged"
    and file.status ~= "D"
    and not has_unstaged_entry(context.status_result, file.path)
  then
    return context.git_root .. "/" .. file.path
  end

  return nil
end

local function load_source(source, errors, callback)
  if source.kind == "empty" then
    callback({})
    return
  end

  if source.kind == "real" then
    local ok, lines = pcall(vim.fn.readfile, source.path)
    if not ok then
      table.insert(errors, string.format("%s: %s", source.path, tostring(lines)))
      callback({})
      return
    end
    callback(lines)
    return
  end

  git.get_file_content(source.revision, source.git_root, source.path, function(err, lines)
    vim.schedule(function()
      if err then
        table.insert(errors, string.format("%s:%s: %s", source.revision, source.path, err))
        callback({})
        return
      end
      callback(lines or {})
    end)
  end)
end

local function load_file(file, context, errors, callback)
  local original_source, modified_source = build_sources(file, context)
  local result = {
    file = file,
    original_source = original_source,
    modified_source = modified_source,
    original_edit_path = editable_path_for_source(original_source, "original", file, context),
    modified_edit_path = editable_path_for_source(modified_source, "modified", file, context),
    original_lines = nil,
    modified_lines = nil,
  }

  local pending = 2
  local function finish()
    pending = pending - 1
    if pending == 0 then
      callback(result)
    end
  end

  load_source(original_source, errors, function(lines)
    result.original_lines = lines
    finish()
  end)

  load_source(modified_source, errors, function(lines)
    result.modified_lines = lines
    finish()
  end)
end

local function load_files(files, context, callback)
  local results = {}
  local errors = {}
  local index = 1

  local function step()
    if index > #files then
      callback(results, errors)
      return
    end

    local current = index
    load_file(files[current], context, errors, function(result)
      results[current] = result
      index = index + 1
      step()
    end)
  end

  step()
end

local function side_path(file, side)
  if side == "original" and (file.status == "A" or file.status == "??") then
    return "/dev/null"
  end
  if side == "modified" and file.status == "D" then
    return "/dev/null"
  end
  if side == "original" then
    return file.old_path or file.path
  end
  return file.path
end

local function treesitter_language_for_path(path)
  if not path or path == "/dev/null" then
    return nil
  end

  local filetype = vim.filetype.match({ filename = path })
  if not filetype or filetype == "" then
    return nil
  end

  if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
    local ok, language = pcall(vim.treesitter.language.get_lang, filetype)
    if ok and language and language ~= "" then
      return language
    end
  end

  return filetype
end

local function header_virtual_lines(file, side, first)
  local prefix = side == "original" and "---" or "+++"
  local label = string.format("[%s:%s]", file.group or "unstaged", file.status or "?")
  local lines = {}
  if not first then
    table.insert(lines, { { "", "Normal" } })
  end
  table.insert(lines, { { string.rep("=", HEADER_WIDTH), "Title" } })
  table.insert(lines, { { string.format("%s %s %s", prefix, side_path(file, side), label), "Comment" } })
  table.insert(lines, { { string.rep("-", HEADER_WIDTH), "Title" } })
  return lines
end

local function header_anchor(line_count_before, content_start, content_count)
  if content_count > 0 then
    return content_start, true
  end

  if line_count_before > 0 then
    return line_count_before, false
  end

  return 1, true
end

local function shift_range(range, offset)
  local shifted = {}
  for key, value in pairs(range or {}) do
    if key == "start_line" or key == "end_line" then
      shifted[key] = value + offset
    else
      shifted[key] = value
    end
  end
  return shifted
end

local function shift_mapping(mapping, original_offset, modified_offset)
  local shifted = {
    original = shift_range(mapping.original, original_offset),
    modified = shift_range(mapping.modified, modified_offset),
    inner_changes = {},
  }

  for _, inner in ipairs(mapping.inner_changes or {}) do
    table.insert(shifted.inner_changes, {
      original = shift_range(inner.original, original_offset),
      modified = shift_range(inner.modified, modified_offset),
    })
  end

  return shifted
end

local function shift_move(move, original_offset, modified_offset)
  return {
    original = shift_range(move.original, original_offset),
    modified = shift_range(move.modified, modified_offset),
  }
end

local function render_headers(bufnr, sections, side)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, section in ipairs(sections) do
    local start_line = side == "original" and section.original_header_start or section.modified_header_start
    local above = side == "original" and section.original_header_above or section.modified_header_above
    local virt_lines = side == "original" and section.original_header_lines or section.modified_header_lines
    local row = math.max(math.min((start_line or 1) - 1, line_count - 1), 0)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_review, row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = above ~= false,
      virt_lines_leftcol = true,
      priority = config.options.diff.highlight_priority,
    })
  end
end

local function apply_section_syntax(bufnr, start_line, lines, language)
  if not language or not lines or #lines == 0 then
    return
  end

  local ok, syntax_hls = pcall(inline.compute_syntax_highlights, lines, language)
  if not ok or not syntax_hls then
    return
  end

  for line_num, line_hls in pairs(syntax_hls) do
    if line_num >= 1 and line_num <= #lines then
      local target_line = start_line + line_num - 2
      local line_text = lines[line_num] or ""

      for _, range in ipairs(line_hls) do
        if range.hl_group then
          local start_col = math.max((range.start_col or 1) - 1, 0)
          local end_col = math.min(range.end_col or start_col, #line_text)

          if end_col > start_col then
            local priority = REVIEW_SYNTAX_PRIORITY
            if range.priority then
              priority = REVIEW_SYNTAX_PRIORITY + range.priority - TREESITTER_PRIORITY
            end
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_review_syntax, target_line, start_col, {
              end_col = end_col,
              hl_group = range.hl_group,
              priority = priority,
              _subpriority = range.order or 0,
              strict = false,
            })
          end
        end
      end
    end
  end
end

local function apply_syntax_highlights(bufnr, syntax_sections, side)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_review_syntax, 0, -1)

  for _, section in ipairs(syntax_sections) do
    if side == "original" then
      apply_section_syntax(bufnr, section.original_content_start, section.original_lines, section.original_language)
    else
      apply_section_syntax(bufnr, section.modified_content_start, section.modified_lines, section.modified_language)
    end
  end
end

local function build_review(results)
  local original_lines = {}
  local modified_lines = {}
  local combined_diff = { changes = {}, moves = {} }
  local sections = {}
  local syntax_sections = {}

  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = config.options.diff.compute_moves,
  }

  for index, result in ipairs(results) do
    local first = index == 1
    local original_offset = #original_lines
    local modified_offset = #modified_lines
    local original_content_count = #(result.original_lines or {})
    local modified_content_count = #(result.modified_lines or {})
    local original_content_start = original_offset + 1
    local modified_content_start = modified_offset + 1
    local original_header_start, original_header_above = header_anchor(original_offset, original_content_start, original_content_count)
    local modified_header_start, modified_header_above = header_anchor(modified_offset, modified_content_start, modified_content_count)

    append_lines(original_lines, result.original_lines)
    append_lines(modified_lines, result.modified_lines)

    table.insert(sections, {
      path = result.file.path,
      old_path = result.file.old_path,
      status = result.file.status,
      group = result.file.group,
      original_source = result.original_source,
      modified_source = result.modified_source,
      original_edit_path = result.original_edit_path,
      modified_edit_path = result.modified_edit_path,
      original_header_start = original_header_start,
      modified_header_start = modified_header_start,
      original_header_above = original_header_above,
      modified_header_above = modified_header_above,
      original_header_lines = header_virtual_lines(result.file, "original", first),
      modified_header_lines = header_virtual_lines(result.file, "modified", first),
      original_content_start = original_content_start,
      modified_content_start = modified_content_start,
      original_content_end = original_content_start + original_content_count,
      modified_content_end = modified_content_start + modified_content_count,
    })

    table.insert(syntax_sections, {
      original_content_start = original_content_start,
      modified_content_start = modified_content_start,
      original_lines = result.original_lines or {},
      modified_lines = result.modified_lines or {},
      original_language = treesitter_language_for_path(side_path(result.file, "original")),
      modified_language = treesitter_language_for_path(side_path(result.file, "modified")),
    })

    local lines_diff = diff_module.compute_diff(result.original_lines or {}, result.modified_lines or {}, diff_options)
    if lines_diff then
      for _, mapping in ipairs(lines_diff.changes or {}) do
        table.insert(combined_diff.changes, shift_mapping(mapping, original_offset, modified_offset))
      end
      for _, move in ipairs(lines_diff.moves or {}) do
        table.insert(combined_diff.moves, shift_move(move, original_offset, modified_offset))
      end
    end
  end

  return original_lines, modified_lines, combined_diff, sections, syntax_sections
end

local function setup_edit_ranges(bufnr, sections, side)
  local entries = {}
  for index, section in ipairs(sections) do
    local edit_path = side == "original" and section.original_edit_path or section.modified_edit_path
    if edit_path then
      local start_line = side == "original" and section.original_content_start or section.modified_content_start
      local end_line = side == "original" and section.original_content_end or section.modified_content_end
      if end_line <= start_line then
        goto continue
      end

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local start_row = math.max(math.min(start_line - 1, line_count - 1), 0)
      local end_row = math.max(math.min(end_line - 1, line_count), start_row)

      table.insert(entries, {
        path = edit_path,
        path_label = section.path,
        section_index = index,
        start_row = start_row,
        end_row = end_row,
        initial_lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false),
      })
    end
    ::continue::
  end

  return entries
end

local function edit_range(_bufnr, entry)
  if not entry or not entry.start_row or not entry.end_row then
    return nil
  end

  return entry.start_row, entry.end_row
end

local function set_edit_range(bufnr, entry, start_row, end_row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  entry.start_row = math.max(math.min(start_row, line_count), 0)
  entry.end_row = math.max(math.min(end_row, line_count), entry.start_row)
end

local function find_entry_at_row(bufnr, entries, row)
  for index, entry in ipairs(entries or {}) do
    local start_row, end_row = edit_range(bufnr, entry)
    if start_row and row >= start_row and row < end_row then
      return entry, index, start_row, end_row
    end
  end
  return nil
end

local function find_entry_ending_at(bufnr, entries, row, skip_entry)
  for _, entry in ipairs(entries or {}) do
    if entry ~= skip_entry then
      local start_row, end_row = edit_range(bufnr, entry)
      if start_row and end_row == row then
        return entry, start_row, end_row
      end
    end
  end
  return nil
end

local function find_entry_starting_at(bufnr, entries, row, skip_entry)
  for _, entry in ipairs(entries or {}) do
    if entry ~= skip_entry then
      local start_row, end_row = edit_range(bufnr, entry)
      if start_row == row then
        return entry, start_row, end_row
      end
    end
  end
  return nil
end

local function leading_whitespace(line)
  return line:match("^%s*") or ""
end

local function insert_review_line(tabpage, bufnr, command)
  local session = lifecycle.get_session(tabpage)
  local entries = session and session.review_write_sections and session.review_write_sections[bufnr] or {}
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local entry, _, start_row, end_row = find_entry_at_row(bufnr, entries, row)

  if not entry then
    vim.notify("CodeDiff review section is not writable", vim.log.levels.WARN)
    return
  end

  local insert_row = command == "O" and row or row + 1
  local previous_entry, previous_start = find_entry_ending_at(bufnr, entries, insert_row, entry)
  local next_entry, _, next_end = find_entry_starting_at(bufnr, entries, insert_row, entry)
  local current_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local line = leading_whitespace(current_line)

  vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { line })
  set_edit_range(bufnr, entry, start_row, end_row + 1)

  if command == "O" and previous_entry and previous_start then
    set_edit_range(bufnr, previous_entry, previous_start, insert_row)
  end

  if command == "o" and next_entry and next_end then
    set_edit_range(bufnr, next_entry, insert_row + 1, next_end + 1)
  end

  vim.api.nvim_win_set_cursor(0, { insert_row + 1, #line })
  vim.cmd("startinsert!")
end

local function setup_boundary_insert_keymaps(tabpage, bufnr)
  for _, key in ipairs({ "o", "O" }) do
    vim.keymap.set("n", key, function()
      insert_review_line(tabpage, bufnr, key)
    end, {
      buffer = bufnr,
      desc = "Insert inside review file section",
      silent = true,
    })
  end
end

local function apply_line_change_to_entry(entry, firstline, lastline, new_lastline)
  local start_row = entry.start_row
  local end_row = entry.end_row
  if not start_row or not end_row then
    return
  end

  local delta = new_lastline - lastline
  local is_insertion = firstline == lastline and delta > 0

  if lastline <= start_row then
    entry.start_row = start_row + delta
    entry.end_row = end_row + delta
    return
  end

  if firstline >= end_row then
    if is_insertion and firstline == end_row then
      entry.end_row = end_row + delta
    end
    return
  end

  if firstline < start_row then
    entry.start_row = firstline
  end
  entry.end_row = math.max(entry.start_row, end_row + delta)
end

local function setup_edit_range_tracking(tabpage, bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, changed_bufnr, _, firstline, lastline, new_lastline)
      local session = lifecycle.get_session(tabpage)
      local entries = session and session.review_write_sections and session.review_write_sections[changed_bufnr]
      if not entries then
        return
      end

      for _, entry in ipairs(entries) do
        apply_line_change_to_entry(entry, firstline, lastline, new_lastline)
      end
    end,
  })
end

local function bufnr_for_path(path)
  local resolved = vim.fn.resolve(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == path or vim.fn.resolve(name) == resolved then
        return buf
      end
    end
  end
  return -1
end

local function write_lines_to_file(path, lines)
  local normalized_path = vim.fn.fnamemodify(path, ":p")
  local target_buf = bufnr_for_path(normalized_path)

  if target_buf ~= -1 and vim.api.nvim_buf_is_loaded(target_buf) then
    if vim.bo[target_buf].modified then
      return false, "target buffer has unsaved changes"
    end

    local modifiable = vim.bo[target_buf].modifiable
    local readonly = vim.bo[target_buf].readonly
    vim.bo[target_buf].modifiable = true
    vim.bo[target_buf].readonly = false

    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
      vim.api.nvim_buf_call(target_buf, function()
        vim.cmd("silent write")
      end)
    end)

    vim.bo[target_buf].modifiable = modifiable
    vim.bo[target_buf].readonly = readonly

    if not ok then
      return false, tostring(err)
    end
    return true
  end

  local ok, result = pcall(vim.fn.writefile, lines, normalized_path)
  if not ok then
    return false, tostring(result)
  end
  if result ~= 0 then
    return false, "writefile returned " .. tostring(result)
  end
  return true
end

local function write_review_buffer(tabpage, bufnr)
  local session = lifecycle.get_session(tabpage)
  local entries = session and session.review_write_sections and session.review_write_sections[bufnr] or {}
  local wrote = 0
  local errors = {}

  for _, entry in ipairs(entries) do
    local start_row, end_row = edit_range(bufnr, entry)
    if start_row then
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
      local last_lines = entry.last_written_lines or entry.initial_lines

      if not same_lines(lines, last_lines) then
        local parent = vim.fn.fnamemodify(entry.path, ":h")
        if parent and parent ~= "" then
          vim.fn.mkdir(parent, "p")
        end

        local ok, err = write_lines_to_file(entry.path, lines)
        if ok then
          wrote = wrote + 1
          entry.last_written_lines = copy_lines(lines)
          entry.initial_lines = copy_lines(lines)
        else
          table.insert(errors, string.format("%s: %s", entry.path_label or entry.path, tostring(err)))
        end
      end
    end
  end

  if #errors > 0 then
    vim.notify("CodeDiff review write failed:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
    return
  end

  vim.bo[bufnr].modified = false
  if wrote > 0 then
    vim.notify(string.format("CodeDiff review wrote %d file%s", wrote, wrote == 1 and "" or "s"), vim.log.levels.INFO)
  end
end

local function setup_writeback(tabpage, bufnr)
  local group = vim.api.nvim_create_augroup("CodeDiffReviewWrite_" .. tabpage .. "_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function(args)
      write_review_buffer(tabpage, args.buf)
    end,
  })
end

local function setup_windows(original_win, modified_win)
  local win_opts = {
    cursorline = true,
    wrap = false,
  }

  for opt, value in pairs(win_opts) do
    vim.wo[original_win][opt] = value
    vim.wo[modified_win][opt] = value
  end
end

local function render_review(tabpage, original_buf, modified_buf, original_win, modified_win, results, errors, on_ready)
  local original_lines, modified_lines, combined_diff, sections, syntax_sections = build_review(results)

  if #original_lines == 0 and #modified_lines == 0 then
    original_lines = { "No changes to review" }
    modified_lines = { "No changes to review" }
    syntax_sections = {}
  end

  set_buffer_lines(original_buf, original_lines)
  set_buffer_lines(modified_buf, modified_lines)

  vim.api.nvim_buf_clear_namespace(original_buf, ns_review, 0, -1)
  vim.api.nvim_buf_clear_namespace(modified_buf, ns_review, 0, -1)

  core.render_diff(original_buf, modified_buf, original_lines, modified_lines, combined_diff)
  render_headers(original_buf, sections, "original")
  render_headers(modified_buf, sections, "modified")
  apply_syntax_highlights(original_buf, syntax_sections, "original")
  apply_syntax_highlights(modified_buf, syntax_sections, "modified")

  lifecycle.update_diff_result(tabpage, combined_diff)
  lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(original_buf), vim.api.nvim_buf_get_changedtick(modified_buf))

  local session = lifecycle.get_session(tabpage)
  if session then
    session.review_sections = sections
    session.review_errors = errors
    session.review_write_sections = {
      [original_buf] = setup_edit_ranges(original_buf, sections, "original"),
      [modified_buf] = setup_edit_ranges(modified_buf, sections, "modified"),
    }
    setup_edit_range_tracking(tabpage, modified_buf)
  end

  local orig_cursor = { 1, 0 }
  local mod_cursor = { 1, 0 }
  if config.options.diff.jump_to_first_change and combined_diff.changes and #combined_diff.changes > 0 then
    orig_cursor = { combined_diff.changes[1].original.start_line, 0 }
    mod_cursor = { combined_diff.changes[1].modified.start_line, 0 }
  end

  render.establish_scrollbind(original_win, modified_win, original_buf, modified_buf, combined_diff, orig_cursor, mod_cursor)
  if vim.api.nvim_win_is_valid(modified_win) then
    vim.api.nvim_set_current_win(modified_win)
    vim.cmd("normal! zz")
  end

  compact.apply_default_and_reapply(tabpage)

  if #errors > 0 then
    vim.notify(string.format("CodeDiff review skipped %d file content load(s)", #errors), vim.log.levels.WARN)
  end

  if on_ready then
    on_ready()
  end
end

---@param session_config SessionConfig
---@param _filetype? string
---@param on_ready? function
---@return table
function M.create(session_config, _filetype, on_ready)
  vim.cmd("tabnew")

  local tabpage = vim.api.nvim_get_current_tabpage()
  local initial_buf = vim.api.nvim_get_current_buf()
  local original_win = vim.api.nvim_get_current_win()
  local split_cmd = config.options.diff.original_position == "right" and "leftabove vsplit" or "rightbelow vsplit"
  vim.cmd(split_cmd)
  local modified_win = vim.api.nvim_get_current_win()

  local original_buf = create_review_buffer("CodeDiff Review [" .. tabpage .. "].original", false)
  local modified_buf = create_review_buffer("CodeDiff Review [" .. tabpage .. "].modified", true)
  vim.api.nvim_win_set_buf(original_win, original_buf)
  vim.api.nvim_win_set_buf(modified_win, modified_buf)
  welcome_window.sync(original_win)
  welcome_window.sync(modified_win)

  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= original_buf and initial_buf ~= modified_buf then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  setup_windows(original_win, modified_win)
  set_buffer_lines(original_buf, { "Loading CodeDiff review..." })
  set_buffer_lines(modified_buf, { "Loading CodeDiff review..." })

  lifecycle.create_session(
    tabpage,
    "review",
    session_config.git_root,
    "",
    "",
    session_config.original_revision,
    session_config.modified_revision,
    original_buf,
    modified_buf,
    original_win,
    modified_win,
    { changes = {}, moves = {} },
    function()
      local ob, mb = lifecycle.get_buffers(tabpage)
      if ob and mb then
        view_keymaps.setup_all_keymaps(tabpage, ob, mb, false)
      end
    end
  )

  setup_writeback(tabpage, modified_buf)
  setup_boundary_insert_keymaps(tabpage, modified_buf)

  local status_result = session_config.review_data and session_config.review_data.status_result or { unstaged = {}, staged = {}, conflicts = {} }
  local files = flatten_status_files(status_result)
  local context = {
    git_root = session_config.git_root,
    base_revision = session_config.original_revision,
    target_revision = session_config.modified_revision,
    status_result = status_result,
  }

  load_files(files, context, function(results, errors)
    if not vim.api.nvim_buf_is_valid(original_buf) or not vim.api.nvim_buf_is_valid(modified_buf) then
      return
    end
    render_review(tabpage, original_buf, modified_buf, original_win, modified_win, results, errors, on_ready)
  end)

  layout.arrange(tabpage)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffOpen",
    modeline = false,
    data = {
      tabpage = tabpage,
      mode = "review",
    },
  })

  return {
    original_buf = original_buf,
    modified_buf = modified_buf,
    original_win = original_win,
    modified_win = modified_win,
  }
end

return M
