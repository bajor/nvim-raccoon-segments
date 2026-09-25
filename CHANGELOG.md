# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-09-25

### Added

- Per-commit AI segmentation and explanations for raccoon's PR and local
  commit viewers, generated on demand (`generate` appends, `regenerate` hard
  resets) and stored by commit SHA.
- `opencode` (default), `claude` and `codex` backends, all run read-only in a
  `git archive` export of the commit with the repository's own agent
  configuration removed; custom backends via `cmd`.
- Segment overlay: tinted diff rows with numbered badges, file-tree dots,
  commit-list marks and a header summary, drawn by a decoration provider.
- Explanation popup with segment and commit navigation, SVG opening, and
  real images in Ghostty through the kitty graphics protocol.
- `SEGMENTS.md` reviewer instructions file, `min_changed_lines` skip,
  validation with one repair round, and `:RaccoonSegments` commands for
  status, logs, cancel and prompts.
- Test suite: pure Lua, embedded-UI Neovim, fake-CLI pipeline and pinned-host
  compatibility tests.
- CI/CD matching nvim-raccoon: luacheck plus `make test` on Neovim 0.10.4,
  stable and nightly for pushes and PRs to `main`; a changelog check on PRs;
  a version tag and GitHub release when a merge changes the top
  `CHANGELOG.md` entry; and cleanup of `visual-explanations/*.svg` after
  merge (needs the `REMOVE_VISUALS_MAIN` repository secret).
