-- Helpers for preserving user viewport state while diff decorations are
-- refreshed. Rendering clears and recreates virtual lines, which can move
-- topline/topfill even when buffer text is unchanged.
local M = {}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(value or min_value, max_value))
end

local function window_view(win)
  local ok, view = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.winsaveview()
  end)
  if ok then
    return view
  end
  return nil
end

local function restore_window_view(win, view)
  if not valid_win(win) or not view then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local restored = vim.deepcopy(view)
  restored.lnum = clamp(restored.lnum, 1, line_count)
  restored.topline = clamp(restored.topline, 1, line_count)
  local line = vim.api.nvim_buf_get_lines(bufnr, restored.lnum - 1, restored.lnum, false)[1] or ""
  restored.col = clamp(restored.col, 0, #line)
  if restored.curswant and restored.curswant >= 0 then
    restored.curswant = clamp(restored.curswant, 0, #line)
  end

  pcall(vim.api.nvim_win_call, win, function()
    vim.fn.winrestview(restored)
  end)
end

local function set_scrollbind(snapshot, value)
  if not snapshot then
    return
  end

  for _, win in ipairs(snapshot.order) do
    if valid_win(win) then
      pcall(function()
        vim.wo[win].scrollbind = value
      end)
    end
  end
end

---Capture view state for a set of windows.
---@param windows integer[]
---@return table
function M.capture(windows)
  local snapshot = {
    current_win = vim.api.nvim_get_current_win(),
    order = {},
    windows = {},
  }

  local seen = {}
  for _, win in ipairs(windows or {}) do
    if valid_win(win) and not seen[win] then
      seen[win] = true
      local view = window_view(win)
      if view then
        table.insert(snapshot.order, win)
        snapshot.windows[win] = {
          view = view,
          scrollbind = vim.wo[win].scrollbind,
        }
      end
    end
  end

  return snapshot
end

---Restore captured views and optionally align a paired side by visual rows.
---@param snapshot table
---@param opts? { sync_source?: integer, sync_target?: integer }
function M.restore(snapshot, opts)
  if not snapshot then
    return
  end

  opts = opts or {}

  -- Prevent native scrollbind from propagating the intermediate restores.
  set_scrollbind(snapshot, false)

  for _, win in ipairs(snapshot.order) do
    local entry = snapshot.windows[win]
    restore_window_view(win, entry and entry.view)
  end

  if valid_win(opts.sync_source) and valid_win(opts.sync_target) then
    local ok, scroll_sync = pcall(require, "codediff.ui.view.scroll_sync")
    if ok and scroll_sync then
      scroll_sync.sync_pair(opts.sync_source, opts.sync_target)
    end
  end

  for _, win in ipairs(snapshot.order) do
    local entry = snapshot.windows[win]
    if entry and valid_win(win) then
      pcall(function()
        vim.wo[win].scrollbind = entry.scrollbind
      end)
    end
  end

  if valid_win(snapshot.current_win) then
    pcall(vim.api.nvim_set_current_win, snapshot.current_win)
  end
end

---Restore a side-by-side pair without moving the active side, then align the
---other side to the same visual row offset so virtual lines remain synchronized.
---@param snapshot table
---@param original_win integer?
---@param modified_win integer?
function M.restore_pair(snapshot, original_win, modified_win)
  local source_win = nil
  local target_win = nil
  local current_win = snapshot and snapshot.current_win or nil

  if current_win == original_win then
    source_win = original_win
    target_win = modified_win
  elseif current_win == modified_win then
    source_win = modified_win
    target_win = original_win
  elseif valid_win(modified_win) then
    source_win = modified_win
    target_win = original_win
  elseif valid_win(original_win) then
    source_win = original_win
    target_win = modified_win
  end

  M.restore(snapshot, {
    sync_source = source_win,
    sync_target = target_win,
  })
end

return M
