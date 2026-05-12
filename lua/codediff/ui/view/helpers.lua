-- Buffer preparation helpers for diff view
local M = {}

local virtual_file = require("codediff.core.virtual_file")

local function is_absolute_path(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

local function normalize_real_path(path, git_root)
  if not path or path == "" then
    return path
  end

  local expanded = vim.fn.expand(path)
  if git_root and git_root ~= "" and not is_absolute_path(expanded) then
    local root = vim.fn.fnamemodify(git_root, ":p"):gsub("[/\\]$", "")
    expanded = root .. "/" .. expanded
  end

  return vim.fn.fnamemodify(expanded, ":p")
end

-- Helper: Check if revision is virtual (commit hash or STAGED)
-- Virtual: "STAGED" or commit hash | Real: nil or "WORKING"
function M.is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Exact buffer name lookup (vim.fn.bufnr uses pattern matching which
-- causes prefix collisions, e.g. "Makefile" matching "Makefile.win")
local function bufnr_exact(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return -1
end

-- Prepare buffer information for loading
-- Returns: { bufnr = number?, target = string?, needs_edit = boolean }
-- - If buffer already exists: { bufnr = 123, target = nil, needs_edit = false }
-- - If needs :edit: { bufnr = nil, target = "path or url", needs_edit = true }
function M.prepare_buffer(is_virtual, git_root, revision, path)
  if is_virtual then
    -- Virtual file: generate URL
    local virtual_url = virtual_file.create_url(git_root, revision, path)
    -- Check if buffer already exists (exact match to avoid prefix collisions)
    local existing_buf = bufnr_exact(virtual_url)

    -- For :0 (staged index), always force reload because index can change
    -- when user runs git add/reset. For commits (immutable), we can cache.
    local is_mutable_revision = revision == ":0" or revision == ":1" or revision == ":2" or revision == ":3"

    if existing_buf ~= -1 and not is_mutable_revision then
      -- Buffer exists for immutable revision, reuse it
      return {
        bufnr = existing_buf,
        target = virtual_url,
        needs_edit = false,
      }
    else
      -- Either buffer doesn't exist, or it's a mutable revision that needs refresh
      -- Don't delete here - let the :edit! handle it (will trigger BufReadCmd)
      return {
        bufnr = existing_buf ~= -1 and existing_buf or nil,
        target = virtual_url,
        needs_edit = true,
      }
    end
  else
    -- Real file: use an absolute file path for buffer lookup/loading so edits
    -- and writes always target the intended working-tree file.
    local real_path = normalize_real_path(path, git_root)
    local existing_buf = bufnr_exact(real_path)
    if existing_buf ~= -1 then
      -- Buffer already exists, reuse it
      return {
        bufnr = existing_buf,
        target = nil,
        needs_edit = false,
      }
    else
      -- Buffer doesn't exist, need to :edit it
      return {
        bufnr = nil,
        target = real_path,
        needs_edit = true,
      }
    end
  end
end

return M
