-- Pure diff handling: git diff-tree output -> files -> change blocks.
--
-- A change block is a maximal run of added/deleted lines inside one hunk.
-- Blocks are identified by content, which keeps them stable regardless of how
-- much context a viewer shows around them.
local M = {}

---Convert a glob into a Lua pattern. Supports `**`, `*` and `?`.
---@param glob string
---@return string
function M.glob_to_pattern(glob)
  local out = { "^" }
  local i = 1
  while i <= #glob do
    local char = glob:sub(i, i)
    if char == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        if glob:sub(i + 2, i + 2) == "/" then
          out[#out + 1] = "\1"
          i = i + 3
        else
          out[#out + 1] = ".*"
          i = i + 2
        end
      else
        out[#out + 1] = "[^/]*"
        i = i + 1
      end
    elseif char == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    else
      out[#out + 1] = char:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

local function glob_matches(glob, path)
  local pattern = M.glob_to_pattern(glob)
  if pattern:find("\1", 1, true) then
    -- "**/" matches zero or more directories.
    local with_dirs = pattern:gsub("\1", ".*/")
    local without_dirs = pattern:gsub("\1", "")
    return path:match(with_dirs) ~= nil or path:match(without_dirs) ~= nil
  end
  return path:match(pattern) ~= nil
end

---@param path string
---@param globs string[]
---@return boolean
function M.is_excluded(path, globs)
  local basename = path:match("[^/]+$") or path
  for _, glob in ipairs(globs or {}) do
    local target = glob:find("/", 1, true) and path or basename
    if glob_matches(glob, target) then return true end
  end
  return false
end

local function split_lines(text)
  if type(text) == "table" then return text end
  local lines = {}
  if text == nil or text == "" then return lines end
  local normalized = text:sub(-1) == "\n" and text or (text .. "\n")
  for line in normalized:gmatch("(.-)\n") do lines[#lines + 1] = line end
  return lines
end
M.split_lines = split_lines

local function unquote(path)
  if path:sub(1, 1) ~= '"' then return path end
  local inner = path:sub(2, -2)
  inner = inner:gsub("\\(%d%d%d)", function(octal) return string.char(tonumber(octal, 8)) end)
  inner = inner:gsub("\\(.)", { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" })
  return inner
end

---Parse `git diff-tree -p` output into files. The filename rule mirrors
---raccoon's parse_diff_output (b-side path of the `diff --git` line) so that
---files can be matched against raccoon's commit-viewer hunks.
---@param text string|string[]
---@return table[] files {filename, old_filename, status, binary, lines}
function M.parse_diff(text)
  local files = {}
  local current
  for _, line in ipairs(split_lines(text)) do
    if line:match("^diff %-%-git ") then
      local a_path, b_path = line:match("^diff %-%-git a/(.+) b/(.+)$")
      if not a_path then
        local qa, qb = line:match('^diff %-%-git ("a/.-") ("b/.-")$')
        if qa then
          a_path, b_path = unquote(qa):sub(3), unquote(qb):sub(3)
        end
      end
      current = {
        filename = (b_path ~= "dev/null" and b_path) or a_path or "?",
        old_filename = nil,
        status = "modified",
        binary = false,
        lines = {},
      }
      files[#files + 1] = current
    elseif current then
      if #current.lines > 0 or line:match("^@@") then
        current.lines[#current.lines + 1] = line
      elseif line:match("^new file mode") then
        current.status = "added"
      elseif line:match("^deleted file mode") then
        current.status = "deleted"
      elseif line:match("^rename from ") then
        current.status = "renamed"
        current.old_filename = unquote(line:match("^rename from (.+)$"))
      elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
        current.binary = true
      end
    end
  end
  return files
end

---Parse hunk lines with the same semantics as raccoon.diff.parse_patch:
---deleted lines carry the last new-file line number before them.
---@param lines string[]
---@return table[] hunks {header, lines = {type, content, line_num}}
function M.parse_hunks(lines)
  local hunks = {}
  local hunk
  local line_num = 0
  for _, line in ipairs(lines) do
    if line:match("^@@") then
      local new_start = line:match("^@@.-+(%d+)")
      hunk = { header = line, lines = {} }
      hunks[#hunks + 1] = hunk
      line_num = (tonumber(new_start) or 1) - 1
    elseif hunk then
      if line:match("^%+") and not line:match("^%+%+%+") then
        line_num = line_num + 1
        hunk.lines[#hunk.lines + 1] = { type = "add", content = line:sub(2), line_num = line_num }
      elseif line:match("^%-") and not line:match("^%-%-%-") then
        hunk.lines[#hunk.lines + 1] = { type = "del", content = line:sub(2), line_num = line_num }
      elseif not line:match("^\\ No newline at end of file$") and (line:match("^%s") or line == "") then
        line_num = line_num + 1
        hunk.lines[#hunk.lines + 1] = { type = "ctx", content = line:sub(2), line_num = line_num }
      end
    end
  end
  return hunks
end

---Group typed lines into runs of consecutive add/del lines.
---@param typed table[] list of {type = "add"|"del"|"ctx", content}
---@return table[] runs {first, last, dels, adds}
function M.runs(typed)
  local runs = {}
  local run
  for index, line in ipairs(typed) do
    if line.type == "add" or line.type == "del" then
      if not run then
        run = { first = index, last = index, dels = {}, adds = {}, anchor = line.line_num }
        runs[#runs + 1] = run
      end
      run.last = index
      if line.type == "add" then
        run.adds[#run.adds + 1] = line.content
      else
        run.dels[#run.dels + 1] = line.content
      end
    else
      run = nil
    end
  end
  return runs
end

---@param dels string[]
---@param adds string[]
---@return string
function M.run_key(dels, adds)
  return table.concat(dels, "\n") .. "\1" .. table.concat(adds, "\n")
end

local function file_label(file)
  local parts = { file.status }
  if file.old_filename then parts[#parts + 1] = "from " .. file.old_filename end
  if file.binary then parts[#parts + 1] = "binary" end
  return table.concat(parts, ", ")
end

---Turn parsed files into change blocks plus an annotated diff for the prompt.
---@param files table[] from parse_diff
---@param opts? {exclude?: string[]}
---@return table result {blocks, excluded, files, annotated, bytes}
function M.build(files, opts)
  opts = opts or {}
  local blocks = {}
  local excluded = {}
  local out_files = {}
  local annotated = {}

  for _, file in ipairs(files) do
    local hunks = M.parse_hunks(file.lines)
    local additions, deletions = 0, 0
    for _, hunk in ipairs(hunks) do
      for _, line in ipairs(hunk.lines) do
        if line.type == "add" then additions = additions + 1 end
        if line.type == "del" then deletions = deletions + 1 end
      end
    end

    if M.is_excluded(file.filename, opts.exclude) then
      excluded[#excluded + 1] = { file = file.filename, additions = additions, deletions = deletions }
    else
      local entry = {
        file = file.filename,
        status = file.status,
        additions = additions,
        deletions = deletions,
        blocks = {},
      }
      out_files[#out_files + 1] = entry
      annotated[#annotated + 1] = ("### %s (%s, +%d -%d)"):format(file.filename, file_label(file), additions, deletions)

      local function new_block(fields)
        fields.id = "c" .. (#blocks + 1)
        fields.file = file.filename
        blocks[#blocks + 1] = fields
        entry.blocks[#entry.blocks + 1] = fields.id
        return fields
      end

      local has_run = false
      for _, hunk in ipairs(hunks) do
        annotated[#annotated + 1] = hunk.header
        local runs = M.runs(hunk.lines)
        local next_run = 1
        for index, line in ipairs(hunk.lines) do
          local run = runs[next_run]
          if run and index == run.first then
            local first_add
            local last_add
            local anchor = line.line_num
            for i = run.first, run.last do
              local l = hunk.lines[i]
              if l.type == "add" then
                first_add = first_add or l.line_num
                last_add = l.line_num
              end
            end
            local block = new_block({
              dels = run.dels,
              adds = run.adds,
              new_start = first_add,
              new_end = last_add,
              anchor = anchor,
            })
            annotated[#annotated + 1] = "@" .. block.id
            has_run = true
            next_run = next_run + 1
          end
          local prefix = line.type == "add" and "+" or (line.type == "del" and "-" or " ")
          annotated[#annotated + 1] = prefix .. line.content
        end
      end

      if not has_run then
        local note = file.binary and "binary change" or (file.status == "renamed" and "rename only") or "metadata only"
        local block = new_block({ dels = {}, adds = {}, file_level = true, note = note })
        annotated[#annotated + 1] = ("@%s (whole file: %s)"):format(block.id, note)
      end
      annotated[#annotated + 1] = ""
    end
  end

  local text = table.concat(annotated, "\n")
  return { blocks = blocks, excluded = excluded, files = out_files, annotated = text, bytes = #text }
end

local function numstat_path(raw)
  local pre, _, new, post = raw:match("^(.-){(.-) => (.-)}(.*)$")
  if pre then return (pre .. new .. post):gsub("//", "/") end
  local _, target = raw:match("^(.-) => (.+)$")
  return target or raw
end

---Count changed lines from `git diff-tree --numstat` output.
---@param text string|string[]
---@param exclude? string[]
---@return integer changed, boolean binary_only
function M.count_numstat(text, exclude)
  local total = 0
  local text_files = 0
  local binary_files = 0
  for _, line in ipairs(split_lines(text)) do
    local added, deleted, raw = line:match("^(%S+)\t(%S+)\t(.+)$")
    if added then
      local path = numstat_path(raw)
      if not M.is_excluded(path, exclude) then
        if added == "-" or deleted == "-" then
          binary_files = binary_files + 1
        else
          text_files = text_files + 1
          total = total + (tonumber(added) or 0) + (tonumber(deleted) or 0)
        end
      end
    end
  end
  return total, (binary_files > 0 and text_files == 0)
end

---Match runs (from a viewer buffer) to blocks by content. When a run carries
---a new-file anchor line, the block with the same content and the closest
---anchor wins, so identical edits in one file map to the right block.
---@param runs table[] from M.runs
---@param blocks table[] candidate blocks (usually one file's blocks)
---@return table<integer, string> run index -> block id
function M.match(runs, blocks)
  local by_key = {}
  for _, block in ipairs(blocks) do
    if not block.file_level then
      local key = M.run_key(block.dels, block.adds)
      by_key[key] = by_key[key] or {}
      table.insert(by_key[key], block)
    end
  end
  local used = {}
  local result = {}
  for index, run in ipairs(runs) do
    local candidates = by_key[M.run_key(run.dels, run.adds)]
    local best, best_distance
    for _, block in ipairs(candidates or {}) do
      if not used[block.id] then
        local distance = 0
        if run.anchor and block.anchor then distance = math.abs(run.anchor - block.anchor) end
        if not best or distance < best_distance then
          best, best_distance = block, distance
        end
      end
    end
    if best then
      used[best.id] = true
      result[index] = best.id
    end
  end
  return result
end

---Rebuild typed lines (with new-file line numbers) from a full-file diff view
---where each row is known to be add/del/ctx.
---@param records table[] {kind = "addition"|"deletion"|"context", content}
---@param first_line? integer new-file line number of the first non-deleted row
---@return table[] typed
function M.typed_from_records(records, first_line)
  local typed = {}
  local line_num = (first_line or 1) - 1
  for index, record in ipairs(records) do
    if record.kind == "deletion" then
      typed[index] = { type = "del", content = record.content, line_num = line_num }
    else
      line_num = line_num + 1
      typed[index] = {
        type = record.kind == "addition" and "add" or "ctx",
        content = record.content,
        line_num = line_num,
      }
    end
  end
  return typed
end

return M
