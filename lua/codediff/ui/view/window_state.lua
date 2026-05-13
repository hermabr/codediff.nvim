-- Utilities for preserving diff window state around decoration refreshes.
local M = {}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function unique_valid_windows(wins)
  local result = {}
  local seen = {}

  for _, win in ipairs(wins or {}) do
    if valid_win(win) and not seen[win] then
      seen[win] = true
      table.insert(result, win)
    end
  end

  return result
end

function M.save(wins)
  local state = {
    current_win = vim.api.nvim_get_current_win(),
    order = {},
    by_win = {},
  }

  for _, win in ipairs(unique_valid_windows(wins)) do
    local ok_view, view = pcall(vim.api.nvim_win_call, win, function()
      return vim.fn.winsaveview()
    end)
    local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    local ok_scrollbind, scrollbind = pcall(function()
      return vim.wo[win].scrollbind
    end)

    table.insert(state.order, win)
    state.by_win[win] = {
      view = ok_view and view or nil,
      cursor = ok_cursor and cursor or nil,
      scrollbind = ok_scrollbind and scrollbind or false,
    }
  end

  return state
end

function M.restore(state)
  if not state then
    return
  end

  for _, win in ipairs(state.order or {}) do
    if valid_win(win) then
      vim.wo[win].scrollbind = false
    end
  end

  for _, win in ipairs(state.order or {}) do
    local entry = state.by_win and state.by_win[win]
    if entry and valid_win(win) then
      if entry.view then
        pcall(vim.api.nvim_win_call, win, function()
          vim.fn.winrestview(entry.view)
        end)
      end
      if entry.cursor then
        pcall(vim.api.nvim_win_set_cursor, win, entry.cursor)
      end
    end
  end

  for _, win in ipairs(state.order or {}) do
    local entry = state.by_win and state.by_win[win]
    if entry and valid_win(win) then
      vim.wo[win].scrollbind = entry.scrollbind
    end
  end

  if valid_win(state.current_win) then
    pcall(vim.api.nvim_set_current_win, state.current_win)
  end
end

function M.with_scrollbind_disabled(wins, fn)
  local saved = {}

  for _, win in ipairs(unique_valid_windows(wins)) do
    saved[win] = vim.wo[win].scrollbind
    vim.wo[win].scrollbind = false
  end

  local ok, err = pcall(fn)

  for win, scrollbind in pairs(saved) do
    if valid_win(win) then
      vim.wo[win].scrollbind = scrollbind
    end
  end

  if not ok then
    error(err, 0)
  end
end

return M
