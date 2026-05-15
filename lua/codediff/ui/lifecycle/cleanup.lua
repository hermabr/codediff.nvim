-- Cleanup and autocmd management for diff views
local M = {}

local accessors = require("codediff.ui.lifecycle.accessors")
local config = require("codediff.config")
local session = require("codediff.ui.lifecycle.session")
local state = require("codediff.ui.lifecycle.state")
local welcome_window = require("codediff.ui.view.welcome_window")

-- Autocmd group for cleanup
local augroup = vim.api.nvim_create_augroup("codediff_lifecycle", { clear = true })

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

local auto_quit_scheduled = false
local auto_quit_suppressed_tabpage = nil

local function quit_neovim_on_close()
  local value = config.options.diff.quit_neovim_on_close
  if value == nil then
    return vim.env.CODEDIFF_QUIT_NVIM_ON_CLOSE == "1"
  end
  return value == true
end

local function schedule_quit_neovim()
  if auto_quit_scheduled then
    return
  end
  auto_quit_scheduled = true
  vim.schedule(function()
    if quit_neovim_on_close() then
      pcall(vim.cmd, "confirm qall")
    end
    auto_quit_scheduled = false
  end)
end

local function consume_auto_quit_suppression(tabpage)
  local suppressed = auto_quit_suppressed_tabpage == tabpage
  if suppressed then
    auto_quit_suppressed_tabpage = nil
  end
  return suppressed
end

local function with_auto_quit_suppressed(tabpage, callback)
  auto_quit_suppressed_tabpage = tabpage
  local ok, err = pcall(callback)
  if not ok then
    if auto_quit_suppressed_tabpage == tabpage then
      auto_quit_suppressed_tabpage = nil
    end
    error(err, 0)
  end
end

-- Cleanup a specific diff session
-- @param tabpage number: Tab page ID
local function cleanup_diff(tabpage)
  local active_diffs = session.get_active_diffs()
  local diff = active_diffs[tabpage]
  if not diff then
    return
  end
  local suppress_auto_quit = consume_auto_quit_suppression(tabpage)

  -- Emit CodeDiffClose User autocmd
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffClose",
    modeline = false,
    data = {
      tabpage = tabpage,
      mode = diff.mode,
    },
  })

  -- Disable auto-refresh for both buffers
  local auto_refresh = require("codediff.ui.auto_refresh")
  auto_refresh.disable(diff.original_bufnr)
  auto_refresh.disable(diff.modified_bufnr)
  require("codediff.ui.view.scroll_sync").disable(tabpage)

  -- Clear highlights from both buffers
  state.clear_buffer_highlights(diff.original_bufnr)
  state.clear_buffer_highlights(diff.modified_bufnr)

  -- Restore buffer states
  state.restore_buffer_state(diff.original_bufnr, diff.original_state)
  state.restore_buffer_state(diff.modified_bufnr, diff.modified_state)

  -- Remove tab-scoped keymaps from all tracked buffers
  accessors.clear_tab_keymaps(tabpage)

  -- Call explorer's cleanup function to stop file watchers
  if diff.explorer and diff.explorer._cleanup_auto_refresh then
    pcall(diff.explorer._cleanup_auto_refresh)
  end
  if diff.explorer and diff.explorer.bufnr and vim.api.nvim_buf_is_valid(diff.explorer.bufnr) then
    pcall(vim.api.nvim_buf_delete, diff.explorer.bufnr, { force = true })
  end

  -- Send didClose notifications for virtual buffers
  -- Compute URIs on-demand since we don't store them anymore
  local original_virtual_uri = session.compute_virtual_uri(diff.git_root, diff.original_revision, diff.original_path)
  local modified_virtual_uri = session.compute_virtual_uri(diff.git_root, diff.modified_revision, diff.modified_path)

  -- Get LSP clients from any valid buffer
  local ref_bufnr = vim.api.nvim_buf_is_valid(diff.original_bufnr) and diff.original_bufnr or diff.modified_bufnr
  local clients = vim.lsp.get_clients({ bufnr = ref_bufnr })

  for _, client in ipairs(clients) do
    if client.server_capabilities.semanticTokensProvider then
      if original_virtual_uri then
        pcall(client.notify, "textDocument/didClose", {
          textDocument = { uri = original_virtual_uri },
        })
      end
      if modified_virtual_uri then
        pcall(client.notify, "textDocument/didClose", {
          textDocument = { uri = modified_virtual_uri },
        })
      end
    end
  end

  -- Delete virtual buffers if they're still valid
  if vim.api.nvim_buf_is_valid(diff.original_bufnr) then
    if is_virtual_revision(diff.original_revision) then
      pcall(vim.api.nvim_buf_delete, diff.original_bufnr, { force = true })
    end
  end

  if vim.api.nvim_buf_is_valid(diff.modified_bufnr) then
    if is_virtual_revision(diff.modified_revision) then
      pcall(vim.api.nvim_buf_delete, diff.modified_bufnr, { force = true })
    end
  end

  -- Clear window variables if windows still exist
  if diff.original_win and vim.api.nvim_win_is_valid(diff.original_win) then
    welcome_window.apply_normal(diff.original_win)
    vim.w[diff.original_win].codediff_restore = nil
  end
  if diff.modified_win and vim.api.nvim_win_is_valid(diff.modified_win) then
    welcome_window.apply_normal(diff.modified_win)
    vim.w[diff.modified_win].codediff_restore = nil
  end

  -- Clear result window variable if exists (conflict mode)
  if diff.result_win and vim.api.nvim_win_is_valid(diff.result_win) then
    vim.w[diff.result_win].codediff_restore = nil
  end

  -- Clear result buffer signs (conflict mode)
  if diff.result_bufnr and vim.api.nvim_buf_is_valid(diff.result_bufnr) then
    local result_signs_ns = vim.api.nvim_create_namespace("codediff-result-signs")
    vim.api.nvim_buf_clear_namespace(diff.result_bufnr, result_signs_ns, 0, -1)
  end

  -- Clear conflict file tracking (buffers remain, just not tracked)
  diff.conflict_files = {}

  -- Clear tab-specific autocmd groups
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_lifecycle_tab_" .. tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_working_sync_" .. tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, "CodeDiffConflictSigns_" .. tabpage)

  -- Remove from tracking
  active_diffs[tabpage] = nil

  if quit_neovim_on_close() and not suppress_auto_quit then
    schedule_quit_neovim()
  end
