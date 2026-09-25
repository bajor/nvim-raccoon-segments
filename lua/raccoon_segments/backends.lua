-- Agent CLI backends. Each returns a command spec:
--   { cmd = string[], env = table|nil, stdin = string|nil, output = "stdout"|"file", output_file = string|nil }
-- The prompt always travels on stdin. Every preset runs the agent read-only,
-- with the repository's own AGENTS.md/CLAUDE.md/plugins disabled where the
-- CLI allows it, because the commit under review is untrusted input.
local M = {}

M.READ_ONLY_AGENT = "raccoon-segments"

local function extend(list, extra)
  for _, item in ipairs(extra or {}) do list[#list + 1] = item end
  return list
end

local function opencode_config()
  return vim.json.encode({
    agent = {
      [M.READ_ONLY_AGENT] = {
        description = "Read-only commit annotator for nvim-raccoon-segments",
        mode = "primary",
        permission = {
          edit = "deny",
          bash = "deny",
          webfetch = "deny",
          websearch = "deny",
          task = "deny",
          skill = "deny",
          todowrite = "deny",
        },
      },
    },
  })
end

local presets = {}

function presets.opencode(ctx)
  local cmd = { "opencode", "run", "--agent", M.READ_ONLY_AGENT }
  if ctx.model then extend(cmd, { "--model", ctx.model }) end
  extend(cmd, ctx.extra_args)
  return {
    cmd = cmd,
    env = {
      OPENCODE_CONFIG_CONTENT = opencode_config(),
      OPENCODE_DISABLE_PROJECT_CONFIG = "1",
      OPENCODE_DISABLE_CLAUDE_CODE = "1",
      OPENCODE_DISABLE_AUTOUPDATE = "1",
    },
    output = "stdout",
    stdin = ctx.prompt,
  }
end

function presets.claude(ctx)
  local cmd = {
    "claude",
    "-p",
    "--output-format", "json",
    "--tools", "Read,Grep,Glob",
    "--permission-mode", "dontAsk",
    "--setting-sources", "user",
    "--no-session-persistence",
  }
  if ctx.model then extend(cmd, { "--model", ctx.model }) end
  extend(cmd, ctx.extra_args)
  return { cmd = cmd, output = "stdout", stdin = ctx.prompt, decode = "claude_json" }
end

function presets.codex(ctx)
  local output_file = ctx.output_path("codex-last-message.txt")
  local cmd = {
    "codex", "exec",
    "--sandbox", "read-only",
    "--skip-git-repo-check",
    "--ephemeral",
    "--color", "never",
    "-o", output_file,
  }
  if ctx.model then extend(cmd, { "-m", ctx.model }) end
  extend(cmd, ctx.extra_args)
  cmd[#cmd + 1] = "-"
  return { cmd = cmd, output = "file", output_file = output_file, stdin = ctx.prompt }
end

---Build the command spec for a backend.
---@param backend string|table|function config value
---@param ctx table {prompt, model, extra_args, output_path = fun(name): string, cwd, sha}
---@return table spec
function M.build(backend, ctx)
  local spec
  if type(backend) == "string" then
    spec = presets[backend](ctx)
  elseif type(backend) == "function" then
    spec = backend(ctx)
  else
    local cmd = backend.cmd
    if type(cmd) == "function" then cmd = cmd(ctx) end
    spec = {
      cmd = vim.deepcopy(cmd),
      env = backend.env,
      output = backend.output or "stdout",
      output_file = backend.output == "file" and ctx.output_path("custom-output.txt") or nil,
      stdin = ctx.prompt,
      decode = backend.decode,
    }
    if spec.output == "file" then
      for index, arg in ipairs(spec.cmd) do
        spec.cmd[index] = arg:gsub("{output}", spec.output_file)
      end
    end
  end
  assert(type(spec) == "table" and type(spec.cmd) == "table" and #spec.cmd > 0, "backend produced no command")
  return spec
end

---Extract the agent's final text from what the backend produced.
---@param spec table
---@param stdout string
---@return string|nil text, string|nil err
function M.final_text(spec, stdout)
  local text = stdout
  if spec.output == "file" then
    local file = io.open(spec.output_file, "rb")
    if not file then return nil, "backend wrote no output file" end
    text = file:read("*a")
    file:close()
  end
  if spec.decode == "claude_json" then
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
      return nil, "claude did not return JSON: " .. (text:sub(1, 200):gsub("\n", " "))
    end
    -- Either the result object on its own, or the whole stream as an array.
    local result = decoded
    if decoded[1] ~= nil then
      result = nil
      for _, event in ipairs(decoded) do
        if type(event) == "table" and event.type == "result" then result = event end
      end
      if not result then return nil, "claude JSON has no result event" end
    end
    if result.is_error then
      return nil, "claude reported an error: " .. tostring(result.result or result.error)
    end
    if type(result.result) ~= "string" then return nil, "claude JSON has no result field" end
    return result.result
  end
  return text
end

---@param backend string|table|function
---@return string
function M.name(backend)
  if type(backend) == "string" then return backend end
  if type(backend) == "function" then return "custom" end
  local cmd = backend.cmd
  if type(cmd) == "table" then return cmd[1] or "custom" end
  return "custom"
end

---@param backend string|table|function
---@return string|nil executable
function M.executable(backend)
  if type(backend) == "string" then return backend end
  if type(backend) == "table" and type(backend.cmd) == "table" then return backend.cmd[1] end
  return nil
end

return M
