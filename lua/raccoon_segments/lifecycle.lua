-- Tracks the active raccoon commit viewer and keeps decorations current.
local adapter = require("raccoon_segments.host.raccoon")
local decorate = require("raccoon_segments.decorate")
local palette = require("raccoon_segments.palette")
local queue = require("raccoon_segments.queue")

local M = {}

local POLL_INTERVAL_MS = 150
local timer
local augroup
local running = false
local diagnostics = "warn"
local diagnosed = {}
local last_generation
local config

local function notify_once(message)
  if diagnostics == "silent" or diagnosed[message] then return end
  diagnosed[message] = true
  local level = diagnostics == "error" and vim.log.levels.ERROR or vim.log.levels.WARN
  vim.notify("raccoon-segments: " .. message, level)
end

---@return table|nil viewer
function M.viewer()
  local ok, viewer, issue = pcall(adapter.viewer)
  if not ok then
    notify_once("host adapter failed: " .. tostring(viewer))
    return nil
  end
  if issue then notify_once(issue) end
  return viewer
end

function M.scan()
  if not running then return end
  local viewer = M.viewer()
  decorate.set_viewer(viewer)
  local generation = viewer and adapter.generation(viewer) or nil
  if generation ~= last_generation then
    last_generation = generation
    decorate.redraw()
  end
end

function M.start(resolved)
  M.stop()
  config = resolved
  diagnostics = resolved.diagnostics
  local compatible, err = adapter.check_compatibility()
  if not compatible then
    notify_once(err)
    return false
  end
  running = true
  palette.setup_highlights(#palette.HUES, resolved.colors)
  decorate.start(resolved.keys)
  decorate.set_overlay(resolved.overlay)
  if not M._listening then
    M._listening = true
    queue.on_change(function()
      decorate.invalidate()
    end)
  end
  augroup = vim.api.nvim_create_augroup("RaccoonSegmentsLifecycle", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TextChanged" }, {
    group = augroup,
    callback = function() vim.schedule(M.scan) end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      palette.setup_highlights(#palette.HUES, config and config.colors)
      decorate.redraw()
    end,
  })
  timer = vim.uv.new_timer()
  if timer then timer:start(POLL_INTERVAL_MS, POLL_INTERVAL_MS, vim.schedule_wrap(M.scan)) end
  vim.schedule(M.scan)
  return true
end

function M.stop()
  running = false
  if timer then
    pcall(timer.stop, timer)
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  decorate.stop()
  last_generation = nil
end

function M.is_running()
  return running
end

return M
