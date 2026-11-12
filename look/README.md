# look

Pictures and clips in a Rex pane beside the agent, drawn with the kitty
graphics protocol; Billy's answer comes back to the agent as JSON. For a
visual question the agent would otherwise describe in words or publish a
page for (which mask, which cut, which of these are wrong), asked and
answered within one turn.

It steers the agent and is never a record. A judgment that must be kept (a
label, a verified answer, anything a product stores) goes through that
product's own review surface; anything shared or read later is a published
page. The pane is local, lives as long as it is open, and plays files from
disk, so nothing is uploaded.

```sh
look ask "Which mask follows the board?" a.png b.png c.png        # pick one (default)
look ask "Which clips are not snowboarding?" --pick many clips/    # pick several
look ask "Better cut?" --answers "left,right,same" --pick none old.mp4 new.mp4
look ask "Mark the take-off" clip.mp4#2-6                           # z zooms; m marks a time
look show --title "cutouts so far" out/*.png                        # returns at once; Billy closes it
look wait ID | look close ID | look self-check
```

An item is `PATH`, `PATH@T` (one frame of a video at T seconds),
`PATH#A-B` (a video from A to B seconds), or a directory (its media, in
name order), each optionally followed by `::CAPTION`. `--items-json FILE`
(or `-`) takes `[{path, caption, t | a, b}]` for captions a shell would
mangle. Images are anything ffmpeg reads; videos loop in their tiles.

`ask` waits up to `--timeout` (default 9m, inside an agent's 10-minute
command limit) and prints the answer:

```json
{"id": "…", "question": "…", "status": "answered", "answer": "same",
 "picked": [{"n": 2, "item": "b.png", "caption": null}],
 "marks": [{"n": 1, "item": "clip.mp4#2-6", "caption": null, "t": 3.27}],
 "note": "the board edge is clipped", "seconds": 14.2}
```

Exit 0 answered, 2 dismissed or closed (`status` says which), 3 still
waiting (the pane stays open; `look wait ID` resumes), 64 a usage error.
`n` is the item's 1-based place in the order given; `item` echoes what the
agent passed; mark times are seconds in the source file.

In the pane: arrows or hjkl move, 1–9 jump, `z` zooms the focused item
(←→ then step through items; a video plays at up to 15 fps with `p` pause,
`,` `.` frame step, `m` mark), space selects (`--pick many`), Enter picks
or sends, each named answer has the letter shown, `/` adds a note, `q`
dismisses. Too many items to fit page with `[` `]`.

While it waits, the pane reports Rex program status `blocked`
(`kind=question`, `app=look`), so its tab shows it waits on Billy. Each
run keeps its spec and answer in `~/.local/state/rig/look/<id>/` for a
week.

It needs Rex (`REX_SESSION`, `REX_BLOCK`) and ffmpeg; Python's standard
library only. Rex reports cell sizes in points, so stills render at twice
the cell box for a Retina screen and videos at once (`STILL_SCALE`).
