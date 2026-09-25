-- Read-only adapter over nvim-raccoon's two commit viewers. Every access is
-- capability-checked; nothing here mutates host state except the documented
-- popup registration (set_popup_win / clear_popup_win).
local M = {}

local MINIMUM_NVIM = { 0, 10, 4 }

local function nvim_at_least(required)
  local current = vim.version()
  if current.major ~= required[1] then return current.major > required[1] end
  if current.minor ~= required[2] then return current.minor > required[2] end
  return current.patch >= required[3]
end

---@return boolean ok, string|nil err
function M.check_compatibility()
  if not nvim_at_least(MINIMUM_NVIM) then
    return false, "Neovim 0.10.4 or newer is required"
  end
  for _, name in ipairs({ "nvim_set_decoration_provider", "nvim_buf_get_extmarks", "nvim_get_namespaces" }) do
    if type(vim.api[name]) ~= "function" then
      return false, "missing Neovim capability vim.api." .. name
    end
  end
  if not pcall(require, "raccoon") then
    return false, "host plugin bajor/nvim-raccoon is unavailable"
  end
  return true
end

local VIEWERS = {
  { kind = "pr", module = "raccoon.commits", namespace = "raccoon_commits" },
  { kind = "local", module = "raccoon.localcommits", namespace = "raccoon_local_commits" },
}

---The active commit viewer, if any.
---@return table|nil viewer {kind, module, state, namespace, repo_path}, string|nil issue
function M.viewer()
  for _, spec in ipairs(VIEWERS) do
    local module = package.loaded[spec.module]
    if module ~= nil then
      if type(module) ~= "table" or type(module._get_state) ~= "function" then
        return nil, "host version unavailable; missing capability " .. spec.module .. "._get_state"
      end
      local ok, state = pcall(module._get_state)
      if ok and type(state) == "table" and state.active == true then
        local namespace = vim.api.nvim_get_namespaces()[spec.namespace]
        if not namespace then
          return nil, "host version unavailable; missing namespace " .. spec.namespace
        end
        local repo_path
        if spec.kind == "pr" then
          local host_state = package.loaded["raccoon.state"]
          if type(host_state) ~= "table" or type(host_state.get_clone_path) ~= "function" then
            return nil, "host version unavailable; missing raccoon.state.get_clone_path"
          end
          repo_path = host_state.get_clone_path()
        else
          repo_path = state.repo_path
        end
        if type(repo_path) ~= "string" or repo_path == "" then
          return nil, "host viewer has no repository path"
        end
        return {
          kind = spec.kind,
          module = module,
          state = state,
          namespace = namespace,
          repo_path = repo_path,
        }
      end
    end
  end
  return nil
end

---Commit rows in sidebar order with their sidebar layout.
---@param viewer table
---@return table[] commits {sha, message, index, section, target}, integer section1_count, boolean split
function M.commits(viewer)
  local state = viewer.state
  local first = viewer.kind == "pr" and (state.pr_commits or {}) or (state.branch_commits or {})
  local second = state.base_commits or {}
  local split = viewer.kind == "pr" or state.base_branch ~= nil
  local commits = {}
  for index, commit in ipairs(first) do
    commits[#commits + 1] = {
      sha = commit.sha,
      message = commit.message or "",
      index = index,
      section = 1,
      target = commit.sha ~= nil,
    }
  end
  for index, commit in ipairs(second) do
    commits[#commits + 1] = {
      sha = commit.sha,
      message = commit.message or "",
      index = #first + index,
      section = 2,
      target = false,
    }
  end
  return commits, #first, split
end

---0-based sidebar row for a combined commit index.
---@param index integer
---@param section1_count integer
---@param split boolean
---@return integer
function M.sidebar_row(index, section1_count, split)
  if split and index > section1_count then return index + 2 end
  return index
end

---@param viewer table
---@return table|nil commit {sha, message, index}
function M.selected(viewer)
  local commits = M.commits(viewer)
  return commits[viewer.state.selected_index or 0]
end

