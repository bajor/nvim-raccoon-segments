-- Explanation popup: one scrollable document per commit, with Ghostty images.
local adapter = require("raccoon_segments.host.raccoon")
local decorate = require("raccoon_segments.decorate")
local kitty = require("raccoon_segments.kitty")
local palette = require("raccoon_segments.palette")
local queue = require("raccoon_segments.queue")
local store = require("raccoon_segments.store")

local M = {}

local ns = vim.api.nvim_create_namespace("raccoon_segments_popup")
local popup -- {win, buf, viewer, sha, headings, placements, segments_svg}
local image_ids = {} -- png path -> image id
local next_image_id = 0x52530000 -- "RS" prefix keeps ids away from other plugins
local next_placement_id = 0
local writer = kitty.write

M.MAX_IMAGE_RATIO = 0.6

function M.set_writer(fn)
  writer = fn
end

function M.is_open()
  return popup ~= nil and vim.api.nvim_win_is_valid(popup.win)
end

local function image_support()
  if M.config and M.config.images == false then return false, "images disabled in config" end
  return kitty.detect()
end
M.image_support = image_support

local function transmit(png_path)
  local id = image_ids[png_path]
  if id then return id end
  local data = store.read(png_path)
  if not data then return nil end
  local width, height = kitty.png_size(data)
  if not width then return nil end
  next_image_id = next_image_id + 1
  id = next_image_id
  for _, command in ipairs(kitty.transmit_png(data, id)) do writer(command) end
  image_ids[png_path] = id
  return id, width, height
end

local function close()
  if not popup then return end
  local current = popup
  popup = nil
  for _, placement in ipairs(current.placements) do
    pcall(writer, kitty.delete(placement.image_id, placement.placement_id))
  end
  if vim.api.nvim_win_is_valid(current.win) then pcall(vim.api.nvim_win_close, current.win, true) end
  adapter.clear_popup_win(current.viewer)
end
M.close = close

