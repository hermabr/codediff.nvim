-- Auto-refresh mechanism for diff views
-- Watches buffer changes (internal and external) and triggers diff recomputation
local M = {}

local diff = require("codediff.core.diff")
local core = require("codediff.ui.core")
local scroll_sync = require("codediff.ui.view.scroll_sync")
local window_state = require("codediff.ui.view.window_state")

-- Throttle delay in milliseconds
local THROTTLE_DELAY_MS = 200

-- Track watched buffers for auto-refresh
-- Structure: { bufnr = { timer = number?, dirty = boolean } }
-- Buffer pair info is retrieved from lifecycle
local watched_buffers = {}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_insert_like_mode()
  local mode = vim.api.nvim_get_mode().mode
  local prefix = mode:sub(1, 1)
  return prefix == "i" or prefix == "R" or mode:match("^ni") ~= nil
end

local function should_defer_refresh(bufnr)
  return vim.api.nvim_get_current_buf() == bufnr and is_insert_like_mode()
end

local function session_windows(session)
  if not session then
    return {}
  end

  return {
    session.original_win,
    session.modified_win,
    session.result_win,
  }
end

local function buffer_windows(bufnr)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      table.insert(wins, win)
    end
  end
  return wins
end

local function sync_peer_scroll(session)
  if
    not session
    or session.layout == "inline"
    or not valid_win(session.original_win)
    or not valid_win(session.modified_win)
  then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  if current_win == session.original_win then
    scroll_sync.sync_pair_without_scrollbind(session.original_win, session.modified_win)
  elseif current_win == session.modified_win then
    scroll_sync.sync_pair_without_scrollbind(session.modified_win, session.original_win)
  end
end

local function render_with_preserved_state(session, render_fn)
  local saved = window_state.save(session_windows(session))
  local ok, err = pcall(render_fn)
  window_state.restore(saved)

  if not ok then
    error(err, 0)
  end

  sync_peer_scroll(session)
end

-- Cancel pending timer for a buffer
local function cancel_timer(bufnr)
  local watcher = watched_buffers[bufnr]
  if watcher and watcher.timer then
    vim.fn.timer_stop(watcher.timer)
    watcher.timer = nil
  end
end

