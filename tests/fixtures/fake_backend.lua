-- Fake agent CLI used by the pipeline tests. Run as: nvim -l fake_backend.lua <kind> [cli args...]
-- Reads the prompt from stdin, records what it saw in $FAKE_BACKEND_DIR and
-- answers with a canned reply that assigns every change id it finds.
local kind = arg[1]
local cli_args = {}
for index = 2, #arg do cli_args[#cli_args + 1] = arg[index] end

local dir = assert(os.getenv("FAKE_BACKEND_DIR"), "FAKE_BACKEND_DIR is not set")
local mode = os.getenv("FAKE_MODE") or "ok"
local prompt = io.read("*a") or ""

local counter_path = dir .. "/calls"
local calls = 0
local counter = io.open(counter_path, "r")
if counter then
  calls = tonumber(counter:read("*a")) or 0
  counter:close()
end
calls = calls + 1
local out = assert(io.open(counter_path, "w"))
out:write(tostring(calls))
out:close()

local function write(name, content)
  local file = assert(io.open(dir .. "/" .. name, "w"))
  file:write(content)
  file:close()
end

local listing = {}
for name in vim.fs.dir(".") do listing[#listing + 1] = name end
table.sort(listing)
write(("call-%d.txt"):format(calls), table.concat({
  "kind=" .. kind,
  "args=" .. table.concat(cli_args, " "),
  "cwd=" .. vim.fn.getcwd(),
  "cwd_listing=" .. table.concat(listing, ","),
  "OPENCODE_CONFIG_CONTENT=" .. tostring(os.getenv("OPENCODE_CONFIG_CONTENT")),
  "OPENCODE_DISABLE_PROJECT_CONFIG=" .. tostring(os.getenv("OPENCODE_DISABLE_PROJECT_CONFIG")),
  "",
  prompt,
}, "\n"))

local ids = {}
for id in prompt:gmatch("\n@(c%d+)") do ids[#ids + 1] = id end

local function json_string(text)
  return '"' .. text:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

local function reply_for(mode_name)
  if mode_name == "repair" and calls == 1 then
    return '<segments>{"overview":"broken","segments":[{"title":"t","changes":["c999"]}]}</segments>'
  end
  if mode_name == "garbage" then
    return "I could not do that."
  end
  local split = math.max(1, math.ceil(#ids / 2))
  local first, second = {}, {}
  for index, id in ipairs(ids) do
    if index <= split then first[#first + 1] = json_string(id) else second[#second + 1] = json_string(id) end
  end
  if mode_name == "noids" then first, second = {}, {} end
  local segments = {
    ('{"title":"Core change","summary":"The main mechanism.","changes":[%s],'
      .. '"explanation":"Explains the **core** change in detail.","review_focus":["Check the edge case"]}')
      :format(table.concat(first, ",")),
  }
  if #second > 0 then
    segments[#segments + 1] = ('{"title":"Tests and plumbing","summary":"Supporting edits.","changes":[%s],'
      .. '"explanation":"Wires things up.","review_focus":[]}'):format(table.concat(second, ","))
  end
  local svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 300">'
    .. '<script>alert(1)</script><rect width="960" height="300" fill="#1e1e2e"/>'
    .. '<text x="20" y="40" fill="#fff" font-size="16">Core change</text></svg>'
  return table.concat({
    "Here is my analysis.",
    "<segments>",
    ('{"overview":"Commit overview for %d changes.","segments":[%s]}'):format(#ids, table.concat(segments, ",")),
    "</segments>",
    '<visual segment="1">',
    svg,
    "</visual>",
    "Done.",
  }, "\n")
end

if mode == "fail" then
  io.stderr:write("fake backend failure\n")
  os.exit(2)
end
if mode == "hang" then
  vim.wait(120000, function() return false end, 100)
  os.exit(0)
end

local reply = reply_for(mode)

if kind == "claude" then
  io.stdout:write(('{"type":"result","is_error":false,"result":%s}'):format(json_string(reply)))
elseif kind == "codex" then
  local output_file
  for index, value in ipairs(cli_args) do
    if value == "-o" then output_file = cli_args[index + 1] end
  end
  assert(output_file, "codex fake expects -o <file>")
  write("codex-last-message.txt", reply)
  local file = assert(io.open(output_file, "w"))
  file:write(reply)
  file:close()
  io.stdout:write("codex progress noise\n")
else
  io.stdout:write(reply, "\n")
end
os.exit(0)
