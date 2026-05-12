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
    local header_line = find_line(modified_lines, "+++ HELLO.md [staged:A]")
    local content_line = find_line(modified_lines, "hey")

    assert.is_not_nil(header_line, "Staged added file header should be present")
    assert.is_not_nil(content_line, "Staged file content should be present")

    vim.api.nvim_buf_set_lines(modified_buf, content_line - 1, content_line + 1, false, { "hello edited", "from review" })
    write_buffer(modified_buf)

    assert.are.same({ "hello edited", "from review" }, vim.fn.readfile(repo.path("HELLO.md")))
  end)
end)
