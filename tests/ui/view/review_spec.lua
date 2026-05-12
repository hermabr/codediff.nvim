local h = dofile("tests/helpers.lua")

local lifecycle = require("codediff.ui.lifecycle")
local navigation = require("codediff.ui.view.navigation")

local function wait_for_review()
  local tabpage
  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and session.mode == "review" and session.review_sections and #session.review_sections > 0 and session.stored_diff_result then
        tabpage = tp
        return true
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff review session should be ready")
  return tabpage, lifecycle.get_session(tabpage)
end

local function find_line(lines, needle)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

local function line_has_highlight(bufnr, line, pattern)
  local syntax_ns = vim.api.nvim_get_namespaces()["codediff-review-syntax"]
  assert.is_not_nil(syntax_ns, "Review syntax namespace should exist")

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, syntax_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if mark[2] == line - 1 and type(details.hl_group) == "string" and details.hl_group:match(pattern) then
      return true
    end
  end

  return false
end

local function line_has_diff_highlight(bufnr, line, pattern)
  local diff_ns = vim.api.nvim_get_namespaces()["codediff-highlight"]
  assert.is_not_nil(diff_ns, "Diff highlight namespace should exist")

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, diff_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if mark[2] == line - 1 and type(details.hl_group) == "string" and details.hl_group:match(pattern) then
      return true
    end
  end

  return false
end

local function setup_command()
  pcall(vim.api.nvim_del_user_command, "CodeDiff")
  local commands = require("codediff.commands")
  require("codediff.ui.view.review")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    range = true,
  })
end

