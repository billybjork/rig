# Working in ~/dev

These rules hold in every project under `~/dev`. A project's own `AGENTS.md`
owns its gate, deploy, notes, and conventions, and wins where it is more
specific. The shared environment (this file, the shared skills, Rex's config,
the ship worker) lives in `~/dev/rig`; change it there, not in a copy.

## Rex

Billy works in Rex. Prefer a visible pane to a hidden background command for
anything he may want to glance at: dev servers, long test runs, Sprite runs,
ship waits.

- **Where things open.**
  - A shell, dev server, Sprite run, or wait that serves your session: a pane
    **below** yours, out of focus.
  - Another agent session (Claude, Codex): a pane **to the right** of yours.
  - A new tab or session only when really warranted. The ship workers'
    session `Shipyard` is the standing exception.
- **The recipe.**

  ```sh
  rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=below --ratio 35 \
    --focus=false --keep-open --label "<what>" -c "$PWD" -- <command>
  rex wait -s "$REX_SESSION" <block> --for 9m    # its exit status; repeat on timeout
  rex capture -s "$REX_SESSION" -b <block> --trim | tail -n 80
  rex block close -s "$REX_SESSION" <block>
  ```

- **No strays.** Close every pane, tab, and session you opened once its work
  is read. Never switch Billy's focused session or view, and never kill or
  restart Rex processes, without asking.
- A tab label starting with `⚙` is rig's watcher marking an idle agent with a
  background shell, not Billy's naming.
- Without Rex (`REX_SESSION` unset), run the same command in the background.

## Worktrees

Several agents work in a repository at once. Isolation is the agent's call
and the agent's job: Billy never creates, names, or cleans up worktrees.

- Small, self-contained work may happen in the primary checkout, per the
  project's rules. Substantive work happens in a linked worktree you create
  and remove yourself.
- The primary checkout is shared: never leave it dirty, never switch its
  branch. Uncommitted changes there that you did not make belong to another
  session; leave them and take a worktree.
- Remove your worktree once its branch has landed.

## Shipping

Every project that ships does it through its `ship` skill and the ship
worker (`~/dev/rig/shipyard`, for now `~/dev/shipyard`). Never weaken a
check, a test, or the gate to pass; a gate change ships on its own. Wait on a
ship in a pane below yours (the project's watch command), not in your own
command.

## Long sessions

A session whose context is heavy hands its work to a fresh one at a clean
point with the `handoff` skill. Before ending any session, stop or hand over
what only it holds: background shells, servers, watches, panes.

## Secrets

- Never print, log, or write a secret's value, in a file, a commit, a
  transcript, or a permission rule. Name it; if you must tell two apart, the
  last 4 characters.
- Do not read `.env*` files or dump the environment. Run commands that need
  secrets the way the project says (its scripts load them for you).
- Security incidents and cross-project chores are recorded in `~/dev/ops`.

## Judgment

- **Surface decisions, don't guess.** A product, scope, spending, vendor, or
  user-facing call is Billy's: ask at the point it blocks, with choices and a
  recommended default, and finish what does not depend on it.
- **Verify the baseline yourself.** Never carry "this failure is
  pre-existing" from an earlier session or prompt; re-run it.
- **Prefer a check to a paragraph.** A rule worth keeping is a test or lint
  whose failure states it.
