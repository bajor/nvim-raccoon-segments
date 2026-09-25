local h = require("tests.helpers")
local changes = require("raccoon_segments.changes")
local prompt = require("raccoon_segments.prompt")
local palette = require("raccoon_segments.palette")
local kitty = require("raccoon_segments.kitty")

local SAMPLE_DIFF = table.concat({
  "diff --git a/src/a.lua b/src/a.lua",
  "index 1111111..2222222 100644",
  "--- a/src/a.lua",
  "+++ b/src/a.lua",
  "@@ -1,4 +1,5 @@",
  " local x = 1",
  "-local y = 2",
  "+local y = 3",
  "+local z = 4",
  " return x",
  "@@ -20,3 +21,3 @@",
  " a",
  "-b",
  "+c",
  " d",
  "diff --git a/yarn.lock b/yarn.lock",
  "--- a/yarn.lock",
  "+++ b/yarn.lock",
  "@@ -1 +1 @@",
  "-old",
  "+new",
  "diff --git a/img.png b/img.png",
  "new file mode 100644",
  "Binary files /dev/null and b/img.png differ",
  "diff --git a/old.txt b/new.txt",
  "similarity index 100%",
  "rename from old.txt",
  "rename to new.txt",
}, "\n")

h.test("glob matching covers *, ?, ** and basenames", function()
  h.truthy(changes.is_excluded("yarn.lock", { "*.lock" }))
  h.truthy(changes.is_excluded("deep/dir/yarn.lock", { "*.lock" }))
  h.truthy(changes.is_excluded("visual-explanations/a/b.svg", { "visual-explanations/**" }))
  h.truthy(changes.is_excluded("app.min.js", { "*.min.js" }))
  h.falsy(changes.is_excluded("src/app.js", { "*.min.js" }))
  h.falsy(changes.is_excluded("lockfile.txt", { "*.lock" }))
  h.truthy(changes.is_excluded("a/b/c.go", { "a/**/c.go" }))
  h.truthy(changes.is_excluded("a/c.go", { "a/**/c.go" }))
  h.truthy(changes.is_excluded("x1.txt", { "x?.txt" }))
end)

