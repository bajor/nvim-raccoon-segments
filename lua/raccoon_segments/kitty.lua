-- Kitty graphics protocol with Unicode placeholders (as implemented by
-- Ghostty). Escape builders and placeholder text are pure; the terminal
-- writer and cell-size query need Neovim.
local M = {}

M.CHUNK = 4096
M.PLACEHOLDER = "\xF3\xA0\xBB\xAE" -- U+10EEEE in UTF-8

local diacritics = require("raccoon_segments.vendor.diacritics")

local function utf8_char(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
  end
  return string.char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + (math.floor(code / 0x1000) % 0x40),
    0x80 + (math.floor(code / 0x40) % 0x40),
    0x80 + (code % 0x40)
  )
end
M.utf8_char = utf8_char

---Diacritic encoding the 0-based row/column `n`.
---@param n integer
---@return string
function M.diacritic(n)
  local code = diacritics[n + 1]
  assert(code, "row/column out of range for placeholder diacritics")
  return utf8_char(code)
end

M.MAX_PLACEHOLDER_DIM = #diacritics

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---@param data string
---@return string
function M.base64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

---Build one APC command: ESC _ G <keys> ; <payload> ESC \
---@param keys table<string, string|integer>
---@param payload? string
---@return string
function M.command(keys, payload)
  local names = {}
  for name in pairs(keys) do names[#names + 1] = name end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. tostring(keys[name]) end
  local body = table.concat(parts, ",")
  if payload and payload ~= "" then body = body .. ";" .. payload end
  return "\27_G" .. body .. "\27\\"
end

---Commands transmitting a PNG as direct data in chunks. q=2 suppresses
---terminal responses so nothing arrives as keystrokes in Neovim.
---@param png string raw PNG bytes
---@param image_id integer
---@return string[] commands
function M.transmit_png(png, image_id)
  local encoded = M.base64(png)
  local commands = {}
  local first = true
  local pos = 1
  repeat
    local chunk = encoded:sub(pos, pos + M.CHUNK - 1)
    pos = pos + M.CHUNK
    local more = pos <= #encoded and 1 or 0
    local keys = { m = more }
    if first then
      keys.a = "t"
      keys.f = 100
      keys.t = "d"
      keys.i = image_id
      keys.q = 2
      first = false
    end
    commands[#commands + 1] = M.command(keys, chunk)
  until more == 0
  return commands
end

---Command creating a Unicode placeholder (virtual) placement.
---@param image_id integer
---@param placement_id integer
---@param cols integer
---@param rows integer
---@return string
function M.place(image_id, placement_id, cols, rows)
  return M.command({ a = "p", U = 1, i = image_id, p = placement_id, c = cols, r = rows, C = 1, q = 2 })
end

---Command deleting a placement (or the whole image when placement_id is nil).
---@param image_id integer
---@param placement_id? integer
---@return string
function M.delete(image_id, placement_id)
  local keys = { a = "d", d = "i", i = image_id, q = 2 }
  if placement_id then keys.p = placement_id end
  return M.command(keys)
end

---Placeholder lines (`rows` lines of `cols` cells) for a placement. Each cell
---is U+10EEEE followed by the row diacritic and the column diacritic.
---@param cols integer
---@param rows integer
---@return string[]
function M.placeholder_lines(cols, rows)
  local lines = {}
  for row = 0, rows - 1 do
    local cells = {}
    local row_mark = M.diacritic(row)
    for col = 0, cols - 1 do
      cells[#cells + 1] = M.PLACEHOLDER .. row_mark .. M.diacritic(col)
    end
    lines[#lines + 1] = table.concat(cells)
  end
  return lines
end

---Parse PNG width/height from the IHDR chunk.
---@param png string
---@return integer|nil width, integer|nil height
function M.png_size(png)
  if type(png) ~= "string" or #png < 24 or png:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
  if png:sub(13, 16) ~= "IHDR" then return nil end
  local function u32(offset)
    local a, b, c, d = png:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

---Rows needed to show an image `cols` cells wide keeping its aspect ratio.
---@param width integer image pixels
---@param height integer image pixels
---@param cols integer
---@param cell_w number pixels per cell
---@param cell_h number pixels per cell
---@return integer rows
function M.rows_for(width, height, cols, cell_w, cell_h)
  local pixel_width = cols * cell_w
  local pixel_height = pixel_width * height / width
  return math.max(1, math.ceil(pixel_height / cell_h))
end

-- Everything below touches Neovim.

---@return boolean supported, string|nil reason
function M.detect()
  if vim.env.TMUX and vim.env.TMUX ~= "" then return false, "inside tmux" end
  local ghostty = vim.env.TERM_PROGRAM == "ghostty"
    or vim.env.TERM == "xterm-ghostty"
    or (vim.env.GHOSTTY_RESOURCES_DIR ~= nil and vim.env.GHOSTTY_RESOURCES_DIR ~= "")
  if not ghostty then return false, "not running in Ghostty" end
  if not vim.o.termguicolors then return false, "termguicolors is off" end
  if #vim.api.nvim_list_uis() == 0 then return false, "no attached UI" end
  return true
end

---Write raw bytes to the terminal.
---@param data string
function M.write(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
    io.stdout:flush()
  end
end

---Pixel size of one terminal cell via ioctl(TIOCGWINSZ); falls back to 1:2.
---@return number cell_w, number cell_h
function M.cell_size()
  local ok, ffi = pcall(require, "ffi")
  if ok then
    local TIOCGWINSZ
    if vim.fn.has("linux") == 1 then
      TIOCGWINSZ = 0x5413
    elseif vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1 then
      TIOCGWINSZ = 0x40087468
    end
    if TIOCGWINSZ then
      local defined = pcall(ffi.cdef, [[
        typedef struct { unsigned short rows, cols, xpixel, ypixel; } raccoon_winsize;
        int ioctl(int, unsigned long, ...);
      ]])
      local size = ffi.new("raccoon_winsize")
      local rc = -1
      if defined or pcall(function() return ffi.typeof("raccoon_winsize") end) then
        rc = ffi.C.ioctl(1, TIOCGWINSZ, size)
      end
      if rc == 0 and size.cols > 0 and size.rows > 0 and size.xpixel > 0 and size.ypixel > 0 then
        return size.xpixel / size.cols, size.ypixel / size.rows
      end
    end
  end
  return 8, 16
end

return M
