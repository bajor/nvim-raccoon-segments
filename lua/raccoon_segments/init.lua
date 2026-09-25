local config = require("raccoon_segments.config")

local M = {}

M.setup_done = false
local resolved
local keymaps_set = {}

local function notify(message, level)
  vim.notify("raccoon-segments: " .. message, level or vim.log.levels.INFO)
end

local function viewer_or_notify()
  local viewer = require("raccoon_segments.lifecycle").viewer()
  if not viewer then
    notify("available only in a raccoon commit viewer (:Raccoon commits / :Raccoon local)", vim.log.levels.WARN)
    return nil
  end
  return viewer
end

local function template_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))), "templates", "SEGMENTS.md")
end

---@return string|nil
function M.load_instructions()
  local file = io.open(resolved.instructions_path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function ensure_instructions_file()
  local path = resolved.instructions_path
  if vim.fn.filereadable(path) == 1 then return path end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local template = io.open(template_path(), "rb")
  local content = template and template:read("*a") or "# Instructions for nvim-raccoon-segments\n"
  if template then template:close() end
  local out = assert(io.open(path, "wb"))
  out:write(content)
  out:close()
  return path
end

local function open_file_float(path, opts)
  opts = opts or {}
  local adapter = require("raccoon_segments.host.raccoon")
  local viewer = require("raccoon_segments.lifecycle").viewer()
  local width = math.max(40, math.min(100, math.floor(vim.o.columns * 0.8)))
  local height = math.max(10, math.floor(vim.o.lines * 0.8))
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or vim.fs.basename(path)) .. " ",
    title_pos = "center",
    footer = opts.readonly and " q close " or " :w save · q close ",
    footer_pos = "center",
    zindex = 60,
  })
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  if opts.readonly then vim.bo[buf].modifiable = false end
  if opts.filetype then vim.bo[buf].filetype = opts.filetype end
  -- Register before entering so raccoon's focus lock leaves the float alone.
  if viewer then adapter.set_popup_win(viewer, win) end
  vim.api.nvim_set_current_win(win)
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      if vim.bo[buf].modified and not opts.readonly then
        notify("save or discard the buffer first (:w / :q!)", vim.log.levels.WARN)
        return
      end
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if viewer then adapter.clear_popup_win(viewer) end
    end,
  })
  return win
end

-- Targets ---------------------------------------------------------------------

