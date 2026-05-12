-- Navigation module - provides public API for navigating hunks and files
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local review_sections = require("codediff.ui.view.review_sections")

local function clamp_line(bufnr, line)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return math.max(1, math.min(line or 1, line_count))
end

local function set_window_topline(win, line)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  local target = clamp_line(bufnr, line)

  vim.api.nvim_win_call(win, function()
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    local view = vim.fn.winsaveview()
    view.topline = target
    view.topfill = 0
    vim.fn.winrestview(view)
  end)
end

local function reveal_review_section(session, section, focus_win)
  if not section then
    return false
  end

  local original_win = session.original_win
  local modified_win = session.modified_win
  if
    not original_win
    or not modified_win
    or not vim.api.nvim_win_is_valid(original_win)
    or not vim.api.nvim_win_is_valid(modified_win)
  then
    return false
  end

  local original_scrollbind = vim.wo[original_win].scrollbind
  local modified_scrollbind = vim.wo[modified_win].scrollbind
  vim.wo[original_win].scrollbind = false
  vim.wo[modified_win].scrollbind = false

  set_window_topline(original_win, review_sections.content_line(section, "original"))
  set_window_topline(modified_win, review_sections.content_line(section, "modified"))

  vim.wo[original_win].scrollbind = original_scrollbind
  vim.wo[modified_win].scrollbind = modified_scrollbind

  if focus_win and vim.api.nvim_win_is_valid(focus_win) then
    vim.api.nvim_set_current_win(focus_win)
  end

  return true
end

