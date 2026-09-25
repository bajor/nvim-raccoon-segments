-- Output protocol: extract, validate and normalize the agent's reply.
-- Needs vim.json for decoding; everything else is plain Lua.
local M = {}

M.MAX_SEGMENTS = 12
M.MAX_TITLE = 60
M.MAX_UNASSIGNED_RATIO = 0.3

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_fences(text)
  local inner = text:match("^%s*```[%w%-]*\n(.-)\n%s*```%s*$")
  return inner or text
end

---Find the last complete <segments> block and every <visual> block.
---@param raw string
---@return table|nil extracted {json = string, visuals = {[index] = svg}}, string|nil err
function M.extract(raw)
  if type(raw) ~= "string" then return nil, "no output" end
  local last_json
  for body in raw:gmatch("<segments>(.-)</segments>") do
    last_json = body
  end
  if not last_json then return nil, "no <segments> block found" end
  local visuals = {}
  for index, body in raw:gmatch('<visual%s+segment%s*=%s*"?(%d+)"?%s*>(.-)</visual>') do
    visuals[tonumber(index)] = trim(strip_fences(trim(body)))
  end
  return { json = trim(strip_fences(trim(last_json))), visuals = visuals }
end

local FORBIDDEN_TAGS = { "script", "foreignObject", "image", "iframe", "object", "embed", "audio", "video" }

---Reduce an SVG to something safe to rasterize and open in a browser.
---@param svg string
---@return string|nil sanitized, string|nil reason
function M.sanitize_svg(svg)
  if type(svg) ~= "string" then return nil, "not a string" end
  local start = svg:find("<svg[%s>]")
  local stop = select(2, svg:find("</svg>%s*$")) or select(2, svg:find(".*</svg>"))
  if not start or not stop then return nil, "not an <svg> element" end
  local body = svg:sub(start, stop)
  for _, tag in ipairs(FORBIDDEN_TAGS) do
    body = body:gsub("<" .. tag .. "[^>]*/>", "")
    body = body:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. ">", "")
    body = body:gsub("<" .. tag .. "[^>]*>", "")
  end
  body = body:gsub("%s+on%w+%s*=%s*\"[^\"]*\"", "")
  body = body:gsub("%s+on%w+%s*=%s*'[^']*'", "")
  body = body:gsub("%s+[%w:]*href%s*=%s*\"%s*[%w+.-]+:[^\"]*\"", function(attr)
    if attr:match("=%s*\"%s*#") then return attr end
    return ""
  end)
  body = body:gsub("%s+[%w:]*href%s*=%s*'%s*[%w+.-]+:[^']*'", function(attr)
    if attr:match("=%s*'%s*#") then return attr end
    return ""
  end)
  body = body:gsub("@import[^;]*;", "")
  body = body:gsub("url%s*%(%s*['\"]?%s*[%w+.-]+:[^)]*%)", "none")
  if not body:match("^<svg[^>]*xmlns%s*=") then
    body = body:gsub("^<svg", '<svg xmlns="http://www.w3.org/2000/svg"', 1)
  end
  return body
end

local function as_string(value)
  if type(value) == "string" then return value end
  if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
  return nil
end

