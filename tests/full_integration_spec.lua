-- Test: Full Integration
-- Validates all supported commands documented in README.md

local commands = require("codediff.commands")

-- Setup CodeDiff command for tests
local function setup_command()
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

describe("Full Integration Suite", function()
  local temp_dir
  local commit_hash_1
  local commit_hash_2

  -- Helper to run git in temp_dir (cross-platform)
  local function git(args)
    local h = dofile('tests/helpers.lua')
    return h.git_cmd(temp_dir, args)
  end

  before_each(function()
    -- Setup command
    setup_command()
    
    -- Create temporary git repository for testing
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    
    -- Initialize git repo
    git("init")
    -- Rename branch to main to be sure
    git("branch -m main")
    git('config user.email "test@example.com"')
    git('config user.name "Test User"')
    
    -- Commit 1
    vim.fn.writefile({"line 1", "line 2"}, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Initial commit"')
    commit_hash_1 = vim.trim(git("rev-parse HEAD"))
    
    -- Tag v1.0.0
    git("tag v1.0.0")

    -- Commit 2
    vim.fn.writefile({"line 1", "line 2 modified"}, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Second commit"')
    commit_hash_2 = vim.trim(git("rev-parse HEAD"))

    -- Create another file for file comparison
    vim.fn.writefile({"file a content"}, temp_dir .. "/file_a.txt")
    vim.fn.writefile({"file b content"}, temp_dir .. "/file_b.txt")
    
    -- Open the main file
    vim.cmd("edit " .. temp_dir .. "/file.txt")
  end)

  after_each(function()
    -- Reset tabs first to close windows/buffers that might be using the dir
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    
    -- Give enough time for async tasks/handles to close
    vim.wait(200)

    -- Clean up
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  -- Helper to verify review opened
  local function assert_review_opened()
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr('$') > 1
    end)
    assert.is_true(opened, "Should open a new tab")

    local lifecycle = require("codediff.ui.lifecycle")
    local has_review = false
    vim.wait(5000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local session = lifecycle.get_session(tp)
        if session and session.mode == "review" and session.review_sections and session.stored_diff_result then
          has_review = true
          return true
        end
      end
      return false
    end)
    assert.is_true(has_review, "Should have review session")
  end

  -- 1. Review Mode: Default
  it("Runs :CodeDiff (Review Default)", function()
    -- Make a change so there is something to show
    vim.fn.writefile({"line 1", "line 2 modified", "line 3"}, temp_dir .. "/file.txt")
    
    vim.cmd("CodeDiff")
    assert_review_opened()
  end)

  -- 2. Review Mode: Revision
  it("Runs :CodeDiff HEAD~1", function()
    vim.cmd("CodeDiff HEAD~1")
    assert_review_opened()
  end)

  -- 3. Review Mode: Branch
  it("Runs :CodeDiff main", function()
    -- Create a dev branch and switch to it so main is different
    git("reset --hard HEAD~1")
    git("checkout -b feature")
    vim.fn.writefile({"feature change"}, temp_dir .. "/file.txt")
    git('commit -am "feature commit"')
    
    -- Now compare against main
    vim.cmd("CodeDiff main")
    assert_review_opened()
  end)

  -- 4. Review Mode: Commit Hash
  it("Runs :CodeDiff <commit_hash>", function()
    vim.cmd("CodeDiff " .. commit_hash_1)
    assert_review_opened()
  end)

  -- 11. Arbitrary Revision Diff (Review)
  it("Runs :CodeDiff main HEAD", function()
    -- Ensure there is a diff between main and HEAD
    git("checkout HEAD~1")
    -- Now HEAD is commit 1. main is commit 2.
    
    vim.cmd("CodeDiff main HEAD")
    assert_review_opened()
  end)

  -- 12. Merge-base Mode (PR-like diff)
  it("Runs :CodeDiff main... (merge-base)", function()
    -- Go back to first commit and create feature branch
    git("checkout " .. commit_hash_1)
    git("checkout -b feature-branch")
    vim.fn.writefile({"feature line 1", "feature line 2"}, temp_dir .. "/feature.txt")
    git("add feature.txt")
    git('commit -m "feature commit"')
    
    -- Now we have:
    -- main: commit_hash_1 -> commit_hash_2
    -- feature-branch: commit_hash_1 -> feature_commit
    -- merge-base(main, HEAD) = commit_hash_1
    -- So :CodeDiff main... should show only the feature.txt change
    
    vim.cmd("CodeDiff main...")
    assert_review_opened()
  end)

  -- 7. CodeDiffOpen autocmd fires on open
  it("Fires CodeDiffOpen User autocmd", function()
    vim.fn.writefile({"line 1", "line 2 modified", "line 3"}, temp_dir .. "/file.txt")

    local event_data = nil
    local au_id = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffOpen",
      callback = function(args)
        event_data = args.data
      end,
    })

    vim.cmd("CodeDiff")
    assert_review_opened()

    assert.is_not_nil(event_data, "CodeDiffOpen should fire")
    assert.equal("review", event_data.mode, "Mode should be review")
    assert.is_not_nil(event_data.tabpage, "tabpage should be set")

    vim.api.nvim_del_autocmd(au_id)
  end)

  -- 8. CodeDiffClose autocmd fires on close
  it("Fires CodeDiffClose User autocmd", function()
    vim.fn.writefile({"line 1", "line 2 modified", "line 3"}, temp_dir .. "/file.txt")

    -- Ensure lifecycle autocmds are set up (TabClosed handler)
    require("codediff.ui.lifecycle").setup()

    local close_data = nil
    local au_id = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffClose",
      callback = function(args)
        close_data = args.data
      end,
    })

    vim.cmd("CodeDiff")
    assert_review_opened()

    -- Close via tabclose (triggers TabClosed autocmd -> cleanup_diff)
    vim.cmd("tabclose")
    vim.wait(2000, function() return close_data ~= nil end)

    assert.is_not_nil(close_data, "CodeDiffClose should fire")
    assert.equal("review", close_data.mode, "Mode should be review")

    vim.api.nvim_del_autocmd(au_id)
  end)

end)
