---
name: handoff
description: Hand the current work to a fresh session in a Rex pane beside this one, so it continues with a clean context. The agent writes the durable state where the project keeps it, cleans up what would orphan (background runs, servers, watches, a finished worktree), writes a short prompt, and `~/dev/rig/bin/handoff open` starts the successor; the successor closes this pane once it is idle. Use when Billy asks to hand off, or on your own at a clean point once the context is heavy (rules inside). Any project in ~/dev; Claude and Codex alike.
---

# Hand off to a fresh session

A long session gets slower and costlier per turn, and it drops detail when it
is summarized. A handoff ends it on purpose at a clean point: the next session
starts from the project's durable record and a short prompt, in a Rex pane
beside this one, and closes this one's pane when it takes over.
`~/dev/rig/bin/handoff` is the mechanics; this skill is the judgment and the
order.

## When

- **Billy asks** ("hand off", "continue in a new session"): do it, at the
  next clean point.
- **On your own** only when both hold (Billy, 2026-10-28):
  - A clean point: between pieces of work (a PR live, a design approved, a
    phase finished, a long run done). Never mid-edit, while a ship is queued
    or red, while a question to Billy waits for his answer, or with
    uncommitted work you cannot describe in a line.
  - The context is heavy: it has been summarized at least once, or you have
    read enough that the rest of the work would be better done fresh.
- **Not past three automatic handoffs per task.** The script counts them
  (`RIG_HANDOFF_GEN`, inherited by each successor) and refuses the fourth.
  Ask Billy; rerun with `--asked` once he agrees.
- The successor continues the same task and the follow-ons Billy already
  approved. A new task, or a decision only Billy can make, is not a handoff:
  ask him.
- Rex is required (`REX_SESSION` set). Without it, give Billy the successor's
  command and the prompt's path instead.

## Before handing off

Anything only this session holds dies with its pane: background shells,
monitors, wakeups, artifact watches, its process. Settle each:

1. **Durable state where the project keeps it.** A project with task notes
   (its `task` skill and `AGENTS.md` say where and how) gets the task's
   handoff written there, with Billy's decisions recorded where it keeps
   them. Elsewhere, the durable state is the commits, the PR, and the
   prompt. The prompt points at the record; it never replaces it.
2. **Memory** (Claude): save what a future session should know and the
   project does not hold (the memory rules).
3. **Background work.** For each background shell, monitor, or wakeup:
   - finish it and record its result, or
   - stop it and name in the prompt the command that resumes it (a
     resumable run, the project's ship wait for a queued ship), or
   - if it must outlive this session, run it in its own Rex pane (it then
     outlives this one) or detached (`nohup … &`, logging to a file), and
     give the pane or PID and log path in the prompt.

   Never leave a background shell running into the handoff.
4. **Servers and browsers.** Stop the dev server, browser sessions, and
   ports you opened, unless the successor needs them now; then say so, with
   the port and PID.
5. **The worktree.**
   - Work continues on this branch (uncommitted changes, unshipped commits,
     an open PR): commit what is coherent, and hand the worktree to the
     successor (its directory is the script's `DIR`). Do not remove it.
   - This branch is merged and the next piece is a new PR: remove the
     worktree first (Claude: ExitWorktree with `keep`, which is all it
     allows for a worktree entered by path or inherited, then `git worktree
     remove` and `git branch -D` from the primary checkout; others: the
     same two git commands), pull `main` in the primary checkout, and start
     the successor there. It isolates itself in a new worktree.
6. **Nothing dirty** in the primary checkout.

## The prompt

Write it to `.local/handoffs/<task-slug>-<n>.md` in the checkout you are in
(add `.local/` to the project's `.gitignore` if it is not there). The
successor reads it once, at start. Keep it short; the successor reads the
durable record for the rest.

- First line: which skill and task to resume, in words both harnesses read
  ("Use the task skill on `Place proposals`"), or the goal in one line where
  the project has no task notes.
- One paragraph: what was just finished (PR numbers), what is next, and that
  Billy approved it if so, so the successor does not ask again.
- Where it starts: the worktree and branch, or "the primary checkout; make
  your own worktree".
- What only this session knows: running processes (pane or PID, log, resume
  command), a queued PR to wait on, traps you hit that cost time, and file or
  test names that would take long to rediscover.
- How it ends: the task's done-when, the ship and deploy check, the handoff
  in the record, its own worktree removed, and where we are / next / needs
  Billy.

The script appends a footer naming this pane and the close command.

## Hand off

```sh
~/dev/rig/bin/handoff open <prompt> [<dir>]
```

It starts the successor with the same harness and the same permission bypass
as this session, in a pane to the right, and prints the pane once the
successor is working. On a trust prompt or no start within 90 s it fails and
says so: tell Billy, and do not open a second one before checking the pane
(`rex capture -b <pane> --trim`).

Then end your turn with one line: the successor's pane, the prompt's path,
and what it is doing. Do nothing after it; the successor closes this pane.

## When you are the successor

1. Read the prompt, then run the close command its footer names in the
   background. It waits until the predecessor is idle, closes its pane, and
   moves the worktree's lock to you when you inherited one.
2. Resume through the skill the prompt names, after the project's bootstrap
   if you are in a new worktree.
3. If the prompt was wrong or left out something that cost you time, say so
   in your last message, so the next handoff prompt is better.