-- Perform diff computation and update decorations
-- @param bufnr number: Buffer to update
-- @param skip_watcher_check boolean: If true, don't require buffer to be in watched_buffers
local function do_diff_update(bufnr, skip_watcher_check)
  local watcher = watched_buffers[bufnr]

  -- Check if buffer is being watched (unless skipped for manual trigger)
  if not skip_watcher_check and not watcher then
    return
  end

  -- Clear timer reference if watcher exists
  if watcher then
    watcher.timer = nil
  end

  -- Validate buffers still exist
  if not vim.api.nvim_buf_is_valid(bufnr) then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  -- Get buffer pair from lifecycle
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = lifecycle.find_tabpage_by_buffer(bufnr)
  if not tabpage then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  local original_bufnr, modified_bufnr = lifecycle.get_buffers(tabpage)
  if not original_bufnr or not modified_bufnr then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  if not vim.api.nvim_buf_is_valid(original_bufnr) or not vim.api.nvim_buf_is_valid(modified_bufnr) then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  local session = lifecycle.get_session(tabpage)
  if session and session.mode == "review" then
    vim.schedule(function()
      local ok, review = pcall(require, "codediff.ui.view.review")
      if ok and review then
        render_with_preserved_state(lifecycle.get_session(tabpage), function()
          review.refresh(tabpage)
        end)
      end
    end)
    return
  end

  -- Get fresh buffer content
  local original_lines = vim.api.nvim_buf_get_lines(original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(modified_bufnr, 0, -1, false)

  -- Async diff computation
  vim.schedule(function()
    -- Double-check buffer validity after schedule
    if not vim.api.nvim_buf_is_valid(original_bufnr) or not vim.api.nvim_buf_is_valid(modified_bufnr) then
      if watched_buffers[bufnr] then
        watched_buffers[bufnr] = nil
      end
      return
    end

    -- Compute diff
    local config = require("codediff.config")
    local diff_options = {
      max_computation_time_ms = config.options.diff.max_computation_time_ms,
      ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
      compute_moves = config.options.diff.compute_moves,
    }
    local lines_diff = diff.compute_diff(original_lines, modified_lines, diff_options)
    if not lines_diff then
      return
    end

    local session = lifecycle.get_session(tabpage)
    render_with_preserved_state(session, function()
      -- Update stored diff result in lifecycle (critical for hunk navigation and do/dp)
      lifecycle.update_diff_result(tabpage, lines_diff)
      lifecycle.update_changedtick(
        tabpage,
        vim.api.nvim_buf_get_changedtick(original_bufnr),
        vim.api.nvim_buf_get_changedtick(modified_bufnr)
      )
      local state = require("codediff.ui.lifecycle.state")
      lifecycle.update_mtime(tabpage, state.get_file_mtime(original_bufnr), state.get_file_mtime(modified_bufnr))

      -- Refresh compact mode folds if active
      require("codediff.ui.view.compact").refresh(tabpage)

      if session and session.layout == "inline" then
        local inline_mod = require("codediff.ui.inline")
        inline_mod.render_inline_diff(modified_bufnr, lines_diff, original_lines, modified_lines)
      else
        core.render_diff(original_bufnr, modified_bufnr, original_lines, modified_lines, lines_diff)
      end
    end)
  end)
end

-- Trigger diff update with throttling
local function trigger_diff_update(bufnr, opts)
  opts = opts or {}
  local watcher = watched_buffers[bufnr]
  if not watcher then
    return
  end

  if not opts.force and should_defer_refresh(bufnr) then
    cancel_timer(bufnr)
    watcher.dirty = true
    return
  end

  watcher.dirty = false

  -- Cancel existing timer
  cancel_timer(bufnr)

  -- Start new timer
  watcher.timer = vim.fn.timer_start(THROTTLE_DELAY_MS, function()
    local current = watched_buffers[bufnr]
    if current and should_defer_refresh(bufnr) then
      current.timer = nil
      current.dirty = true
      return
    end
    do_diff_update(bufnr)
  end)
end

-- Setup auto-refresh for a buffer
-- @param bufnr number: Buffer to watch for changes
-- Note: Buffer pair info is retrieved from lifecycle when needed
function M.enable(bufnr)
  -- Store watcher info for throttling and insert-mode coalescing
  watched_buffers[bufnr] = {
    timer = nil,
    dirty = false,
  }

  -- Setup autocmds for this buffer
  local buf_augroup = vim.api.nvim_create_augroup("codediff_auto_refresh_" .. bufnr, { clear = true })

  -- Internal changes (user editing)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_diff_update(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      local watcher = watched_buffers[bufnr]
      if watcher and watcher.dirty then
        trigger_diff_update(bufnr, { force = true })
      end
    end,
  })

  -- External changes (file modified on disk)
  vim.api.nvim_create_autocmd({ "FileChangedShellPost", "FocusGained" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_diff_update(bufnr)
    end,
  })

  -- Cleanup on buffer delete/wipe
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })
end

-- Disable auto-refresh for a buffer
function M.disable(bufnr)
  cancel_timer(bufnr)
  watched_buffers[bufnr] = nil

  -- Clear autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_auto_refresh_" .. bufnr)
end

-- Track result buffer refresh state only (base_lines stored in lifecycle)
local result_watchers = {}

local function cancel_result_timer(bufnr)
  local watcher = result_watchers[bufnr]
  if watcher and watcher.timer then
    vim.fn.timer_stop(watcher.timer)
    watcher.timer = nil
  end
end

-- Perform diff update for result buffer against BASE
local function do_result_diff_update(bufnr)
  -- Clear timer reference
  if result_watchers[bufnr] then
    result_watchers[bufnr].timer = nil
  end

  -- Validate buffer still exists
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Get base_lines from lifecycle
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = lifecycle.find_tabpage_by_buffer(bufnr)
  if not tabpage then
    return
  end

  local base_lines = lifecycle.get_result_base_lines(tabpage)
  if not base_lines then
    return
  end

  -- Get current result buffer content
  local result_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Compute diff: BASE vs result (result shows what was added/changed from BASE)
  local config = require("codediff.config")
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = config.options.diff.compute_moves,
  }
  local lines_diff = diff.compute_diff(base_lines, result_lines, diff_options)
  if not lines_diff then
    return
  end

  local saved = window_state.save(buffer_windows(bufnr))
  local ok, err = pcall(function()
    -- Render highlights on result buffer only (modified side = insertions shown as green)
    core.render_single_buffer(bufnr, lines_diff, "modified")
  end)
  window_state.restore(saved)

  if not ok then
    error(err, 0)
  end
end