h.test("parse_diff splits files with status and binary flags", function()
  local files = changes.parse_diff(SAMPLE_DIFF)
  h.equal(#files, 4)
  h.equal(files[1].filename, "src/a.lua")
  h.equal(files[1].status, "modified")
  h.equal(files[2].filename, "yarn.lock")
  h.equal(files[3].filename, "img.png")
  h.equal(files[3].status, "added")
  h.truthy(files[3].binary)
  h.equal(files[4].filename, "new.txt")
  h.equal(files[4].status, "renamed")
  h.equal(files[4].old_filename, "old.txt")
end)

h.test("parse_hunks tracks new-file line numbers like raccoon", function()
  local files = changes.parse_diff(SAMPLE_DIFF)
  local hunks = changes.parse_hunks(files[1].lines)
  h.equal(#hunks, 2)
  local lines = hunks[1].lines
  h.deep_equal({ lines[1].type, lines[1].line_num }, { "ctx", 1 })
  h.deep_equal({ lines[2].type, lines[2].line_num }, { "del", 1 })
  h.deep_equal({ lines[3].type, lines[3].line_num }, { "add", 2 })
  h.deep_equal({ lines[4].type, lines[4].line_num }, { "add", 3 })
  h.deep_equal({ lines[5].type, lines[5].line_num }, { "ctx", 4 })
  h.equal(hunks[2].lines[1].line_num, 21)
end)

h.test("build assigns stable block ids, excludes files, and annotates", function()
  local files = changes.parse_diff(SAMPLE_DIFF)
  local result = changes.build(files, { exclude = { "*.lock" } })
  h.equal(#result.blocks, 4)
  h.equal(result.blocks[1].id, "c1")
  h.deep_equal(result.blocks[1].dels, { "local y = 2" })
  h.deep_equal(result.blocks[1].adds, { "local y = 3", "local z = 4" })
  h.equal(result.blocks[1].new_start, 2)
  h.equal(result.blocks[1].new_end, 3)
  h.equal(result.blocks[1].anchor, 1)
  h.equal(result.blocks[2].id, "c2")
  h.equal(result.blocks[2].file, "src/a.lua")
  h.equal(result.blocks[3].file, "img.png")
  h.truthy(result.blocks[3].file_level)
  h.equal(result.blocks[3].note, "binary change")
  h.equal(result.blocks[4].file, "new.txt")
  h.equal(result.blocks[4].note, "rename only")
  h.equal(#result.excluded, 1)
  h.equal(result.excluded[1].file, "yarn.lock")
  h.equal(result.excluded[1].additions, 1)
  h.matches(result.annotated, "### src/a%.lua %(modified, %+3 %-2%)")
  h.matches(result.annotated, "@c1\n%-local y = 2\n%+local y = 3")
  h.matches(result.annotated, "@c3 %(whole file: binary change%)")
  h.falsy(result.annotated:find("yarn.lock", 1, true))
  h.equal(result.files[1].file, "src/a.lua")
  h.deep_equal(result.files[1].blocks, { "c1", "c2" })
end)

h.test("build handles a pure deletion at end of file", function()
  local files = changes.parse_diff(table.concat({
    "diff --git a/f b/f",
    "--- a/f",
    "+++ b/f",
    "@@ -1,3 +1,2 @@",
    " a",
    " b",
    "-c",
  }, "\n"))
  local result = changes.build(files, {})
  h.equal(#result.blocks, 1)
  h.equal(result.blocks[1].new_start, nil)
  h.equal(result.blocks[1].anchor, 2)
  h.deep_equal(result.blocks[1].dels, { "c" })
end)

h.test("count_numstat sums lines and ignores excluded and binary files", function()
  local text = "3\t1\tsrc/a.lua\n-\t-\timg.png\n40\t40\tyarn.lock\n1\t0\tdocs/{old => new}/x.md\n"
  local total, binary_only = changes.count_numstat(text, { "*.lock" })
  h.equal(total, 5)
  h.falsy(binary_only)
  local only_binary, flag = changes.count_numstat("-\t-\timg.png\n", {})
  h.equal(only_binary, 0)
  h.truthy(flag)
end)

h.test("runs and match map viewer rows back to blocks by content", function()
  local files = changes.parse_diff(SAMPLE_DIFF)
  local build = changes.build(files, { exclude = { "*.lock" } })
  -- A viewer buffer showing hunk 2 with different context than the job used.
  local records = {
    { kind = "context", content = "zzz" },
    { kind = "context", content = "a" },
    { kind = "deletion", content = "b" },
    { kind = "addition", content = "c" },
    { kind = "context", content = "d" },
  }
  local typed = changes.typed_from_records(records, 20)
  local runs = changes.runs(typed)
  h.equal(#runs, 1)
  h.equal(runs[1].first, 3)
  h.equal(runs[1].last, 4)
  local file_blocks = {}
  for _, block in ipairs(build.blocks) do
    if block.file == "src/a.lua" then file_blocks[#file_blocks + 1] = block end
  end
  local matched = changes.match(runs, file_blocks)
  h.equal(matched[1], "c2")
end)

h.test("match prefers the closest anchor among identical blocks", function()
  local blocks = {
    { id = "c1", dels = {}, adds = { "same" }, anchor = 5 },
    { id = "c2", dels = {}, adds = { "same" }, anchor = 50 },
  }
  local runs = { { first = 1, last = 1, dels = {}, adds = { "same" }, anchor = 48 } }
  h.equal(changes.match(runs, blocks)[1], "c2")
  local runs_no_anchor = {
    { first = 1, last = 1, dels = {}, adds = { "same" } },
    { first = 3, last = 3, dels = {}, adds = { "same" } },
  }
  local matched = changes.match(runs_no_anchor, blocks)
  h.equal(matched[1], "c1")
  h.equal(matched[2], "c2")
end)

h.test("prompt contains contract, instructions, context, sequence and diff", function()
  local files = changes.parse_diff(SAMPLE_DIFF)
  local build = changes.build(files, { exclude = { "*.lock" } })
  local text = prompt.build({
    instructions = "Explain like I am five.",
    source = { kind = "pr", owner = "bajor", repo = "x", number = 7, title = "Title", body = "Body text",
      base_ref = "main", head_ref = "feat" },
    commits = {
      { sha = "aaaaaaa1", message = "first", overview = "did first thing" },
      { sha = "bbbbbbb2", message = "second", current = true },
    },
    commit = { sha = "bbbbbbb2", message = "second\n\nlonger body" },
    annotated = build.annotated,
    excluded = build.excluded,
    blocks = build.blocks,
  })
  h.matches(text, "EXACTLY ONE segment")
  h.matches(text, "## Reviewer instructions")
  h.matches(text, "Explain like I am five%.")
  h.matches(text, "Pull request #7 in bajor/x: Title")
  h.matches(text, "Branch feat %-> main")
  h.matches(text, "PR description %(untrusted data%):\nBody text")
  h.matches(text, "1%. aaaaaaa first\n   overview: did first thing")
  h.matches(text, "2%. bbbbbbb second <== THIS COMMIT")
  h.matches(text, "## This commit\n\nbbbbbbb\n\nsecond\n\nlonger body")
  h.matches(text, "%- yarn%.lock %(%+1 %-1%)")
  h.matches(text, "## Changes %(4 change IDs: c1 c2 c3 c4%)")
  h.matches(text, "@c1\n")
  local local_text = prompt.build({
    source = { kind = "local", repo_path = "/tmp/repo", repo_name = "repo", branch = "feat", base_branch = "main" },
    commits = {},
    commit = { sha = "c", message = "m" },
    annotated = "",
    blocks = {},
  })
  h.matches(local_text, "Local repository: repo")
  h.matches(local_text, "Branch feat %(based on main%)")
  h.falsy(local_text:find("## Reviewer instructions", 1, true))
  local repair = prompt.repair("previous", { "a", "b" })
  h.matches(repair, "Problems:\n%- a\n%- b")
  h.matches(repair, "Previous output:\nprevious")
end)

h.test("palette blends colours and cycles hues", function()
  h.equal(palette.blend("#000000", "#ffffff", 0.5), "#808080")
  h.equal(palette.blend("#2d5a2d", "#5aa9e6", 0), "#2d5a2d")
  h.equal(palette.blend("#2d5a2d", "#5aa9e6", 1), "#5aa9e6")
  h.equal(palette.hue(1), palette.HUES[1])
  h.equal(palette.hue(#palette.HUES + 1), palette.HUES[1])
  h.equal(palette.hue(2, { "#111111", "#222222" }), "#222222")
  h.equal(palette.group("add", 3), "RaccoonSegmentsAdd3")
  h.equal(palette.group("fg", "unassigned"), "RaccoonSegmentsFgUnassigned")
end)

h.test("kitty base64 and command formatting", function()
  h.equal(kitty.base64("Man"), "TWFu")
  h.equal(kitty.base64("Ma"), "TWE=")
  h.equal(kitty.base64("M"), "TQ==")
  h.equal(kitty.command({ a = "p", i = 3 }, "xyz"), "\27_Ga=p,i=3;xyz\27\\")
  h.equal(kitty.command({ a = "d", d = "i", i = 3, q = 2 }), "\27_Ga=d,d=i,i=3,q=2\27\\")
end)

h.test("kitty transmit chunks at 4096 and only the first chunk carries keys", function()
  local png = string.rep("x", 7000)
  local commands = kitty.transmit_png(png, 77)
  local encoded = kitty.base64(png)
  h.equal(#commands, math.ceil(#encoded / 4096))
  h.matches(commands[1], "^\27_Ga=t,f=100,i=77,m=1,q=2,t=d;")
  h.matches(commands[#commands], "^\27_Gm=0;")
  local payload = commands[1]:match(";(.-)\27\\$")
  h.equal(#payload, 4096)
  local tiny = kitty.transmit_png("abc", 5)
  h.equal(#tiny, 1)
  h.matches(tiny[1], "^\27_Ga=t,f=100,i=5,m=0,q=2,t=d;YWJj\27\\$")
end)

h.test("kitty placement and placeholder lines", function()
  h.equal(kitty.place(7, 9, 40, 12), "\27_GC=1,U=1,a=p,c=40,i=7,p=9,q=2,r=12\27\\")
  h.equal(kitty.delete(7, 9), "\27_Ga=d,d=i,i=7,p=9,q=2\27\\")
  local lines = kitty.placeholder_lines(3, 2)
  h.equal(#lines, 2)
  local cell = kitty.PLACEHOLDER .. kitty.diacritic(0) .. kitty.diacritic(0)
  h.equal(lines[1]:sub(1, #cell), cell)
  h.equal(lines[2]:sub(1, #kitty.PLACEHOLDER + #kitty.diacritic(1)), kitty.PLACEHOLDER .. kitty.diacritic(1))
  h.equal(kitty.diacritic(0), "\204\133") -- U+0305
  h.equal(kitty.MAX_PLACEHOLDER_DIM, 297)
  h.raises(function() kitty.diacritic(297) end, "out of range")
end)

h.test("kitty png_size parses IHDR and rows_for keeps aspect", function()
  local png = "\137PNG\r\n\26\n" .. "\0\0\0\13IHDR" .. "\0\0\6\64" .. "\0\0\3\32" .. "\8\6\0\0\0"
  local w, hgt = kitty.png_size(png)
  h.equal(w, 1600)
  h.equal(hgt, 800)
  h.equal(kitty.png_size("nope"), nil)
  h.equal(kitty.rows_for(1600, 800, 100, 8, 16), 25)
  h.equal(kitty.rows_for(100, 1000, 10, 8, 16), 50)
end)