end

-- Count windows in current tabpage that have diff markers
local function count_diff_windows()
  local count = 0
  for i = 1, vim.fn.winnr("$") do
    local win = vim.fn.win_getid(i)
    if vim.w[win].codediff_restore then
      count = count + 1
    end
  end
  return count
end

-- Check if we should trigger cleanup for a window
local function should_cleanup(winid)
  return vim.w[winid].codediff_restore and vim.api.nvim_win_is_valid(winid)
end

-- Setup autocmds for automatic cleanup
function M.setup_autocmds()
  -- When a window is closed, check if we should cleanup the diff
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if not closed_win then
        return
      end

      -- Give Neovim a moment to update window state
      vim.schedule(function()
        -- Check if the closed window was part of a diff
        local active_diffs = session.get_active_diffs()
        for tabpage, diff in pairs(active_diffs) do
          if diff.original_win == closed_win or diff.modified_win == closed_win then
            -- single_pane/inline mode: we expect only 1 diff window
            local is_single_window = diff.single_pane == true or diff.layout == "inline"
            local diff_win_count = count_diff_windows()
            local threshold = is_single_window and 0 or 1
            if diff_win_count <= threshold then
              cleanup_diff(tabpage)
            end
            break
          end
        end
      end)
    end,
  })

  -- When a tab is closed, cleanup its diff
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      -- TabClosed doesn't give us the tab number, so we need to scan
      -- Remove any diffs for tabs that no longer exist
      local valid_tabs = {}
      for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        valid_tabs[tabpage] = true
      end

      local active_diffs = session.get_active_diffs()
      for tabpage, _ in pairs(active_diffs) do
        if not valid_tabs[tabpage] then
          cleanup_diff(tabpage)
        end
      end
    end,
  })

  -- Fallback: When entering a buffer, check if we need cleanup
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      local active_diffs = session.get_active_diffs()
      local diff = active_diffs[current_tab]

      if diff then
        local diff_win_count = count_diff_windows()
        local is_single_window = diff.single_pane == true or diff.layout == "inline"
        local threshold = is_single_window and 0 or 1
        if diff_win_count <= threshold then
          cleanup_diff(current_tab)
        end
      end
    end,
  })
