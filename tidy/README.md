# tidy

Session hygiene every project in `~/dev` shares: what finished agent
sessions leave behind on the laptop, reported, and in `prune` removed
when it provably has no owner. A project keeps what is its own in
`.tidy.json` at its root (`lib/tidy/config.ex` names each field): what
"landed" means for it, its agent branches, the file that derives a
checkout's suffix, its Postgres, and its databases' names. The mechanics
are here.

```sh
tidy                                  # report every section, change nothing
tidy prune                            # prune every section
tidy report worktrees prune databases processes   # a mode applies to the sections after it
tidy self-check                       # this tool's gate (compile, format, tests)
```

| Section | Reports | `prune` |
| --- | --- | --- |
| `worktrees` | each linked worktree and its state | removes one whose work landed, clean and unlocked, and its branch; never the checkout tidy runs in |
| `branches` | agent branches (`branches`) no worktree carries; remote ones with their state | deletes a local one that landed or holds nothing beyond `origin/main`; never a remote one |
| `databases` | databases matching a `databases` name with a suffix no existing checkout derives | drops them (one with open connections refuses and stays) |
| `processes` | a `dev_commands` process reparented to launchd; a node/BEAM/esbuild/tailwind process whose cwd is a removed worktree | stops it with its tree |
| `simulators` | iOS Simulators booted over two hours, machine-wide | reports only: another session may be driving one |

A checkout's suffix has one definition, the project's own
`config/workspace.exs`: tidy evaluates it in each existing checkout (its
own copy, else the primary's), with `root:` bound and the checkout as the
current directory, rather than re-deriving the slug. When any checkout's
evaluation fails, no database is touched. Each project keeps a test that
its Repo config uses the names its `.tidy.json` declares.

A project's bootstrap calls `~/dev/rig/bin/tidy` (or `$RIG/bin/tidy`)
with the sections and modes its policy wants, and its own
`worktrees.sh` is a wrapper that sets `TIDY_AS`, the name tidy's hints
print. Where rig is absent (Claude Code on the web, a fresh clone), the
bootstrap skips it: the leftovers tidy clears exist only on a machine
where many sessions come and go, which is the laptop rig runs on, and an
in-repo fallback would be the second copy this replaces.

It is a command, not part of rigd: each sweep belongs to a project and
runs when a session starts in it (and from its ship), with that project's
checkout and toolchain at hand. If a machine-wide sweep is ever wanted
(every project's databases on a schedule), rigd can run `tidy` in each
project; the rules stay here.
