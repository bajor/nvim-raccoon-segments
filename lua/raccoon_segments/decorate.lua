-- Decoration provider: draws segment tints, badges, sidebar marks, header
-- summary and file-tree dots with ephemeral extmarks, so raccoon's own buffer
-- rewrites never disturb them.
local adapter = require("raccoon_segments.host.raccoon")
local changes = require("raccoon_segments.changes")
local palette = require("raccoon_segments.palette")
local queue = require("raccoon_segments.queue")
local store = require("raccoon_segments.store")

local M = {}

M.PRIORITY = 150
local CIRCLED = { "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫" }

local ns = vim.api.nvim_create_namespace("raccoon_segments")
local enabled = true
local overlay = true
local artifact_cache = {}
local row_cache = {}
local current_viewer

---@return integer
function M.namespace()
  return ns
end

function M.set_overlay(value)
  overlay = value
  M.redraw()
end

function M.overlay()
  return overlay
end

-- Ephemeral marks only refresh when a window repaints, so force it.
function M.redraw()
  vim.schedule(function() pcall(vim.cmd, "redraw!") end)
end

---Cached artifact for a sha (nil when none). Cleared on queue changes.
---@param sha string|nil
---@return table|nil
function M.artifact(sha)
  if not sha then return nil end
  local cached = artifact_cache[sha]
  if cached ~= nil then return cached or nil end
  local artifact = store.has(sha) and store.load(sha) or false
  artifact_cache[sha] = artifact
  return artifact or nil
end

function M.invalidate()
  artifact_cache = {}
  row_cache = {}
  M.redraw()
end

---@param index integer
---@return string
function M.circled(index)
  return CIRCLED[index] or ("(" .. index .. ")")
end

-- Segment lookup ------------------------------------------------------------

---@param artifact table
---@return table<string, table> block id -> segment
local function segment_by_block(artifact)
  if artifact._by_block then return artifact._by_block end
  local map = {}
  for _, segment in ipairs(artifact.segments) do
    for _, id in ipairs(segment.changes) do map[id] = segment end
  end
  artifact._by_block = map
  return map
end

---@param artifact table
---@return table<string, table[]> file -> blocks
local function blocks_by_file(artifact)
  if artifact._by_file then return artifact._by_file end
  local map = {}
  for _, block in ipairs(artifact.blocks or {}) do
    map[block.file] = map[block.file] or {}
    table.insert(map[block.file], block)
  end
  artifact._by_file = map
  return map
end

---Row -> segment info for a viewer buffer. Cached per buffer/changedtick.
---@param viewer table
---@param artifact table
---@param buffer integer
---@param filename string
---@param first_line integer|nil
---@return table rows {[row0] = {segment, kind, first}}
local function buffer_rows(viewer, artifact, buffer, filename, first_line)
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  local key = table.concat({ artifact.sha, filename, tostring(first_line) }, ":")
  local cached = row_cache[buffer]
  if cached and cached.tick == tick and cached.key == key then return cached.rows end

  local records = adapter.typed_records(buffer, viewer.namespace)
  local typed = changes.typed_from_records(records, first_line)
  local runs = changes.runs(typed)
  local blocks = blocks_by_file(artifact)[filename] or {}
  local matched = changes.match(runs, blocks)
  local by_block = segment_by_block(artifact)
  local rows = {}
  for index, run in ipairs(runs) do
    local id = matched[index]
    if id then
      local segment = by_block[id]
      for row = run.first, run.last do
        rows[row - 1] = {
          segment = segment,
          unassigned = segment == nil,
          kind = typed[row].type,
          first = row == run.first,
          id = id,
        }
      end
    end
  end
  row_cache[buffer] = { tick = tick, key = key, rows = rows }
  return rows
end

-- Drawing helpers -----------------------------------------------------------

local function set(buffer, row, col, opts)
  opts.ephemeral = true
  pcall(vim.api.nvim_buf_set_extmark, buffer, ns, row, col, opts)
end

local function segment_group(kind, segment)
  local index = segment and segment.index or "unassigned"
  return palette.group(kind, index)
end

local function draw_diff_rows(buffer, rows, topline, botline)
  for row = topline, botline do
    local info = rows[row]
    if info then
      local group = segment_group(info.kind == "del" and "del" or "add", info.segment)
      set(buffer, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = group,
        hl_eol = true,
        priority = M.PRIORITY,
      })
      if info.first then
        local label
        if info.segment then
          label = M.circled(info.segment.index) .. " " .. info.segment.title
        else
          label = "○ unassigned"
        end
        set(buffer, row, 0, {
          virt_text = { { " " .. label .. " ", segment_group("badge", info.segment) } },
          virt_text_pos = "right_align",
          priority = M.PRIORITY + 1,
        })
      end
    end
  end
end

local function status_mark(entry)
  if not entry then return nil end
  if entry.status == "running" then return { "⟳", "RaccoonSegmentsFg1" } end
  if entry.status == "queued" then return { "…", "RaccoonSegmentsDim" } end
  if entry.status == "failed" then return { "✗", "DiagnosticError" } end
  if entry.status == "skipped" then return { "–", "RaccoonSegmentsDim" } end
  if entry.status == "cancelled" then return { "✗", "RaccoonSegmentsDim" } end
  return nil
end

