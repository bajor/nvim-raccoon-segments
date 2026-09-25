# nvim-raccoon-segments

Precomputed, AI-written explanations for every commit you step through in
[nvim-raccoon](https://github.com/bajor/nvim-raccoon)'s commit viewers.

For each commit an agent splits the diff into logical **segments**, writes an
overview of the commit, and explains every segment with text plus a diagram.
All of it is generated ahead of time and stored by commit SHA, so inside the
commit viewer you press one key and the explanation is already there:

- segments are tinted in the diff grid, with a numbered badge on each block
- files touched by a segment get coloured dots in the file tree
- commits that have explanations get dots in the commit list
- one key opens the explanation popup; in Ghostty the diagrams render as
  real images inside the popup

Like [nvim-raccoon-diffs](https://github.com/bajor/nvim-raccoon-diffs), this
is a separate companion plugin. It reads raccoon's state and never patches,
replaces or monkeypatches the host plugin.

## Where the idea comes from

This comes from something Aaron Bauer said on Jane Street's *Signals and
Threads* podcast, in the episode
[Teaching in the Age of AI: Learning Goals and the Goals of Learning](https://www.youtube.com/watch?v=qN6OM1IzjIE):
now that producing the code is the easy part, the work moves to reading it,
and a change is much easier to review when it is broken into logical pieces
with each piece explained. That resonated with how I already review PRs in
raccoon, commit by commit, so this plugin does exactly that for every commit
in the viewer.

## What it does not do

- Nothing changes in raccoon's flat diff mode. Segments live in the two
  commit viewers only: the PR commit viewer (`:Raccoon commits`) and the local
  commit viewer (`:Raccoon local`).
- Nothing runs automatically. You trigger generation for a PR or branch when
  it is worth it.
- Explanations are an aid, not a verdict. The agent reads the commit and the
  repository; it does not run tests and it can be wrong.

## Requirements

- Neovim 0.10.4 or newer
- [`bajor/nvim-raccoon`](https://github.com/bajor/nvim-raccoon), installed and
  configured
- one agent CLI on your `PATH`: [`opencode`](https://opencode.ai) (default),
  [`claude`](https://docs.anthropic.com/en/docs/claude-code) or
  [`codex`](https://github.com/openai/codex), logged in to your provider
- `git` and `tar`
- optional, for images: Ghostty and an SVG rasterizer (`rsvg-convert`,
  `magick`, or macOS's built-in `qlmanage`; the first one found is used)

No other runtime dependency: no Node, no Python, no image library in Neovim.

## Installation

Install raccoon first.

### lazy.nvim

```lua
return {
  {
    "bajor/nvim-raccoon",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("raccoon").setup()
    end,
  },
  {
    "bajor/nvim-raccoon-segments",
    main = "raccoon_segments",
    dependencies = { "bajor/nvim-raccoon" },
    opts = {},
  },
}
```

### vim-plug

```vim
Plug 'nvim-lua/plenary.nvim'
Plug 'bajor/nvim-raccoon'
Plug 'bajor/nvim-raccoon-segments'

lua require('raccoon_segments').setup()
```

## Usage

1. Open a PR in raccoon and enter the commit viewer (`<leader>cm`), or run
   `:Raccoon local` in any repository.
2. Press `<leader>vg`. Every commit in the list that has no explanation yet is
   sent to the agent, oldest first, two at a time. The commit list shows `…`
   for queued and `⟳` for running commits. You can keep reviewing; jobs
   continue even if you leave the viewer.
3. When a commit is done its row shows one coloured `●` per segment, the diff
   grid is tinted by segment, and the header says how many segments there are.
4. Press `<leader>ve` on any commit to read its explanation.

Reopening the same PR or branch later needs no new run: explanations are
looked up by commit SHA.

### Keys and commands

All keys are global normal-mode maps and can be changed or disabled in
`setup()`. Their descriptions start with `Raccoon:`, which is what raccoon's
commit viewer uses to let a key through its key blocking, so they work
inside the viewer without touching `commit_viewer.passthrough_keys`.

| Key | Command | Action |
| --- | --- | --- |
| `<leader>ve` | `:RaccoonSegments explain` | Open (or close) the explanation popup for the selected commit. In the file tree it jumps to the first segment touching the file under the cursor; in a diff cell or the maximized diff it jumps to the segment under the cursor. |
| `<leader>vs` | `:RaccoonSegments toggle` | Show or hide the overlay (tints, badges, file-tree dots). The commit-list marks stay. |
| `<leader>vg` | `:RaccoonSegments generate` | **Append**: generate explanations for the commits in this view that have none. |
| `<leader>vG` | `:RaccoonSegments regenerate` | **Hard reset**: after confirmation, delete the explanations of every commit in this view and generate them all again. |
| | `:RaccoonSegments cancel` | Stop every queued and running job. |
| | `:RaccoonSegments status` | Job list with phase, timing and errors, plus warnings for the selected commit. |
| | `:RaccoonSegments log` | Open the selected commit's job directory (prompt, raw output, stderr, SVGs). |
| | `:RaccoonSegments instructions` | Edit your `SEGMENTS.md` (see below). |
| | `:RaccoonSegments prompt` | Show the exact prompt that was sent for the selected commit. |

Raccoon blocks `:` inside its viewer buffers, so use the keys there; the
commands work from any other buffer.

Which commits `generate` and `regenerate` target:

| Viewer | Commits |
| --- | --- |
| PR commit viewer | the PR's commits |
| Local viewer on a feature branch | the branch's commits (not "Current changes") |
| Local viewer on the default branch or a detached HEAD | the `local_recent_commits` most recent commits (default 10) |

Base-branch commits are never generated. Commits with fewer than
`min_changed_lines` changed lines (default 10, generated and lock files
excluded) are skipped and marked `–`; set it to `0` to explain everything.

### The explanation popup

One scrollable document per commit:

- the overview
- for every segment: a coloured heading, the diagram (Ghostty only), the
  explanation, "Review focus" bullets, and the files with `+/-` counts

| Key | Action |
| --- | --- |
| `]s` / `[s` | next / previous segment |
| `]c` / `[c` | explanation of the next / previous explained commit in the list (raccoon's own selection is left alone) |
| `o` | open the segment's SVG in your browser |
| `q`, `<Esc>` | close |

## Images: Ghostty only

Diagrams are shown as real images inside the popup through the kitty
graphics protocol with Unicode placeholders. This is tested against
**Ghostty** only. Requirements:

- running in Ghostty (`TERM_PROGRAM=ghostty`), not inside tmux
- `termguicolors` on
- a PNG for the segment, which means an SVG rasterizer was found when the
  explanation was generated: `rsvg-convert` (librsvg), `magick`
  (ImageMagick 7) or `qlmanage` (ships with macOS)

Anywhere else the popup shows the text only, says why in its first line, and
`o` still opens the SVG in a browser. No other terminal is claimed to work;
kitty and WezTerm speak the same protocol and may well work, but they are not
tested.

## Configuration

`setup()` rejects unknown options and invalid values. Defaults:

```lua
require("raccoon_segments").setup({
  backend = "opencode",             -- "opencode" | "claude" | "codex" | custom table/function
  model = nil,                      -- passed to the backend's model flag when set
  backend_args = {},                -- extra CLI arguments
  backend_env = {},                 -- extra environment variables for the CLI
  timeout_ms = 20 * 60 * 1000,      -- per commit
  max_parallel = 2,                 -- commits generated at the same time
  min_changed_lines = 10,           -- skip smaller commits (0 = never skip)
  local_recent_commits = 10,        -- targets in local history mode
  max_diff_bytes = 400 * 1024,      -- refuse bigger commits
  exclude = { "*.lock", "package-lock.json", "yarn.lock", "*.min.js", "visual-explanations/**", ... },
  export_tree = true,               -- give the agent a `git archive` of the commit (see Privacy)
  images = "auto",                  -- "auto" | false
  rasterizer = "auto",              -- "auto" | "rsvg-convert" | "magick" | "qlmanage" | false
  instructions_path = "~/.config/raccoon/SEGMENTS.md",
  data_dir = vim.fn.stdpath("data") .. "/raccoon-segments",
  overlay = true,                   -- start with tints/badges/dots shown
  colors = nil,                     -- list of "#rrggbb" segment hues; default has 10
  diagnostics = "warn",             -- "silent" | "warn" | "error" for host-compatibility issues
  keys = {
    explain = "<leader>ve",
    toggle = "<leader>vs",
    generate = "<leader>vg",
    regenerate = "<leader>vG",      -- any key can be set to false
  },
})
```

### Your instructions: `SEGMENTS.md`

`:RaccoonSegments instructions` creates `~/.config/raccoon/SEGMENTS.md` from
a template and opens it, the same way `:Raccoon config` works. Its content is
sent with every prompt. Use it for style, depth, language and diagram
preferences. The fixed rules (assign every change to a segment, read-only
access, output format, SVG constraints) are enforced by the plugin and cannot
be overridden there.

### Backends

The prompt goes to the CLI on stdin; the CLI runs in a directory holding the
repository as of the commit, read-only. Every preset disables the repository's
own agent configuration (see Privacy).

| Backend | Command | Notes |
| --- | --- | --- |
| `opencode` (default) | `opencode run --agent raccoon-segments [--model provider/model]` | A read-only agent (edit, bash, webfetch, websearch, task, skill, todowrite denied) is injected through `OPENCODE_CONFIG_CONTENT`; `OPENCODE_DISABLE_PROJECT_CONFIG=1` and `OPENCODE_DISABLE_CLAUDE_CODE=1` stop the repo's `opencode.json`, plugins and `AGENTS.md` from loading. opencode has no output-schema option, so the reply is parsed from its text; the plugin validates it and asks once for a corrected reply if needed. |
| `claude` | `claude -p --output-format json --tools Read,Grep,Glob --permission-mode dontAsk --setting-sources user --no-session-persistence [--model m]` | Uses your Claude Code login. Project settings are ignored. `CLAUDE.md` is not loaded because the export tree has none. |
| `codex` | `codex exec --sandbox read-only --skip-git-repo-check --ephemeral -o <file> [-m m] -` | Uses your Codex login. The final message is read from the `-o` file. |

Custom backend: `backend = { cmd = { "my-agent", "--out", "{output}" }, output = "file" }`
(or `output = "stdout"`, or `cmd = function(ctx) ... end`). The prompt is on
stdin; `{output}` is replaced with a file path for the final message.

Whatever the backend, the reply must contain one `<segments>` block with JSON
and optional `<visual segment="N">` blocks with SVG. Unknown or duplicate
change ids are dropped with a warning, unassigned ids land in an "Unassigned"
group, and if the reply is unusable the plugin sends the errors back once for
a repair. `:RaccoonSegments status` lists the warnings of the selected commit.

## Privacy and untrusted input

- **What is sent**: for every generated commit, the commit message, the diff
  of that commit (minus `exclude` files), the branch or PR title and
  description, the list of commit subjects, your `SEGMENTS.md`, and whatever
  files the agent decides to read from the checkout. It goes to whichever
  provider your CLI is configured for. Do not generate explanations for
  repositories you are not allowed to send to that provider.
- **The commit is untrusted**. A PR can carry `AGENTS.md`, `CLAUDE.md`,
  `.opencode/` plugins or `.claude/` settings that try to steer or extend the
  agent. By default the agent runs in a temporary `git archive` of the commit
  from which these files are removed, the CLIs are told not to load project
  configuration, and the prompt says to treat repository content as data. If
  you set `export_tree = false` the agent runs in raccoon's clone instead and
  only the CLI flags protect you.
- Nothing is written to the repository. Prompts, raw replies, stderr, SVGs and
  PNGs are stored under `data_dir` (default
  `~/.local/share/nvim/raccoon-segments/commits/<sha>/`).

## Cost

One agent run per commit (two when a repair is needed), plus whatever files
the agent reads. `min_changed_lines` keeps trivial commits out; `regenerate`
redoes everything, so use `generate` unless you changed `SEGMENTS.md` or the
backend and want fresh output.

## How it works

```text
raccoon commit viewer state (read-only)         git diff-tree / git archive
            |                                              |
            v                                              v
   host adapter (capability-checked)           change blocks @c1..@cN + prompt
            |                                              |
            v                                              v
   decoration provider (ephemeral marks)  <--  artifact.json by SHA  <--  agent CLI
            |                                              ^
            v                                              |
   tints, badges, dots, header, popup           validate, repair once, rasterize SVG
```

- `host/raccoon.lua` reads `raccoon.commits._get_state()` and
  `raccoon.localcommits._get_state()`, raccoon's own `raccoon_commits` /
  `raccoon_local_commits` extmarks to know which rows are additions or
  deletions, and calls only `set_popup_win` / `clear_popup_win` so raccoon's
  focus lock leaves the popup alone.
- Rows are matched to change blocks by content, so the tint does not depend
  on how much context raccoon shows around a hunk, and raccoon's full-buffer
  rewrites never leave stale marks behind: everything is drawn by a
  decoration provider on each redraw.
- Highlights: `RaccoonSegmentsAdd<N>` / `RaccoonSegmentsDel<N>` blend segment
  hue N over `RaccoonAdd` / `RaccoonDelete`; `RaccoonSegmentsFg<N>` and
  `RaccoonSegmentsBadge<N>` colour dots and badges. Override any of them after
  `setup()`.

Tested host revision: `bajor/nvim-raccoon` commit
`785ef2d7b32c6f4f0468f2efb85fbdb7c144b103`. Private host interfaces can
change; on a missing capability the plugin fails closed with one diagnostic.

## Limitations

- Commit viewers only; flat diff mode is untouched.
- Deleted rows are tinted in the commit viewers (they are real rows there);
  raccoon shows no diff for root commits, so those get an explanation but no
  tint.
- `]c` / `[c` inside the popup do not move raccoon's selection: raccoon has no
  API for that.
- Images: Ghostty only, not in tmux.
- Jobs are killed when Neovim exits.
- The test suite drives the pipeline with fake `opencode`, `claude` and
  `codex` CLIs, not the real ones. The presets' flags were checked against
  opencode 1.18.32, Claude Code 2.1.282 and codex 0.157.0, and the opencode
  preset was run for real against a local stand-in model server to confirm
  stdin input, the read-only tool set and the config injection. The
  `qlmanage` rasterizer is covered for its command line only; it was not run
  on macOS.

## Verification

```sh
make test
```

Runs pure Lua tests (`lua tests/run.lua`), Neovim tests inside an embedded
Neovim with a UI attached (so screen-level assertions work), pipeline tests
with fake `opencode`/`claude`/`codex` CLIs, host-compatibility tests against
the pinned raccoon commit in both commit viewers, `luacheck`, and
`git diff --check`.

## Development and releases

Same flow as nvim-raccoon, using the shared workflows from
[bajor/github-workflows](https://github.com/bajor/github-workflows):

- Changes go to `main` through pull requests. Every PR must touch
  `CHANGELOG.md` (the **Changelog Check** workflow fails otherwise).
- **CI** runs on every push and PR to `main`: `luacheck`, and `make test` on
  Neovim 0.10.4, stable and nightly.
- **Release** runs when a push to `main` changes `CHANGELOG.md`. It tags
  `v<version>` from the top `## [version]` heading if that tag does not exist
  yet, and publishes a GitHub release for `X.Y` / `X.Y.0` versions (patch
  versions such as `0.1.1` are tagged without a release).
- **Delete Visual Explanation SVGs** removes `visual-explanations/*.svg` from
  `main` after a merge. It pushes with the `REMOVE_VISUALS_MAIN` repository
  secret, a fine-grained PAT with Contents read/write whose owner may bypass
  the `main` ruleset.

Run `make test` locally before opening a PR.

## License

MIT
