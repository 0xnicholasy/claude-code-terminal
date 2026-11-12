---
name: implement
description: Implements the next todo of the Claude Code features, round 2 feature from docs/claude-code-features/TODO.md on feat/claude-code-features: picks the next ready todo, builds it on its own branch in the main checkout (or a worktree with --worktree), verifies it, PRs it into feat/claude-code-features, merges it and marks it done. One todo per run, designed to be looped with /goal. After the last todo it cleans itself up. Use when the user runs /implement, says "next todo", "continue the feature", "implement T04", or asks "how far along is claude-code-features".
argument-hint: "[next | <todo id e.g. T04> | status | resume | cleanup] [--worktree]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill, AskUserQuestion
---

# /implement (claude-code-features)

Created by `/ultraplan`. Lives only on `feat/claude-code-features`; `cleanup` deletes it.
Single source of truth: `docs/claude-code-features/TODO.md` on `origin/feat/claude-code-features`. Read the TODO format from its own header and existing entries; keep it exactly.

## Arguments

| Argument | Does |
| --- | --- |
| none / `next` | Ship the next ready todo |
| `<id>` | Ship that todo if its `needs` are done or skipped |
| `status` | Read-only progress line, changes nothing |
| `resume` | Continue a todo left `in_progress` (its branch or worktree / open PR) |
| `--worktree` | Build in a separate worktree instead of the main checkout (see step 3) |
| `cleanup` | The final step (below). Runs automatically when only `TZZ` is left |

## Every run ends with exactly one of these lines (the /goal evaluator reads them)

- `IMPLEMENTED <id>: <what now works> (#<pr>). Progress: <done>/<total>. Next: <id>`
- `ULTRAPLAN BLOCKED <id>: <reason>. Needs: <the one thing the owner must do>`
- `ULTRAPLAN COMPLETE claude-code-features: landing PR #<n> into main awaits owner merge`

## Ship one todo

Stop at any step that fails its check, and end with the BLOCKED line.

### 1. Preflight
- `pwd`, `git branch --show-current`, fresh `git status`, `git fetch origin --prune`.
- Read `docs/claude-code-features/TODO.md` from `origin/feat/claude-code-features` (`git show origin/feat/claude-code-features:docs/claude-code-features/TODO.md`), not the local copy.
- A todo already `in_progress`: do `resume` for it instead of starting another. Also check `gh pr list --base feat/claude-code-features --state open`.
- Pick: the first `todo` in file order whose `needs` are all `done`/`skipped`. None ready but some not done: BLOCKED, naming what they wait on. Only `TZZ` left: go to Cleanup.
- A todo whose `done when` depends on an unanswered decision or external answer: BLOCKED. Never build against a guess.

### 2. Sync with main
If `git merge-base --is-ancestor origin/main origin/feat/claude-code-features` fails: in the main checkout, `git switch feat/claude-code-features && git pull --ff-only`, `git merge --no-ff origin/main`, normal push (worktree mode: do this in a temporary worktree on `feat/claude-code-features`). Conflict: `git merge --abort` (and remove any temporary worktree), BLOCKED with the conflicting files.

### 3. Branch
- Default, main checkout (tree must be clean): `git switch -c feat/claude-code-features-<id lc> origin/feat/claude-code-features`.
- Worktree mode, only with `--worktree` or when the main checkout holds changes this run did not make (leave those untouched): `git worktree add .claude/worktrees/claude-code-features-<id lc> -b feat/claude-code-features-<id lc> origin/feat/claude-code-features`, then project worktree setup (env links, `bun install` in touched apps) per the project CLAUDE.md.
- Every later command: `cd <abs working copy> && <cmd>`, where the working copy is the main checkout or the worktree.