describe("CodeDiff review view", function()
  local cwd
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        jump_to_first_change = false,
      },
    })
    setup_command()
    require("codediff.ui.highlights").setup()
    cwd = vim.fn.getcwd()
  end)

  after_each(function()
    h.close_extra_tabs()
    if cwd then
      vim.fn.chdir(cwd)
    end
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  local function create_repo_with_changes()
    repo = h.create_temp_git_repo()
    repo.write_file("first.txt", { "one", "two" })
    repo.git("add first.txt")
    repo.git("commit -m initial")
    repo.write_file("first.txt", { "one", "TWO" })
    repo.write_file("second.txt", { "new file" })
    vim.fn.chdir(repo.dir)
  end

  local function create_repo_with_single_change()
    repo = h.create_temp_git_repo()
    repo.write_file("first.txt", { "one", "two" })
    repo.git("add first.txt")
    repo.git("commit -m initial")
    repo.write_file("first.txt", { "one", "TWO" })
    vim.fn.chdir(repo.dir)
  end

  local function create_repo_with_lua_change()
    repo = h.create_temp_git_repo()
    repo.write_file("sample.lua", { "local value = 1", "return value" })
    repo.git("add sample.lua")
    repo.git("commit -m initial")
    repo.write_file("sample.lua", { "local value = 2", "return value" })
    vim.fn.chdir(repo.dir)
  end

  local function create_repo_with_markdown_and_lua_changes()
    repo = h.create_temp_git_repo()
    repo.write_file("notes.md", {
      "# Notes",
      "",
      "```lua",
      "local old_value = 1",
      "```",
    })
    repo.write_file("sample.lua", { "local value = 1", "return value" })
    repo.git("add notes.md sample.lua")
    repo.git("commit -m initial")
    repo.write_file("notes.md", {
      "# Notes",
      "",
      "```lua",
      "local new_value = 2",
      "```",
    })
    repo.write_file("sample.lua", { "local value = 2", "return value" })
    vim.fn.chdir(repo.dir)
  end

  local function create_repo_with_distant_change()
    repo = h.create_temp_git_repo()
    local original = {}
    local modified = {}
    for i = 1, 12 do
      original[i] = "line " .. i
      modified[i] = "line " .. i
    end
    modified[12] = "changed line 12"

    repo.write_file("long.txt", original)
    repo.git("add long.txt")
    repo.git("commit -m initial")
    repo.write_file("long.txt", modified)
    vim.fn.chdir(repo.dir)
  end

  it("opens every changed file in one side-by-side review", function()
    create_repo_with_changes()

    vim.cmd("CodeDiff review")
    local tabpage, session = wait_for_review()
    local original_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)

    assert.is_nil(session.explorer, "Review mode should not create an explorer panel")
    assert.equal(2, #vim.api.nvim_tabpage_list_wins(tabpage), "Review mode should only create the two diff windows")
    assert.equal(2, #session.review_sections, "Review should include both changed files")

    local first_header = find_line(modified_lines, "+++ first.txt [unstaged:M]")
    local second_header = find_line(modified_lines, "+++ second.txt [unstaged:??]")
    assert.is_not_nil(first_header, "Modified review buffer should include the modified file header")
    assert.is_not_nil(second_header, "Modified review buffer should include the untracked file header")
    assert.is_true(first_header < second_header, "Files should be rendered sequentially in one review buffer")

    assert.is_not_nil(find_line(original_lines, "--- first.txt [unstaged:M]"), "Original review buffer should include the modified file header")
    assert.is_not_nil(find_line(original_lines, "--- /dev/null [unstaged:??]"), "Original review buffer should show /dev/null for untracked files")
    assert.is_not_nil(find_line(modified_lines, "TWO"), "Modified content should be present in the review buffer")
    assert.is_not_nil(find_line(modified_lines, "new file"), "Untracked content should be present in the review buffer")
  end)

  it("installs the quit keymap immediately", function()
    create_repo_with_single_change()
    local initial_tab_count = #vim.api.nvim_list_tabpages()

    vim.cmd("CodeDiff review")
    local tabpage, session = wait_for_review()
    vim.api.nvim_set_current_win(session.modified_win)
    vim.cmd("normal q")

    local closed = vim.wait(1000, function()
      return not vim.api.nvim_tabpage_is_valid(tabpage) or lifecycle.get_session(tabpage) == nil
    end, 50)

    assert.is_true(closed, "q should close a freshly opened review tab")
    assert.equal(initial_tab_count, #vim.api.nvim_list_tabpages(), "Review tab should be closed")
  end)

  it("refreshes review highlights after diffget without diffing headers", function()
    create_repo_with_single_change()

    vim.cmd("CodeDiff review")
    local tabpage, session = wait_for_review()
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local target_line = find_line(modified_lines, "TWO")
    local header_line = find_line(modified_lines, "+++ first.txt [unstaged:M]")
    assert.is_not_nil(target_line, "Changed line should be present before diffget")
    assert.is_not_nil(header_line, "Header line should be present before diffget")
    assert.is_true(line_has_diff_highlight(session.modified_bufnr, target_line, "CodeDiffLineInsert"))

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { target_line, 0 })
    vim.cmd("normal do")

    local refreshed = vim.wait(2000, function()
      local current = lifecycle.get_session(tabpage)
      if not current or not current.stored_diff_result then
        return false
      end
      local current_lines = vim.api.nvim_buf_get_lines(current.modified_bufnr, 0, -1, false)
      local changes = current.stored_diff_result.changes or {}
      return current_lines[target_line] == "two" and #changes == 0
    end, 50)

    assert.is_true(refreshed, "Review diff should refresh after diffget")
    assert.is_false(line_has_diff_highlight(session.modified_bufnr, target_line, "CodeDiffLineInsert"))
    assert.is_false(line_has_diff_highlight(session.modified_bufnr, header_line, "CodeDiffLine"))
  end)

  it("applies syntax highlights for each reviewed file", function()
    create_repo_with_lua_change()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local target_line = find_line(modified_lines, "local value = 2")
    assert.is_not_nil(target_line, "Lua content should be present in the review buffer")

    local syntax_ns = vim.api.nvim_get_namespaces()["codediff-review-syntax"]
    assert.is_not_nil(syntax_ns, "Review syntax namespace should exist")

    local marks = vim.api.nvim_buf_get_extmarks(session.modified_bufnr, syntax_ns, 0, -1, { details = true })
    local has_keyword = false
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if mark[2] == target_line - 1 and type(details.hl_group) == "string" and details.hl_group:match("keyword") then
        has_keyword = true
        break
      end
    end

    assert.is_true(has_keyword, "Review buffer should highlight Lua keywords")
  end)

  it("applies injected Markdown code block highlights in a mixed review", function()
    create_repo_with_markdown_and_lua_changes()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local markdown_code_line = find_line(modified_lines, "local new_value = 2")
    local lua_line = find_line(modified_lines, "local value = 2")
    assert.is_not_nil(markdown_code_line, "Markdown fenced Lua content should be present")
    assert.is_not_nil(lua_line, "Lua content should be present")

    assert.is_true(
      line_has_highlight(session.modified_bufnr, markdown_code_line, "keyword"),
      "Review buffer should highlight injected Lua keywords in Markdown"
    )
    assert.is_true(
      line_has_highlight(session.modified_bufnr, lua_line, "keyword"),
      "Review buffer should still highlight standalone Lua files"
    )
  end)

  it("applies compact mode after review content loads", function()
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        jump_to_first_change = false,
        compact = true,
        compact_context_lines = 0,
      },
    })
    create_repo_with_distant_change()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local section = session.review_sections[1]
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local changed_line = find_line(modified_lines, "changed line 12")

    assert.is_true(session.compact_mode, "Review mode should honor diff.compact")
    assert.equal("expr", vim.wo[session.modified_win].foldmethod, "Review window should use compact folds")
    assert.equal(0, vim.api.nvim_win_call(session.modified_win, function()
      return vim.fn.foldlevel(section.modified_header_start)
    end), "Review file header should remain visible in compact mode")
    assert.equal(1, vim.api.nvim_win_call(session.modified_win, function()
      return vim.fn.foldlevel(section.modified_content_start)
    end), "Unchanged content away from hunks should be folded in compact mode")
    assert.equal(0, vim.api.nvim_win_call(session.modified_win, function()
      return vim.fn.foldlevel(changed_line)
    end), "Changed content should remain visible in compact mode")
  end)

  it("navigates between file sections in review mode", function()
    create_repo_with_changes()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { session.review_sections[1].modified_header_start, 0 })

    assert.is_true(navigation.next_file(), "next_file should jump to the next review section")
    assert.equal(session.review_sections[2].modified_header_start, vim.api.nvim_win_get_cursor(session.modified_win)[1])

    assert.is_true(navigation.prev_file(), "prev_file should jump to the previous review section")
    assert.equal(session.review_sections[1].modified_header_start, vim.api.nvim_win_get_cursor(session.modified_win)[1])
  end)
end)
