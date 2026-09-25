-- Shared helpers for Neovim-based specs.
local M = {}

function M.tempdir(label)
  local dir = vim.fn.tempname() .. "-" .. label
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

function M.read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

function M.git(repo, args)
  local cmd = { "git", "-C", repo }
  for _, arg in ipairs(args) do cmd[#cmd + 1] = arg end
  local result = vim.system(cmd, {
    text = true,
    env = {
      GIT_AUTHOR_NAME = "Test",
      GIT_AUTHOR_EMAIL = "test@example.com",
      GIT_COMMITTER_NAME = "Test",
      GIT_COMMITTER_EMAIL = "test@example.com",
      GIT_CONFIG_GLOBAL = "/dev/null",
      HOME = os.getenv("HOME"),
      PATH = os.getenv("PATH"),
    },
  }):wait()
  assert(result.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. tostring(result.stderr))
  return (result.stdout or ""):gsub("%s+$", "")
end

---Create a repository with a linear history. Returns repo path and shas (oldest first).
---@param dir string
---@param commits table[] {message, files = {path = content}}
function M.make_repo(dir, commits)
  M.git(dir, { "init", "-q", "-b", "main", "." })
  local shas = {}
  for _, commit in ipairs(commits) do
    for path, content in pairs(commit.files) do
      if content == false then
        os.remove(vim.fs.joinpath(dir, path))
      else
        M.write_file(vim.fs.joinpath(dir, path), content)
      end
    end
    M.git(dir, { "add", "-A" })
    M.git(dir, { "commit", "-q", "-m", commit.message })
    shas[#shas + 1] = M.git(dir, { "rev-parse", "HEAD" })
  end
  return shas
end

---Wait until fn() is truthy or fail.
function M.wait_for(fn, timeout_ms, message)
  local ok = vim.wait(timeout_ms or 10000, fn, 20)
  assert(ok, message or "timed out waiting")
end

---Install fake agent CLIs on PATH. Returns the fake dir (logs land there).
function M.install_fake_backends(label)
  local bin = M.tempdir((label or "fake") .. "-bin")
  local log_dir = M.tempdir((label or "fake") .. "-log")
  local script = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "fake_backend.lua")
  for _, name in ipairs({ "opencode", "claude", "codex" }) do
    local path = vim.fs.joinpath(bin, name)
    M.write_file(path, ("#!/bin/sh\nexec %q -l %q %s \"$@\"\n"):format(vim.v.progpath, script, name))
    vim.fn.setfperm(path, "rwxr-xr-x")
  end
  vim.env.PATH = bin .. ":" .. vim.env.PATH
  vim.env.FAKE_BACKEND_DIR = log_dir
  vim.env.FAKE_MODE = "ok"
  return log_dir
end

function M.fake_calls(log_dir)
  local content = M.read_file(vim.fs.joinpath(log_dir, "calls"))
  return tonumber(content) or 0
end

function M.reset_fake(log_dir)
  for name in vim.fs.dir(log_dir) do os.remove(vim.fs.joinpath(log_dir, name)) end
end

---Minimal valid PNG (1x1, transparent) for image tests.
function M.tiny_png()
  local hex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d494441547801636000"
    .. "0100000005000102a05a4d5f0000000049454e44ae426082"
  return (hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end))
end

return M
