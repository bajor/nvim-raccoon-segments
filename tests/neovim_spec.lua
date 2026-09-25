
local h = require("tests.helpers")
local support = require("tests.support")
local config = require("raccoon_segments.config")
local protocol = require("raccoon_segments.protocol")
local store = require("raccoon_segments.store")
local backends = require("raccoon_segments.backends")
local palette = require("raccoon_segments.palette")
local adapter = require("raccoon_segments.host.raccoon")
local decorate = require("raccoon_segments.decorate")
local lifecycle = require("raccoon_segments.lifecycle")
local explain = require("raccoon_segments.explain")
local kitty = require("raccoon_segments.kitty")
local queue = require("raccoon_segments.queue")

package.preload["raccoon"] = package.preload["raccoon"] or function() return {} end
vim.o.termguicolors = true

local BLOCKS = {
  { id = "c1", file = "src/a.lua", dels = { "old" }, adds = { "new" }, anchor = 1 },
  { id = "c2", file = "src/a.lua", dels = {}, adds = { "added" }, anchor = 10 },
  { id = "c3", file = "src/b.lua", dels = { "gone" }, adds = {}, anchor = 3 },
}

h.test("config resolves defaults and rejects bad options", function()
  local resolved = config.resolve()
  h.equal(resolved.backend, "opencode")
  h.equal(resolved.min_changed_lines, 10)
  h.equal(resolved.keys.explain, "<leader>ve")
  h.truthy(resolved.instructions_path:match("SEGMENTS%.md$"))
  h.equal(config.resolve({ keys = { explain = false } }).keys.explain, false)
  h.equal(config.resolve({ backend = "claude", model = "opus" }).model, "opus")
  h.equal(config.resolve({ backend = { cmd = { "my-agent" } } }).backend.cmd[1], "my-agent")
  h.raises(function() config.resolve({ nope = 1 }) end, "unknown raccoon%-segments option nope")
  h.raises(function() config.resolve({ backend = "gemini" }) end, "backend must be")
  h.raises(function() config.resolve({ min_changed_lines = -1 }) end, "non%-negative integer")
  h.raises(function() config.resolve({ keys = { fly = "x" } }) end, "unknown key name")
  h.raises(function() config.resolve({ images = true }) end, "images must be auto or false")
  h.raises(function() config.resolve({ colors = { "red" } }) end, "#rrggbb")
  h.raises(function() config.resolve({ backend = { cmd = "x" } }) end, "custom backend needs cmd")
end)

h.test("protocol extracts the last block, ignores noise and fences", function()
  local raw = "junk <segments>{\"overview\":\"first\"}</segments>\nmore\n"
    .. "<segments>\n```json\n{\"overview\":\"second\",\"segments\":[]}\n```\n</segments>\n"
    .. "<visual segment=\"1\">\n```svg\n<svg viewBox=\"0 0 960 300\"></svg>\n```\n</visual>trailing"
  local extracted = protocol.extract(raw)
  h.equal(extracted.json, '{"overview":"second","segments":[]}')
  h.equal(extracted.visuals[1], '<svg viewBox="0 0 960 300"></svg>')
  h.equal(protocol.extract("no tags here"), nil)
end)

