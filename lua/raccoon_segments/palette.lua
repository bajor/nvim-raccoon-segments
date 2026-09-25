-- Segment colours: pure blend math plus Neovim highlight groups.
local M = {}

-- Ten hues that avoid pure red and green so they never read as add/delete.
M.HUES = {
  "#5aa9e6", -- blue
  "#f2a65a", -- orange
  "#b07be0", -- purple
  "#3cc9c0", -- teal
  "#e6c34a", -- yellow
  "#ec7cb0", -- pink
  "#8fbf61", -- lime
  "#e07a5f", -- coral
  "#7e9cf0", -- periwinkle
  "#c9a66b", -- sand
}
M.UNASSIGNED = "#8a8a8a"

---@param hex string "#rrggbb"
---@return integer r, integer g, integer b
function M.hex_to_rgb(hex)
  local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

---@param r number
---@param g number
---@param b number
---@return string
function M.rgb_to_hex(r, g, b)
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v + 0.5)))
  end
  return ("#%02x%02x%02x"):format(clamp(r), clamp(g), clamp(b))
end

---Blend colour `top` over `base` with opacity `alpha` (0..1).
---@param base string
---@param top string
---@param alpha number
---@return string
function M.blend(base, top, alpha)
  local br, bg, bb = M.hex_to_rgb(base)
  local tr, tg, tb = M.hex_to_rgb(top)
  return M.rgb_to_hex(br + (tr - br) * alpha, bg + (tg - bg) * alpha, bb + (tb - bb) * alpha)
end

---@param index integer 1-based segment index
---@param colors? string[]
---@return string
function M.hue(index, colors)
  local list = colors or M.HUES
  return list[((index - 1) % #list) + 1]
end

local NAMES = {
  add = "RaccoonSegmentsAdd",
  del = "RaccoonSegmentsDel",
  fg = "RaccoonSegmentsFg",
  badge = "RaccoonSegmentsBadge",
}

---@param kind "add"|"del"|"fg"|"badge"
---@param index integer|"unassigned"
---@return string
function M.group(kind, index)
  return NAMES[kind] .. (index == "unassigned" and "Unassigned" or tostring(index))
end

local function hl_bg(name, fallback)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" and hl.bg then return ("#%06x"):format(hl.bg) end
  return fallback
end

---Define highlight groups for `count` segments. Safe to call repeatedly.
---@param count integer
---@param colors? string[]
function M.setup_highlights(count, colors)
  local add_bg = hl_bg("RaccoonAdd", hl_bg("DiffAdd", "#2d5a2d"))
  local del_bg = hl_bg("RaccoonDelete", hl_bg("DiffDelete", "#5a2020"))
  local normal_bg = hl_bg("Normal", "#1e1e1e")
  local function define(index, hue)
    vim.api.nvim_set_hl(0, M.group("add", index), { bg = M.blend(add_bg, hue, 0.35) })
    vim.api.nvim_set_hl(0, M.group("del", index), { bg = M.blend(del_bg, hue, 0.35) })
    vim.api.nvim_set_hl(0, M.group("fg", index), { fg = hue, bold = true })
    vim.api.nvim_set_hl(0, M.group("badge", index), { fg = hue, bg = M.blend(normal_bg, hue, 0.12), bold = true })
  end
  for index = 1, math.max(count, #(colors or M.HUES)) do
    define(index, M.hue(index, colors))
  end
  define("unassigned", M.UNASSIGNED)
  vim.api.nvim_set_hl(0, "RaccoonSegmentsHeading", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "RaccoonSegmentsDim", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "RaccoonSegmentsStale", { default = true, link = "WarningMsg" })
end

return M
