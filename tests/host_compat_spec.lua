-- Runs against a pinned nvim-raccoon checkout (see Makefile) inside the UI
-- child: real commit viewers, real layouts, real extmarks.
package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local h = require("tests.helpers")
local support = require("tests.support")

assert(pcall(require, "raccoon"), "host plugin raccoon must be on the runtimepath")
local raccoon_state = require("raccoon.state")
local commits = require("raccoon.commits")
local localcommits = require("raccoon.localcommits")

vim.g.mapleader = " "
vim.o.termguicolors = true
pcall(require("raccoon").setup)

local adapter = require("raccoon_segments.host.raccoon")
local decorate = require("raccoon_segments.decorate")
local explain = require("raccoon_segments.explain")
local lifecycle = require("raccoon_segments.lifecycle")
local queue = require("raccoon_segments.queue")
local segments = require("raccoon_segments")
local store = require("raccoon_segments.store")

local log_dir = support.install_fake_backends("host")
local data_dir = support.tempdir("host-store")

-- Repositories: a bare origin with main + feat, a raccoon-style shallow clone
-- of feat, and a plain working repository on feat for the local viewer.
local origin = support.tempdir("origin")
support.git(origin, { "init", "-q", "--bare", "-b", "main", "." })
local work = support.tempdir("work")
local main_shas = support.make_repo(work, {
  { message = "Initial commit", files = { ["src/app.lua"] = "local M = {}\nreturn M\n", ["README.md"] = "# demo\n" } },
  { message = "Second on main", files = { ["README.md"] = "# demo\n\nmore\n" } },
})
support.git(work, { "remote", "add", "origin", origin })
support.git(work, { "push", "-q", "origin", "main" })
support.git(work, { "checkout", "-q", "-b", "feat" })
support.write_file(vim.fs.joinpath(work, "src/app.lua"), "local M = {}\nlocal RETRIES = 3\nfunction M.run()\n"
  .. "  for _ = 1, RETRIES do\n    if pcall(M.attempt) then return true end\n  end\n  return false\nend\n"
  .. "function M.attempt()\n  return 1\nend\nreturn M\n")
support.write_file(vim.fs.joinpath(work, "tests/app_spec.lua"), "describe('run', function() end)\n")
support.git(work, { "add", "-A" })
support.git(work, { "commit", "-q", "-m", "Add retry logic" })
local feat1 = support.git(work, { "rev-parse", "HEAD" })
support.write_file(vim.fs.joinpath(work, "src/app.lua"), "local M = {}\nlocal RETRIES = 5\nfunction M.run()\n"
  .. "  for _ = 1, RETRIES do\n    if pcall(M.attempt) then return true end\n  end\n  return false\nend\n"
  .. "function M.attempt()\n  return 2\nend\nreturn M\n")
support.git(work, { "add", "-A" })
support.git(work, { "commit", "-q", "-m", "Bump retries" })
local feat2 = support.git(work, { "rev-parse", "HEAD" })
support.git(work, { "push", "-q", "origin", "feat" })

local clone = vim.fn.tempname() .. "-clone"
support.git(".", { "clone", "-q", "--depth", "1", "--branch", "feat", origin, clone })

