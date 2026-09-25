-- On-disk store keyed by commit SHA. Writes are atomic (temp file + rename).
local M = {}

M.VERSION = 1

local data_dir

---@param dir string
function M.configure(dir)
  data_dir = dir
end

---@return string
function M.root()
  return data_dir or vim.fs.joinpath(vim.fn.stdpath("data"), "raccoon-segments")
end

---@param sha string
---@return string
function M.commit_dir(sha)
  assert(type(sha) == "string" and sha:match("^%x+$"), "store: invalid sha")
  return vim.fs.joinpath(M.root(), "commits", sha)
end

---@param sha string
---@param name string
---@return string
function M.path(sha, name)
  return vim.fs.joinpath(M.commit_dir(sha), name)
end

---@param path string
---@return string|nil
function M.read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

---@param path string
---@param content string
---@return boolean ok, string|nil err
function M.write(path, content)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, "p")
  local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
  local file, err = io.open(tmp, "wb")
  if not file then return false, err end
  local ok, write_err = file:write(content)
  file:close()
  if not ok then
    os.remove(tmp)
    return false, write_err
  end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false, rename_err
  end
  return true
end

---@param sha string
---@return boolean
function M.has(sha)
  return vim.fn.filereadable(M.path(sha, "artifact.json")) == 1
end

---@param sha string
---@return table|nil artifact, string|nil err
function M.load(sha)
  local content = M.read(M.path(sha, "artifact.json"))
  if not content then return nil, "no artifact" end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then return nil, "artifact.json is corrupt" end
  if decoded.version ~= M.VERSION then
    return nil, ("artifact version %s is not supported"):format(tostring(decoded.version))
  end
  decoded.dir = M.commit_dir(sha)
  return decoded
end

---@param sha string
---@param artifact table
---@return boolean ok, string|nil err
function M.save(sha, artifact)
  artifact.version = M.VERSION
  artifact.sha = sha
  local copy = vim.deepcopy(artifact)
  copy.dir = nil
  local ok, encoded = pcall(vim.json.encode, copy)
  if not ok then return false, tostring(encoded) end
  return M.write(M.path(sha, "artifact.json"), encoded)
end

---@param sha string
function M.delete(sha)
  local dir = M.commit_dir(sha)
  if vim.fn.isdirectory(dir) == 1 then vim.fn.delete(dir, "rf") end
end

---@param sha string
---@param name string
---@return string|nil path
function M.file_if_exists(sha, name)
  local path = M.path(sha, name)
  if vim.fn.filereadable(path) == 1 then return path end
  return nil
end

return M
