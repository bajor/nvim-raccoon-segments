-- SVG to PNG rasterization with whatever the machine has.
local M = {}

M.PNG_WIDTH = 1600

local cached

---@param preference string|false "auto"|"rsvg-convert"|"magick"|"qlmanage"|false
---@return string|nil name
function M.detect(preference)
  if preference == false then return nil end
  if preference ~= "auto" then
    return vim.fn.executable(preference) == 1 and preference or nil
  end
  if cached ~= nil then return cached or nil end
  for _, candidate in ipairs({ "rsvg-convert", "magick", "qlmanage" }) do
    if vim.fn.executable(candidate) == 1 then
      cached = candidate
      return candidate
    end
  end
  cached = false
  return nil
end

function M.reset_cache()
  cached = nil
end

---Command that writes `png` from `svg`. qlmanage names its output itself:
---<dir>/<basename>.png, which the caller renames afterwards.
---@param tool string
---@param svg string
---@param png string
---@return string[] cmd, string|nil produced_path
function M.command(tool, svg, png)
  if tool == "rsvg-convert" then
    return { "rsvg-convert", "-w", tostring(M.PNG_WIDTH), "-o", png, svg }
  end
  if tool == "magick" then
    return { "magick", "-density", "144", "-background", "none", svg, "-resize", M.PNG_WIDTH .. "x", png }
  end
  local dir = vim.fs.dirname(png)
  local produced = vim.fs.joinpath(dir, vim.fs.basename(svg) .. ".png")
  return { "qlmanage", "-t", "-s", tostring(M.PNG_WIDTH), "-o", dir, svg }, produced
end

---@param tool string
---@param svg string
---@param png string
---@param callback fun(ok: boolean, err: string|nil)
function M.rasterize(tool, svg, png, callback)
  local cmd, produced = M.command(tool, svg, png)
  vim.system(cmd, { text = true }, function(result)
    -- Callback runs on the main loop: vim.fn is not allowed in luv callbacks.
    vim.schedule(function()
      if result.code ~= 0 then
        callback(false, (tool .. " failed: " .. (result.stderr or "")):gsub("%s+$", ""))
        return
      end
      if produced and produced ~= png then
        local renamed = os.rename(produced, png)
        if not renamed then
          callback(false, tool .. " produced no output file")
          return
        end
      end
      if vim.fn.filereadable(png) == 0 then
        callback(false, tool .. " produced no output file")
        return
      end
      callback(true)
    end)
  end)
end

return M
