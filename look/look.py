#!/usr/bin/env python3
"""look: show Billy pictures and clips in a Rex pane beside the agent, and
bring his answer back as JSON. The README beside this file is the guide.

The agent's side (ask, show, wait, close) opens a split running this file's
viewer (`__view DIR`), which draws with the kitty graphics protocol and
writes DIR/answer.json before it exits. Standard library plus ffmpeg only.
"""
import argparse, base64, json, math, os, queue, re, select, shutil, signal
import subprocess, sys, termios, textwrap, threading, time, tty, uuid, zlib
from concurrent.futures import ThreadPoolExecutor

STATE = os.path.expanduser("~/.local/state/rig/look")
VIDEO = {".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".gif"}
IMAGE = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff", ".heic"}
PICKS = ("one", "many", "none")
RESERVED = set("hjklzqpm")  # keys the viewer uses itself
KEEP_DAYS = 7

EXIT_ANSWERED, EXIT_DISMISSED, EXIT_WAITING, EXIT_USAGE = 0, 2, 3, 64


class Usage(Exception):
    pass


# ================================================================ items

_TIME = r"(\d+(?:\.\d+)?)"


def parse_item(arg):
    """`PATH[@T | #A-B][::CAPTION]` into one item, or a directory's media."""
    caption = None
    body = arg
    if "::" in arg and not os.path.exists(arg):
        body, caption = arg.rsplit("::", 1)
    if os.path.isdir(body):
        files = sorted(f for f in os.listdir(body)
                       if os.path.splitext(f)[1].lower() in VIDEO | IMAGE and not f.startswith("."))
        if not files:
            raise Usage(f"{body}: no images or videos in it")
        return [_item(os.path.join(body, f), None, None, None, None) for f in files]
    t = a = b = None
    path = body
    if not os.path.exists(body):
        m = re.fullmatch(rf"(.+)@{_TIME}", body) or None
        r = re.fullmatch(rf"(.+)#{_TIME}-{_TIME}", body) or None
        if m:
            path, t = m.group(1), float(m.group(2))
        elif r:
            path, a, b = r.group(1), float(r.group(2)), float(r.group(3))
            if b <= a:
                raise Usage(f"{arg}: a range ends after it starts")
    if not os.path.isfile(path):
        raise Usage(f"{path}: no such file")
    return [_item(path, t, a, b, caption, spec=arg)]


def _item(path, t, a, b, caption, spec=None):
    ext = os.path.splitext(path)[1].lower()
    if ext in IMAGE:
        if t is not None or a is not None:
            raise Usage(f"{path}: @time and #range apply to videos only")
        kind = "image"
    elif ext in VIDEO:
        kind = "frame" if t is not None else "video"
    else:
        raise Usage(f"{path}: not an image or video this knows ({ext or 'no extension'})")
    return {"spec": spec or path, "path": os.path.abspath(path), "kind": kind,
            "t": t, "a": a, "b": b, "caption": caption}


def parse_items(args):
    items = []
    for arg in args:
        items.extend(parse_item(arg))
    if not items:
        raise Usage("nothing to show: name at least one image or video")
    return items


def items_from_spec(data):
    """A JSON list of {path, caption?, t?, a?, b?}, for captions a shell would mangle."""
    out = []
    for e in data:
        if not isinstance(e, dict) or "path" not in e:
            raise Usage("--items-json: each entry is an object with a path")
        arg = e["path"]
        if e.get("t") is not None:
            arg += f"@{e['t']}"
        elif e.get("a") is not None:
            arg += f"#{e['a']}-{e['b']}"
        for it in parse_item(arg):
            it["caption"] = e.get("caption")
            out.append(it)
    return out


def answer_keys(answers):
    """A distinct letter for each named answer, its own first letter where free."""
    used, keys = set(RESERVED), []
    for ans in answers:
        pick = next((ch for ch in ans.lower() if ch.isalpha() and ch not in used), None)
        if pick is None:
            pick = next(ch for ch in "abcdefgiorstuvwxy" if ch not in used)
        used.add(pick)
        keys.append(pick)
    return keys


# ================================================================ layout

def fit(wpx, hpx, maxc, maxr, cw, ch):
    """The largest cell box with the media's aspect inside maxc x maxr cells."""
    c = maxc
    r = max(1, round(c * cw * hpx / (wpx * ch)))
    if r > maxr:
        r = maxr
        c = max(1, round(r * ch * wpx / (hpx * cw)))
    return min(c, maxc), min(r, maxr)


MIN_TILE = (10, 4)  # inner cells, below which a page holds fewer items


def choose_grid(n, width, height, aspect, cw, ch):
    """(cols, rows, inner_w, inner_h) showing n tiles largest; each tile has a
    border (2 cells each way), a gap column and a caption row."""
    best = None
    for cols in range(1, n + 1):
        rows = math.ceil(n / cols)
        iw, ih = width // cols - 3, height // rows - 3
        if iw < MIN_TILE[0] or ih < MIN_TILE[1]:
            continue
        c, r = fit(aspect * 1000, 1000, iw, ih, cw, ch)
        area = c * cw * r * ch
        if best is None or area > best[0]:
            best = (area, cols, rows, iw, ih)
    return best[1:] if best else None


def per_page(n, width, height, aspect, cw, ch):
    """How many items fit on one page at no less than MIN_TILE."""
    k = n
    while k > 1 and choose_grid(k, width, height, aspect, cw, ch) is None:
        k -= 1
    return k


def build_answer(spec, status, picked, answer, marks, note, seconds):
    items = spec["items"]

    def ref(i):
        it = items[i]
        return {"n": i + 1, "item": it["spec"], "caption": it.get("caption")}

    return {
        "id": spec["id"], "question": spec.get("question"), "status": status,
        "answer": answer,
        "picked": [ref(i) for i in sorted(picked)],
        "marks": [dict(ref(i), t=round(t, 3)) for i, t in marks],
        "note": (note or "").strip() or None, "seconds": round(seconds, 1),
    }


# ================================================================ terminal

OUT = sys.stdout.buffer


def w(s):
    OUT.write(s.encode() if isinstance(s, str) else s)


def at(row, col, text=""):
    w(f"\x1b[{row};{col}H{text}")


def gfx(ctrl, data=b""):
    """One kitty graphics command, chunked as the protocol requires."""
    ctrl = dict(ctrl)
    ctrl.setdefault("q", 2)
    head = ",".join(f"{k}={v}" for k, v in ctrl.items())
    b = base64.standard_b64encode(data)
    if len(b) <= 4096:
        OUT.write(b"\x1b_G" + head.encode() + b";" + b + b"\x1b\\")
        return
    for n in range(0, len(b), 4096):
        last = n + 4096 >= len(b)
        k = f"{head},m={0 if last else 1}" if n == 0 else f"m={0 if last else 1},q=2"
        OUT.write(b"\x1b_G" + k.encode() + b";" + b[n:n + 4096] + b"\x1b\\")


def status(state, msg=None):
    """Rex program status (OSC 7501): the tab shows this pane waits on Billy."""
    body = f"state={state}"
    if state == "blocked":
        body += ":kind=question"
    if state != "clear":
        body += ":app=look"
    if msg:
        clean = "".join(ch if ch.isprintable() else " " for ch in msg)[:200]
        body += ":msg=" + base64.standard_b64encode(clean.encode()).decode()
    w(f"\x1b]7501;{body}\x1b\\")


def trunc(s, n):
    return s if len(s) <= n else s[: max(0, n - 1)] + "…"


# ================================================================ media

def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height:stream_side_data=rotation:format=duration", "-of", "json", path],
        capture_output=True, text=True).stdout
    try:
        d = json.loads(out)
        s = d["streams"][0]
        wd, ht = s["width"], s["height"]
        rot = next((abs(int(x.get("rotation", 0))) for x in s.get("side_data_list", [])), 0)
        if rot in (90, 270):
            wd, ht = ht, wd
        dur = float(d.get("format", {}).get("duration") or 0)
        return wd, ht, dur
    except Exception:
        return 16, 9, 0.0


