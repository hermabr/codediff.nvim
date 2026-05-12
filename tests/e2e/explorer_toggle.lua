-- E2E Scenario: Validate explorer hide/show (toggle visibility)
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("file.txt", {"original"})
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'initial'")
    ctx.repo.write_file("file.txt", {"modified"})
    vim.cmd("edit " .. ctx.repo.path("file.txt"))
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

    -- Record initial state
    ctx.initial_explorer_win = e2e.find_window_by_filetype("codediff-explorer")
    ctx.initial_win_count = #e2e.get_all_windows()

    -- Toggle explorer off via actions API
    local actions = require("codediff.ui.explorer.actions")
    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)
    local explorer_obj = session and session.explorer
    if explorer_obj then
      actions.toggle_visibility(explorer_obj)
    end
    vim.wait(500)
    ctx.hidden_explorer_win = e2e.find_window_by_filetype("codediff-explorer")
    ctx.hidden_win_count = #e2e.get_all_windows()

    -- Toggle explorer back on
    if explorer_obj then
      actions.toggle_visibility(explorer_obj)
    end
    vim.wait(500)
    ctx.restored_explorer_win = e2e.find_window_by_filetype("codediff-explorer")
    ctx.restored_win_count = #e2e.get_all_windows()

    -- Check it's still on the left after restore
    if ctx.restored_explorer_win then
      ctx.restored_col = vim.api.nvim_win_get_position(ctx.restored_explorer_win)[2]
    end
  end,

  validate = function(ctx, e2e)
    local ok = true

    -- Initially should have explorer
    ok = ok and e2e.assert_true(ctx.initial_explorer_win ~= nil, "Should have explorer initially")

    -- After hide, explorer window should be gone
    ok = ok and e2e.assert_true(ctx.hidden_explorer_win == nil, "Explorer should be hidden after toggle")
    ok = ok and e2e.assert_true(ctx.hidden_win_count < ctx.initial_win_count, "Window count should decrease after hide")

    -- After show, explorer should be back
    ok = ok and e2e.assert_true(ctx.restored_explorer_win ~= nil, "Explorer should be restored after second toggle")
    ok = ok and e2e.assert_equals(ctx.initial_win_count, ctx.restored_win_count, "Window count should match original")

    -- Restored explorer should be at the left edge
    ok = ok and e2e.assert_equals(0, ctx.restored_col, "Restored explorer should be at column 0 (leftmost)")

    return ok
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