local function draw_sidebar(viewer, buffer, topline, botline)
  local commits, section1, split = adapter.commits(viewer)
  for _, commit in ipairs(commits) do
    local row = adapter.sidebar_row(commit.index, section1, split)
    if row >= topline and row <= botline and commit.sha then
      local chunks
      local artifact = M.artifact(commit.sha)
      if artifact then
        chunks = {}
        for _, segment in ipairs(artifact.segments) do
          chunks[#chunks + 1] = { "●", palette.group("fg", segment.index) }
        end
        if #artifact.unassigned > 0 then chunks[#chunks + 1] = { "○", palette.group("fg", "unassigned") } end
      else
        local mark = status_mark(queue.entry(commit.sha))
        if mark then chunks = { mark } end
      end
      if chunks then
        chunks[#chunks + 1] = { " ", "Normal" }
        set(buffer, row, 0, { virt_text = chunks, virt_text_pos = "right_align", priority = M.PRIORITY })
      end
    end
  end
end

local function draw_filetree(viewer, buffer, topline, botline, artifact)
  local paths = adapter.filetree_paths(viewer)
  local by_file = {}
  for _, segment in ipairs(artifact.segments) do
    for _, file in ipairs(segment.files or {}) do
      by_file[file.file] = by_file[file.file] or {}
      table.insert(by_file[file.file], segment.index)
    end
  end
  for row = topline, botline do
    local path = paths[row]
    local segments = path and by_file[path]
    if segments then
      local chunks = {}
      for _, index in ipairs(segments) do chunks[#chunks + 1] = { "●", palette.group("fg", index) } end
      chunks[#chunks + 1] = { " ", "Normal" }
      set(buffer, row, 0, { virt_text = chunks, virt_text_pos = "right_align", priority = M.PRIORITY })
    end
  end
end

local function header_text(viewer)
  local selected = adapter.selected(viewer)
  if not selected or not selected.sha then return nil end
  local artifact = M.artifact(selected.sha)
  local keys = M.keys or {}
  if artifact then
    local hint = keys.explain and (" · " .. keys.explain) or ""
    return { ("◆ %d segment%s%s "):format(#artifact.segments, #artifact.segments == 1 and "" or "s", hint),
      "RaccoonSegmentsFg1" }
  end
  local entry = queue.entry(selected.sha)
  if entry and entry.status == "running" then
    local status = queue.status()
    return { ("⟳ generating (%s) %d running, %d queued "):format(entry.phase or "…", status.running, status.queued),
      "RaccoonSegmentsFg1" }
  end
  if entry and entry.status == "queued" then return { "… queued for explanation ", "RaccoonSegmentsDim" } end
  if entry and entry.status == "failed" then
    return { "✗ explanation failed · :RaccoonSegments status ", "DiagnosticError" }
  end
  if entry and entry.status == "skipped" then
    return { ("– skipped: %d changed lines "):format(entry.changed or 0), "RaccoonSegmentsDim" }
  end
  if keys.generate then return { ("no explanation · %s to generate "):format(keys.generate), "RaccoonSegmentsDim" } end
  return nil
end

-- Provider ------------------------------------------------------------------

local function on_win(_, _, buffer, topline, botline)
  if not enabled then return false end
  local viewer = current_viewer
  if not viewer then return false end
  local info = adapter.classify(viewer, buffer)
  if not info then return false end
  if info.role == "sidebar" then
    draw_sidebar(viewer, buffer, topline, botline)
    return false
  end
  if info.role == "header" then
    local text = header_text(viewer)
    if text then
      set(buffer, 0, 0, { virt_text = { text }, virt_text_pos = "right_align", priority = M.PRIORITY })
    end
    return false
  end
  if not overlay then return false end
  local selected = adapter.selected(viewer)
  local artifact = selected and M.artifact(selected.sha)
  if not artifact then return false end
  if info.role == "filetree" then
    draw_filetree(viewer, buffer, topline, botline, artifact)
    return false
  end
  if info.filename then
    local rows = buffer_rows(viewer, artifact, buffer, info.filename, info.role == "cell" and info.first_line or nil)
    draw_diff_rows(buffer, rows, topline, botline)
  end
  return false
end

local provider_set = false

---@param viewer table|nil
function M.set_viewer(viewer)
  current_viewer = viewer
  if not viewer then row_cache = {} end
end

function M.start(keys)
  M.keys = keys
  enabled = true
  if not provider_set then
    vim.api.nvim_set_decoration_provider(ns, { on_win = on_win })
    provider_set = true
  end
end

function M.stop()
  enabled = false
  current_viewer = nil
  row_cache = {}
  artifact_cache = {}
  if provider_set then
    vim.api.nvim_set_decoration_provider(ns, {})
    provider_set = false
  end
end

---Segment under a cursor row in a viewer buffer (for explain-from-diff).
---@param viewer table
---@param buffer integer
---@param row0 integer
---@return table|nil segment
function M.segment_at(viewer, buffer, row0)
  local info = adapter.classify(viewer, buffer)
  if not info or not info.filename then return nil end
  local selected = adapter.selected(viewer)
  local artifact = selected and M.artifact(selected.sha)
  if not artifact then return nil end
  local rows = buffer_rows(viewer, artifact, buffer, info.filename, info.role == "cell" and info.first_line or nil)
  local hit = rows[row0]
  return hit and hit.segment or nil
end

return M
