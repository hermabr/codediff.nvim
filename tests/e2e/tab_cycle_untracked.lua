-- E2E Scenario: Tab cycling with untracked file should not crash (PR #309)
--
-- Root cause: show_untracked_file() stored {} as stored_diff_result instead of
-- {changes={}, moves={}}. When resume_diff() reuses that value (no recompute
-- needed), render_diff() crashes on ipairs(nil) because {}.changes is nil.
--
-- This test validates the invariant directly: after selecting an untracked file,
-- stored_diff_result.changes must be a table (not nil). It then performs a full
-- tab cycle to exercise the resume_diff path end-to-end.
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("tracked.txt", { "hello world" })
    ctx.repo.git("add . && git commit -m 'initial'")
    ctx.repo.write_file("untracked.txt", { "I am untracked" })
    vim.cmd("edit " .. ctx.repo.path("tracked.txt"))
  end,

  run = function(ctx, e2e)
    e2e.exec("CodeDiff")
    vim.wait(5000, function()
      local session = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
      return session and session.mode == "review" and session.review_sections
    end, 100)
    require("codediff.ui.view").toggle_review()
    e2e.wait_for_explorer(5000)
    e2e.wait_for_diff_ready(5000)

    -- Find the untracked file in the explorer tree
    local function find_untracked()
      local lines = e2e.get_explorer_files()
      ctx.explorer_lines = lines
      if not lines then return nil end
      for i, line in ipairs(lines) do
        if line:find("untracked.txt") then return i end
      end
      return nil
    end

    local untracked_line = find_untracked()

    -- If section is collapsed, expand it first
    if not untracked_line and ctx.explorer_lines then
      for i, line in ipairs(ctx.explorer_lines) do
        if line:find("ntracked") then
          e2e.select_explorer_item(i)
          vim.wait(500)
          break
        end
      end
      untracked_line = find_untracked()
    end

    ctx.found_untracked = untracked_line ~= nil
    if not untracked_line then
      ctx.error = "Could not find untracked.txt in explorer"
      return
    end

    -- Select the untracked file → triggers show_untracked_file → single-pane view
    e2e.select_explorer_item(untracked_line)
    vim.wait(1000)

    -- KEY CHECK: Capture stored_diff_result IMMEDIATELY after show_untracked_file.
    -- Before the fix this was {}, meaning .changes and .moves were nil.
    -- After the fix this is {changes={}, moves={}}.
    local session = e2e.get_diff_session()
    if session and session.stored_diff_result then
      ctx.immediate_has_changes = session.stored_diff_result.changes ~= nil
      ctx.immediate_has_moves = session.stored_diff_result.moves ~= nil
      ctx.immediate_changes_type = type(session.stored_diff_result.changes)
    else
      ctx.immediate_has_changes = false
      ctx.immediate_has_moves = false
    end

    -- Now exercise the full tab-cycle path (suspend → resume → render)
    ctx.codediff_tabnr = vim.fn.tabpagenr()
    ctx.codediff_tabpage = vim.api.nvim_get_current_tabpage()

    vim.cmd("tabnew")
    vim.wait(500)

    -- Cycle back via tabnext (triggers TabEnter → vim.schedule → resume_diff)
    ctx.cycle_ok, ctx.cycle_err = pcall(function()
      vim.cmd("tabnext " .. ctx.codediff_tabnr)
    end)

    -- Let TabEnter → vim.schedule → resume_diff complete
    local lifecycle = require("codediff.ui.lifecycle")
    vim.wait(3000, function()
      local s = lifecycle.get_session(ctx.codediff_tabpage)
      return s and not s.suspended
    end, 50)

    -- Capture state after the full cycle
    local after = lifecycle.get_session(ctx.codediff_tabpage)
    ctx.session_alive = after ~= nil
    if after then
      ctx.after_suspended = after.suspended
      ctx.after_mod_win_valid = after.modified_win and vim.api.nvim_win_is_valid(after.modified_win)
    end
  end,

  validate = function(ctx, e2e)
    local ok = true

    ok = ok and e2e.assert_true(ctx.found_untracked,
      "Should find untracked.txt in explorer (lines: " .. vim.inspect(ctx.explorer_lines) .. ")")
    if not ctx.found_untracked then return false end

    ok = ok and e2e.assert_true(ctx.error == nil, "No error: " .. tostring(ctx.error))

    -- Core invariant: stored_diff_result must have .changes right after show_untracked_file
    ok = ok and e2e.assert_true(ctx.immediate_has_changes,
      "stored_diff_result.changes must not be nil immediately after show_untracked_file (was: "
        .. tostring(ctx.immediate_changes_type) .. ")")

    ok = ok and e2e.assert_true(ctx.immediate_has_moves,
      "stored_diff_result.moves must not be nil immediately after show_untracked_file")

    -- Tab cycle should not crash
    ok = ok and e2e.assert_true(ctx.cycle_ok ~= false,
      "Tab cycle should not error: " .. tostring(ctx.cycle_err))

    -- Session survives the cycle
    ok = ok and e2e.assert_true(ctx.session_alive, "Session should exist after tab cycle")
    ok = ok and e2e.assert_true(ctx.after_suspended == false, "Session should resume after tab cycle")
    ok = ok and e2e.assert_true(ctx.after_mod_win_valid, "Modified window should be valid after tab cycle")

    return ok
  end,

  cleanup = function(ctx, e2e)
    pcall(function() e2e.cleanup_tabs() end)
    if ctx.repo then ctx.repo.cleanup() end
  end,
}
