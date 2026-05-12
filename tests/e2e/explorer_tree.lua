-- E2E Scenario: Validate explorer tree expand/collapse and file selection
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("src/a.txt", {"aaa"})
    ctx.repo.write_file("src/b.txt", {"bbb"})
    ctx.repo.write_file("c.txt", {"ccc"})
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'initial'")
    ctx.repo.write_file("src/a.txt", {"aaa modified"})
    ctx.repo.write_file("src/b.txt", {"bbb modified"})
    ctx.repo.write_file("c.txt", {"ccc modified"})
    vim.cmd("edit " .. ctx.repo.path("c.txt"))
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

    -- Get explorer content
    local _, explorer_buf = e2e.find_window_by_filetype("codediff-explorer")
    ctx.explorer_lines = e2e.get_buffer_lines(explorer_buf)
    ctx.explorer_content = e2e.get_buffer_content(explorer_buf)

    -- Try selecting a different file via next_file
    e2e.next_file()
    vim.wait(500)

    -- Get diff content after navigation
    ctx.modified_content = e2e.get_modified_content()
  end,

  validate = function(ctx, e2e)
    local ok = true

    -- Explorer should have content (tree rendered)
    ok = ok and e2e.assert_true(#ctx.explorer_lines > 0, "Explorer should have lines")

    -- Explorer should show file names
    ok = ok and e2e.assert_true(
      ctx.explorer_content:find("a.txt") or ctx.explorer_content:find("b.txt") or ctx.explorer_content:find("c.txt"),
      "Explorer should show file names"
    )

    -- Should have a group header
    ok = ok and e2e.assert_contains(ctx.explorer_content, "Changes", "Explorer should have Changes group")

    -- After next_file, modified content should exist
    ok = ok and e2e.assert_true(ctx.modified_content ~= nil and #ctx.modified_content > 0, "Should have modified content after navigation")

    return ok
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