end

-- Manual cleanup function (can be called explicitly)
function M.cleanup(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  cleanup_diff(tabpage)
end

-- Aggressive cleanup for quitting neovim from the last diff tab.
-- Deletes ALL codediff-owned buffers (explorer, scratch placeholders, virtual,
-- result) so session-persistence plugins don't save them.
function M.cleanup_for_quit(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local active_diffs = session.get_active_diffs()
  local diff = active_diffs[tabpage]

  -- Collect all codediff-owned buffer numbers before cleanup_diff removes tracking
  local bufs_to_delete = {}
  if diff then
    -- Explorer / history panel buffer
    if diff.explorer and diff.explorer.bufnr then
      bufs_to_delete[diff.explorer.bufnr] = true
    end
    -- Diff pane buffers (virtual AND scratch placeholders)
    if diff.original_bufnr then
      bufs_to_delete[diff.original_bufnr] = true
    end
    if diff.modified_bufnr then
      bufs_to_delete[diff.modified_bufnr] = true
    end
    -- Conflict result buffer
    if diff.result_bufnr then
      bufs_to_delete[diff.result_bufnr] = true
    end
  end

  -- Run normal cleanup first (LSP notifications, autocmds, state restore, etc.)
  cleanup_diff(tabpage)

  -- Now force-delete all collected buffers that aren't real files worth keeping
  for bufnr, _ in pairs(bufs_to_delete) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bt = vim.bo[bufnr].buftype
      local name = vim.api.nvim_buf_get_name(bufnr)
      -- Keep real, named, on-disk file buffers; delete everything else
      local is_real_file = bt == "" and name ~= "" and vim.fn.filereadable(name) == 1
      if not is_real_file then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
end

--- Close a codediff session using the default behavior.
--- Closing the last tab quits Neovim; otherwise the codediff tab is closed.
function M.close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local active_diffs = session.get_active_diffs()
  if not active_diffs[tabpage] then
    return false
  end

  if not accessors.confirm_close_with_unsaved(tabpage) then
    return false
  end

  local ok, err = pcall(function()
    if #vim.api.nvim_list_tabpages() == 1 then
      with_auto_quit_suppressed(tabpage, function()
        M.cleanup_for_quit(tabpage)
      end)
      vim.cmd("qall")
    else
      if not vim.api.nvim_tabpage_is_valid(tabpage) then
        error("codediff tab is no longer valid")
      end
      vim.api.nvim_set_current_tabpage(tabpage)
      vim.cmd("tabclose")
    end
  end)

  if not ok then
    vim.notify("codediff: failed to close\n" .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  return true
end

--- Close a codediff session while keeping Neovim alive.
--- If codediff is the only tab, create a replacement tab before closing it.
function M.close_without_quit(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local active_diffs = session.get_active_diffs()
  if not active_diffs[tabpage] then
    return false
  end

  if not accessors.confirm_close_with_unsaved(tabpage) then
    return false
  end

  local created_tabpage
  local ok, err = pcall(function()
    with_auto_quit_suppressed(tabpage, function()
      if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd("tabnew")
        created_tabpage = vim.api.nvim_get_current_tabpage()
      end
      if not vim.api.nvim_tabpage_is_valid(tabpage) then
        error("codediff tab is no longer valid")
      end
      vim.api.nvim_set_current_tabpage(tabpage)
      vim.cmd("tabclose")
    end)
  end)

  if not ok then
    if created_tabpage and vim.api.nvim_tabpage_is_valid(created_tabpage) then
      local current = vim.api.nvim_get_current_tabpage()
      pcall(vim.api.nvim_set_current_tabpage, created_tabpage)
      pcall(vim.cmd, "tabclose")
      if vim.api.nvim_tabpage_is_valid(current) then
        pcall(vim.api.nvim_set_current_tabpage, current)
      end
    end
    vim.notify("codediff: failed to close without quitting Neovim\n" .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  return true
end

-- Cleanup all active diffs (useful for plugin unload/reload)
function M.cleanup_all()
  local active_diffs = session.get_active_diffs()
  for tabpage, _ in pairs(active_diffs) do
    cleanup_diff(tabpage)
  end
end

-- Initialize lifecycle management
function M.setup()
  M.setup_autocmds()
end

return M
