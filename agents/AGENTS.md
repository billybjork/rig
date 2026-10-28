# Working in ~/dev

These rules hold in every project under `~/dev`. A project's own `AGENTS.md`
owns its gate, deploy, notes, and conventions, and wins where it is more
specific. The shared environment (this file, the shared skills, Rex's config,
the ship worker) lives in `~/dev/rig`; change it there, not in a copy.

## Rex

Billy works in Rex and wants his tabs uncluttered (Billy, 2026-10-28).

- **Shells run in background terminals.** A dev server, long test run,
  Sprite run, or wait runs in a Rex terminal that no tab shows
  (`~/dev/rig/bin/bg run`): a real terminal in your session, out of Billy's
  way, which he brings into view from the palette ("Background: Show") when
  he wants to look. Prefer it to the harness's own background commands for
  anything that runs more than a minute or that Billy may want to see.

  ```sh
  block=$(bg run --label "<what>" -- <command>)  # runs in an interactive login zsh, in $PWD
  rex wait -s "$REX_SESSION" "$block" --for 9m   # its exit status; on a timeout exits 1 saying "timed out": repeat
  rex capture -s "$REX_SESSION" -b "$block" --trim | tail -n 80
  rex block close -s "$REX_SESSION" "$block"
  ```

  `bg ls` lists your session's background terminals. A project's watch
  commands (a ship's wait) already use one.
- **Another agent session** (Claude, Codex) still opens as a visible pane
  **to the right** of yours (the `handoff` skill does this).
- **No new tabs or sessions** unless Billy asks. The ship workers' session
  `Shipyard` is the standing exception.
- **No strays.** Close every background terminal, pane, and tab you opened
  once its work is read. Never switch Billy's focused session or view, and
  never kill or restart Rex processes, without asking.
- A tab label starting with `⚙` is rigd marking an idle agent with a
  background shell, not Billy's naming.
- Without Rex (`REX_SESSION` unset), run the command in the harness's
  background instead.

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
worker (`~/dev/rig/shipyard`). Never weaken a
check, a test, or the gate to pass; a gate change ships on its own. Wait on a
ship with the project's watch command, which waits in a background terminal,
not in your own command.

## Long sessions

A session whose context is heavy hands its work to a fresh one at a clean
point with the `handoff` skill. Before ending any session, stop or hand over
what only it holds: background shells, servers, watches, panes.

## Secrets

- Never print, log, or write a secret's value, in a file, a commit, a
  transcript, or a permission rule. Name it; if you must tell two apart, the
  last 4 characters.
- Values live in Bitwarden Secrets Manager. A project's `fnox.toml` names its
  secrets; run a command that needs them as `fnox exec -- <command>` (prod-
  facing and unattended ones: `fnox -P deploy exec --no-defaults -- …`).
  Never run `fnox get`, `fnox export`, `bws secret`, or a Keychain lookup of a
  token, and do not read `.env*` files or dump the environment. A project
  whose scripts already wrap fnox needs nothing extra.
- Adding or rotating a secret: Billy sets the value in Bitwarden (key
  `<repo>-<NAME>`), you add its name to `fnox.toml`, then `fnox daemon clear`.
- Security incidents and cross-project chores are recorded in `~/dev/ops`.

## Judgment

- **Surface decisions, don't guess.** A product, scope, spending, vendor, or
  user-facing call is Billy's: ask at the point it blocks, with choices and a
  recommended default, and finish what does not depend on it.
- **Verify the baseline yourself.** Never carry "this failure is
  pre-existing" from an earlier session or prompt; re-run it.
- **Prefer a check to a paragraph.** A rule worth keeping is a test or lint
  whose failure states it.
