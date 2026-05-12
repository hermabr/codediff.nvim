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

local function write_buffer(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("write")
  end)
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

local function virtual_header_lines(bufnr)
  local review_ns = vim.api.nvim_get_namespaces()["codediff-review"]
  assert.is_not_nil(review_ns, "Review namespace should exist")

  local lines = {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, review_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    for _, virt_line in ipairs(details.virt_lines or {}) do
      local chunks = {}
      for _, chunk in ipairs(virt_line) do
        table.insert(chunks, chunk[1] or "")
      end
      table.insert(lines, table.concat(chunks))
    end
  end

  return lines
end

local function has_virtual_header(bufnr, needle)
  for _, line in ipairs(virtual_header_lines(bufnr)) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(1000, function()
    return vim.api.nvim_get_mode().mode == "n"
  end, 10)
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

  local function create_repo_with_deleted_then_modified()
    repo = h.create_temp_git_repo()
    repo.write_file("a_deleted.txt", { "deleted one", "deleted two", "deleted three" })
    repo.write_file("b_changed.txt", { "before", "old value" })
    repo.git("add a_deleted.txt b_changed.txt")
    repo.git("commit -m initial")
    vim.fn.delete(repo.path("a_deleted.txt"))
    repo.write_file("b_changed.txt", { "before", "new value" })
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

    assert.is_nil(find_line(modified_lines, "+++ first.txt [unstaged:M]"), "Modified file headers should be virtual")
    assert.is_nil(find_line(original_lines, "--- first.txt [unstaged:M]"), "Original file headers should be virtual")
    assert.is_true(has_virtual_header(session.modified_bufnr, "+++ first.txt [unstaged:M]"), "Modified review buffer should include the modified file header")
    assert.is_true(has_virtual_header(session.modified_bufnr, "+++ second.txt [unstaged:??]"), "Modified review buffer should include the untracked file header")
    assert.is_true(has_virtual_header(session.original_bufnr, "--- first.txt [unstaged:M]"), "Original review buffer should include the modified file header")
    assert.is_true(has_virtual_header(session.original_bufnr, "--- /dev/null [unstaged:??]"), "Original review buffer should show /dev/null for untracked files")
    assert.is_not_nil(find_line(modified_lines, "TWO"), "Modified content should be present in the review buffer")
    assert.is_not_nil(find_line(modified_lines, "new file"), "Untracked content should be present in the review buffer")
    assert.is_true(find_line(modified_lines, "TWO") < find_line(modified_lines, "new file"), "Files should be rendered sequentially in one review buffer")
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
      return vim.fn.foldlevel(section.modified_content_start)
    end), "First content line should remain visible so the virtual file header is visible in compact mode")
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

  it("keeps virtual boundaries ordered when an empty side is followed by another file", function()
    create_repo_with_deleted_then_modified()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local original_headers = virtual_header_lines(session.original_bufnr)
    local modified_headers = virtual_header_lines(session.modified_bufnr)
    local original_deleted_header = find_line(original_headers, "--- a_deleted.txt [unstaged:D]")
    local deleted_header = find_line(modified_headers, "+++ /dev/null [unstaged:D]")
    local changed_header = find_line(modified_headers, "+++ b_changed.txt [unstaged:M]")
    local has_filler_between = false

    assert.is_not_nil(original_deleted_header, "Deleted file should still have an original-side virtual header")
    assert.is_not_nil(deleted_header, "Deleted file should still have a modified-side virtual header")
    assert.is_not_nil(changed_header, "Following file should have a modified-side virtual header")
    assert.is_true(deleted_header < changed_header, "Deleted file header should render before the following file header")

    for line = deleted_header + 1, changed_header - 1 do
      if modified_headers[line] and modified_headers[line]:find("╱", 1, true) then
        has_filler_between = true
        break
      end
    end

    assert.is_true(has_filler_between, "Empty-side filler should render between adjacent virtual file headers")
  end)

  it("writes edited modified review sections to their backing files", function()
    create_repo_with_changes()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("first.txt")))
    local first_buf = vim.api.nvim_get_current_buf()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local modified_buf = session.modified_bufnr
    local modified_lines = vim.api.nvim_buf_get_lines(modified_buf, 0, -1, false)
    local first_line = find_line(modified_lines, "TWO")
    local second_line = find_line(modified_lines, "new file")

    assert.is_true(vim.bo[modified_buf].modifiable, "Modified review buffer should be editable")
    assert.is_not_nil(first_line, "First file content should be in the modified review buffer")
    assert.is_not_nil(second_line, "Second file content should be in the modified review buffer")

    vim.api.nvim_buf_set_lines(modified_buf, second_line - 1, second_line, false, { "second edited" })
    vim.api.nvim_buf_set_lines(modified_buf, first_line - 1, first_line, false, { "TWO edited", "inserted in first" })
    write_buffer(modified_buf)

    assert.are.same({ "one", "TWO edited", "inserted in first" }, vim.fn.readfile(repo.path("first.txt")))
    assert.are.same({ "one", "TWO edited", "inserted in first" }, vim.api.nvim_buf_get_lines(first_buf, 0, -1, false))
    assert.are.same({ "second edited" }, vim.fn.readfile(repo.path("second.txt")))
  end)

  it("assigns o and O insertions at file edges to the selected review section", function()
    create_repo_with_changes()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local modified_buf = session.modified_bufnr
    vim.api.nvim_set_current_win(session.modified_win)

    local modified_lines = vim.api.nvim_buf_get_lines(modified_buf, 0, -1, false)
    local first_last_line = find_line(modified_lines, "TWO")
    assert.is_not_nil(first_last_line, "First file content should be in the modified review buffer")
    vim.api.nvim_win_set_cursor(session.modified_win, { first_last_line, 0 })
    feedkeys("oafter first<Esc>")

    modified_lines = vim.api.nvim_buf_get_lines(modified_buf, 0, -1, false)
    local second_first_line = find_line(modified_lines, "new file")
    assert.is_not_nil(second_first_line, "Second file content should be in the modified review buffer")
    vim.api.nvim_win_set_cursor(session.modified_win, { second_first_line, 0 })
    feedkeys("Obefore second<Esc>")

    write_buffer(modified_buf)

    assert.are.same({ "one", "TWO", "after first" }, vim.fn.readfile(repo.path("first.txt")))
    assert.are.same({ "before second", "new file" }, vim.fn.readfile(repo.path("second.txt")))
  end)

  it("writes a staged added review section back to the working tree file", function()
    repo = h.create_temp_git_repo()
    repo.write_file("README.md", { "root" })
    repo.git("add README.md")
    repo.git("commit -m initial")
    repo.write_file("HELLO.md", { "hey", "# this" })
    repo.git("add HELLO.md")
    vim.fn.chdir(repo.dir)

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local modified_buf = session.modified_bufnr
    local modified_lines = vim.api.nvim_buf_get_lines(modified_buf, 0, -1, false)
    local content_line = find_line(modified_lines, "hey")

    assert.is_nil(find_line(modified_lines, "+++ HELLO.md [staged:A]"), "Staged added file header should be virtual")
    assert.is_true(has_virtual_header(modified_buf, "+++ HELLO.md [staged:A]"), "Staged added file header should be present")
    assert.is_not_nil(content_line, "Staged file content should be present")

    vim.api.nvim_buf_set_lines(modified_buf, content_line - 1, content_line + 1, false, { "hello edited", "from review" })
    write_buffer(modified_buf)

    assert.are.same({ "hello edited", "from review" }, vim.fn.readfile(repo.path("HELLO.md")))
  end)
end)
