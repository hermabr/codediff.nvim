# AGENTS.md

## Task Completion Requirements

- Do not run tests or linters before considering tasks completed.

## Project Snapshot

codediff.nvim is a minimal and flexible plugin for showing git diffs in neovim.

This repository is a VERY EARLY WIP and does not have any users. Proposing sweeping changes that improve long-term maintainability is encouraged.

## Core Priorities

1. Performance first.
2. Reliability first.
3. Keep behavior predictable under load and during failures (session restarts, reconnects).

If a tradeoff is required, choose correctness and robustness over short-term convenience.

## Maintainability

Long term maintainability is a core priority. If you add new functionality, first check if there is shared logic that can be extracted to a separate module. Duplicate logic across multiple files is a code smell and should be avoided. Don't be afraid to change existing code. Don't take shortcuts by just adding local logic to solve a problem. Make an active effort to implement all changes as directed and minimally as possible.
