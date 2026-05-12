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

local function open_review()
  vim.cmd("CodeDiff")
  return wait_for_review()
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

local function filler_rows(bufnr)
  local review_ns = vim.api.nvim_get_namespaces()["codediff-review"]
  assert.is_not_nil(review_ns, "Review namespace should exist")

  local rows = {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, review_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    for _, chunk in ipairs(details.virt_text or {}) do
      if (chunk[1] or ""):find("╱", 1, true) then
        rows[mark[2] + 1] = true
      end
    end
  end

  return rows
end

local function diff_filler_rows(bufnr)
  local filler_ns = vim.api.nvim_get_namespaces()["codediff-filler"]
  assert.is_not_nil(filler_ns, "Diff filler namespace should exist")

  local rows = {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, filler_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_lines and #details.virt_lines > 0 then
      rows[mark[2] + 1] = #details.virt_lines
    end
  end

  return rows
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(1000, function()
    return vim.api.nvim_get_mode().mode == "n"
  end, 10)
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

  local function create_repo_with_staged_added_then_modified()
    repo = h.create_temp_git_repo()
    repo.write_file("b_changed.txt", { "before", "old value" })
    repo.git("add b_changed.txt")
    repo.git("commit -m initial")
    repo.write_file("a_added.txt", { "added one", "added two", "added three", "added four" })
    repo.write_file("b_changed.txt", { "before", "new value" })
    repo.git("add a_added.txt b_changed.txt")
    vim.fn.chdir(repo.dir)
  end

  local function create_repo_with_inserted_then_modified()
    repo = h.create_temp_git_repo()
    repo.write_file("a_insert.txt", { "alpha", "omega" })
    repo.write_file("b_changed.txt", { "before", "old value" })
    repo.git("add a_insert.txt b_changed.txt")
    repo.git("commit -m initial")
    repo.write_file("a_insert.txt", { "alpha", "beta", "gamma", "omega" })
    repo.write_file("b_changed.txt", { "before", "new value" })
    vim.fn.chdir(repo.dir)
  end

  local function create_repo_with_compact_scroll_drift()
    repo = h.create_temp_git_repo()
    repo.write_file("a_formatter.py", {
      '"""Formatting helpers for display strings."""',
      "",
      "",
      "def normalize_name(name):",
      '    collapsed = " ".join(name.strip().split())',
      "    return collapsed.title()",
      "",
      "",
      "def format_user(first_name, last_name):",
      "    first = normalize_name(first_name)",
      "    last = normalize_name(last_name)",
      '    return f"{first} {last}"',
      "",
      "",
      'def format_money(cents, currency="$"):',
      "    dollars = cents / 100",
      '    return f"{currency}{dollars:,.2f}"',
      "",
      "",
      "def bullet_list(items):",
      "    lines = []",
      "    for item in items:",
      '        lines.append(f"- {item}")',
      '    return "\\n".join(lines)',
    })
    repo.write_file("b_tests.py", {
      "from tss.calculator import add, moving_total, subtract, total",
      "",
      "",
      "def test_add():",
      "    assert add(2, 3) == 5",
      "",
      "",
      "def test_subtract():",
      "    assert subtract(7, 4) == 3",
      "",
      "",
      "def test_total():",
      "    assert total([1, 2, 3]) == 6",
      "",
      "",
      "def test_moving_total():",
      "    assert moving_total([2, 4, 8]) == [2, 6, 14]",
    })
    repo.git("add a_formatter.py b_tests.py")
    repo.git("commit -m initial")
    repo.write_file("a_formatter.py", {
      '"""Formatting helpers for display strings."""',
      "",
      "",
      "def normalize_name(name):",
      '    collapsed = " ".join(name.strip().split())',
      "    return collapsed.title()",
      "",
      "",
      "def format_user(first_name, last_name):",
      "    first = normalize_name(first_name)",
      "    last = normalize_name(last_name)",
      '    return f"{first} {last}"',
      "",
      "",
      'def format_money(cents, currency="$"):',
      "    dollars = cents / 100",
      '    return f"{currency}{dollars:,.2f}"',
      "",
      "",
      "def bullet_list(items, indent=0):",
      '    prefix = " " * indent + "- "',
      "    lines = []",
      "    for item in items:",
      '        lines.append(f"{prefix}{item}")',
      '    return "\\n".join(lines)',
    })
    repo.write_file("b_tests.py", {
      "import pytest",
      "",
      "from tss.calculator import add, average, moving_total, subtract, total",
      "",
      "",
      "def test_add():",
      "    assert add(2, 3) == 5",
      "",
      "",
      "def test_subtract():",
      "    assert subtract(7, 4) == 3",
      "",
      "",
      "def test_total():",
      "    assert total([1, 2, 3]) == 6",
      "",
      "",
      "def test_average():",
      "    assert average([10, 20, 30]) == 20",
      "",
      "",
      "def test_average_rejects_empty_values():",
      "    with pytest.raises(ValueError):",
      "        average([])",
      "",
      "",
      "def test_moving_total():",
      "    assert moving_total([2, 4, 8]) == [2, 6, 14]",
    })
    vim.fn.chdir(repo.dir)
  end

  it("opens every changed file in one side-by-side review", function()
    create_repo_with_changes()

    local tabpage, session = open_review()
    local original_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)

    assert.is_not_nil(session.explorer, "Review mode should keep the explorer session for toggling back")
    assert.is_true(session.explorer.is_hidden, "Review mode should hide the explorer panel")
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

  it("keeps the original review buffer read-only", function()
    create_repo_with_single_change()

    local _, session = open_review()

    assert.is_false(vim.bo[session.original_bufnr].modifiable, "Original review buffer should not be editable")
    assert.is_true(vim.bo[session.original_bufnr].readonly, "Original review buffer should be readonly")
    assert.is_true(vim.bo[session.modified_bufnr].modifiable, "Modified review buffer should remain editable")
    assert.is_false(vim.bo[session.modified_bufnr].readonly, "Modified review buffer should remain writable")
  end)

  it("toggles back to explorer mode", function()
    create_repo_with_single_change()

    local tabpage = open_review()
    assert.is_true(require("codediff.ui.view").toggle_review(tabpage), "Review mode should toggle off")

    local restored = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session
        and session.mode == "explorer"
        and session.explorer
        and not session.explorer.is_hidden
        and session.explorer.current_selection
        and session.original_path ~= ""
    end, 100)

    assert.is_true(restored, "Explorer mode should be restored with the previous file selected")
  end)

  it("installs the quit keymap immediately", function()
    create_repo_with_single_change()
    local initial_tab_count = #vim.api.nvim_list_tabpages()

    local tabpage, session = open_review()
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

    local tabpage, session = open_review()
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local target_line = find_line(modified_lines, "TWO")
    assert.is_not_nil(target_line, "Changed line should be present before diffget")
    assert.is_nil(find_line(modified_lines, "+++ first.txt [unstaged:M]"), "Header should remain virtual before diffget")
    assert.is_true(has_virtual_header(session.modified_bufnr, "+++ first.txt [unstaged:M]"), "Virtual header should be present before diffget")
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
    assert.is_nil(
      find_line(vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "+++ first.txt [unstaged:M]"),
      "Header should remain virtual after diffget"
    )
    assert.is_true(has_virtual_header(session.modified_bufnr, "+++ first.txt [unstaged:M]"), "Virtual header should remain present after diffget")
  end)

  it("applies syntax highlights for each reviewed file", function()
    create_repo_with_lua_change()

    local _, session = open_review()
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

    local _, session = open_review()
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

    local _, session = open_review()
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

    local _, session = open_review()
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
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local modified_fillers = filler_rows(session.modified_bufnr)
    local original_deleted_header = find_line(original_headers, "--- a_deleted.txt [unstaged:D]")
    local deleted_header = find_line(modified_headers, "+++ /dev/null [unstaged:D]")
    local changed_header = find_line(modified_headers, "+++ b_changed.txt [unstaged:M]")

    assert.is_not_nil(original_deleted_header, "Deleted file should still have an original-side virtual header")
    assert.is_not_nil(deleted_header, "Deleted file should still have a modified-side virtual header")
    assert.is_not_nil(changed_header, "Following file should have a modified-side virtual header")
    assert.is_true(deleted_header < changed_header, "Deleted file header should render before the following file header")
    assert.are.same({ "", "", "", "before", "new value" }, modified_lines)
    assert.is_true(modified_fillers[1], "Deleted file should add modified-side filler at row 1")
    assert.is_true(modified_fillers[2], "Deleted file should add modified-side filler at row 2")
    assert.is_true(modified_fillers[3], "Deleted file should add modified-side filler at row 3")
    assert.equal(1, session.review_sections[1].modified_header_start)
    assert.equal(4, session.review_sections[2].modified_header_start)
  end)

  it("keeps compact added-file boundaries aligned before the following file", function()
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        jump_to_first_change = false,
        compact = true,
        compact_context_lines = 0,
      },
    })
    create_repo_with_staged_added_then_modified()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local added = session.review_sections[1]
    local changed = session.review_sections[2]
    local has_added_change = false

    for _, change in ipairs(session.stored_diff_result.changes or {}) do
      if change.section_index == 1 then
        has_added_change = true
        break
      end
    end

    assert.equal("a_added.txt", added.path)
    assert.equal("A", added.status)
    assert.equal("b_changed.txt", changed.path)
    assert.is_true(has_added_change, "Added file should contribute a diff mapping for compact visibility")
    assert.equal(added.original_placeholder_end, changed.original_header_start)
    assert.equal(added.modified_content_end, changed.modified_header_start)

    vim.api.nvim_win_call(session.modified_win, function()
      for line = added.modified_content_start, added.modified_content_end - 1 do
        assert.equal(0, vim.fn.foldlevel(line), "Added content should remain visible in compact mode")
      end
    end)

    vim.api.nvim_win_call(session.original_win, function()
      for line = added.original_placeholder_start, added.original_placeholder_end - 1 do
        assert.equal(0, vim.fn.foldlevel(line), "Added-file placeholder should remain visible in compact mode")
      end
    end)
  end)

  it("keeps compact insertion fillers visible before the following file", function()
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        jump_to_first_change = false,
        compact = true,
        compact_context_lines = 0,
      },
    })
    create_repo_with_inserted_then_modified()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local inserted = session.review_sections[1]
    local changed = session.review_sections[2]
    local original_fillers = diff_filler_rows(session.original_bufnr)

    assert.equal("a_insert.txt", inserted.path)
    assert.equal("b_changed.txt", changed.path)
    assert.equal(2, original_fillers[inserted.original_content_start], "Insertion filler should be anchored on a visible original line")
    assert.equal(
      vim.fn.screenpos(session.original_win, changed.original_content_start, 1).row,
      vim.fn.screenpos(session.modified_win, changed.modified_content_start, 1).row,
      "Following file should start on the same screen row"
    )

    vim.api.nvim_win_call(session.original_win, function()
      assert.equal(0, vim.fn.foldlevel(inserted.original_content_start), "Insertion filler anchor should remain visible")
      assert.equal(1, vim.fn.foldlevel(inserted.original_content_start + 1), "Unchanged line after insertion should stay foldable")
    end)

    vim.api.nvim_win_call(session.modified_win, function()
      assert.equal(0, vim.fn.foldlevel(inserted.modified_content_start + 1), "Inserted content should remain visible")
      assert.equal(0, vim.fn.foldlevel(inserted.modified_content_start + 2), "Inserted content should remain visible")
      assert.equal(1, vim.fn.foldlevel(inserted.modified_content_start + 3), "Unchanged line after insertion should stay foldable")
    end)

    vim.api.nvim_set_current_win(session.modified_win)
    vim.cmd("normal! 2\005")
    require("codediff.ui.view.scroll_sync").sync_pair(session.modified_win, session.original_win)
    assert.equal(
      vim.fn.screenpos(session.original_win, changed.original_content_start, 1).row,
      vim.fn.screenpos(session.modified_win, changed.modified_content_start, 1).row,
      "Following file should stay aligned while scrolling through insertion filler"
    )
  end)

  it("keeps visible compact file boundaries aligned after fold-height drift", function()
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        jump_to_first_change = false,
        compact = true,
        compact_context_lines = 3,
      },
    })
    create_repo_with_compact_scroll_drift()

    vim.cmd("CodeDiff review")
    local _, session = wait_for_review()
    local second = session.review_sections[2]

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { second.modified_content_start, 0 })
    vim.cmd("normal! zt")
    vim.cmd("normal! 4\025")
    require("codediff.ui.view.scroll_sync").sync_pair(session.modified_win, session.original_win)

    local original_row = vim.fn.screenpos(session.original_win, second.original_content_start, 1).row
    local modified_row = vim.fn.screenpos(session.modified_win, second.modified_content_start, 1).row
    assert.is_true(original_row > 0, "Second file boundary should be visible on the original side")
    assert.is_true(modified_row > 0, "Second file boundary should be visible on the modified side")
    assert.equal(original_row, modified_row, "Visible file boundary should stay aligned after scroll sync")
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