---Commits to generate for the active viewer, oldest first, plus the full
---sequence used as prompt context.
---@param viewer table
---@return table[] targets, table[] all_commits
function M.targets(viewer)
  local adapter = require("raccoon_segments.host.raccoon")
  local commits, _, split = adapter.commits(viewer)
  local first = {}
  for _, commit in ipairs(commits) do
    if commit.section == 1 and commit.sha then first[#first + 1] = commit end
  end
  if viewer.kind == "local" and not split then
    local recent = {}
    for index = 1, math.min(#first, resolved.local_recent_commits) do recent[index] = first[index] end
    first = recent
  end
  local oldest_first = {}
  for index = #first, 1, -1 do
    oldest_first[#oldest_first + 1] = { sha = first[index].sha, message = first[index].message }
  end
  return oldest_first, oldest_first
end

local function submit(mode)
  local viewer = viewer_or_notify()
  if not viewer then return end
  local adapter = require("raccoon_segments.host.raccoon")
  local queue = require("raccoon_segments.queue")
  local targets, all = M.targets(viewer)
  if #targets == 0 then
    notify("no commits to explain in this view", vim.log.levels.WARN)
    return
  end
  if mode == "regenerate" then
    local answer = vim.fn.confirm(
      ("Delete and regenerate explanations for %d commit%s?"):format(#targets, #targets == 1 and "" or "s"),
      "&Yes\n&No", 2)
    if answer ~= 1 then return end
  end
  queue.submit({
    targets = targets,
    all_commits = all,
    repo_path = viewer.repo_path,
    source = adapter.source(viewer),
    mode = mode,
  })
end

-- Commands --------------------------------------------------------------------

function M.generate()
  submit("append")
end

function M.regenerate()
  submit("regenerate")
end

function M.toggle()
  local decorate = require("raccoon_segments.decorate")
  decorate.set_overlay(not decorate.overlay())
  notify("segment overlay " .. (decorate.overlay() and "on" or "off"))
end

function M.explain()
  local explain = require("raccoon_segments.explain")
  if explain.is_open() then
    explain.close()
    return
  end
  local viewer = viewer_or_notify()
  if not viewer then return end
  local adapter = require("raccoon_segments.host.raccoon")
  local decorate = require("raccoon_segments.decorate")
  local selected = adapter.selected(viewer)
  if not selected or not selected.sha then
    notify("select a commit first (\"Current changes\" is not a commit)", vim.log.levels.INFO)
    return
  end
  local buffer = vim.api.nvim_get_current_buf()
  local info = adapter.classify(viewer, buffer)
  local focus
  if info and info.role == "filetree" then
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local path = adapter.filetree_paths(viewer)[row]
    local artifact = path and decorate.artifact(selected.sha)
    if artifact then
      for _, segment in ipairs(artifact.segments) do
        for _, file in ipairs(segment.files or {}) do
          if file.file == path and not focus then focus = segment end
        end
      end
    end
  elseif info and info.filename then
    focus = decorate.segment_at(viewer, buffer, vim.api.nvim_win_get_cursor(0)[1] - 1)
  end
  explain.show(viewer, selected, focus)
end

function M.cancel()
  local count = require("raccoon_segments.queue").cancel()
  notify(count == 0 and "nothing running" or ("cancelled " .. count .. " job(s)"))
end

local function elapsed(entry)
  if not entry.started_at then return "" end
  local stop = entry.finished_at or vim.uv.now()
  return (" %ds"):format(math.floor((stop - entry.started_at) / 1000))
end

function M.status()
  local queue = require("raccoon_segments.queue")
  local backends = require("raccoon_segments.backends")
  local status = queue.status()
  local lines = {
    ("backend: %s%s"):format(backends.name(resolved.backend), resolved.model and (" (" .. resolved.model .. ")") or ""),
    ("store: %s"):format(require("raccoon_segments.store").root()),
    ("running %d · queued %d · done %d · failed %d · skipped %d"):format(
      status.running, status.queued, status.done, status.failed, status.skipped),
    "",
  }
  if #status.entries == 0 then lines[#lines + 1] = "no jobs in this session" end
  for _, entry in ipairs(status.entries) do
    local detail = ""
    if entry.status == "running" then detail = " · " .. (entry.phase or "") .. elapsed(entry) end
    if entry.status == "done" and entry.segments then
      detail = (" · %d segments"):format(entry.segments) .. elapsed(entry)
    end
    if entry.status == "failed" then detail = " · " .. tostring(entry.error) end
    if entry.status == "skipped" then detail = (" · %d changed lines"):format(entry.changed or 0) end
    lines[#lines + 1] = ("%-9s %s %s%s"):format(entry.status, entry.sha:sub(1, 7), entry.subject or "", detail)
  end
  local artifact_warnings = {}
  local viewer = require("raccoon_segments.lifecycle").viewer()
  if viewer then
    local selected = require("raccoon_segments.host.raccoon").selected(viewer)
    local artifact = selected and selected.sha and require("raccoon_segments.decorate").artifact(selected.sha)
    if artifact and artifact.warnings and #artifact.warnings > 0 then
      artifact_warnings[#artifact_warnings + 1] = ""
      artifact_warnings[#artifact_warnings + 1] = "warnings for " .. selected.sha:sub(1, 7) .. ":"
      for _, warning in ipairs(artifact.warnings) do artifact_warnings[#artifact_warnings + 1] = "  " .. warning end
    end
  end
  for _, line in ipairs(artifact_warnings) do lines[#lines + 1] = line end
  local tmp = vim.fn.tempname() .. "-raccoon-segments-status.txt"
  local file = assert(io.open(tmp, "wb"))
  file:write(table.concat(lines, "\n"), "\n")
  file:close()
  open_file_float(tmp, { title = "raccoon-segments status", readonly = true })
end

local function selected_sha()
  local viewer = require("raccoon_segments.lifecycle").viewer()
  if not viewer then return nil end
  local selected = require("raccoon_segments.host.raccoon").selected(viewer)
  return selected and selected.sha or nil
end

function M.log()
  local store = require("raccoon_segments.store")
  local sha = selected_sha()
  local dir = sha and store.commit_dir(sha) or store.root()
  if vim.fn.isdirectory(dir) == 0 then
    notify("no job directory yet for this commit (" .. dir .. ")", vim.log.levels.INFO)
    return
  end
  notify("job directory: " .. dir)
  pcall(vim.ui.open, dir)
end

function M.instructions()
  open_file_float(ensure_instructions_file(), { title = "SEGMENTS.md", filetype = "markdown" })
end

function M.prompt()
  local store = require("raccoon_segments.store")
  local sha = selected_sha()
  local path = sha and store.file_if_exists(sha, "prompt.md")
  if not path then
    notify("no prompt has been sent for the selected commit", vim.log.levels.INFO)
    return
  end
  open_file_float(path, { title = "prompt for " .. sha:sub(1, 7), readonly = true, filetype = "markdown" })
end

M.commands = {
  explain = M.explain,
  toggle = M.toggle,
  generate = M.generate,
  regenerate = M.regenerate,
  cancel = M.cancel,
  status = M.status,
  log = M.log,
  instructions = M.instructions,
  prompt = M.prompt,
}

function M.command_names()
  local names = {}
  for name in pairs(M.commands) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- Setup -----------------------------------------------------------------------

local function clear_keymaps()
  for _, lhs in ipairs(keymaps_set) do pcall(vim.keymap.del, "n", lhs) end
  keymaps_set = {}
end

local function set_keymaps(keys)
  clear_keymaps()
  local descriptions = {
    explain = "Raccoon: segments explain commit",
    toggle = "Raccoon: segments toggle overlay",
    generate = "Raccoon: segments generate (append)",
    regenerate = "Raccoon: segments regenerate (hard reset)",
  }
  for name, lhs in pairs(keys) do
    if lhs then
      vim.keymap.set("n", lhs, M.commands[name], { desc = descriptions[name], silent = true })
      keymaps_set[#keymaps_set + 1] = lhs
    end
  end
end

---@param options? table
function M.setup(options)
  resolved = config.resolve(options)
  M.config = resolved
  require("raccoon_segments.store").configure(resolved.data_dir)
  require("raccoon_segments.queue").configure(resolved, M.load_instructions)
  require("raccoon_segments.explain").config = resolved
  require("raccoon_segments.explain").keys = resolved.keys
  set_keymaps(resolved.keys)
  M.setup_done = require("raccoon_segments.lifecycle").start(resolved)
  return M.setup_done
end

function M.disable()
  clear_keymaps()
  require("raccoon_segments.lifecycle").stop()
  M.setup_done = false
end

function M.refresh()
  require("raccoon_segments.decorate").invalidate()
  require("raccoon_segments.lifecycle").scan()
end

return M