h.test("protocol normalizes ids: unknown, duplicate, missing, dropped segments", function()
  local data = {
    overview = "ov",
    segments = {
      { title = "One", changes = { "c1", "c9", "c1" }, explanation = "e", review_focus = { "r1", 2 } },
      { title = "", changes = { "c1", "c2" } },
      { title = "Empty", changes = {} },
    },
  }
  local four = vim.deepcopy(BLOCKS)
  four[4] = { id = "c4", file = "src/c.lua", dels = {}, adds = { "x" }, anchor = 1 }
  data.segments[2].changes[3] = "c4"
  local result, errors, warnings = protocol.normalize(data, four)
  h.equal(#errors, 0)
  h.truthy(result)
  h.equal(#result.segments, 2)
  h.deep_equal(result.segments[1].changes, { "c1" })
  h.deep_equal(result.segments[1].review_focus, { "r1", "2" })
  h.equal(result.segments[2].title, "Segment 2")
  h.deep_equal(result.segments[2].changes, { "c2", "c4" })
  h.deep_equal(result.unassigned, { "c3" })
  local joined = table.concat(warnings, "\n")
  h.matches(joined, "unknown change id c9")
  h.matches(joined, "already assigned")
  h.matches(joined, "missing title")
  h.matches(joined, "no valid changes; dropped")
  h.matches(joined, "unassigned change ids: c3")

  local _, errs = protocol.normalize({ overview = "x", segments = { { title = "t", changes = { "c1" } } } }, BLOCKS)
  h.matches(table.concat(errs, "\n"), "2 of 3 change ids were not assigned")
  local _, errs2 = protocol.normalize({ segments = {} }, BLOCKS)
  h.matches(table.concat(errs2, "\n"), "overview is missing")
  h.matches(table.concat(errs2, "\n"), "non%-empty array")
  local _, errs3 = protocol.normalize("nope", BLOCKS)
  h.matches(errs3[1], "must be an object")
end)

h.test("protocol sanitizes svg and parse attaches visuals", function()
  local dirty = 'text <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 300" onload="x()">'
    .. '<script>bad()</script><image href="http://x/y.png"/><a href="https://evil"><text>t</text></a>'
    .. '<use href="#local"/><style>@import url(http://x); .a{fill:url(http://x)}</style>'
    .. "<foreignObject><div/></foreignObject></svg> tail"
  local clean = protocol.sanitize_svg(dirty)
  h.falsy(clean:find("script", 1, true))
  h.falsy(clean:find("onload", 1, true))
  h.falsy(clean:find("<image", 1, true))
  h.falsy(clean:find("https://evil", 1, true))
  h.truthy(clean:find('href="#local"', 1, true))
  h.falsy(clean:find("@import", 1, true))
  h.falsy(clean:find("url(http", 1, true))
  h.falsy(clean:find("foreignObject", 1, true))
  h.matches(clean, "^<svg")
  h.matches(clean, "</svg>$")
  h.equal(protocol.sanitize_svg("<div>nope</div>"), nil)
  h.matches(protocol.sanitize_svg('<svg viewBox="0 0 1 1"></svg>'), '^<svg xmlns="http://www.w3.org/2000/svg"')

  local raw = '<segments>{"overview":"o","segments":[{"title":"A","changes":["c1","c2","c3"]}]}</segments>'
    .. '<visual segment="1"><svg viewBox="0 0 960 300"><script>x</script></svg></visual>'
  local result, errors = protocol.parse(raw, BLOCKS)
  h.equal(#errors, 0)
  h.matches(result.segments[1].svg, "^<svg")
  h.falsy(result.segments[1].svg:find("script", 1, true))
  local _, bad = protocol.parse("<segments>{not json</segments>", BLOCKS)
  h.matches(bad[1], "JSON in <segments> is invalid")
end)

h.test("store round-trips artifacts atomically", function()
  local dir = support.tempdir("store")
  store.configure(dir)
  local sha = string.rep("a", 40)
  h.falsy(store.has(sha))
  h.truthy(store.save(sha, { overview = "x", segments = {}, dir = "ignored" }))
  h.truthy(store.has(sha))
  local loaded = store.load(sha)
  h.equal(loaded.overview, "x")
  h.equal(loaded.version, store.VERSION)
  h.equal(loaded.dir, store.commit_dir(sha))
  h.equal(#vim.fn.glob(store.commit_dir(sha) .. "/*.tmp.*", false, true), 0)
  support.write_file(store.path(sha, "artifact.json"), "{corrupt")
  local _, err = store.load(sha)
  h.matches(err, "corrupt")
  store.delete(sha)
  h.falsy(store.has(sha))
  h.raises(function() store.commit_dir("../x") end, "invalid sha")
end)

h.test("backends build read-only command lines for every preset", function()
  local ctx = { prompt = "P", model = "m", extra_args = { "--x" }, output_path = function(n) return "/tmp/" .. n end }
  local oc = backends.build("opencode", ctx)
  h.deep_equal(oc.cmd, { "opencode", "run", "--agent", "raccoon-segments", "--model", "m", "--x" })
  h.equal(oc.stdin, "P")
  h.equal(oc.env.OPENCODE_DISABLE_PROJECT_CONFIG, "1")
  h.matches(oc.env.OPENCODE_CONFIG_CONTENT, '"edit":"deny"')
  h.matches(oc.env.OPENCODE_CONFIG_CONTENT, '"bash":"deny"')
  local cl = backends.build("claude", { prompt = "P", extra_args = {}, output_path = ctx.output_path })
  h.equal(cl.cmd[1], "claude")
  h.truthy(vim.tbl_contains(cl.cmd, "--tools"))
  h.truthy(vim.tbl_contains(cl.cmd, "Read,Grep,Glob"))
  h.truthy(vim.tbl_contains(cl.cmd, "json"))
  h.equal(cl.decode, "claude_json")
  h.equal(backends.final_text(cl, '{"result":"hi","is_error":false}'), "hi")
  h.equal(backends.final_text(cl, "not json"), nil)
  h.equal(backends.final_text(cl, '{"is_error":true,"result":"boom"}'), nil)
  -- `claude -p --output-format json` emits the whole stream as an array; the
  -- text lives in the result event, which is not always the last one.
  h.equal(backends.final_text(cl, '[{"type":"system","subtype":"init"},' ..
    '{"type":"rate_limit_event"},{"type":"assistant"},' ..
    '{"type":"result","subtype":"success","is_error":false,"result":"hi"}]'), "hi")
  h.equal(backends.final_text(cl,
    '[{"type":"result","subtype":"error","is_error":true,"result":"boom"}]'), nil)
  h.equal(backends.final_text(cl, '[{"type":"system"},{"type":"assistant"}]'), nil)
  local cx = backends.build("codex", ctx)
  h.equal(cx.cmd[1], "codex")
  h.truthy(vim.tbl_contains(cx.cmd, "read-only"))
  h.equal(cx.cmd[#cx.cmd], "-")
  h.equal(cx.output, "file")
  h.equal(cx.output_file, "/tmp/codex-last-message.txt")
  local custom = backends.build({ cmd = { "agent", "--out", "{output}" }, output = "file" }, ctx)
  h.equal(custom.cmd[3], "/tmp/custom-output.txt")
  local fn = backends.build(function(c) return { cmd = { "x", c.model }, output = "stdout" } end, ctx)
  h.equal(fn.cmd[2], "m")
  h.equal(backends.name("codex"), "codex")
  h.equal(backends.name({ cmd = { "agent" } }), "agent")
end)

-- Fake raccoon commit viewer ---------------------------------------------------

local fake = {}

local function fake_viewer(kind)
  local ns_name = kind == "pr" and "raccoon_commits" or "raccoon_local_commits"
  local ns = vim.api.nvim_create_namespace(ns_name)
  local function scratch(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end
  local sha1, sha2 = string.rep("1", 40), string.rep("2", 40)
  local state = {
    active = true,
    selected_index = 1,
    select_generation = 1,
    current_page = 1,
    grid_rows = 1,
    grid_cols = 2,
    all_hunks = {
      { filename = "src/a.lua", hunk = { start_line = 1, lines = {} } },
      { filename = "src/b.lua", hunk = { start_line = 2, lines = {} } },
    },
    commit_files = { ["src/a.lua"] = true, ["src/b.lua"] = true },
    cached_line_paths = { [1] = "src/a.lua", [2] = "src/b.lua", [3] = "README.md" },
    popup_win = nil,
    repo_path = "/tmp/fake-repo",
  }
  if kind == "pr" then
    state.pr_commits = { { sha = sha1, message = "feat: thing" }, { sha = sha2, message = "fix: other" } }
    state.base_commits = { { sha = string.rep("3", 40), message = "base commit" } }
  else
    state.branch_commits = { { sha = nil, message = "Current changes" }, { sha = sha1, message = "feat: thing" },
      { sha = sha2, message = "fix: other" } }
    state.base_commits = { { sha = string.rep("3", 40), message = "base commit" } }
    state.base_branch = "main"
    state.current_branch = "feat"
  end
  state.sidebar_buf = scratch({ "── PR Branch ──", "  feat: thing", "  fix: other", "", "── Base ──", "  base commit" })
  if kind == "local" then
    vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false,
      { "── feat ──", "  Current changes", "  feat: thing", "  fix: other", "", "── main ──", "  base commit" })
  end
  state.header_buf = scratch({ " 1/1 feat: thing" })
  state.filetree_buf = scratch({ "src", "├ a.lua", "└ b.lua", "README.md" })
  state.grid_bufs = {
    scratch({ "ctx", "old", "new", "ctx2", "added" }),
    scratch({ "x", "y", "gone", "z" }),
  }
  vim.api.nvim_buf_set_extmark(state.grid_bufs[1], ns, 1, 0, { line_hl_group = "RaccoonDelete", sign_text = "-" })
  vim.api.nvim_buf_set_extmark(state.grid_bufs[1], ns, 2, 0, { line_hl_group = "RaccoonAdd", sign_text = "+" })
  vim.api.nvim_buf_set_extmark(state.grid_bufs[1], ns, 4, 0, { line_hl_group = "RaccoonAdd", sign_text = "+" })
  vim.api.nvim_buf_set_extmark(state.grid_bufs[2], ns, 2, 0, { line_hl_group = "RaccoonDelete", sign_text = "-" })
  local module = {
    _get_state = function() return state end,
    set_popup_win = function(win) state.popup_win = win; fake.popup_calls = (fake.popup_calls or 0) + 1 end,
    clear_popup_win = function() state.popup_win = nil; fake.clear_calls = (fake.clear_calls or 0) + 1 end,
  }
  package.loaded[kind == "pr" and "raccoon.commits" or "raccoon.localcommits"] = module
  if kind == "pr" then
    package.loaded["raccoon.state"] = {
      get_clone_path = function() return "/tmp/fake-repo" end,
      get_pr = function()
        return { title = "PR title", body = "b", base = { ref = "main" }, head = { ref = "feat" } }
      end,
      get_owner = function() return "bajor" end,
      get_repo = function() return "repo" end,
      get_number = function() return 5 end,
    }
  end
  return state, sha1, sha2
end

local function layout(state)
  vim.cmd("silent! only")
  vim.api.nvim_win_set_buf(0, state.sidebar_buf)
  local sidebar = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(sidebar, 40)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, state.grid_bufs[1])
  local cell1 = vim.api.nvim_get_current_win()
  vim.wo[cell1].signcolumn = "yes:1"
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, state.grid_bufs[2])
  local cell2 = vim.api.nvim_get_current_win()
  vim.wo[cell2].signcolumn = "yes:1"
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, state.filetree_buf)
  local tree = vim.api.nvim_get_current_win()
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, state.header_buf)
  local header = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(header, 1)
  return { sidebar = sidebar, cell1 = cell1, cell2 = cell2, tree = tree, header = header }
end

local function screen_row_text(win, row)
  local pos = vim.fn.win_screenpos(win)
  local width = vim.api.nvim_win_get_width(win)
  local chars = {}
  for col = pos[2], pos[2] + width - 1 do chars[#chars + 1] = vim.fn.screenstring(pos[1] + row, col) end
  return table.concat(chars)
end

local function screen_attr(win, row, col)
  local pos = vim.fn.win_screenpos(win)
  return vim.fn.screenattr(pos[1] + row, pos[2] + col)
end

local function make_artifact(sha, dir)
  return {
    sha = sha,
    subject = "feat: thing",
    overview = "This commit does a thing.",
    segments = {
      { index = 1, title = "Core change", summary = "sum", changes = { "c1" }, explanation = "Explains it.",
        review_focus = { "Check it" }, files = { { file = "src/a.lua", additions = 1, deletions = 1 } } },
      { index = 2, title = "Cleanup", summary = "", changes = { "c2", "c3" }, explanation = "Cleans up.",
        review_focus = {}, files = { { file = "src/a.lua", additions = 1, deletions = 0 },
          { file = "src/b.lua", additions = 0, deletions = 1 } } },
    },
    unassigned = {},
    blocks = BLOCKS,
    warnings = {},
    dir = dir,
  }
end

h.test("adapter reads both viewers, maps sidebar rows and classifies buffers", function()
  local state, sha1 = fake_viewer("pr")
  local viewer, issue = adapter.viewer()
  h.equal(issue, nil)
  h.equal(viewer.kind, "pr")
  h.equal(viewer.repo_path, "/tmp/fake-repo")
  local commits, section1, split = adapter.commits(viewer)
  h.equal(#commits, 3)
  h.equal(section1, 2)
  h.truthy(split)
  h.truthy(commits[1].target)
  h.falsy(commits[3].target)
  h.equal(adapter.sidebar_row(1, 2, true), 1)
  h.equal(adapter.sidebar_row(3, 2, true), 5)
  h.equal(adapter.selected(viewer).sha, sha1)
  h.equal(adapter.source(viewer).kind, "pr")
  h.equal(adapter.source(viewer).number, 5)
  h.deep_equal(adapter.classify(viewer, state.grid_bufs[1]), { role = "cell", filename = "src/a.lua", first_line = 1 })
  h.equal(adapter.classify(viewer, state.sidebar_buf).role, "sidebar")
  h.equal(adapter.classify(viewer, state.filetree_buf).role, "filetree")
  h.equal(adapter.classify(viewer, state.header_buf).role, "header")
  h.equal(adapter.classify(viewer, 9999), nil)
  local records = adapter.typed_records(state.grid_bufs[1], viewer.namespace)
  h.deep_equal({ records[1].kind, records[2].kind, records[3].kind, records[5].kind },
    { "context", "deletion", "addition", "addition" })
  state.focus_target = "filetree"
  state.filetree_preview_path = "src/z.lua"
  h.equal(adapter.classify(viewer, state.grid_bufs[1]).role, "preview")
  state.active = false
  package.loaded["raccoon.commits"] = nil

  local local_state = fake_viewer("local")
  local lv = adapter.viewer()
  h.equal(lv.kind, "local")
  local lcommits, lsection1 = adapter.commits(lv)
  h.equal(lsection1, 3)
  h.falsy(lcommits[1].target, "Current changes is never a target")
  h.truthy(lcommits[2].target)
  h.equal(adapter.source(lv).kind, "local")
  h.equal(adapter.source(lv).branch, "feat")
  local_state.base_branch = nil
  local _, _, lsplit = adapter.commits(lv)
  h.falsy(lsplit)
  h.equal(adapter.sidebar_row(3, 3, false), 3)
  local_state.active = false
  package.loaded["raccoon.localcommits"] = nil
end)

h.test("decorations tint rows, badge segments, mark sidebar and file tree, and survive rewrites", function()
  local dir = support.tempdir("decorate-store")
  store.configure(dir)
  queue.configure(config.resolve({ data_dir = dir }), function() return nil end)
  local state, sha1, sha2 = fake_viewer("pr")
  store.save(sha1, make_artifact(sha1, store.commit_dir(sha1)))
  lifecycle.start(config.resolve({ data_dir = dir }))
  lifecycle.scan()
  local wins = layout(state)
  vim.cmd("redraw!")

  -- Column 2 sits inside the text, past the one-cell sign column.
  local tinted_attr = screen_attr(wins.cell1, 2, 2)
  local plain_row_attr = screen_attr(wins.cell1, 0, 2)
  h.truthy(tinted_attr ~= plain_row_attr, "tinted addition differs from context row")
  local deletion_attr = screen_attr(wins.cell1, 1, 2)
  h.truthy(deletion_attr ~= tinted_attr, "deletion tint differs from addition tint")
  h.truthy(screen_attr(wins.cell1, 2, 10) == tinted_attr, "tint extends past end of line")
  h.matches(screen_row_text(wins.cell1, 1), "① Core change")
  h.matches(screen_row_text(wins.cell1, 4), "② Cleanup")
  h.matches(screen_row_text(wins.cell2, 2), "② Cleanup")
  h.matches(screen_row_text(wins.sidebar, 1), "●●")
  h.falsy(screen_row_text(wins.sidebar, 2):find("●", 1, true), "unexplained commit has no dots")
  h.matches(screen_row_text(wins.tree, 1), "●●")
  h.matches(screen_row_text(wins.tree, 2), "●")
  h.falsy(screen_row_text(wins.tree, 3):find("●", 1, true))
  h.matches(screen_row_text(wins.header, 0), "◆ 2 segments")

  -- Raccoon rewrites buffers wholesale; ephemeral marks must come back.
  vim.api.nvim_buf_set_lines(state.grid_bufs[1], 0, -1, false, { "ctx", "old", "new", "ctx2", "added" })
  local ns = vim.api.nvim_create_namespace("raccoon_commits")
  vim.api.nvim_buf_set_extmark(state.grid_bufs[1], ns, 1, 0, { line_hl_group = "RaccoonDelete", sign_text = "-" })
  vim.api.nvim_buf_set_extmark(state.grid_bufs[1], ns, 2, 0, { line_hl_group = "RaccoonAdd", sign_text = "+" })
  vim.api.nvim_buf_set_extmark(state.grid_bufs[1], ns, 4, 0, { line_hl_group = "RaccoonAdd", sign_text = "+" })
  vim.cmd("redraw!")
  h.matches(screen_row_text(wins.cell1, 1), "① Core change")

  -- Overlay off keeps sidebar/header marks but drops tints and badges.
  decorate.set_overlay(false)
  vim.cmd("redraw!")
  h.falsy(screen_row_text(wins.cell1, 1):find("Core change", 1, true))
  h.equal(screen_attr(wins.cell1, 2, 2), screen_attr(wins.cell1, 4, 2))
  h.truthy(screen_attr(wins.cell1, 2, 2) ~= tinted_attr, "plain RaccoonAdd once overlay is off")
  h.matches(screen_row_text(wins.sidebar, 1), "●●")
  decorate.set_overlay(true)

  -- Selecting an unexplained commit shows the generate hint and no tints.
  state.selected_index = 2
  state.select_generation = 2
  lifecycle.scan()
  vim.cmd("redraw!")
  h.matches(screen_row_text(wins.header, 0), "no explanation")
  h.falsy(screen_row_text(wins.cell1, 1):find("Core change", 1, true))
  h.equal(decorate.segment_at(adapter.viewer(), state.grid_bufs[1], 2), nil)
  state.selected_index = 1
  lifecycle.scan()
  h.equal(decorate.segment_at(adapter.viewer(), state.grid_bufs[1], 2).title, "Core change")
  h.equal(decorate.segment_at(adapter.viewer(), state.grid_bufs[1], 4).title, "Cleanup")
  h.equal(decorate.segment_at(adapter.viewer(), state.grid_bufs[1], 0), nil)

  -- Queue status marks.
  queue.reset()
  support.write_file(store.path(sha2, "error.txt"), "boom\n")
  decorate.invalidate()
  vim.cmd("redraw!")
  h.matches(screen_row_text(wins.sidebar, 2), "✗")
  os.remove(store.path(sha2, "error.txt"))

  lifecycle.stop()
  state.active = false
  package.loaded["raccoon.commits"] = nil
  package.loaded["raccoon.state"] = nil
  vim.cmd("silent! only")
end)

h.test("explain popup renders text, registers with the host, navigates and closes", function()
  local dir = support.tempdir("explain-store")
  store.configure(dir)
  queue.reset()
  queue.configure(config.resolve({ data_dir = dir }), function() return nil end)
  local state, sha1, sha2 = fake_viewer("pr")
  local artifact = make_artifact(sha1, store.commit_dir(sha1))
  artifact.segments[1].visual = "seg-01.svg"
  store.save(sha1, artifact)
  support.write_file(store.path(sha1, "seg-01.svg"), "<svg/>")
  lifecycle.start(config.resolve({ data_dir = dir, images = false }))
  explain.config = config.resolve({ data_dir = dir, images = false })
  explain.keys = { generate = "<leader>vg" }
  lifecycle.scan()
  fake.popup_calls, fake.clear_calls = 0, 0
  local viewer = adapter.viewer()
  local win = explain.show(viewer, adapter.selected(viewer))
  h.truthy(explain.is_open())
  h.equal(state.popup_win, win)
  h.equal(fake.popup_calls, 1)
  local buf = vim.api.nvim_win_get_buf(win)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  h.matches(text, "images disabled in config")
  h.matches(text, "Overview\nThis commit does a thing%.")
  h.matches(text, "① Core change")
  h.matches(text, "%[diagram: seg%-01%.svg")
  h.matches(text, "Review focus\n  • Check it")
  h.matches(text, "② Cleanup")
  h.matches(text, "src/b%.lua  %+0 %-1")
  local first_row = vim.api.nvim_win_get_cursor(win)[1]
  vim.api.nvim_feedkeys("]s", "x", false)
  local after_first = vim.api.nvim_win_get_cursor(win)[1]
  h.truthy(after_first > first_row, "]s moves to a heading")
  vim.api.nvim_feedkeys("]s", "x", false)
  h.truthy(vim.api.nvim_win_get_cursor(win)[1] > after_first, "]s moves to the next heading")
  vim.api.nvim_feedkeys("[s", "x", false)
  h.equal(vim.api.nvim_win_get_cursor(win)[1], after_first)
  local shown
  local original_notify = vim.notify
  vim.notify = function(message) shown = message end
  vim.api.nvim_feedkeys("]c", "x", false)
  vim.notify = original_notify
  h.matches(shown, "no later explained commit")
  vim.api.nvim_feedkeys("q", "x", false)
  h.falsy(explain.is_open())
  h.equal(state.popup_win, nil)
  h.truthy(fake.clear_calls >= 1)

  -- Explaining an unexplained commit only notifies.
  vim.notify = function(message) shown = message end
  explain.show(viewer, { sha = sha2, message = "fix", index = 2 })
  vim.notify = original_notify
  h.matches(shown, "no explanation for 2222222 yet")
  h.falsy(explain.is_open())

  -- Focus on a segment.
  local win2 = explain.show(viewer, adapter.selected(viewer), artifact.segments[2])
  local row = vim.api.nvim_win_get_cursor(win2)[1]
  h.matches(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win2), row - 1, row, false)[1], "② Cleanup")
  explain.close()
  lifecycle.stop()
  state.active = false
  package.loaded["raccoon.commits"] = nil
  package.loaded["raccoon.state"] = nil
end)

h.test("explain popup transmits and places images through the kitty protocol", function()
  local dir = support.tempdir("image-store")
  store.configure(dir)
  local state, sha1 = fake_viewer("pr")
  local artifact = make_artifact(sha1, store.commit_dir(sha1))
  artifact.segments[1].visual = "seg-01.svg"
  artifact.segments[1].png = "seg-01.png"
  store.save(sha1, artifact)
  support.write_file(store.path(sha1, "seg-01.png"), support.tiny_png())
  local written = {}
  explain.set_writer(function(data) written[#written + 1] = data end)
  local original_detect = kitty.detect
  kitty.detect = function() return true end
  explain.config = config.resolve({ data_dir = dir })
  lifecycle.start(config.resolve({ data_dir = dir }))
  lifecycle.scan()
  local viewer = adapter.viewer()
  local win = explain.show(viewer, adapter.selected(viewer))
  local transmit = written[1]
  h.matches(transmit, "^\27_Ga=t,f=100,i=%d+,m=0,q=2,t=d;")
  h.matches(written[2], "^\27_GC=1,U=1,a=p,c=%d+,i=%d+,p=%d+,q=2,r=%d+\27\\$")
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local placeholder_rows = 0
  for _, line in ipairs(lines) do
    if line:find(kitty.PLACEHOLDER, 1, true) then placeholder_rows = placeholder_rows + 1 end
  end
  h.truthy(placeholder_rows >= 1, "placeholder rows present")
  local cols = tonumber(written[2]:match("c=(%d+)"))
  local rows = tonumber(written[2]:match("r=(%d+)"))
  h.equal(placeholder_rows, rows)
  h.equal(cols, vim.api.nvim_win_get_width(win) - 2)
  local hl = vim.api.nvim_get_hl(0, { name = "RaccoonSegmentsImage" .. written[2]:match("p=(%d+)") })
  h.equal(hl.fg, tonumber(written[2]:match("i=(%d+)")))
  explain.close()
  h.matches(written[#written], "^\27_Ga=d,d=i,i=%d+,p=%d+,q=2\27\\$")
  -- Same image is not transmitted twice.
  local before = #written
  explain.show(viewer, adapter.selected(viewer))
  h.matches(written[before + 1], "^\27_GC=1,U=1,a=p")
  explain.close()
  kitty.detect = original_detect
  explain.set_writer(kitty.write)
  lifecycle.stop()
  state.active = false
  package.loaded["raccoon.commits"] = nil
  package.loaded["raccoon.state"] = nil
end)

h.test("setup, commands and instructions file work end to end", function()
  local dir = support.tempdir("cmd-store")
  local instructions = vim.fs.joinpath(support.tempdir("cmd-cfg"), "SEGMENTS.md")
  local segments = require("raccoon_segments")
  vim.g.mapleader = " "
  h.truthy(segments.setup({ data_dir = dir, images = false, instructions_path = instructions }))
  h.matches(vim.fn.maparg("<leader>vg", "n", false, true).desc, "^Raccoon: segments")
  h.equal(vim.fn.exists(":RaccoonSegments"), 2)
  local notified = {}
  local original_notify = vim.notify
  vim.notify = function(message) notified[#notified + 1] = message end

  -- Outside a viewer every viewer command only notifies.
  vim.cmd("RaccoonSegments generate")
  h.matches(notified[#notified], "available only in a raccoon commit viewer")
  vim.cmd("RaccoonSegments explain")
  h.matches(notified[#notified], "available only in a raccoon commit viewer")
  vim.cmd("RaccoonSegments toggle")
  h.matches(notified[#notified], "overlay off")
  h.falsy(decorate.overlay())
  segments.toggle()
  h.truthy(decorate.overlay())
  vim.cmd("RaccoonSegments cancel")
  h.matches(notified[#notified], "nothing running")
  vim.cmd("RaccoonSegments prompt")
  h.matches(notified[#notified], "no prompt has been sent")
  vim.cmd("RaccoonSegments bogus")
  h.matches(notified[#notified], "Usage: :RaccoonSegments <")

  -- instructions creates the file from the template and opens it in a float.
  h.equal(vim.fn.filereadable(instructions), 0)
  vim.cmd("RaccoonSegments instructions")
  h.equal(vim.fn.filereadable(instructions), 1)
  h.matches(support.read_file(instructions), "# Instructions for nvim%-raccoon%-segments")
  local win = vim.api.nvim_get_current_win()
  h.truthy(vim.api.nvim_win_get_config(win).relative ~= "", "instructions open in a float")
  h.equal(vim.api.nvim_buf_get_name(0), instructions)
  h.matches(segments.load_instructions(), "Diagrams")
  vim.api.nvim_feedkeys("q", "x", false)
  h.falsy(vim.api.nvim_win_is_valid(win))

  -- status opens a read-only float with the backend line.
  vim.cmd("RaccoonSegments status")
  local status_win = vim.api.nvim_get_current_win()
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  h.matches(text, "backend: opencode")
  h.matches(text, "no jobs in this session")
  h.falsy(vim.bo.modifiable)
  vim.api.nvim_feedkeys("q", "x", false)
  h.falsy(vim.api.nvim_win_is_valid(status_win))

  vim.notify = original_notify
  segments.disable()
  h.equal(vim.fn.maparg("<leader>vg", "n"), "")
  h.raises(function() segments.setup({ backend = "nope" }) end, "backend must be")
end)

h.test("palette defines highlight groups over host colours", function()
  vim.api.nvim_set_hl(0, "RaccoonAdd", { bg = "#2d5a2d" })
  palette.setup_highlights(3)
  local add = vim.api.nvim_get_hl(0, { name = "RaccoonSegmentsAdd1" })
  h.truthy(add.bg)
  h.truthy(add.bg ~= tonumber("2d5a2d", 16), "tint differs from RaccoonAdd")
  local del = vim.api.nvim_get_hl(0, { name = "RaccoonSegmentsDel1" })
  h.truthy(del.bg ~= add.bg)
  local fg = vim.api.nvim_get_hl(0, { name = "RaccoonSegmentsFg2" })
  h.equal(fg.fg, tonumber(palette.HUES[2]:sub(2), 16))
  h.truthy(vim.api.nvim_get_hl(0, { name = "RaccoonSegmentsFgUnassigned" }).fg)
end)

return h.run()
