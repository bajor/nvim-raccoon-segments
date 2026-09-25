local M = {}

M.DEFAULT_EXCLUDE = {
  "*.lock",
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
  "Cargo.lock",
  "go.sum",
  "poetry.lock",
  "uv.lock",
  "Gemfile.lock",
  "composer.lock",
  "*.min.js",
  "*.min.css",
  "*.map",
  "visual-explanations/**",
}

local function defaults()
  return {
    backend = "opencode",
    model = nil,
    backend_args = {},
    backend_env = {},
    timeout_ms = 20 * 60 * 1000,
    max_parallel = 2,
    min_changed_lines = 10,
    local_recent_commits = 10,
    max_diff_bytes = 400 * 1024,
    exclude = vim.deepcopy(M.DEFAULT_EXCLUDE),
    export_tree = true,
    images = "auto",
    rasterizer = "auto",
    instructions_path = "~/.config/raccoon/SEGMENTS.md",
    data_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "raccoon-segments"),
    overlay = true,
    colors = nil,
    diagnostics = "warn",
    keys = {
      explain = "<leader>ve",
      toggle = "<leader>vs",
      generate = "<leader>vg",
      regenerate = "<leader>vG",
    },
  }
end

M.defaults = defaults

local BACKENDS = { opencode = true, claude = true, codex = true }
local KEY_NAMES = { explain = true, toggle = true, generate = true, regenerate = true }

local function fail(message)
  error("raccoon-segments: " .. message, 0)
end

local function check_type(name, value, expected)
  if type(value) ~= expected then
    fail(("option %s must be a %s"):format(name, expected))
  end
end

local function check_positive_integer(name, value, allow_zero)
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or (value == 0 and not allow_zero) then
    fail(("option %s must be a %s integer"):format(name, allow_zero and "non-negative" or "positive"))
  end
end

local function check_string_list(name, value)
  check_type(name, value, "table")
  for index, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      fail(("option %s[%d] must be a non-empty string"):format(name, index))
    end
  end
end

local function check_backend(value)
  local kind = type(value)
  if kind == "string" then
    if not BACKENDS[value] then fail("option backend must be opencode, claude, codex, or a custom table") end
    return
  end
  if kind == "function" then return end
  if kind ~= "table" then fail("option backend must be opencode, claude, codex, or a custom table") end
  if type(value.cmd) ~= "table" and type(value.cmd) ~= "function" then
    fail("custom backend needs cmd (list of strings or function)")
  end
  if value.output ~= nil and value.output ~= "stdout" and value.output ~= "file" then
    fail("custom backend output must be stdout or file")
  end
end

local function check_color_list(value)
  check_type("colors", value, "table")
  if #value == 0 then fail("option colors must contain at least one color") end
  for index, item in ipairs(value) do
    if type(item) ~= "string" or not item:match("^#%x%x%x%x%x%x$") then
      fail(("option colors[%d] must be a #rrggbb string"):format(index))
    end
  end
end

---@param options? table
---@return table
function M.resolve(options)
  local resolved = defaults()
  if options == nil then return resolved end
  check_type("setup options", options, "table")
  for key, value in pairs(options) do
    if resolved[key] == nil and key ~= "model" and key ~= "colors" then
      fail("unknown raccoon-segments option " .. tostring(key))
    end
    if key == "keys" then
      check_type("keys", value, "table")
      for name, lhs in pairs(value) do
        if not KEY_NAMES[name] then fail("unknown key name keys." .. tostring(name)) end
        if lhs ~= false and (type(lhs) ~= "string" or lhs == "") then
          fail(("keys.%s must be a non-empty string or false"):format(name))
        end
        resolved.keys[name] = lhs
      end
    else
      resolved[key] = value
    end
  end

  check_backend(resolved.backend)
  if resolved.model ~= nil then check_type("model", resolved.model, "string") end
  check_string_list("backend_args", resolved.backend_args)
  check_type("backend_env", resolved.backend_env, "table")
  for name, value in pairs(resolved.backend_env) do
    if type(name) ~= "string" or type(value) ~= "string" then
      fail("option backend_env must map strings to strings")
    end
  end
  check_positive_integer("timeout_ms", resolved.timeout_ms)
  check_positive_integer("max_parallel", resolved.max_parallel)
  check_positive_integer("min_changed_lines", resolved.min_changed_lines, true)
  check_positive_integer("local_recent_commits", resolved.local_recent_commits)
  check_positive_integer("max_diff_bytes", resolved.max_diff_bytes)
  check_string_list("exclude", resolved.exclude)
  check_type("export_tree", resolved.export_tree, "boolean")
  if resolved.images ~= "auto" and resolved.images ~= false then fail("option images must be auto or false") end
  local rasterizers = { auto = true, ["rsvg-convert"] = true, magick = true, qlmanage = true }
  if resolved.rasterizer ~= false and not rasterizers[resolved.rasterizer] then
    fail("option rasterizer must be auto, rsvg-convert, magick, qlmanage, or false")
  end
  check_type("instructions_path", resolved.instructions_path, "string")
  check_type("data_dir", resolved.data_dir, "string")
  check_type("overlay", resolved.overlay, "boolean")
  if resolved.colors ~= nil then check_color_list(resolved.colors) end
  local levels = { silent = true, warn = true, error = true }
  if not levels[resolved.diagnostics] then fail("option diagnostics must be silent, warn, or error") end

  resolved.instructions_path = vim.fn.expand(resolved.instructions_path)
  resolved.data_dir = vim.fn.expand(resolved.data_dir)
  return resolved
end

return M
