-- One generation job: diff -> blocks -> export -> prompt -> agent -> parse
-- (-> one repair round) -> visuals -> artifact on disk.
local changes = require("raccoon_segments.changes")
local prompt = require("raccoon_segments.prompt")
local protocol = require("raccoon_segments.protocol")
local backends = require("raccoon_segments.backends")
local visuals = require("raccoon_segments.visuals")
local store = require("raccoon_segments.store")

local M = {}

-- Files in the exported tree that could steer the agent. They are removed
-- from the export (never from the real repository) before the agent runs.
M.UNTRUSTED_PATHS = {
  "AGENTS.md", "CLAUDE.md", "GEMINI.md", ".claude", ".opencode", ".codex", ".agents",
  "opencode.json", "opencode.jsonc", ".opencode.json", ".mcp.json", ".cursorrules", ".windsurfrules",
}

-- vim.system callbacks run on the luv loop where vim.fn is off limits, so
-- every callback in this module is hopped onto the main loop first.
local function system(cmd, opts, callback)
  return vim.system(cmd, opts, function(result)
    vim.schedule(function() callback(result) end)
  end)
end

local function git(repo, args, callback)
  local cmd = { "git", "-C", repo, "-c", "core.longpaths=true" }
  for _, arg in ipairs(args) do cmd[#cmd + 1] = arg end
  return system(cmd, { text = true }, function(result)
    if result.code ~= 0 then
      callback(nil, ("git %s failed: %s"):format(args[1], (result.stderr or ""):gsub("%s+$", "")))
      return
    end
    callback(result.stdout or "")
  end)
end

local function tail(text, limit)
  text = (text or ""):gsub("%s+$", "")
  if #text <= limit then return text end
  return "…" .. text:sub(-limit)
end

local function remove_untrusted(export_dir)
  for _, name in ipairs(M.UNTRUSTED_PATHS) do
    local path = vim.fs.joinpath(export_dir, name)
    if vim.uv.fs_stat(path) then vim.fn.delete(path, "rf") end
  end
end

---@class RaccoonSegmentsJobOptions
---@field sha string
---@field subject string
---@field repo_path string
---@field source table
---@field commits table[] {sha, message, overview?, current?}
---@field config table resolved config
---@field instructions string|nil
---@field on_done fun(artifact: table|nil, err: string|nil)
---@field on_phase? fun(phase: string)

---@param opts RaccoonSegmentsJobOptions
---@return table handle {cancel = fun()}
function M.run(opts)
  local sha = opts.sha
  local config = opts.config
  local dir = store.commit_dir(sha)
  local handle = { cancelled = false, proc = nil, phase = "starting" }
  local export_dir
  local finished = false

  local function phase(name)
    handle.phase = name
    if opts.on_phase then pcall(opts.on_phase, name) end
  end

  local function cleanup()
    if export_dir and vim.fn.isdirectory(export_dir) == 1 then
      pcall(vim.fn.delete, export_dir, "rf")
    end
    export_dir = nil
  end

  local function finish(artifact, err)
    if finished then return end
    finished = true
    cleanup()
    if err and not handle.cancelled then
      store.write(vim.fs.joinpath(dir, "error.txt"), err .. "\n")
    end
    vim.schedule(function() opts.on_done(artifact, err) end)
  end

  local function fail(err)
    finish(nil, err)
  end

  local function alive()
    if handle.cancelled then
      finish(nil, "cancelled")
      return false
    end
    return true
  end

  function handle.cancel()
    handle.cancelled = true
    if handle.proc then pcall(handle.proc.kill, handle.proc, 15) end
    finish(nil, "cancelled")
  end

  vim.fn.mkdir(dir, "p")
  pcall(os.remove, vim.fs.joinpath(dir, "error.txt"))

  local diff_text, full_message
  local build
  local prompt_text

  local function run_agent(prompt_body, attempt, callback)
    phase(attempt == 1 and "agent" or "repair")
    local spec = backends.build(config.backend, {
      prompt = prompt_body,
      model = config.model,
      extra_args = config.backend_args,
      cwd = export_dir or opts.repo_path,
      sha = sha,
      output_path = function(name) return vim.fs.joinpath(dir, name) end,
    })
    local env = vim.tbl_extend("force", spec.env or {}, config.backend_env or {})
    if next(env) == nil then env = nil end
    local executable = spec.cmd[1]
    if vim.fn.executable(executable) == 0 then
      fail(("backend executable '%s' not found in PATH"):format(executable))
      return
    end
    local stdin = spec.stdin
    local ok, proc = pcall(system, spec.cmd, {
      cwd = export_dir or opts.repo_path,
      env = env,
      stdin = stdin ~= nil and stdin or false,
      text = true,
      timeout = config.timeout_ms,
    }, function(result)
      handle.proc = nil
      if not alive() then return end
      local suffix = attempt == 1 and "" or ("-repair" .. attempt)
      store.write(vim.fs.joinpath(dir, "raw" .. suffix .. ".txt"), result.stdout or "")
      store.write(vim.fs.joinpath(dir, "stderr" .. suffix .. ".log"), result.stderr or "")
      if result.code == 124 then
        fail(("backend killed after timeout_ms=%d"):format(config.timeout_ms))
        return
      end
      if result.signal and result.signal ~= 0 then
        fail(("backend killed by signal %d"):format(result.signal))
        return
      end
      if result.code ~= 0 then
        fail(("backend exited with code %d: %s"):format(result.code, tail(result.stderr, 400)))
        return
      end
      local text, err = backends.final_text(spec, result.stdout or "")
      if not text then
        fail(err)
        return
      end
      callback(text)
    end)
    if not ok then
      fail("failed to start backend: " .. tostring(proc))
      return
    end
    handle.proc = proc
  end

  local function write_visuals(result, callback)
    phase("visuals")
    local pending = {}
    for _, segment in ipairs(result.segments) do
      if segment.svg then pending[#pending + 1] = segment end
    end
    local warnings = {}
    local tool = visuals.detect(config.rasterizer)
    local index = 0
    local function next_segment()
      index = index + 1
      local segment = pending[index]
      if not segment then
        callback(warnings)
        return
      end
      local base = ("seg-%02d"):format(segment.index)
      local svg_path = vim.fs.joinpath(dir, base .. ".svg")
      local written, err = store.write(svg_path, segment.svg)
      segment.svg = nil
      if not written then
        warnings[#warnings + 1] = ("segment %d: could not write svg (%s)"):format(segment.index, tostring(err))
        next_segment()
        return
      end
      segment.visual = base .. ".svg"
      if not tool then
        next_segment()
        return
      end
      local png_path = vim.fs.joinpath(dir, base .. ".png")
      visuals.rasterize(tool, svg_path, png_path, function(ok, raster_err)
        if ok then
          segment.png = base .. ".png"
        else
          warnings[#warnings + 1] = ("segment %d: %s"):format(segment.index, raster_err or "rasterize failed")
        end
        next_segment()
      end)
    end
    next_segment()
  end

  local function finalize(result, warnings)
    write_visuals(result, function(visual_warnings)
      if not alive() then return end
      for _, warning in ipairs(visual_warnings) do warnings[#warnings + 1] = warning end
      for _, segment in ipairs(result.segments) do
        local files = {}
        local order = {}
        for _, id in ipairs(segment.changes) do
          for _, block in ipairs(build.blocks) do
            if block.id == id then
              local entry = files[block.file]
              if not entry then
                entry = { file = block.file, additions = 0, deletions = 0 }
                files[block.file] = entry
                order[#order + 1] = entry
              end
              entry.additions = entry.additions + #block.adds
              entry.deletions = entry.deletions + #block.dels
            end
          end
        end
        segment.files = order
      end
      local blocks = {}
      for _, block in ipairs(build.blocks) do
        blocks[#blocks + 1] = {
          id = block.id,
          file = block.file,
          dels = block.dels,
          adds = block.adds,
          new_start = block.new_start,
          new_end = block.new_end,
          anchor = block.anchor,
          file_level = block.file_level or nil,
          note = block.note,
        }
      end
      local artifact = {
        sha = sha,
        subject = opts.subject,
        message = full_message,
        source = opts.source,
        backend = { name = backends.name(config.backend), model = config.model },
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        overview = result.overview,
        segments = result.segments,
        unassigned = result.unassigned,
        excluded = build.excluded,
        files = build.files,
        blocks = blocks,
        warnings = warnings,
      }
      local saved, err = store.save(sha, artifact)
      if not saved then
        fail("could not save artifact: " .. tostring(err))
        return
      end
      artifact.dir = dir
      finish(artifact)
    end)
  end

  local function parse_and_maybe_repair(text, attempt)
    phase("parse")
    local result, errors, warnings = protocol.parse(text, build.blocks)
    if result then
      finalize(result, warnings)
      return
    end
    if attempt >= 2 then
      fail("agent output unusable after repair: " .. table.concat(errors, "; "))
      return
    end
    local repair_prompt = prompt_text .. "\n\n" .. prompt.repair(text, errors)
    store.write(vim.fs.joinpath(dir, "prompt-repair.md"), repair_prompt)
    run_agent(repair_prompt, attempt + 1, function(repaired)
      parse_and_maybe_repair(repaired, attempt + 1)
    end)
  end

  local function start_agent()
    if not alive() then return end
    phase("prompt")
    prompt_text = prompt.build({
      instructions = opts.instructions,
      source = opts.source,
      commits = opts.commits,
      commit = { sha = sha, message = full_message },
      annotated = build.annotated,
      excluded = build.excluded,
      blocks = build.blocks,
    })
    store.write(vim.fs.joinpath(dir, "prompt.md"), prompt_text)
    run_agent(prompt_text, 1, function(text) parse_and_maybe_repair(text, 1) end)
  end

  local function export_tree()
    if not config.export_tree then
      start_agent()
      return
    end
    phase("export")
    export_dir = vim.fn.tempname() .. "-raccoon-segments-" .. sha:sub(1, 12)
    vim.fn.mkdir(export_dir, "p")
    local tarball = export_dir .. ".tar"
    git(opts.repo_path, { "archive", "--format=tar", "-o", tarball, sha }, function(_, err)
      if not alive() then return end
      if err then
        fail(err)
        return
      end
      system({ "tar", "-xf", tarball, "-C", export_dir }, { text = true }, function(result)
        pcall(os.remove, tarball)
        if not alive() then return end
        if result.code ~= 0 then
          fail("tar failed: " .. tail(result.stderr, 300))
          return
        end
        remove_untrusted(export_dir)
        start_agent()
      end)
    end)
  end

  phase("diff")
  git(opts.repo_path, { "diff-tree", "-p", "-m", "--first-parent", "--root", "--no-commit-id", "-U3", sha },
    function(text, err)
      if not alive() then return end
      if err then
        fail(err)
        return
      end
      diff_text = text
      git(opts.repo_path, { "show", "-s", "--format=%B", sha }, function(message, message_err)
        if not alive() then return end
        if message_err then
          fail(message_err)
          return
        end
        full_message = (message or ""):gsub("%s+$", "")
        local files = changes.parse_diff(diff_text)
        build = changes.build(files, { exclude = config.exclude })
        if #build.blocks == 0 then
          fail(#build.excluded > 0 and "only excluded files changed" or "commit has no changes")
          return
        end
        if build.bytes > config.max_diff_bytes then
          fail(("diff is %d bytes; max_diff_bytes is %d"):format(build.bytes, config.max_diff_bytes))
          return
        end
        export_tree()
      end)
    end)

  return handle
end

return M
