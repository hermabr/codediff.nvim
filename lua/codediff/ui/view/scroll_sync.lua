-- Visual scroll synchronization for side-by-side windows that use virtual
-- lines and folds. Native scrollbind tracks buffer line numbers, while this
-- maps by rendered screen rows.
local M = {}

local states = {}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function text_height(win, opts)
  if not vim.api.nvim_win_text_height then
    return nil
  end

  local ok, result = pcall(vim.api.nvim_win_text_height, win, opts)
  if ok and result then
    return result
  end
  return nil
end

local function row_text_height(win, row)
  return text_height(win, { start_row = row, end_row = row })
end

local function visual_rows_through(win, row)
  local result = text_height(win, { start_row = 0, end_row = row })
  return result and result.all or row + 1
end

local function content_height(row_height)
  if not row_height then
    return 1
  end
  return math.max(1, (row_height.all or 1) - (row_height.fill or 0))
end

local function visual_rows_before(win, row)
  if row <= 0 then
    return 0
  end

  local through = text_height(win, { start_row = 0, end_row = row })
  local current = row_text_height(win, row)
  if not through then
    return row
  end

  return math.max(0, through.all - content_height(current))
end

local function visual_offset(win)
  return vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local row = math.max((view.topline or 1) - 1, 0)
    return math.max(0, visual_rows_before(win, row) - (view.topfill or 0))
  end)
end

local function position_for_visual_offset(win, offset)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 1 then
    return 1, 0
  end

  offset = math.max(0, math.floor(offset or 0))

  local low = 0
  local high = line_count - 1
  local row = line_count - 1

  while low <= high do
    local mid = math.floor((low + high) / 2)
    if visual_rows_through(win, mid) > offset then
      row = mid
      high = mid - 1
    else
      low = mid + 1
    end
  end

  local through = text_height(win, { start_row = 0, end_row = row })
  local current = row_text_height(win, row)
  if not through then
    return row + 1, 0
  end

  local before = math.max(0, through.all - content_height(current))
  local fill = current and current.fill or 0
  local topfill = math.max(0, math.min(fill, before - offset))
  return row + 1, topfill
end

local function restore_visual_offset(win, offset)
  local topline, topfill = position_for_visual_offset(win, offset)

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    if view.topline == topline and (view.topfill or 0) == topfill then
      return
    end
    view.topline = topline
    view.topfill = topfill
    vim.fn.winrestview(view)
  end)
end

local function session_for_pair(source_win, target_win)
  local lifecycle = require("codediff.ui.lifecycle")

  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local session = lifecycle.get_session(tabpage)
    if session then
      local is_pair = (session.original_win == source_win and session.modified_win == target_win)
        or (session.modified_win == source_win and session.original_win == target_win)
      if is_pair then
        return session
      end
    end
  end

  return nil
end

local function side_for_win(session, win)
  if session.original_win == win then
    return "original"
  end
  if session.modified_win == win then
    return "modified"
  end
  return nil
end

local function section_content_line(section, side)
  if side == "original" then
    return section.original_content_start
  end
  return section.modified_content_start
end

local function screen_row(win, line)
  if not line or line < 1 then
    return nil
  end

  local ok, pos = pcall(vim.fn.screenpos, win, line, 1)
  if not ok or not pos or (pos.row or 0) <= 0 then
    return nil
  end
  return pos.row
end

local function window_topline(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline or 1
  end)
end

local function section_at_or_before(sections, side, line)
  local low = 1
  local high = #sections
  local result = 1

  while low <= high do
    local mid = math.floor((low + high) / 2)
    local section_line = section_content_line(sections[mid], side) or 1
    if section_line <= line then
      result = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end

  return result
end

local function first_visible_section(session, win, side)
  local sections = session.review_sections or {}
  local topline = window_topline(win)
  local start = section_at_or_before(sections, side, topline)

  for index = start, #sections do
    local section = sections[index]
    local line = section_content_line(section, side)
    local row = screen_row(win, line)
    if row then
      return section, row
    end

    if line and line > topline then
      break
    end
  end

  return nil, nil
end

local function align_visible_review_boundary(source_win, target_win)
  local session = session_for_pair(source_win, target_win)
  if not session or session.mode ~= "review" then
    return
  end

  local source_side = side_for_win(session, source_win)
  local target_side = side_for_win(session, target_win)
  if not source_side or not target_side then
    return
  end

  local section, source_row = first_visible_section(session, source_win, source_side)
  if not section or not source_row then
    return
  end

  local target_row = screen_row(target_win, section_content_line(section, target_side))
  if not target_row then
    return
  end

  local delta = target_row - source_row
  if delta ~= 0 then
    restore_visual_offset(target_win, visual_offset(target_win) + delta)
  end
end

local function changed(event, win)
  local entry = event and event[tostring(win)]
  return entry and ((entry.topline or 0) ~= 0 or (entry.topfill or 0) ~= 0 or (entry.height or 0) ~= 0)
end

local function source_from_event(session)
  local current = vim.api.nvim_get_current_win()
  local original_changed = changed(vim.v.event, session.original_win)
  local modified_changed = changed(vim.v.event, session.modified_win)

  if current == session.original_win and original_changed then
    return session.original_win, session.modified_win
  end
  if current == session.modified_win and modified_changed then
    return session.modified_win, session.original_win
  end
  if original_changed and not modified_changed then
    return session.original_win, session.modified_win
  end
  if modified_changed and not original_changed then
    return session.modified_win, session.original_win
  end

  return nil, nil
end

function M.sync_pair(source_win, target_win)
  if not valid_win(source_win) or not valid_win(target_win) then
    return
  end

  restore_visual_offset(target_win, visual_offset(source_win))
  align_visible_review_boundary(source_win, target_win)
end

function M.enable(tabpage)
  if not vim.api.nvim_win_text_height then
    return
  end

  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  if
    not session
    or session.layout == "inline"
    or not valid_win(session.original_win)
    or not valid_win(session.modified_win)
  then
    return
  end

  M.disable(tabpage)

  vim.wo[session.original_win].scrollbind = false
  vim.wo[session.modified_win].scrollbind = false

  local state = {
    ignore_win = nil,
    augroup = vim.api.nvim_create_augroup("CodeDiffVisualScrollSync_" .. tabpage, { clear = true }),
  }
  states[tabpage] = state

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = state.augroup,
    callback = function()
      local active = states[tabpage]
      if not active then
        return
      end

      local current_session = lifecycle.get_session(tabpage)
      if not current_session or not current_session.compact_mode then
        return
      end

      local source_win, target_win = source_from_event(current_session)
      if not source_win or not target_win then
        return
      end

      if active.ignore_win == source_win then
        active.ignore_win = nil
        return
      end

      active.ignore_win = target_win
      M.sync_pair(source_win, target_win)
      vim.schedule(function()
        if states[tabpage] == active and active.ignore_win == target_win then
          active.ignore_win = nil
        end
      end)
    end,
  })
end

function M.disable(tabpage)
  local state = states[tabpage]
  if not state then
    return
  end

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  states[tabpage] = nil
end

return M
