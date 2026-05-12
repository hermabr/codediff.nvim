-- E2E Scenario: Validate explorer window position and layout
-- Tests that explorer appears at the LEFT edge (not between diff panes)
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("file1.txt", {"line 1", "line 2"})
    ctx.repo.write_file("file2.txt", {"hello"})
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'initial'")
    ctx.repo.write_file("file1.txt", {"line 1", "line 2 modified"})
    ctx.repo.write_file("file2.txt", {"hello world"})
    vim.cmd("edit " .. ctx.repo.path("file1.txt"))
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

    -- Collect window layout info
    ctx.windows = e2e.get_all_windows()
    ctx.explorer_win, ctx.explorer_buf = e2e.find_window_by_filetype("codediff-explorer")
  end,

  validate = function(ctx, e2e)
    local ok = true

    -- Must have explorer window
    ok = ok and e2e.assert_true(ctx.explorer_win ~= nil, "Explorer window should exist")
    if not ctx.explorer_win then return false end

    -- Must have 3 windows (explorer + 2 diff panes)
    ok = ok and e2e.assert_true(#ctx.windows >= 3, "Should have at least 3 windows, got " .. #ctx.windows)

    -- Explorer must be the LEFTMOST window (col position = 0)
    local explorer_col = vim.api.nvim_win_get_position(ctx.explorer_win)[2]
    ok = ok and e2e.assert_equals(0, explorer_col, "Explorer should be at column 0 (leftmost), got " .. explorer_col)

    -- Explorer width should be reasonable (not full screen)
    local explorer_width = vim.api.nvim_win_get_width(ctx.explorer_win)
    ok = ok and e2e.assert_true(explorer_width <= 60, "Explorer should be reasonable width, got " .. explorer_width)

    -- Diff panes should be to the RIGHT of explorer
    for _, win_info in ipairs(ctx.windows) do
      if win_info.winid ~= ctx.explorer_win then
        local col = vim.api.nvim_win_get_position(win_info.winid)[2]
        ok = ok and e2e.assert_true(col > explorer_col, "Diff pane should be right of explorer")
      end
    end

    return ok
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
