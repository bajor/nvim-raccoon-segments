-- Runs a spec inside an embedded child Neovim that has a UI attached, so
-- screen-level assertions (screenstring/screenattr, decoration providers)
-- work. Usage: nvim --headless -u NONE -l tests/run_in_ui.lua <spec.lua> [extra child args...]
local spec = arg[1]
assert(spec, "usage: run_in_ui.lua <spec.lua> [child args]")
local cmd = { vim.v.progpath, "--embed", "-u", "tests/minimal_init.lua" }
for index = 2, #arg do cmd[#cmd + 1] = arg[index] end

local stderr = {}
local exit_code
local chan = vim.fn.jobstart(cmd, {
  rpc = true,
  on_stderr = function(_, data)
    for _, line in ipairs(data) do
      if line ~= "" then
        stderr[#stderr + 1] = line
        if os.getenv("RACCOON_SEGMENTS_TRACE") then io.stderr:write(line .. "\n") end
      end
    end
  end,
  on_exit = function(_, code) exit_code = code end,
})
assert(chan > 0, "could not start child neovim")

local function request(...)
  local ok, result = pcall(vim.rpcrequest, chan, ...)
  if not ok then
    io.stderr:write("child request failed: " .. tostring(result) .. "\n" .. table.concat(stderr, "\n") .. "\n")
    os.exit(1)
  end
  return result
end

request("nvim_ui_attach", 140, 45, { rgb = true })
-- Give the child time to finish initialising after the UI attached.
local ready = false
for _ = 1, 50 do
  vim.wait(100)
  local ok, uis = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return #vim.api.nvim_list_uis()", {})
  if ok and uis == 1 then
    ready = true
    break
  end
end
assert(ready, "child neovim never became ready")

local code = ([[
  _G.RACCOON_SEGMENTS_COLLECT = true
  -- With a UI attached, stacked messages raise a hit-enter prompt that would
  -- block this request forever; keep messages out of the way.
  vim.o.more = false
  vim.opt.shortmess:append("aoOstTWIcCF")
  vim.notify = function() end
  local ok, result = xpcall(function() return dofile(%q) end, debug.traceback)
  if not ok then return { output = "", failures = 1, error = tostring(result) } end
  return result
]]):format(spec)
local result = request("nvim_exec_lua", code, {})
if type(result) ~= "table" then
  io.stderr:write("spec returned no result (did it call helpers.run()?)\n")
  os.exit(1)
end
io.write(result.output or "")
if result.error then io.stderr:write(result.error .. "\n") end
pcall(vim.fn.jobstop, chan)
vim.wait(500, function() return exit_code ~= nil end, 20)
if (result.failures or 0) > 0 then os.exit(1) end