local function string_list(value, limit)
  local out = {}
  if type(value) ~= "table" then return out end
  for _, item in ipairs(value) do
    local text = as_string(item)
    if text and trim(text) ~= "" then out[#out + 1] = trim(text) end
    if limit and #out >= limit then break end
  end
  return out
end

local function truncate(text, limit)
  if #text <= limit then return text end
  return text:sub(1, limit - 1) .. "…"
end

---Validate decoded JSON against the change blocks.
---@param data any decoded JSON
---@param blocks table[] from changes.build
---@return table|nil normalized {overview, segments, unassigned}, string[] errors, string[] warnings
function M.normalize(data, blocks)
  local errors, warnings = {}, {}
  if type(data) ~= "table" then
    return nil, { "JSON in <segments> must be an object" }, warnings
  end
  local overview = as_string(data.overview)
  if not overview or trim(overview) == "" then
    errors[#errors + 1] = "overview is missing or empty"
    overview = ""
  end

  local known = {}
  for _, block in ipairs(blocks) do known[block.id] = block end
  local assigned = {}
  local segments = {}

  if type(data.segments) ~= "table" or #data.segments == 0 then
    errors[#errors + 1] = "segments must be a non-empty array"
  else
    for index, raw in ipairs(data.segments) do
      if type(raw) ~= "table" then
        warnings[#warnings + 1] = ("segment %d is not an object; dropped"):format(index)
      else
        local changes = {}
        local raw_changes = raw.changes
        if type(raw_changes) == "string" then raw_changes = { raw_changes } end
        for _, id in ipairs(type(raw_changes) == "table" and raw_changes or {}) do
          local text = as_string(id)
          text = text and trim(text)
          if not text or not known[text] then
            warnings[#warnings + 1] = ("segment %d: unknown change id %s; dropped"):format(index, tostring(id))
          elseif assigned[text] then
            warnings[#warnings + 1] = ("segment %d: change %s already assigned to segment %d; dropped")
              :format(index, text, assigned[text])
          else
            assigned[text] = index
            changes[#changes + 1] = text
          end
        end
        local title = as_string(raw.title)
        title = title and trim(title) or ""
        if title == "" then
          title = "Segment " .. index
          warnings[#warnings + 1] = ("segment %d: missing title"):format(index)
        end
        if #changes == 0 and not raw.file_level then
          warnings[#warnings + 1] = ("segment %d (%s): no valid changes; dropped"):format(index, title)
        else
          segments[#segments + 1] = {
            title = truncate(title, M.MAX_TITLE),
            summary = trim(as_string(raw.summary) or ""),
            changes = changes,
            explanation = trim(as_string(raw.explanation) or ""),
            review_focus = string_list(raw.review_focus, 6),
            source_index = index,
          }
        end
      end
    end
    if #segments == 0 and #errors == 0 then
      errors[#errors + 1] = "every segment was dropped (no valid change ids)"
    end
    if #segments > M.MAX_SEGMENTS then
      warnings[#warnings + 1] = ("%d segments; keeping the first %d"):format(#segments, M.MAX_SEGMENTS)
      for i = #segments, M.MAX_SEGMENTS + 1, -1 do
        for _, id in ipairs(segments[i].changes) do assigned[id] = nil end
        segments[i] = nil
      end
    end
  end

  local unassigned = {}
  for _, block in ipairs(blocks) do
    if not assigned[block.id] then unassigned[#unassigned + 1] = block.id end
  end
  if #blocks > 0 and #unassigned > 0 then
    local ratio = #unassigned / #blocks
    local ids = table.concat(unassigned, ", ")
    if ratio > M.MAX_UNASSIGNED_RATIO then
      errors[#errors + 1] = ("%d of %d change ids were not assigned to any segment: %s")
        :format(#unassigned, #blocks, ids)
    else
      warnings[#warnings + 1] = ("unassigned change ids: %s"):format(ids)
    end
  end

  if #errors > 0 then return nil, errors, warnings end
  for index, segment in ipairs(segments) do segment.index = index end
  return { overview = trim(overview), segments = segments, unassigned = unassigned }, errors, warnings
end

---Full parse: raw text -> normalized result with sanitized visuals.
---@param raw string
---@param blocks table[]
---@return table|nil result, string[] errors, string[] warnings
function M.parse(raw, blocks)
  local extracted, err = M.extract(raw)
  if not extracted then return nil, { err }, {} end
  local ok, data = pcall(vim.json.decode, extracted.json)
  if not ok then
    return nil, { "JSON in <segments> is invalid: " .. tostring(data):gsub("\n.*", "") }, {}
  end
  local result, errors, warnings = M.normalize(data, blocks)
  if not result then return nil, errors, warnings end
  for _, segment in ipairs(result.segments) do
    local svg = extracted.visuals[segment.source_index]
    if svg then
      local clean, reason = M.sanitize_svg(svg)
      if clean then
        segment.svg = clean
      else
        warnings[#warnings + 1] = ("segment %d: visual dropped (%s)"):format(segment.index, reason)
      end
    end
    segment.source_index = nil
  end
  return result, errors, warnings
end

return M