local function wrap(text, width)
  local out = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    if paragraph == "" then
      out[#out + 1] = ""
    elseif paragraph:match("^%s*[-*] ") or paragraph:match("^%s*%d+%. ") or paragraph:match("^```") then
      out[#out + 1] = paragraph
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line == "" then
          line = word
        elseif vim.fn.strdisplaywidth(line .. " " .. word) > width then
          out[#out + 1] = line
          line = word
        else
          line = line .. " " .. word
        end
      end
      out[#out + 1] = line
    end
  end
  return out
end

---Build the document lines plus highlight/image plans.
---@param artifact table
---@param opts {width: integer, images: boolean, cell_w: number, cell_h: number, max_rows: integer}
---@return string[] lines, table[] marks, table[] images, table headings
function M.render(artifact, opts)
  local lines, marks, images, headings = {}, {}, {}, {}
  local width = opts.width
  local function add(text, group)
    lines[#lines + 1] = text
    if group then marks[#marks + 1] = { row = #lines - 1, group = group } end
  end

  add("Overview", "RaccoonSegmentsHeading")
  for _, line in ipairs(wrap(artifact.overview or "", width)) do add(line) end
  if artifact.warnings and #artifact.warnings > 0 then
    add("")
    add(("⚠ %d warning%s while generating (see :RaccoonSegments status)"):format(
      #artifact.warnings, #artifact.warnings == 1 and "" or "s"), "RaccoonSegmentsStale")
  end

  for _, segment in ipairs(artifact.segments) do
    add("")
    local heading = ("%s %s"):format(decorate.circled(segment.index), segment.title)
    add(heading, palette.group("fg", segment.index))
    headings[#headings + 1] = { row = #lines - 1, segment = segment }
    if segment.summary and segment.summary ~= "" then
      for _, line in ipairs(wrap(segment.summary, width)) do add(line, "RaccoonSegmentsDim") end
    end

    local png = segment.png and vim.fs.joinpath(artifact.dir, segment.png)
    if opts.images and png and vim.fn.filereadable(png) == 1 then
      local data = store.read(png)
      local pw, ph
      if data then pw, ph = kitty.png_size(data) end
      if pw then
        local cols = math.min(width, kitty.MAX_PLACEHOLDER_DIM)
        local rows = math.min(kitty.rows_for(pw, ph, cols, opts.cell_w, opts.cell_h), opts.max_rows,
          kitty.MAX_PLACEHOLDER_DIM)
        add("")
        images[#images + 1] = { row = #lines, cols = cols, rows = rows, png = png, segment = segment }
        for _ = 1, rows do add("") end
      end
    elseif segment.visual then
      add("")
      add(("[diagram: %s — press o to open in browser]"):format(segment.visual), "RaccoonSegmentsDim")
    end

    if segment.explanation and segment.explanation ~= "" then
      add("")
      for _, line in ipairs(wrap(segment.explanation, width)) do add(line) end
    end
    if segment.review_focus and #segment.review_focus > 0 then
      add("")
      add("Review focus", "RaccoonSegmentsHeading")
      for _, item in ipairs(segment.review_focus) do
        local wrapped = wrap(item, width - 4)
        for index, line in ipairs(wrapped) do add((index == 1 and "  • " or "    ") .. line) end
      end
    end
    if segment.files and #segment.files > 0 then
      add("")
      for _, file in ipairs(segment.files) do
        add(("  %s  +%d -%d"):format(file.file, file.additions or 0, file.deletions or 0), "RaccoonSegmentsDim")
      end
    end
  end

  if artifact.unassigned and #artifact.unassigned > 0 then
    add("")
    add("○ Unassigned changes: " .. table.concat(artifact.unassigned, ", "), palette.group("fg", "unassigned"))
  end
  return lines, marks, images, headings
end

local function place_images(buf, images)
  local placements = {}
  for _, image in ipairs(images) do
    local image_id = transmit(image.png)
    if image_id then
      next_placement_id = next_placement_id + 1
      local placement_id = next_placement_id
      writer(kitty.place(image_id, placement_id, image.cols, image.rows))
      local group = ("RaccoonSegmentsImage%d"):format(placement_id)
      vim.api.nvim_set_hl(0, group, { fg = image_id, sp = placement_id, nocombine = true })
      local lines = kitty.placeholder_lines(image.cols, image.rows)
      vim.api.nvim_buf_set_lines(buf, image.row, image.row + image.rows, false, lines)
      for offset = 0, image.rows - 1 do
        vim.api.nvim_buf_set_extmark(buf, ns, image.row + offset, 0, {
          end_row = image.row + offset,
          end_col = #lines[offset + 1],
          hl_group = group,
          priority = 300,
        })
      end
      placements[#placements + 1] = { image_id = image_id, placement_id = placement_id }
    end
  end
  return placements
end

local function explained_neighbours(viewer, sha, direction)
  local commits = adapter.commits(viewer)
  local position
  for index, commit in ipairs(commits) do
    if commit.sha == sha then position = index end
  end
  if not position then return nil end
  local index = position + direction
  while commits[index] do
    if commits[index].sha and store.has(commits[index].sha) then return commits[index] end
    index = index + direction
  end
  return nil
end

local function jump_heading(direction)
  if not popup then return end
  local row = vim.api.nvim_win_get_cursor(popup.win)[1] - 1
  local target
  if direction > 0 then
    for _, heading in ipairs(popup.headings) do
      if heading.row > row then
        target = heading
        break
      end
    end
  else
    for index = #popup.headings, 1, -1 do
      if popup.headings[index].row < row then
        target = popup.headings[index]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(popup.win, { target.row + 1, 0 })
    vim.cmd("normal! zt")
  end
end

local function segment_under_cursor()
  if not popup then return nil end
  local row = vim.api.nvim_win_get_cursor(popup.win)[1] - 1
  local current
  for _, heading in ipairs(popup.headings) do
    if heading.row <= row then current = heading.segment end
  end
  return current or (popup.headings[1] and popup.headings[1].segment)
end

local function open_svg()
  local segment = segment_under_cursor()
  if not segment or not segment.visual then
    vim.notify("raccoon-segments: this segment has no diagram", vim.log.levels.INFO)
    return
  end
  local path = vim.fs.joinpath(popup.artifact.dir, segment.visual)
  local ok, err = pcall(function()
    local result = vim.ui.open(path)
    if type(result) == "table" and result.wait then result:wait() end
  end)
  if not ok then
    vim.notify("raccoon-segments: could not open " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

---@param viewer table
---@param commit table {sha, message, index}
---@param focus_segment? table
function M.show(viewer, commit, focus_segment)
  close()
  local artifact = decorate.artifact(commit.sha)
  if not artifact then
    local entry = queue.entry(commit.sha)
    local keys = M.keys or {}
    local message
    if entry and entry.status == "running" then
      message = ("still generating (%s)"):format(entry.phase or "…")
    elseif entry and entry.status == "queued" then
      message = "queued for generation"
    elseif entry and entry.status == "failed" then
      message = "generation failed: " .. tostring(entry.error) .. " — :RaccoonSegments log"
    elseif entry and entry.status == "skipped" then
      message = ("skipped: %d changed lines < min_changed_lines (%d)"):format(entry.changed or 0,
        M.config and M.config.min_changed_lines or 0)
    else
      message = ("no explanation for %s yet — %s to generate"):format(
        commit.sha:sub(1, 7), keys.generate or ":RaccoonSegments generate")
    end
    vim.notify("raccoon-segments: " .. message, vim.log.levels.INFO)
    return
  end
  palette.setup_highlights(#artifact.segments, M.config and M.config.colors)

  local editor_w, editor_h = vim.o.columns, vim.o.lines
  local win_w = math.max(40, math.min(110, math.floor(editor_w * 0.8)))
  local win_h = math.max(10, math.floor(editor_h * 0.85))
  local text_w = win_w - 2
  local images_ok, reason = image_support()
  local cell_w, cell_h = 8, 16
  if images_ok then cell_w, cell_h = kitty.cell_size() end
  local lines, marks, images, headings = M.render(artifact, {
    width = text_w,
    images = images_ok,
    cell_w = cell_w,
    cell_h = cell_h,
    max_rows = math.max(4, math.floor(win_h * M.MAX_IMAGE_RATIO)),
  })
  if not images_ok then
    local has_visual = false
    for _, segment in ipairs(artifact.segments) do has_visual = has_visual or segment.visual ~= nil end
    if has_visual then
      table.insert(lines, 1, "")
      table.insert(lines, 1, ("(diagrams shown as text: %s; press o on a segment to open its SVG)"):format(
        reason or "no image support"))
      for _, mark in ipairs(marks) do mark.row = mark.row + 2 end
      for _, heading in ipairs(headings) do heading.row = heading.row + 2 end
      marks[#marks + 1] = { row = 0, group = "RaccoonSegmentsDim" }
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local commits = adapter.commits(viewer)
  local total = 0
  for _, item in ipairs(commits) do
    if item.section == 1 and item.sha then total = total + 1 end
  end
  local subject = (artifact.subject or commit.message or ""):sub(1, win_w - 30)
  local title = (" %s · %s "):format(commit.sha:sub(1, 7), subject)
  -- Open without entering, register with raccoon's focus lock, then enter:
  -- entering first would let the lock pull the cursor straight back out.
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = math.floor((editor_h - win_h) / 2),
    col = math.floor((editor_w - win_w) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    footer = (" commit %d/%d · ]s [s segments · ]c [c commits · o svg · q close "):format(commit.index, total),
    footer_pos = "center",
    zindex = 60,
  })
  adapter.set_popup_win(viewer, win)
  vim.api.nvim_set_current_win(win)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].conceallevel = 0
  vim.bo[buf].filetype = "markdown"
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, 0, { line_hl_group = mark.group, priority = 200 })
  end
  popup = { win = win, buf = buf, viewer = viewer, sha = commit.sha, headings = headings, placements = {},
    artifact = artifact, commit = commit }
  if images_ok and #images > 0 then
    popup.placements = place_images(buf, images)
  end
  vim.bo[buf].modifiable = false

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("]s", function() jump_heading(1) end)
  map("[s", function() jump_heading(-1) end)
  map("o", open_svg)
  local function show_neighbour(direction)
    local neighbour = explained_neighbours(viewer, commit.sha, direction)
    if neighbour then
      M.show(viewer, neighbour)
    else
      vim.notify(("raccoon-segments: no %s explained commit"):format(direction > 0 and "later" or "earlier"),
        vim.log.levels.INFO)
    end
  end
  map("]c", function() show_neighbour(1) end)
  map("[c", function() show_neighbour(-1) end)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if popup and popup.win == win then close() end
    end,
  })
  if focus_segment then
    for _, heading in ipairs(headings) do
      if heading.segment.index == focus_segment.index then
        vim.api.nvim_win_set_cursor(win, { heading.row + 1, 0 })
        vim.cmd("normal! zt")
      end
    end
  end
  return win
end

function M.reset_images()
  for _, id in pairs(image_ids) do pcall(writer, kitty.delete(id)) end
  image_ids = {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("RaccoonSegmentsExplain", { clear = true }),
  callback = function()
    if popup then close() end
    M.reset_images()
  end,
})

return M