function M.jump_to_review_file(tabpage, file_data, opts)
  opts = opts or {}
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()

  local session = lifecycle.get_session(tabpage)
  if not session or session.mode ~= "review" then
    return false
  end

  local index, section = review_sections.find_section_index(
    session,
    file_data and file_data.path,
    file_data and file_data.group
  )
  if not index or not section then
    return false
  end

  local focus_win = opts.focus_win or vim.api.nvim_get_current_win()
  if not reveal_review_section(session, section, focus_win) then
    return false
  end

  if opts.update_explorer ~= false then
    local explorer = lifecycle.get_explorer(tabpage)
    if explorer and explorer.set_current_selection then
      explorer.set_current_selection(review_sections.file_data(section), { reveal = true })
    end
  end

  vim.api.nvim_echo(
    { { string.format("File %d of %d: %s", index, #(session.review_sections or {}), section.path), "None" } },
    false,
    {}
  )
  return true
end

local function current_review_index(tabpage, session)
  local sections = session.review_sections or {}
  if #sections == 0 then
    return nil
  end

  local current_win = vim.api.nvim_get_current_win()
  local side = review_sections.side_for_win(session, current_win)
  if side then
    return review_sections.section_index_at_or_before(
      sections,
      side,
      review_sections.window_cursorline(current_win)
    )
  end

  local explorer = lifecycle.get_explorer(tabpage)
  if explorer then
    local index = review_sections.find_section_index(
      session,
      explorer.current_file_path,
      explorer.current_file_group
    )
    if index then
      return index
    end
  end

  if session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) then
    return review_sections.section_index_at_or_before(
      sections,
      "modified",
      review_sections.window_cursorline(session.modified_win)
    )
  end

  return 1
end

local function navigate_review_file(tabpage, session, direction)
  local sections = session.review_sections or {}
  if #sections == 0 then
    return false
  end

  local current_index = current_review_index(tabpage, session)
  if not current_index then
    return false
  end

  local next_index = current_index + direction
  if next_index > #sections then
    if not config.options.diff.cycle_next_file then
      vim.api.nvim_echo(
        { { string.format("Last file (%d of %d)", #sections, #sections), "WarningMsg" } },
        false,
        {}
      )
      return false
    end
    next_index = 1
  elseif next_index < 1 then
    if not config.options.diff.cycle_next_file then
      vim.api.nvim_echo(
        { { string.format("First file (1 of %d)", #sections), "WarningMsg" } },
        false,
        {}
      )
      return false
    end
    next_index = #sections
  end

  local section = sections[next_index]
  local current_win = vim.api.nvim_get_current_win()
  if not reveal_review_section(session, section, current_win) then
    return false
  end

  local explorer = lifecycle.get_explorer(tabpage)
  if explorer and explorer.set_current_selection then
    explorer.set_current_selection(review_sections.file_data(section), { reveal = true })
  end

  vim.api.nvim_echo(
    { { string.format("File %d of %d: %s", next_index, #sections, section.path), "None" } },
    false,
    {}
  )
  return true
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local original_bufnr = session.original_bufnr
  local modified_bufnr = session.modified_bufnr
  local is_inline = session.layout == "inline"

  local is_original = current_buf == original_bufnr
  local is_modified = current_buf == modified_bufnr
  local is_result = session.result_bufnr and current_buf == session.result_bufnr

  -- Inline mode: always use modified line numbers
  if is_inline then
    is_original = false
  -- If cursor is in result buffer (conflict mode), use modified side line numbers
  elseif is_result then
    is_original = false
  -- If cursor is not in any diff buffer, switch to modified window
  elseif not is_original and not is_modified then
    is_original = false
    local target_win = session.modified_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    else
      return false
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find next hunk after current line
  for i, mapping in ipairs(diff_result.changes) do
    local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
    if target_line > current_line then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
      vim.cmd("normal! zz")
      vim.api.nvim_echo({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } }, false, {})
      return true
    end
  end

  -- Wrap around to first hunk (if cycling enabled)
  if config.options.diff.cycle_next_hunk then
    local first_hunk = diff_result.changes[1]
    local target_line = is_original and first_hunk.original.start_line or first_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Hunk 1 of %d", #diff_result.changes), "None" } }, false, {})
    return true
  else
    vim.api.nvim_echo({ { string.format("Last hunk (%d of %d)", #diff_result.changes, #diff_result.changes), "WarningMsg" } }, false, {})
    return false
  end
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local original_bufnr = session.original_bufnr
  local modified_bufnr = session.modified_bufnr
  local is_inline = session.layout == "inline"

  local is_original = current_buf == original_bufnr
  local is_modified = current_buf == modified_bufnr
  local is_result = session.result_bufnr and current_buf == session.result_bufnr

  -- Inline mode: always use modified line numbers
  if is_inline then
    is_original = false
  -- If cursor is in result buffer (conflict mode), use modified side line numbers
  elseif is_result then
    is_original = false
  -- If cursor is not in any diff buffer, switch to modified window
  elseif not is_original and not is_modified then
    is_original = false
    local target_win = session.modified_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    else
      return false
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find previous hunk before current line (search backwards)
  for i = #diff_result.changes, 1, -1 do
    local mapping = diff_result.changes[i]
    local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
    if target_line < current_line then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
      vim.cmd("normal! zz")
      vim.api.nvim_echo({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } }, false, {})
      return true
    end
  end

  -- Wrap around to last hunk (if cycling enabled)
  if config.options.diff.cycle_next_hunk then
    local last_hunk = diff_result.changes[#diff_result.changes]
    local target_line = is_original and last_hunk.original.start_line or last_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Hunk %d of %d", #diff_result.changes, #diff_result.changes), "None" } }, false, {})
    return true
  else
    vim.api.nvim_echo({ { string.format("First hunk (1 of %d)", #diff_result.changes), "WarningMsg" } }, false, {})
    return false
  end
end

-- Navigate to next file in explorer/history/review mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  local panel_obj = lifecycle.get_explorer(tabpage)

  if session and session.mode == "review" then
    return navigate_review_file(tabpage, session, 1)
  end

  if not panel_obj then
    return false
  end

  local is_history_mode = session and session.mode == "history"

  if is_history_mode then
    local history = require("codediff.ui.history")
    if panel_obj.is_single_file_mode then
      history.navigate_next_commit(panel_obj)
    else
      history.navigate_next(panel_obj)
    end
  else
    local explorer = require("codediff.ui.explorer")
    explorer.navigate_next(panel_obj)
  end

  return true
end

-- Navigate to previous file in explorer/history/review mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  local panel_obj = lifecycle.get_explorer(tabpage)

  if session and session.mode == "review" then
    return navigate_review_file(tabpage, session, -1)
  end

  if not panel_obj then
    return false
  end

  local is_history_mode = session and session.mode == "history"

  if is_history_mode then
    local history = require("codediff.ui.history")
    if panel_obj.is_single_file_mode then
      history.navigate_prev_commit(panel_obj)
    else
      history.navigate_prev(panel_obj)
    end
  else
    local explorer = require("codediff.ui.explorer")
    explorer.navigate_prev(panel_obj)
  end

  return true
end

return M
