-- Append / regenerate queue over per-commit jobs.
local changes = require("raccoon_segments.changes")
local job = require("raccoon_segments.job")
local store = require("raccoon_segments.store")

local M = {}

---@type table<string, table> sha -> {status, sha, subject, error, phase, started_at, finished_at, changed}
local entries = {}
---@type string[] queued shas in order
local pending = {}
local running = {}
local running_count = 0
local listeners = {}
local batch
local config
local instructions_loader = function() return nil end

local notify_level = { ok = vim.log.levels.INFO, warn = vim.log.levels.WARN, err = vim.log.levels.ERROR }

local function notify(message, level)
  vim.schedule(function()
    vim.notify("raccoon-segments: " .. message, notify_level[level or "ok"])
  end)
end

---@param resolved table resolved config
---@param load_instructions fun(): string|nil
function M.configure(resolved, load_instructions)
  config = resolved
  instructions_loader = load_instructions
end

---@param fn fun()
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

local function changed()
  for _, fn in ipairs(listeners) do pcall(fn) end
end

---Status for a sha: consults the store for finished commits.
---@param sha string|nil
---@return table|nil entry {status = "queued"|"running"|"done"|"failed"|"skipped"|"cancelled", ...}
function M.entry(sha)
  if not sha then return nil end
  local entry = entries[sha]
  if entry and entry.status ~= "done" then return entry end
  if store.has(sha) then
    entries[sha] = entries[sha] or { sha = sha, status = "done" }
    entries[sha].status = "done"
    return entries[sha]
  end
  if entry then return entry end
  local error_path = store.file_if_exists(sha, "error.txt")
  if error_path then
    local text = (store.read(error_path) or ""):gsub("%s+$", "")
    entries[sha] = { sha = sha, status = "failed", error = text, previous = true }
    return entries[sha]
  end
  return nil
end

---@return table snapshot {running, queued, done, failed, skipped, entries}
function M.status()
  local counts = { running = 0, queued = 0, done = 0, failed = 0, skipped = 0 }
  local list = {}
  for _, entry in pairs(entries) do
    if counts[entry.status] then counts[entry.status] = counts[entry.status] + 1 end
    list[#list + 1] = entry
  end
  table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end)
  counts.entries = list
  counts.batch = batch
  return counts
end

local submitting = 0

function M.is_busy()
  return running_count > 0 or #pending > 0 or submitting > 0
end