def decode(item, wd, ht, max_frames, max_fps):
    """[zlib-compressed RGB frames], fps. A still is one frame."""
    vf = (f"scale={wd}:{ht}:force_original_aspect_ratio=decrease,"
          f"pad={wd}:{ht}:(ow-iw)/2:(oh-ih)/2")
    kind, path = item["kind"], item["path"]
    if kind in ("image", "frame"):
        pre = ["-ss", str(item["t"])] if kind == "frame" else []
        args = [*pre, "-i", path, "-frames:v", "1", "-vf", vf]
        fps = 0
    else:
        dur = (item["b"] - item["a"]) if item["a"] is not None else max(item["dur"], 0.1)
        fps = max(1.0, min(max_fps, max_frames / dur))
        pre = ["-ss", str(item["a"]), "-t", str(dur)] if item["a"] is not None else []
        args = [*pre, "-i", path, "-vf", f"fps={fps:.4f},{vf}", "-frames:v", str(max_frames)]
    raw = subprocess.run(["ffmpeg", "-v", "error", *args, "-f", "rawvideo",
                          "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    n = wd * ht * 3
    frames = [zlib.compress(raw[i:i + n], 1) for i in range(0, len(raw) - n + 1, n)]
    return frames, fps


# ================================================================ viewer

STILL_SCALE = 2          # Rex reports cells in points; stills render at 2x for Retina
TILE_BUDGET = 48 << 20   # raw bytes of tile frames per page, all tiles together
ZOOM_AREA = 330_000      # pixels in a zoomed video frame
ZOOM_FRAMES, ZOOM_FPS, TILE_FPS = 180, 15, 8
ZOOM_ID = 9000


class Viewer:
    def __init__(self, run_dir):
        self.dir = run_dir
        with open(os.path.join(run_dir, "spec.json")) as f:
            self.spec = json.load(f)
        self.items = self.spec["items"]
        self.ask = self.spec["mode"] == "ask"
        self.pick = self.spec.get("pick", "none")
        self.answers = self.spec.get("answers") or []
        self.akeys = answer_keys(self.answers)
        self.focus, self.selected, self.marks, self.note = 0, set(), [], ""
        self.zoom = False
        self.cw, self.ch = 8, 16
        self.t0 = time.time()
        self.pool = ThreadPoolExecutor(6)
        self.results = queue.Queue()
        self.cache = {}       # (idx, w, h, tag) -> (frames, fps)
        self.pending = set()
        self.gen = 0          # bumps on each layout; stale decodes are dropped
        self.size = None
        self.play = None      # zoomed video: dict(frames, fps, i, paused, next, box)

    # ---------------------------------------------------------- setup

    def query_cells(self):
        w("\x1b[16t"); OUT.flush()
        buf, end = b"", time.time() + 0.6
        while time.time() < end:
            r, _, _ = select.select([0], [], [], 0.1)
            if r:
                buf += os.read(0, 64)
                if buf.endswith(b"t"):
                    break
        m = re.search(rb"\x1b\[6;(\d+);(\d+)t", buf)
        if m:
            self.ch, self.cw = int(m.group(1)), int(m.group(2))

    def probe_all(self):
        with ThreadPoolExecutor(8) as ex:
            for it, (wd, ht, dur) in zip(self.items, ex.map(lambda i: probe(i["path"]), self.items)):
                it["w"], it["h"], it["dur"] = wd, ht, dur
        aspects = sorted(it["w"] / it["h"] for it in self.items)
        self.aspect = aspects[len(aspects) // 2]

    # ---------------------------------------------------------- drawing

    def header(self):
        cols = self.size[0]
        title = self.spec.get("question") or self.spec.get("title") or "look"
        lines = textwrap.wrap(title, cols - 4)[:3] or [""]
        for i, l in enumerate(lines):
            at(1 + i, 3, f"\x1b[1m{l}\x1b[0m")
        n = len(self.items)
        sub = f"{n} item{'s' if n != 1 else ''}"
        if self.pages > 1:
            sub += f" · page {self.page + 1} of {self.pages}  ([ ] turn)"
        at(len(lines) + 1, 3, f"\x1b[2m{sub}\x1b[0m")
        return len(lines) + 2

    def footer(self):
        cols, rows = self.size
        keys = []
        if self.zoom:
            keys.append("←→ prev/next")
            if self.play:
                keys.append("p pause  , . step  m mark")
            keys.append("z grid")
        else:
            keys.append("arrows move  z zoom")
        if self.ask:
            if self.pick == "many":
                keys.append("space select  ⏎ send")
            elif self.pick == "one":
                keys.append("⏎ pick this")
            for k, a in zip(self.akeys, self.answers):
                keys.append(f"\x1b[1m{k}\x1b[22m {a}")
            keys.append("/ note  q dismiss")
        else:
            keys.append("q close")
        at(rows - 1, 1, "\x1b[2K")
        at(rows, 1, "\x1b[2K")
        at(rows, 3, trunc("   ".join(keys), cols + 40) + "\x1b[0m")
        info = []
        if self.selected:
            info.append("picked " + ", ".join(str(i + 1) for i in sorted(self.selected)))
        if self.marks:
            info.append("marks " + ", ".join(f"{i + 1}@{t:.2f}s" for i, t in self.marks))
        if self.note:
            info.append(f"note: {self.note}")
        if info:
            at(rows - 1, 3, f"\x1b[38;5;114m{trunc('   '.join(info), cols - 4)}\x1b[0m")

    def layout(self):
        """Recompute everything for the current size, page or zoom and redraw."""
        self.gen += 1
        self.play = None
        gfx({"a": "d", "d": "a"})  # placements only; image data stays for reuse
        w("\x1b[2J")
        cols, rows = self.size
        aspect = self.aspect
        self.pages = 1
        self.page = 0
        # a first header pass sizes the grid; the page count it prints follows
        top = len(textwrap.wrap(self.spec.get("question") or self.spec.get("title") or "", cols - 4)[:3] or [""]) + 2
        height = rows - top - 2
        k = per_page(len(self.items), cols - 1, height, aspect, self.cw, self.ch)
        self.k = k
        self.pages = math.ceil(len(self.items) / k)
        self.page = self.focus // k
        top = self.header()
        if self.zoom:
            self.draw_zoom(top, rows - top - 2)
        else:
            self.draw_grid(top, height)
        self.footer()
        OUT.flush()

    def draw_grid(self, top, height):
        cols = self.size[0]
        first = self.page * self.k
        idxs = list(range(first, min(first + self.k, len(self.items))))
        g = choose_grid(len(idxs), cols - 1, height, self.aspect, self.cw, self.ch)
        if g is None:
            at(top + 1, 3, "pane too small; widen it")
            self.tiles = {}
            return
        gc, gr, iw, ih = g
        cell_w, cell_h = (cols - 1) // gc, height // gr
        self.tiles, self.grid = {}, (gc, gr)
        frames_each = max(1, min(48, TILE_BUDGET // max(1, len(idxs) * iw * self.cw * ih * self.ch * 3)))
        for slot, i in enumerate(idxs):
            x, y = 2 + (slot % gc) * cell_w, top + (slot // gc) * cell_h
            it = self.items[i]
            c, r = fit(it["w"], it["h"], iw, ih, self.cw, self.ch)
            ox, oy = x + 1 + (iw - c) // 2, y + 1 + (ih - r) // 2
            self.tiles[i] = dict(x=x, y=y, iw=iw, ih=ih, c=c, r=r, ox=ox, oy=oy)
            self.draw_tile(i)
            moving = it["kind"] == "video"
            sc = 1 if moving else STILL_SCALE
            self.request(i, c * self.cw * sc, r * self.ch * sc, frames_each if moving else 1,
                         TILE_FPS, "tile")

    def draw_tile(self, i):
        t = self.tiles.get(i)
        if not t:
            return
        focus, sel = i == self.focus, i in self.selected
        color = "38;5;114" if sel else ("38;5;209" if focus else "38;5;240")
        tl, tr_, bl, br, hz, vt = ("┏", "┓", "┗", "┛", "━", "┃") if focus else ("╭", "╮", "╰", "╯", "─", "│")
        label = f" {i + 1}{' ✓' if sel else ''} "
        top_line = tl + hz + label + hz * max(0, t["iw"] - len(label) - 1) + tr_
        at(t["y"], t["x"], f"\x1b[{color}{';1' if focus else ''}m{top_line}")
        for row in range(t["ih"]):
            at(t["y"] + 1 + row, t["x"], vt)
            at(t["y"] + 1 + row, t["x"] + t["iw"] + 1, vt)
        at(t["y"] + t["ih"] + 1, t["x"], bl + hz * t["iw"] + br + "\x1b[0m")
        cap = self.items[i].get("caption") or os.path.basename(self.items[i]["spec"])
        at(t["y"] + t["ih"] + 2, t["x"] + 1,
           f"\x1b[{'1' if focus else '2'}m{trunc(cap, t['iw']).ljust(t['iw'])}\x1b[0m")

    def draw_zoom(self, top, height):
        cols = self.size[0]
        i = self.focus
        it = self.items[i]
        c, r = fit(it["w"], it["h"], cols - 4, height - 2, self.cw, self.ch)
        ox, oy = 2 + (cols - 2 - c) // 2, top
        self.zbox = dict(c=c, r=r, ox=ox, oy=oy, cap_row=top + r)
        cap = it.get("caption") or os.path.basename(it["spec"])
        sel = " ✓" if i in self.selected else ""
        at(top + r, 3, f"\x1b[1m{i + 1}{sel}\x1b[0m  {trunc(cap, cols - 30)}")
        if it["kind"] == "video":
            px, py = c * self.cw, r * self.ch
            s = min(1.0, math.sqrt(ZOOM_AREA / (px * py)))
            self.request(i, int(px * s) // 2 * 2, int(py * s) // 2 * 2, ZOOM_FRAMES, ZOOM_FPS, "zoom")
        else:
            self.request(i, c * self.cw * STILL_SCALE, r * self.ch * STILL_SCALE, 1, 0, "zoom")

    # ---------------------------------------------------------- media flow

    def request(self, i, wd, ht, frames, fps, tag):
        key = (i, wd, ht, tag)
        if key in self.cache:
            self.show(key, self.gen)
            return
        if not self.zoom or tag == "zoom":
            box = self.tiles[i] if tag == "tile" else self.zbox
            at(box["oy"], box["ox"], "\x1b[2mloading…\x1b[0m")
        if key in self.pending:
            return
        self.pending.add(key)
        gen = self.gen

        def job():
            try:
                res = decode(self.items[i], wd, ht, frames, fps)
            except Exception:
                res = ([], 0)
            self.results.put((key, gen, res))

        self.pool.submit(job)

    def drain(self):
        while True:
            try:
                key, gen, res = self.results.get_nowait()
            except queue.Empty:
                return
            self.pending.discard(key)
            self.cache[key] = res
            if gen == self.gen:
                self.show(key, gen)
                OUT.flush()

    def show(self, key, gen):
        i, wd, ht, tag = key
        frames, fps = self.cache[key]
        if tag == "tile":
            if self.zoom or i not in self.tiles:
                return
            box = self.tiles[i]
            img = 100 + i
        else:
            if not self.zoom or i != self.focus:
                return
            box = self.zbox
            img = ZOOM_ID
        at(box["oy"], box["ox"], " " * 8)
        if not frames:
            at(box["oy"], box["ox"], "\x1b[31mcould not decode\x1b[0m")
            return
        base = {"f": 24, "s": wd, "v": ht, "o": "z"}
        if tag == "zoom" and len(frames) > 1:
            # played by this process, so it can pause, step, and mark
            self.play = dict(frames=frames, fps=fps, i=0, paused=False, next=time.time(),
                             wd=wd, ht=ht, item=i, box=box)
            self.tick()
            return
        gfx({"a": "t", "i": img, **base}, frames[0])
        if len(frames) > 1:
            gap = int(1000 / fps)
            for fr in frames[1:]:
                gfx({"a": "f", "i": img, "z": gap, **base}, fr)
            gfx({"a": "a", "i": img, "r": 1, "z": gap})
        at(box["oy"], box["ox"])
        gfx({"a": "p", "i": img, "p": 1, "c": box["c"], "r": box["r"], "C": 1})
        if len(frames) > 1:
            gfx({"a": "a", "i": img, "s": 3, "v": 1})

    def tick(self):
        p = self.play
        if not p:
            return
        now = time.time()
        if not p["paused"]:
            if now < p["next"]:
                return
            p["i"] = (p["i"] + 1) % len(p["frames"]) if p.get("shown") else 0
            p["next"] = max(p["next"] + 1 / p["fps"], now - 0.5)
        self.put_frame()

    def put_frame(self):
        p = self.play
        b = p["box"]
        at(b["oy"], b["ox"])
        gfx({"a": "T", "i": ZOOM_ID, "p": 1, "f": 24, "s": p["wd"], "v": p["ht"], "o": "z",
             "c": b["c"], "r": b["r"], "C": 1}, p["frames"][p["i"]])
        p["shown"] = True
        it = self.items[p["item"]]
        t = self.play_time()
        total = (it["b"] - it["a"]) if it["a"] is not None else it["dur"]
        state = "paused" if p["paused"] else "playing"
        at(b["cap_row"], self.size[0] - 26, f"\x1b[K\x1b[2m{state} {t:6.2f}s / {(it['a'] or 0) + total:.2f}s\x1b[0m")
        OUT.flush()

    def play_time(self):
        p = self.play
        it = self.items[p["item"]]
        return (it["a"] or 0) + p["i"] / p["fps"]

    # ---------------------------------------------------------- input

    def read_key(self, timeout):
        r, _, _ = select.select([0], [], [], timeout)
        if not r:
            return None
        b = os.read(0, 64)
        named = {b"\x1b[A": "up", b"\x1b[B": "down", b"\x1b[C": "right", b"\x1b[D": "left",
                 b"\r": "enter", b"\n": "enter", b"\x1b": "esc", b" ": "space", b"\x7f": "bs",
                 b"\x03": "q"}
        if b in named:
            return named[b]
        if b.startswith(b"\x1b"):
            return None
        return b.decode(errors="ignore")[:1] or None

    def read_note(self):
        cols, rows = self.size
        w("\x1b[?25h")
        text = self.note
        while True:
            at(rows - 1, 1, f"\x1b[2K  note: {text}")
            OUT.flush()
            k = self.read_key(None)
            if k == "enter":
                break
            if k == "esc":
                text = self.note
                break
            if k == "bs":
                text = text[:-1]
            elif k == "space":
                text += " "
            elif k and len(k) == 1 and k.isprintable():
                text += k
        w("\x1b[?25l")
        self.note = text.strip()
        self.footer()
        OUT.flush()

    def move(self, d):
        n = len(self.items)
        if self.zoom:
            step = {"left": -1, "right": 1, "h": -1, "l": 1}.get(d, 0)
            if step:
                self.focus = (self.focus + step) % n
                self.layout()
            return
        gc = self.grid[0] if getattr(self, "grid", None) else 1
        step = {"left": -1, "h": -1, "right": 1, "l": 1, "up": -gc, "k": -gc, "down": gc, "j": gc}[d]
        new = min(max(0, self.focus + step), n - 1)
        if new == self.focus:
            return
        old, self.focus = self.focus, new
        if new // self.k != old // self.k:
            self.layout()
        else:
            self.draw_tile(old)
            self.draw_tile(new)
            OUT.flush()

    def toggle(self, i):
        if self.pick == "many":
            self.selected ^= {i}
        elif self.pick == "one":
            self.selected = {i}
        if self.zoom:
            self.layout()
        else:
            self.draw_tile(i)
            self.footer()
            OUT.flush()

    def finish(self, status_, answer=None):
        if not self.ask:
            return True
        picked = set(self.selected)
        if status_ == "answered" and answer is None and self.pick == "one":
            picked = {self.focus}
        if status_ != "answered":
            picked = set()
        ans = build_answer(self.spec, status_, picked, answer, self.marks, self.note,
                           time.time() - self.t0)
        tmp = os.path.join(self.dir, "answer.json.tmp")
        with open(tmp, "w") as f:
            json.dump(ans, f, indent=2)
        os.replace(tmp, os.path.join(self.dir, "answer.json"))
        return True

    def handle(self, k):
        """True once the viewer should exit."""
        if k == "q" or (k == "esc" and not self.zoom):
            return self.finish("dismissed")
        if k in ("up", "down", "left", "right", "h", "j", "k", "l"):
            self.move(k)
        elif k in ("z", "esc"):
            if k == "z" or self.zoom:
                self.zoom = not self.zoom
                self.layout()
        elif k == "[" or k == "]":
            if self.pages > 1:
                self.focus = min(len(self.items) - 1,
                                 max(0, (self.page + (1 if k == "]" else -1)) % self.pages * self.k))
                self.layout()
        elif k and k.isdigit() and k != "0":
            i = self.page * self.k + int(k) - 1
            if i < len(self.items) and not self.zoom:
                old, self.focus = self.focus, i
                self.draw_tile(old); self.draw_tile(i); OUT.flush()
        elif self.play and k == "p":
            self.play["paused"] = not self.play["paused"]
            self.play["next"] = time.time()
            self.put_frame()
        elif self.play and k in (",", "."):
            p = self.play
            p["paused"] = True
            p["i"] = (p["i"] + (1 if k == "." else -1)) % len(p["frames"])
            self.put_frame()
        elif not self.ask:
            pass
        elif k == "space" and self.pick == "many":
            self.toggle(self.focus)
        elif k == "enter" and self.pick in ("one", "many"):
            if self.pick == "many" and not self.selected:
                self.selected = {self.focus}
            return self.finish("answered")
        elif k in self.akeys:
            return self.finish("answered", self.answers[self.akeys.index(k)])
        elif k == "/":
            self.read_note()
        elif self.play and k == "m":
            self.marks.append((self.play["item"], self.play_time()))
            self.footer(); OUT.flush()
        return False

    # ---------------------------------------------------------- run

    def run(self):
        fd = 0
        old = termios.tcgetattr(fd)
        tty.setcbreak(fd)
        w("\x1b[?1049h\x1b[?25l")
        try:
            self.query_cells()
            if self.ask:
                status("blocked", self.spec.get("question"))
            at(1, 3, "\x1b[2mreading media…\x1b[0m"); OUT.flush()
            self.probe_all()
            while True:
                size = tuple(os.get_terminal_size())
                if size != self.size:
                    self.size = size
                    self.layout()
                self.drain()
                self.tick()
                timeout = 0.1
                if self.play and not self.play["paused"]:
                    timeout = max(0, min(timeout, self.play["next"] - time.time()))
                k = self.read_key(timeout)
                if k and self.handle(k):
                    break
        finally:
            gfx({"a": "d", "d": "A"})
            status("clear")
            w("\x1b[0m\x1b[?25h\x1b[?1049l")
            OUT.flush()
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            self.pool.shutdown(wait=False, cancel_futures=True)


# ================================================================ agent side

def rex(*args, check=True):
    r = subprocess.run(["rex", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"look: rex {args[0]} failed: {r.stderr.strip() or r.stdout.strip()}")
    return r


def prune():
    if not os.path.isdir(STATE):
        return
    cutoff = time.time() - KEEP_DAYS * 86400
    for d in os.listdir(STATE):
        p = os.path.join(STATE, d)
        try:
            if os.path.getmtime(p) < cutoff:
                shutil.rmtree(p)
        except OSError:
            pass


def open_pane(spec, ratio, focus):
    for var in ("REX_SESSION", "REX_BLOCK"):
        if not os.environ.get(var):
            raise SystemExit(f"look: needs Rex ({var} unset); without Rex, describe the media or publish a page")
    if not shutil.which("ffmpeg"):
        raise SystemExit("look: needs ffmpeg on PATH")
    prune()
    run_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
    run_dir = os.path.join(STATE, run_id)
    os.makedirs(run_dir)
    spec["id"] = run_id
    with open(os.path.join(run_dir, "spec.json"), "w") as f:
        json.dump(spec, f, indent=2)
    r = rex("split", "-s", os.environ["REX_SESSION"], "-b", os.environ["REX_BLOCK"],
            "--split=right", f"--ratio={ratio}", f"--focus={'true' if focus else 'false'}",
            "--shell=none", "--", sys.executable, os.path.abspath(__file__), "__view", run_dir)
    block = re.search(r"block:\S+", r.stdout)
    if not block:
        raise SystemExit(f"look: rex split printed no block: {r.stdout.strip()}")
    with open(os.path.join(run_dir, "block"), "w") as f:
        f.write(block.group(0))
    return run_id


def parse_duration(s):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(s|m|h)?", s)
    if not m:
        raise Usage(f"--timeout {s}: say 90s, 9m or 2h")
    return float(m.group(1)) * {"s": 1, "m": 60, "h": 3600, None: 1}[m.group(2)]


def wait(run_id, timeout):
    run_dir = os.path.join(STATE, run_id)
    if not os.path.isdir(run_dir):
        raise SystemExit(f"look: no run {run_id}")
    with open(os.path.join(run_dir, "block")) as f:
        block = f.read().strip()
    answer = os.path.join(run_dir, "answer.json")
    end = time.time() + timeout
    while True:
        if os.path.exists(answer):
            break
        left = end - time.time()
        if left <= 0:
            print(json.dumps({"id": run_id, "status": "waiting"}))
            print(f"look: Billy has not answered yet; the pane stays open. "
                  f"Wait again with: look wait {run_id}", file=sys.stderr)
            return EXIT_WAITING
        r = rex("wait", "-s", os.environ.get("REX_SESSION", ""), block,
                "--for", f"{max(1, int(min(left, 60)))}s", check=False)
        if r.returncode != 0 and "timed out" not in (r.stdout + r.stderr):
            break  # the pane is gone
    if os.path.exists(answer):
        with open(answer) as f:
            data = json.load(f)
        print(json.dumps(data, indent=2))
        return EXIT_ANSWERED if data["status"] == "answered" else EXIT_DISMISSED
    print(json.dumps({"id": run_id, "status": "closed"}))
    return EXIT_DISMISSED


def close(run_id):
    path = os.path.join(STATE, run_id, "block")
    if not os.path.exists(path):
        raise SystemExit(f"look: no run {run_id}")
    with open(path) as f:
        rex("block", "close", "-s", os.environ.get("REX_SESSION", ""), f.read().strip(), check=False)
    return 0


def self_check():
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([sys.executable, "-m", "unittest", "-q", "test_look"], cwd=here)
    return r.returncode


def main(argv):
    if len(argv) >= 2 and argv[0] == "__view":
        Viewer(argv[1]).run()
        return 0
    ap = argparse.ArgumentParser(prog="look", description="Pictures and clips in a Rex pane beside the agent.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def media(p):
        p.add_argument("items", nargs="*", help="PATH, PATH@T (a frame), PATH#A-B (a span), DIR; ::CAPTION after any")
        p.add_argument("--items-json", help="a file (or - for stdin) with [{path, caption, t | a,b}]")
        p.add_argument("--ratio", type=int, default=55, help="the pane's share of the split, percent")

    a = sub.add_parser("ask", help="ask Billy about the media; prints his answer as JSON")
    a.add_argument("question")
    media(a)
    a.add_argument("--pick", choices=PICKS, help="one item (default), several, or none (answers only)")
    a.add_argument("--answers", help="comma-separated named answers, each a key in the pane")
    a.add_argument("--timeout", default="9m", help="how long to wait (default 9m; 0 returns at once)")
    s = sub.add_parser("show", help="show media; returns at once, Billy closes it with q")
    s.add_argument("--title", default=None)
    media(s)
    wt = sub.add_parser("wait", help="wait for an earlier ask's answer")
    wt.add_argument("id")
    wt.add_argument("--timeout", default="9m")
    c = sub.add_parser("close", help="close a pane look opened")
    c.add_argument("id")
    sub.add_parser("self-check", help="this tool's tests")
    args = ap.parse_args(argv)

    try:
        if args.cmd == "self-check":
            return self_check()
        if args.cmd == "wait":
            return wait(args.id, parse_duration(args.timeout))
        if args.cmd == "close":
            return close(args.id)
        items = parse_items(args.items) if args.items else []
        if args.items_json:
            src = sys.stdin if args.items_json == "-" else open(args.items_json)
            items += items_from_spec(json.load(src))
        if not items:
            raise Usage("nothing to show: name at least one image or video")
        if args.cmd == "show":
            run_id = open_pane({"mode": "show", "title": args.title, "items": items}, args.ratio, False)
            print(run_id)
            return 0
        answers = [x.strip() for x in (args.answers or "").split(",") if x.strip()]
        pick = args.pick or ("none" if answers else "one")
        if pick == "none" and not answers:
            raise Usage("--pick none needs --answers, or Billy has no way to answer")
        timeout = parse_duration(args.timeout)
        run_id = open_pane({"mode": "ask", "question": args.question, "pick": pick,
                            "answers": answers, "items": items}, args.ratio, True)
        if timeout == 0:
            print(json.dumps({"id": run_id, "status": "waiting"}))
            return EXIT_WAITING
        return wait(run_id, timeout)
    except Usage as e:
        print(f"look: {e}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main(sys.argv[1:]))
