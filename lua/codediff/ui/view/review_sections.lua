-- Shared helpers for mapping review buffers back to reviewed file sections.
local M = {}

function M.side_for_win(session, win)
  if not session then
    return nil
  end

  if session.original_win == win then
    return "original"
  end
  if session.modified_win == win then
    return "modified"
  end
  return nil
end

function M.content_line(section, side)
  if side == "original" then
    return section.original_content_start
  end
  return section.modified_content_start
end

function M.window_topline(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 1
  end

  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline or 1
  end)
end

function M.window_cursorline(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 1
  end

  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok or not cursor then
    return 1
  end

  return cursor[1] or 1
end

function M.section_index_at_or_before(sections, side, line)
  if not sections or #sections == 0 then
    return nil
  end

  local low = 1
  local high = #sections
  local result = 1

  while low <= high do
    local mid = math.floor((low + high) / 2)
    local section_line = M.content_line(sections[mid], side) or 1
    if section_line <= line then
      result = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end

  return result
end

function M.section_at_line(session, win, line)
  if not session then
    return nil, nil
  end

  local sections = session.review_sections or {}
  local side = M.side_for_win(session, win)
  if not side or #sections == 0 then
    return nil, nil
  end

  local index = M.section_index_at_or_before(sections, side, line or 1)
  return index, index and sections[index] or nil
end

function M.section_at_topline(session, win)
  return M.section_at_line(session, win, M.window_topline(win))
end

function M.section_at_cursor(session, win)
  return M.section_at_line(session, win, M.window_cursorline(win))
end

function M.find_section_index(session, path, group)
  if not session or not path then
    return nil, nil
  end

  for index, section in ipairs(session.review_sections or {}) do
    if section.path == path and (group == nil or section.group == group) then
      return index, section
    end
  end

  return nil, nil
end

function M.file_data(section)
  if not section then
    return nil
  end

  return {
    path = section.path,
    old_path = section.old_path,
    status = section.status,
    group = section.group,
  }
end

return M