-- Text of buffer row `row` (0-based) as shown on screen; raccoon's windows
-- carry a winbar, which occupies the first screen row of the window.
local function screen_row_text(win, row)
  local pos = vim.fn.win_screenpos(win)
  local width = vim.api.nvim_win_get_width(win)
  local offset = vim.wo[win].winbar ~= "" and 1 or 0
  local chars = {}
  for col = pos[2], pos[2] + width - 1 do chars[#chars + 1] = vim.fn.screenstring(pos[1] + row + offset, col) end
  return table.concat(chars)
end

-- Runs `body`, then `cleanup` even when the body fails, so a failed test can
-- never leave a raccoon viewer open for the next one (two live focus locks
-- fight over the cursor forever).
local function guarded(body, cleanup)
  local ok, err = xpcall(body, debug.traceback)
  pcall(cleanup)
  if not ok then error(err, 0) end
end

local function wait_viewer(module, min_hunks)
  support.wait_for(function()
    local state = module._get_state()
    return state.active and state.grid_bufs and #state.grid_bufs > 0 and #(state.all_hunks or {}) >= (min_hunks or 1)
  end, 30000, "commit viewer did not load")
  vim.wait(200)
end

h.test("plugin setup registers keys that raccoon does not shadow", function()
  h.truthy(segments.setup({ data_dir = data_dir, images = false, rasterizer = false, min_changed_lines = 0 }))
  local map = vim.fn.maparg("<leader>ve", "n", false, true)
  h.matches(map.desc or "", "^Raccoon:")
  h.truthy(vim.fn.exists(":RaccoonSegments") == 2)
end)

h.test("PR commit viewer: adapter, sidebar rows, cells, generation, decorations, popup", function()
 guarded(function()
  raccoon_state.start({
    owner = "bajor", repo = "demo", number = 1, url = "https://github.com/bajor/demo/pull/1",
    github_host = "github.com", clone_path = clone,
  })
  raccoon_state.set_pr({
    number = 1, title = "Retry logic", body = "Adds retries.",
    base = { ref = "main", sha = main_shas[2] }, head = { ref = "feat", sha = feat2 },
  })
  raccoon_state.set_files({})
  commits.toggle()
  wait_viewer(commits)
  lifecycle.scan()

  local viewer, issue = adapter.viewer()
  h.equal(issue, nil)
  h.equal(viewer.kind, "pr")
  h.equal(viewer.repo_path, clone)
  local list, section1, split = adapter.commits(viewer)
  h.equal(section1, 2)
  h.truthy(split)
  h.equal(list[1].sha, feat2)
  h.equal(list[2].sha, feat1)
  h.truthy(#list > 2, "base commits follow")
  h.falsy(list[3].target)
  local state = viewer.state
  for _, commit in ipairs(list) do
    local row = adapter.sidebar_row(commit.index, section1, split)
    local line = vim.api.nvim_buf_get_lines(state.sidebar_buf, row, row + 1, false)[1] or ""
    h.truthy(line:find(commit.message, 1, true), "sidebar row " .. row .. " holds " .. commit.message)
  end
  h.equal(adapter.selected(viewer).sha, feat2)
  local source = adapter.source(viewer)
  h.equal(source.kind, "pr")
  h.equal(source.title, "Retry logic")
  h.equal(source.base_ref, "main")

  local info = adapter.classify(viewer, state.grid_bufs[1])
  h.equal(info.role, "cell")
  h.equal(info.filename, "src/app.lua")
  h.equal(adapter.classify(viewer, state.sidebar_buf).role, "sidebar")
  h.equal(adapter.classify(viewer, state.filetree_buf).role, "filetree")
  h.equal(adapter.classify(viewer, state.header_buf).role, "header")
  local records = adapter.typed_records(state.grid_bufs[1], viewer.namespace)
  local kinds = {}
  for _, record in ipairs(records) do kinds[record.kind] = true end
  h.truthy(kinds.addition and kinds.deletion, "raccoon extmarks typed as additions and deletions")
  h.truthy(adapter.filetree_paths(viewer)[0] ~= nil or next(adapter.filetree_paths(viewer)) ~= nil)

  -- Generate through the real queue and fake opencode, then look at the screen.
  local targets, all = segments.targets(viewer)
  h.equal(#targets, 2)
  h.equal(targets[1].sha, feat1, "oldest first")
  queue.submit({ targets = targets, all_commits = all, repo_path = viewer.repo_path, source = source, mode = "append" })
  support.wait_for(function() return not queue.is_busy() end, 60000, "generation did not finish")
  h.truthy(store.has(feat1))
  h.truthy(store.has(feat2))
  h.equal(support.fake_calls(log_dir), 2)
  local prompt = support.read_file(store.path(feat2, "prompt.md"))
  h.matches(prompt, "Pull request #1 in bajor/demo: Retry logic")
  h.matches(prompt, "Add retry logic")
  h.matches(prompt, "Bump retries <== THIS COMMIT")

  vim.cmd("redraw!")
  local sidebar_row_1 = screen_row_text(state.sidebar_win, 1)
  h.matches(sidebar_row_1, "●")
  local cell_win = state.grid_wins[1]
  local badge_seen = false
  for row = 0, vim.api.nvim_win_get_height(cell_win) - 1 do
    if screen_row_text(cell_win, row):find("①", 1, true) then badge_seen = true end
  end
  h.truthy(badge_seen, "segment badge drawn in a real grid cell")
  local tree_dots = false
  for row = 0, vim.api.nvim_win_get_height(state.filetree_win) - 1 do
    if screen_row_text(state.filetree_win, row):find("●", 1, true) then tree_dots = true end
  end
  h.truthy(tree_dots, "file tree dots drawn")
  h.matches(screen_row_text(state.header_win, 0), "segment")

  -- Popup registers with raccoon's focus lock and closes cleanly.
  segments.explain()
  h.truthy(explain.is_open())
  h.truthy(state.popup_win ~= nil and vim.api.nvim_win_is_valid(state.popup_win))
  local popup_buf = vim.api.nvim_win_get_buf(state.popup_win)
  h.matches(table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), "\n"), "Overview")
  h.equal(vim.api.nvim_get_current_win(), state.popup_win, "popup keeps focus despite raccoon's focus lock")
  vim.wait(100)
  h.equal(vim.api.nvim_get_current_win(), state.popup_win, "popup still focused after scheduled refocus")
  segments.explain()
  h.falsy(explain.is_open())
  h.equal(state.popup_win, nil)

  commits.toggle()
  vim.wait(200)
  lifecycle.scan()
  h.equal(adapter.viewer(), nil)
  raccoon_state.stop()
 end, function()
  if explain.is_open() then explain.close() end
  if commits._get_state().active then commits.toggle() end
  vim.wait(200)
  raccoon_state.stop()
 end)
end)

h.test("local commit viewer: branch mode shares artifacts by sha, history mode limits targets", function()
 local original_cwd = vim.fn.getcwd()
 guarded(function()
  vim.cmd("cd " .. vim.fn.fnameescape(work))
  localcommits.toggle()
  wait_viewer(localcommits, 0)
  support.wait_for(function() return localcommits._get_state().base_branch ~= nil end, 20000, "branch mode")
  lifecycle.scan()
  local viewer = adapter.viewer()
  h.equal(viewer.kind, "local")
  h.equal(viewer.repo_path, work)
  local list, section1, split = adapter.commits(viewer)
  h.truthy(split)
  h.equal(section1, 3)
  h.equal(list[1].sha, nil)
  h.falsy(list[1].target)
  h.equal(list[2].sha, feat2)
  local targets = segments.targets(viewer)
  h.equal(#targets, 2)
  h.equal(targets[1].sha, feat1)
  local state = viewer.state
  for _, commit in ipairs(list) do
    local row = adapter.sidebar_row(commit.index, section1, split)
    local line = vim.api.nvim_buf_get_lines(state.sidebar_buf, row, row + 1, false)[1] or ""
    h.truthy(line:find(commit.message, 1, true), "sidebar row " .. row .. " holds " .. commit.message)
  end
  h.equal(adapter.source(viewer).branch, "feat")
  h.equal(adapter.source(viewer).base_branch, "main")

  -- Artifacts generated in the PR viewer are found by sha here.
  h.truthy(decorate.artifact(feat2))
  vim.cmd("redraw!")
  h.matches(screen_row_text(state.sidebar_win, 2), "●")
  h.falsy(screen_row_text(state.sidebar_win, 1):find("●", 1, true), "Current changes has no marks")
  localcommits.toggle()
  vim.wait(200)

  -- History mode on main: no split, recent-commit limit applies.
  support.git(work, { "checkout", "-q", "main" })
  segments.setup({ data_dir = data_dir, images = false, rasterizer = false, local_recent_commits = 1 })
  localcommits.toggle()
  wait_viewer(localcommits, 0)
  support.wait_for(function() return #localcommits._get_state().branch_commits >= 3 end, 20000, "history mode")
  lifecycle.scan()
  local hviewer = adapter.viewer()
  local hlist, hsection1, hsplit = adapter.commits(hviewer)
  h.falsy(hsplit)
  h.equal(hsection1, 3)
  h.equal(hlist[2].sha, main_shas[2])
  h.equal(adapter.sidebar_row(2, hsection1, hsplit), 2)
  local hstate = hviewer.state
  local line = vim.api.nvim_buf_get_lines(hstate.sidebar_buf, 2, 3, false)[1] or ""
  h.truthy(line:find("Second on main", 1, true))
  local htargets = segments.targets(hviewer)
  h.equal(#htargets, 1)
  h.equal(htargets[1].sha, main_shas[2])
  localcommits.toggle()
  vim.wait(200)
  h.equal(adapter.viewer(), nil)
 end, function()
  if localcommits._get_state().active then localcommits.toggle() end
  vim.wait(200)
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
 end)
end)

return h.run()
