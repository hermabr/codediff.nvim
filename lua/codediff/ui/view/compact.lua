-- Compact mode: fold unchanged regions, showing only hunks + context lines
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

-- Module-level state: maps window ID → set of visible line numbers
local visible_lines_by_win = {}

--- Called by Neovim for each line when foldmethod=expr
--- @return string fold level: "0" for visible lines, "1" for foldable
function M.foldexpr_eval()
  local visible = visible_lines_by_win[vim.api.nvim_get_current_win()]
  if not visible then
    return "0"
  end
  return visible[vim.v.lnum] and "0" or "1"
end

--- Compute set of line numbers that should remain visible (near hunks)
--- @param changes table[] array of hunk mappings with original/modified ranges
--- @param side string "original" or "modified"
--- @param line_count number total lines in buffer
--- @param context_lines number lines of context around each hunk
--- @return table<number, boolean> set of 1-indexed visible line numbers
function M.compute_visible_lines(changes, side, line_count, context_lines)
  local visible = {}
  for _, change in ipairs(changes) do
    local range = change[side]
    local range_start = range.start_line
    local range_end = range.end_line -- exclusive

    -- For zero-width ranges (pure insertion/deletion), use start_line as anchor
    if range_start == range_end then
      range_end = range_start + 1
    end

    local ctx_start = math.max(1, range_start - context_lines)
    local ctx_end = math.min(line_count, range_end - 1 + context_lines)
    for l = ctx_start, ctx_end do
      visible[l] = true
    end
  end
  return visible
end

local function add_review_header_lines(visible, session, side)
  if not session or session.mode ~= "review" then
    return
  end

  local header_key = side == "original" and "original_header_start" or "modified_header_start"
  local content_key = side == "original" and "original_content_start" or "modified_content_start"

  for _, section in ipairs(session.review_sections or {}) do
    local header_start = section[header_key]
    local content_start = section[content_key]
    if header_start then
      visible[header_start] = true
    end
    if content_start then
      visible[content_start] = true
    end
  end
end

local function compute_visible_lines_for_session(session, side, line_count, context_lines)
  local changes = session.stored_diff_result and session.stored_diff_result.changes or {}
  local visible = M.compute_visible_lines(changes, side, line_count, context_lines)
  add_review_header_lines(visible, session, side)
  return visible
end

local function compact_entries(session)
  local entries = {}
  if session.layout == "inline" then
    table.insert(entries, { win = session.modified_win, buf = session.modified_bufnr, side = "modified" })
  else
    table.insert(entries, { win = session.original_win, buf = session.original_bufnr, side = "original" })
    table.insert(entries, { win = session.modified_win, buf = session.modified_bufnr, side = "modified" })
  end
  return entries
end

local function has_conflict_result(session)
  return session.result_win and vim.api.nvim_win_is_valid(session.result_win)
end

