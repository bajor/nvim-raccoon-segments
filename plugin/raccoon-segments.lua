if vim.g.loaded_raccoon_segments == 1 then return end
vim.g.loaded_raccoon_segments = 1

vim.api.nvim_create_user_command("RaccoonSegments", function(opts)
  local segments = require("raccoon_segments")
  local name = opts.fargs[1]
  if not segments.setup_done then
    vim.notify("raccoon-segments: call require('raccoon_segments').setup() first", vim.log.levels.WARN)
    return
  end
  local command = name and segments.commands[name]
  if not command then
    vim.notify("Usage: :RaccoonSegments <" .. table.concat(segments.command_names(), "|") .. ">",
      vim.log.levels.WARN)
    return
  end
  command()
end, {
  nargs = "?",
  complete = function()
    return require("raccoon_segments").command_names()
  end,
  desc = "Raccoon: segments commands",
})