---Prompt context describing where commits come from.
---@param viewer table
---@return table source
function M.source(viewer)
  if viewer.kind == "pr" then
    local host_state = package.loaded["raccoon.state"]
    local pr = type(host_state) == "table" and type(host_state.get_pr) == "function" and host_state.get_pr() or {}
    pr = pr or {}
    return {
      kind = "pr",
      owner = host_state.get_owner and host_state.get_owner() or nil,
      repo = host_state.get_repo and host_state.get_repo() or nil,
      number = host_state.get_number and host_state.get_number() or nil,
      title = pr.title,
      body = pr.body,
      base_ref = pr.base and pr.base.ref or nil,
      head_ref = pr.head and pr.head.ref or nil,
    }
  end
  local state = viewer.state
  return {
    kind = "local",
    repo_path = viewer.repo_path,
    repo_name = vim.fs.basename(viewer.repo_path),
    branch = state.current_branch,
    base_branch = state.base_branch,
  }
end

---Rows of a viewer buffer typed via the host's own extmarks.
---@param buffer integer
---@param namespace integer
---@return table[] records {kind, content}
function M.typed_records(buffer, namespace)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local kinds = {}
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buffer, namespace, 0, -1, { details = true })
  for _, mark in ipairs(ok and marks or {}) do
    local details = mark[4] or {}
    if details.sign_text == "+" or details.line_hl_group == "RaccoonAdd" then
      kinds[mark[2]] = "addition"
    elseif details.sign_text == "-" or details.line_hl_group == "RaccoonDelete" then
      kinds[mark[2]] = "deletion"
    end
  end
  local records = {}
  for index, content in ipairs(lines) do
    records[index] = { kind = kinds[index - 1] or "context", content = content }
  end
  return records
end

local function winbar_filename(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local ok, winbar = pcall(function() return vim.wo[win].winbar end)
  if not ok or type(winbar) ~= "string" then return nil end
  return winbar:match("^ (.-)%%=")
end

---Classify a buffer of the active viewer.
---@param viewer table
---@param buffer integer
---@return table|nil info {role = "cell"|"preview"|"maximize"|"sidebar"|"filetree"|"header", filename?, first_line?}
function M.classify(viewer, buffer)
  local state = viewer.state
  if buffer == state.sidebar_buf then return { role = "sidebar" } end
  if buffer == state.filetree_buf then return { role = "filetree" } end
  if buffer == state.header_buf then return { role = "header" } end
  if buffer == state.maximize_buf then
    return { role = "maximize", filename = winbar_filename(state.maximize_win) }
  end
  for index, cell in ipairs(state.grid_bufs or {}) do
    if cell == buffer then
      if index == 1 and state.focus_target == "filetree" and state.filetree_preview_path then
        return { role = "preview", filename = state.filetree_preview_path }
      end
      local cells = (state.grid_rows or 1) * (state.grid_cols or 1)
      local entry = (state.all_hunks or {})[((state.current_page or 1) - 1) * cells + index]
      if entry then
        return { role = "cell", filename = entry.filename, first_line = entry.hunk and entry.hunk.start_line }
      end
      return { role = "cell" }
    end
  end
  return nil
end

---Files of the selected commit as raccoon knows them (path -> true).
---@param viewer table
---@return table<string, boolean>
function M.commit_files(viewer)
  return viewer.state.commit_files or {}
end

---File-tree row -> path map.
---@param viewer table
---@return table<integer, string>
function M.filetree_paths(viewer)
  return viewer.state.cached_line_paths or {}
end

---@param viewer table
---@param win integer
function M.set_popup_win(viewer, win)
  if type(viewer.module.set_popup_win) == "function" then
    pcall(viewer.module.set_popup_win, win)
  end
end

---@param viewer table
function M.clear_popup_win(viewer)
  if type(viewer.module.clear_popup_win) == "function" then
    pcall(viewer.module.clear_popup_win)
  end
end

---A cheap fingerprint of the viewer state used to decide when to redraw.
---@param viewer table
---@return string
function M.generation(viewer)
  local state = viewer.state
  return table.concat({
    viewer.kind,
    tostring(state.select_generation),
    tostring(state.selected_index),
    tostring(state.current_page),
    tostring(state.preview_generation),
    tostring(state.focus_target),
    tostring(state.filetree_preview_path),
    tostring(state.maximize_buf),
    tostring(#(state.all_hunks or {})),
  }, ":")
end

return M