local function finish_batch_if_done()
  if not batch or running_count > 0 or #pending > 0 then return end
  local done, failed = 0, 0
  for _, sha in ipairs(batch.shas) do
    local entry = entries[sha]
    if entry and entry.status == "done" then done = done + 1 end
    if entry and (entry.status == "failed" or entry.status == "cancelled") then failed = failed + 1 end
  end
  local summary = ("%d/%d commits explained"):format(done, #batch.shas)
  if failed > 0 then
    summary = summary .. (", %d failed — :RaccoonSegments status"):format(failed)
  end
  notify(summary, failed > 0 and "warn" or "ok")
  batch = nil
  changed()
end

local pump

local function start(sha)
  local entry = entries[sha]
  entry.status = "running"
  entry.started_at = vim.uv.now()
  entry.phase = "starting"
  running_count = running_count + 1
  changed()
  local commits = {}
  for _, item in ipairs(entry.batch_commits or {}) do
    local artifact = item.sha ~= sha and store.has(item.sha) and store.load(item.sha) or nil
    commits[#commits + 1] = {
      sha = item.sha,
      message = item.message,
      current = item.sha == sha,
      overview = artifact and artifact.overview or nil,
    }
  end
  running[sha] = job.run({
    sha = sha,
    subject = entry.subject,
    repo_path = entry.repo_path,
    source = entry.source,
    commits = commits,
    config = config,
    instructions = instructions_loader(),
    on_phase = function(name)
      entry.phase = name
      changed()
    end,
    on_done = function(artifact, err)
      running[sha] = nil
      running_count = running_count - 1
      entry.finished_at = vim.uv.now()
      entry.phase = nil
      if artifact then
        entry.status = "done"
        entry.segments = #artifact.segments
      elseif err == "cancelled" then
        entry.status = "cancelled"
      else
        entry.status = "failed"
        entry.error = err
      end
      changed()
      pump()
      finish_batch_if_done()
    end,
  })
end

pump = function()
  while running_count < (config and config.max_parallel or 1) and #pending > 0 do
    local sha = table.remove(pending, 1)
    if entries[sha] and entries[sha].status == "queued" then start(sha) end
  end
end

local order_counter = 0

local function enqueue(target, context)
  order_counter = order_counter + 1
  entries[target.sha] = {
    sha = target.sha,
    subject = (target.message or ""):match("^[^\n]*"),
    status = "queued",
    order = order_counter,
    repo_path = context.repo_path,
    source = context.source,
    batch_commits = context.batch_commits,
  }
  pending[#pending + 1] = target.sha
end

---Count changed lines for a commit (cached per sha).
local line_counts = {}

local function count_lines(repo_path, sha, callback)
  local cached = line_counts[sha]
  if cached then
    callback(cached.changed, cached.binary_only)
    return
  end
  vim.system({
    "git", "-C", repo_path, "diff-tree", "--numstat", "-m", "--first-parent", "--root", "--no-commit-id", sha,
  }, { text = true }, function(result)
    vim.schedule(function()
      local total, binary_only = 0, false
      if result.code == 0 then
        total, binary_only = changes.count_numstat(result.stdout or "", config.exclude)
      end
      line_counts[sha] = { changed = total, binary_only = binary_only }
      callback(total, binary_only)
    end)
  end)
end

---@class RaccoonSegmentsQueueRequest
---@field targets table[] {sha, message} oldest first
---@field all_commits table[] {sha, message} oldest first, for prompt context
---@field repo_path string
---@field source table
---@field mode "append"|"regenerate"

---@param request RaccoonSegmentsQueueRequest
function M.submit(request)
  if not config then error("raccoon-segments queue is not configured") end
  local targets = request.targets
  if #targets == 0 then
    notify("no commits to explain here", "warn")
    return
  end
  if request.mode == "regenerate" then
    for _, target in ipairs(targets) do
      if running[target.sha] then running[target.sha].cancel() end
      store.delete(target.sha)
      entries[target.sha] = nil
      line_counts[target.sha] = nil
    end
  end

  local context = {
    repo_path = request.repo_path,
    source = request.source,
    batch_commits = request.all_commits,
  }
  local queued, skipped, already = {}, 0, 0
  local remaining = #targets
  submitting = submitting + 1

  local function after_counts()
    submitting = submitting - 1
    if #queued == 0 then
      local parts = {}
      if already > 0 then parts[#parts + 1] = ("%d already explained"):format(already) end
      if skipped > 0 then
        parts[#parts + 1] = ("%d skipped (< %d changed lines)"):format(skipped, config.min_changed_lines)
      end
      notify("nothing to generate" .. (#parts > 0 and (": " .. table.concat(parts, ", ")) or ""), "ok")
      changed()
      return
    end
    batch = batch or { shas = {} }
    for _, sha in ipairs(queued) do batch.shas[#batch.shas + 1] = sha end
    local backend = require("raccoon_segments.backends").name(config.backend)
    local note = ""
    if skipped > 0 then note = (" (%d skipped: < %d lines)"):format(skipped, config.min_changed_lines) end
    notify(("generating %d commit%s via %s%s"):format(#queued, #queued == 1 and "" or "s", backend, note))
    changed()
    pump()
  end

  for _, target in ipairs(targets) do
    local sha = target.sha
    local existing = entries[sha]
    local in_flight = existing and (existing.status == "running" or existing.status == "queued")
    if request.mode == "append" and (store.has(sha) or in_flight) then
      already = already + 1
      remaining = remaining - 1
      if remaining == 0 then after_counts() end
    else
      count_lines(request.repo_path, sha, function(total, binary_only)
        if (config.min_changed_lines > 0 and total < config.min_changed_lines) or binary_only then
          order_counter = order_counter + 1
          entries[sha] = {
            sha = sha,
            subject = (target.message or ""):match("^[^\n]*"),
            status = "skipped",
            changed = total,
            binary_only = binary_only,
            order = order_counter,
          }
          skipped = skipped + 1
        else
          enqueue(target, context)
          queued[#queued + 1] = sha
        end
        remaining = remaining - 1
        if remaining == 0 then after_counts() end
      end)
    end
  end
end

---Stop every queued and running job.
function M.cancel()
  local count = #pending
  pending = {}
  for sha, handle in pairs(running) do
    count = count + 1
    handle.cancel()
    if entries[sha] then entries[sha].status = "cancelled" end
  end
  for sha, entry in pairs(entries) do
    if entry.status == "queued" then entries[sha].status = "cancelled" end
  end
  batch = nil
  changed()
  return count
end

---Forget in-memory state (tests).
function M.reset()
  M.cancel()
  entries = {}
  line_counts = {}
  running_count = 0
  submitting = 0
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("RaccoonSegmentsQueue", { clear = true }),
  callback = function()
    for _, handle in pairs(running) do pcall(handle.cancel) end
  end,
})

return M