### 4. Build
Build with a `general-purpose` implementation agent (model `sonnet`, 80-tool-call cap). Spike and live-check todos (T01-T03, T07, T12, T18, T23) change no app code: run them inline and record results in the TODO Log. Landing todos (T08, T13, T19, T24) only open or comment on the PR `feat/claude-code-features` -> `main` per D1/D6 and never merge it.
Spec handed over: the todo's scope, files, done-when, verify, the TODO `## Constraints`, and "work only in <abs working copy>, on branch feat/claude-code-features-<id lc>".
In the same branch, edit `docs/claude-code-features/TODO.md`: this todo `status: done (#PR, <date>)`, bump `Progress`, append a `## Log` line, add any follow-ups found to `## Backlog`. Also update `README.md` (Features and Shortcuts sections) if the todo changes what they describe.

### 5. Check before pushing
All must pass, with output kept as evidence:
- Every command in the todo's `verify`, plus GATE from `docs/claude-code-features/TODO.md` ## Constraints (`xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test` in `App/` of the working copy), plus BUILD (`scripts/build-app.sh`) when the todo touches UI for the apps touched.
- The `done when` shown true (command output, test name, or screenshot for UI).
- A code-review pass on the diff (`code-reviewer`, model `sonnet`); fix Medium and above, at most 2 fix rounds.
- `git diff --cached --stat`: only files this todo names, plus TODO.md. Unstage anything else.
Failure after 2 attempts: leave the todo `in_progress`, push nothing, BLOCKED with the failing output's decisive line.

### 6. PR, CI, merge
- Push; PR base `feat/claude-code-features` (never main, never `release`); read the base back. Title `<type>(claude-code-features): <id> <title>`. Body: done-when evidence, verify output summary, review result, attribution line from the session's system reminder.
- Fill the PR number into TODO.md, push.
- `gh pr checks <n> --watch`. Real failure (job started): fix in the working copy, at most 2 attempts. Jobs never started (billing/quota): rerun once, then run each red check's local equivalent (read the workflow file whole) and merge on that evidence, naming which command stood in for which check.
- `BEHIND`: merge `origin/feat/claude-code-features` into the branch, push, re-watch. Squash-merge, confirm with `git log -1 origin/feat/claude-code-features`, then `git switch feat/claude-code-features && git pull --ff-only` in the main checkout (worktree mode: remove the worktree instead), and delete the todo branch locally and remotely.
- End with the IMPLEMENTED line.

## Status
`<done>/<total> done. In progress: <id or none>. Next ready: <id title>. Blocked: <ids + reason, max 5>.`

## Cleanup (TZZ)
Runs when every other todo is `done` or `skipped`. Branch `feat/claude-code-features-cleanup` from `origin/feat/claude-code-features`, in the main checkout (or `.claude/worktrees/claude-code-features-cleanup`, same rule as step 3):
1. `git rm -r .claude/skills/implement` (this skill).
2. TODO.md: `Status: COMPLETE <date>, kept as backlog`, `TZZ` `done`, final Log line. Keep the file; it lands on main as the record.
3. Remove anything the enabling PR added on main that is on this branch too: the `CLAUDE.md` integration-branch bullet for `feat/claude-code-features`, CI branch filters for `feat/claude-code-features`, the matching deploy-doc lines. Leave any `.gitignore` exception that keeps `docs/claude-code-features/` tracked.
4. Verify: no remaining reference to `feat/claude-code-features` or `/implement` outside `docs/claude-code-features/` (`git grep`), full test run for every app the feature touched (GATE from `docs/claude-code-features/TODO.md` ## Constraints (`xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test` in `App/` of the working copy), plus BUILD (`scripts/build-app.sh`) when the todo touches UI).
5. PR into `feat/claude-code-features`, CI, merge (same as step 6 above).
6. Open the landing PR `feat/claude-code-features` into main (merge commit, not squash, so the per-todo history stays). Body: Goal, todo table with PR numbers, Backlog, test evidence. Do NOT merge it: landing is the owner's call. Delete tag `pre-claude-code-features-main` only after the owner merges.
7. End with the COMPLETE line.

## Rules
- One todo per run, one PR per todo. Never batch.
- A todo whose scope turns out wrong: stop, BLOCKED, and propose the TODO.md edit (split, new todo, changed done-when) for the owner to approve.
- Never push to main or `release`, never force-push, never rebase `feat/claude-code-features`.
- Tests go through the project's test skills, never hand-rolled commands when the project mandates skills.