-- Trigger throttled diff update for result buffer
local function trigger_result_diff_update(bufnr, opts)
  opts = opts or {}
  local watcher = result_watchers[bufnr]
  if not watcher then
    return
  end

  if not opts.force and should_defer_refresh(bufnr) then
    cancel_result_timer(bufnr)
    watcher.dirty = true
    return
  end

  watcher.dirty = false
  cancel_result_timer(bufnr)

  -- Start new throttled timer
  watcher.timer = vim.fn.timer_start(THROTTLE_DELAY_MS, function()
    vim.schedule(function()
      local current = result_watchers[bufnr]
      if not current then
        return
      end
      if should_defer_refresh(bufnr) then
        current.timer = nil
        current.dirty = true
        return
      end
      do_result_diff_update(bufnr)
    end)
  end)
end

-- Enable auto-refresh for result buffer (diffs against BASE stored in lifecycle)
function M.enable_for_result(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Disable if already enabled
  M.disable_result(bufnr)

  result_watchers[bufnr] = {
    timer = nil,
    dirty = false,
  }

  -- Setup autocmds for this buffer
  local buf_augroup = vim.api.nvim_create_augroup("codediff_result_refresh_" .. bufnr, { clear = true })

  -- Internal changes (user editing)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_result_diff_update(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      local watcher = result_watchers[bufnr]
      if watcher and watcher.dirty then
        trigger_result_diff_update(bufnr, { force = true })
      end
    end,
  })

  -- Cleanup on buffer delete/wipe
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      M.disable_result(bufnr)
    end,
  })

  -- Initial render
  vim.schedule(function()
    do_result_diff_update(bufnr)
  end)
end

-- Disable auto-refresh for result buffer
function M.disable_result(bufnr)
  cancel_result_timer(bufnr)
  result_watchers[bufnr] = nil

  -- Clear autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_result_refresh_" .. bufnr)
end

-- Immediately refresh result buffer diff (call after programmatic changes)
function M.refresh_result_now(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Cancel pending timer if any
  cancel_result_timer(bufnr)
  if result_watchers[bufnr] then
    result_watchers[bufnr].dirty = false
  end
  do_result_diff_update(bufnr)
end

-- Sync mutable revision buffers (:0-:3) with current git index content.
-- Called when .git directory changes. Only writes if content actually changed,
-- which triggers TextChanged → auto_refresh recomputes diff automatically.
-- @param tabpage number: Tabpage whose session buffers to sync
function M.sync_mutable_buffers(tabpage)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local git = require("codediff.core.git")

  local function is_mutable(revision)
    return revision and revision:match("^:[0-3]$")
  end

  local function sync_buffer(bufnr, revision, path)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not is_mutable(revision) or not path or path == "" then
      return
    end

    git.get_file_content(revision, session.git_root, path, function(err, lines)
      vim.schedule(function()
        if err or not lines then
          return
        end
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end

        -- Only write if content actually changed
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        if #current_lines == #lines then
          local same = true
          for i = 1, #lines do
            if current_lines[i] ~= lines[i] then
              same = false
              break
            end
          end
          if same then
            return
          end
        end

        local was_modifiable = vim.bo[bufnr].modifiable
        local was_readonly = vim.bo[bufnr].readonly
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modifiable = was_modifiable
        vim.bo[bufnr].readonly = was_readonly
        -- TextChanged doesn't fire on nowrite/nofile buffers, trigger explicitly
        M.trigger(bufnr)
      end)
    end)
  end

  sync_buffer(session.original_bufnr, session.original_revision, session.original_path)
  sync_buffer(session.modified_bufnr, session.modified_revision, session.modified_path)
end

-- Cleanup all watched buffers
function M.cleanup_all()
  for bufnr, _ in pairs(watched_buffers) do
    M.disable(bufnr)
  end
  for bufnr, _ in pairs(result_watchers) do
    M.disable_result(bufnr)
  end
end

-- Manually trigger a diff refresh for a buffer (e.g., after programmatic changes)
-- Works for any buffer in a diff session, even if auto-refresh is not enabled for it
-- @param bufnr number: Buffer that was changed
function M.trigger(bufnr)
  if watched_buffers[bufnr] then
    -- Buffer has auto-refresh enabled, use throttled update
    trigger_diff_update(bufnr)
  else
    -- Buffer might not have auto-refresh enabled (e.g., virtual buffer)
    -- Do immediate update, skipping watcher check
    do_diff_update(bufnr, true)
  end
end

return M