--- Enable compact mode for a tabpage
--- @param tabpage number
--- @return boolean success
function M.enable(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end
  if session.compact_mode then
    return true
  end
  if has_conflict_result(session) then
    vim.notify("Cannot enable compact mode in conflict mode", vim.log.levels.WARN)
    return false
  end

  local changes = session.stored_diff_result.changes
  if not changes or #changes == 0 then
    vim.notify("No changes to compact", vim.log.levels.INFO)
    return false
  end

  local context = config.options.diff.compact_context_lines

  session.compact_saved_fold_state = {}

  for _, entry in ipairs(compact_entries(session)) do
    if entry.win and vim.api.nvim_win_is_valid(entry.win) then
      -- Save current fold state
      session.compact_saved_fold_state[entry.win] = {
        foldmethod = vim.wo[entry.win].foldmethod,
        foldexpr = vim.wo[entry.win].foldexpr,
        foldlevel = vim.wo[entry.win].foldlevel,
        foldminlines = vim.wo[entry.win].foldminlines,
        foldenable = vim.wo[entry.win].foldenable,
        foldtext = vim.wo[entry.win].foldtext,
      }

      -- Compute visible lines
      local line_count = vim.api.nvim_buf_line_count(entry.buf)
      visible_lines_by_win[entry.win] = compute_visible_lines_for_session(session, entry.side, line_count, context)

      -- Apply fold settings
      vim.wo[entry.win].foldmethod = "expr"
      vim.wo[entry.win].foldexpr = "v:lua.require'codediff.ui.view.compact'.foldexpr_eval()"
      vim.wo[entry.win].foldenable = true
      vim.wo[entry.win].foldlevel = 0
      vim.wo[entry.win].foldminlines = 1
    end
  end

  session.compact_mode = true
  return true
end

--- Disable compact mode for a tabpage
--- @param tabpage number
--- @return boolean success
function M.disable(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.compact_mode then
    return false
  end

  local saved = session.compact_saved_fold_state or {}
  for win, fold_state in pairs(saved) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].foldmethod = fold_state.foldmethod
      vim.wo[win].foldexpr = fold_state.foldexpr
      vim.wo[win].foldlevel = fold_state.foldlevel
      vim.wo[win].foldminlines = fold_state.foldminlines
      vim.wo[win].foldenable = fold_state.foldenable
      vim.wo[win].foldtext = fold_state.foldtext
    end
    visible_lines_by_win[win] = nil
  end

  session.compact_saved_fold_state = nil
  session.compact_mode = false
  return true
end

--- Toggle compact mode
--- @param tabpage? number defaults to current tabpage
--- @return boolean success
function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if session.compact_mode then
    return M.disable(tabpage)
  else
    return M.enable(tabpage)
  end
end

--- Re-apply compact mode fold settings to current windows.
--- Called after file switches or re-renders where window buffers change
--- but session.compact_mode should persist.
--- @param tabpage number
function M.reapply(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.compact_mode then
    return
  end
  if not session.stored_diff_result then
    return
  end

  local changes = session.stored_diff_result.changes
  if not changes or #changes == 0 then
    return
  end

  local context = config.options.diff.compact_context_lines

  for _, entry in ipairs(compact_entries(session)) do
    if entry.win and vim.api.nvim_win_is_valid(entry.win) then
      local line_count = vim.api.nvim_buf_line_count(entry.buf)
      visible_lines_by_win[entry.win] = compute_visible_lines_for_session(session, entry.side, line_count, context)

      vim.wo[entry.win].foldmethod = "expr"
      vim.wo[entry.win].foldexpr = "v:lua.require'codediff.ui.view.compact'.foldexpr_eval()"
      vim.wo[entry.win].foldenable = true
      vim.wo[entry.win].foldlevel = 0
      vim.wo[entry.win].foldminlines = 1
    end
  end
end

--- Refresh compact mode after diff recomputation.
--- Re-applies fold settings and forces fold re-evaluation.
--- @param tabpage number
function M.refresh(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.compact_mode then
    return
  end

  local changes = session.stored_diff_result and session.stored_diff_result.changes
  if not changes or #changes == 0 then
    M.disable(tabpage)
    return
  end

  M.reapply(tabpage)
end

--- Enable default compact mode for a tabpage if configured.
--- @param tabpage number
--- @return boolean enabled true when this call enabled compact mode
function M.apply_default(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not config.options.diff.compact or session.compact_default_applied or session.compact_mode then
    return false
  end

  local changes = session.stored_diff_result and session.stored_diff_result.changes
  if not changes or #changes == 0 or has_conflict_result(session) then
    return false
  end

  if M.enable(tabpage) then
    session.compact_default_applied = true
    return true
  end

  return false
end

--- Apply default compact mode if needed, then refresh active compact folds.
--- @param tabpage number
function M.apply_default_and_reapply(tabpage)
  M.apply_default(tabpage)
  M.reapply(tabpage)
end

return M
