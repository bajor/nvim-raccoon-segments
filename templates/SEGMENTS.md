# Instructions for nvim-raccoon-segments

This file is sent to the AI agent with every commit it explains. Use it for
your preferences about style, depth and diagrams. Fixed rules (assign every
change, read-only access, output format, SVG constraints) are enforced by the
plugin and cannot be changed here.

Delete the examples below and write your own.

## Style

- Explain to a senior engineer who does not know this codebase. Name the
  functions and types involved; do not paraphrase the diff line by line.
- Lead with intent: what problem the segment solves, then how.
- Keep explanations under 200 words per segment unless the change is subtle.

## Review focus

- Prefer concrete checks ("`retry()` swallows `ECONNRESET`; confirm callers
  expect that") over generic advice ("check error handling").
- Call out behaviour changes that tests do not cover.

## Diagrams

- Draw a diagram only when it shows something the text cannot: data flow
  between components, a state machine, a before/after structure.
- Use boxes and arrows with short labels. No decorative diagrams.
