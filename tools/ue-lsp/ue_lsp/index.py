"""Index build, cache and incremental refresh.

Cache layout (%LOCALAPPDATA%/ue-lsp/cache):
  files-<hash(root)>.pickle   per-scope file table {path: (mtime_ns, size, module, parsed)}  (engine / project)
  derived-<hash(engine,project)>.pickle   merged, query-ready index (loaded first on warm start)
"""
import hashlib
import os
import pickle
import re
import sys
import time

from . import headers, ini, specs

CACHE_VERSION = 5
PRUNE = {"thirdparty", "intermediate", "binaries", "content", "saved", "deriveddatacache", "resources",
         "shaders", "documentation", "extras", ".git", ".vs", ".idea", "node_modules", "__pycache__"}
OCC_CAP = 8


def cache_dir():
    d = os.environ.get("UE_LSP_CACHE_DIR")
    if not d:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache")
        d = os.path.join(base, "ue-lsp", "cache")
    os.makedirs(d, exist_ok=True)
    return d


def _h(*parts):
    return hashlib.sha1("|".join(os.path.normcase(os.path.abspath(p)) if p else "" for p in parts).encode()).hexdigest()[:16]


def norm(p):
    return os.path.normpath(p)


# ---------------------------------------------------------------- walking

def walk_scope(roots):
    """roots: list of (dir, in_config). Returns {path: (mtime_ns, size, module, kind)} kind in {'h','ini'}."""
    out = {}
    stack = [(norm(r), None, cfg) for r, cfg in roots if r and os.path.isdir(r)]
    while stack:
        d, mod, cfg = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            n = e.name
            if n.endswith(".Build.cs"):
                mod = n[:-9]
                break
        for e in entries:
            n = e.name
            try:
                if e.is_dir(follow_symlinks=False):
                    ln = n.lower()
                    if ln in PRUNE:
                        continue
                    stack.append((e.path, mod, cfg or ln == "config"))
                    continue
            except OSError:
                continue
            if n.endswith(".h"):
                if mod and not cfg:
                    st = e.stat()
                    out[e.path] = (st.st_mtime_ns, st.st_size, mod, "h")
            elif cfg and n.endswith(".ini"):
                st = e.stat()
                out[e.path] = (st.st_mtime_ns, st.st_size, None, "ini")
    return out


def engine_roots(engine):
    if not engine:
        return []
    e = os.path.join(engine, "Engine")
    return [(os.path.join(e, "Source"), False), (os.path.join(e, "Plugins"), False), (os.path.join(e, "Platforms"), False),
            (os.path.join(e, "Config"), True)]


def project_roots(project_dir):
    if not project_dir:
        return []
    return [(os.path.join(project_dir, "Source"), False), (os.path.join(project_dir, "Plugins"), False),
            (os.path.join(project_dir, "Config"), True)]


# ---------------------------------------------------------------- parsing

def parse_ini_text(text):
    return [e for e in ini.iter_ini(text)]


def _parse_one(path, kind):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if kind == "h":
        try:
            return headers.parse_header(data)
        except Exception:  # never let one odd header kill the index
            return None
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        try:
            text = data.decode("utf-16")
        except UnicodeError:
            text = data.decode("latin-1")
    return parse_ini_text(text)


def _parse_chunk(items):
    return [(p, _parse_one(p, k)) for p, k in items]


def parse_files(items, workers=None):
    """items: list of (path, kind). Uses a process pool for large batches."""
    if len(items) < 400:
        return dict(_parse_chunk(items))
    from concurrent.futures import ProcessPoolExecutor  # lazy: keeps warm start fast
    workers = workers or max(1, min(16, (os.cpu_count() or 2) - 1))
    chunk = max(50, len(items) // (workers * 8))
    chunks = [items[i:i + chunk] for i in range(0, len(items), chunk)]
    out = {}
    with ProcessPoolExecutor(max_workers=workers) as ex:
        for res in ex.map(_parse_chunk, chunks):
            out.update(res)
    return out


def refresh_scope(roots, old, log=None):
    """Walk roots, re-parse new/changed files. Returns (table, changed_count)."""
    t0 = time.perf_counter()
    stats = walk_scope(roots)
    t1 = time.perf_counter()
    table = {}
    todo = []
    for p, (mt, sz, mod, kind) in stats.items():
        o = old.get(p) if old else None
        if o and o[0] == mt and o[1] == sz and o[2] == mod:
            table[p] = o
        else:
            todo.append((p, kind))
    removed = len(old) - (len(stats) - len(todo)) if old else 0
    parsed = parse_files(todo) if todo else {}
    for p, kind in todo:
        mt, sz, mod, _k = stats[p]
        table[p] = (mt, sz, mod, parsed.get(p))
    if log:
        log("walk %d files in %.2fs, parsed %d in %.2fs, removed %d" % (
            len(stats), t1 - t0, len(todo), time.perf_counter() - t1, max(0, removed)))
    return table, len(todo) + max(0, removed)


# ---------------------------------------------------------------- derived index

_IDENT_RE = re.compile(r"\b([EF][A-Z]\w*)\b")


def _ini_sort_key(path, engine, project):
    p = path.lower()
    name = os.path.basename(p)
    if engine and p.startswith(os.path.normcase(engine).lower()):
        scope = 0 if os.sep + "plugins" + os.sep not in p else 1
    else:
        scope = 2 if not (project and os.sep + "plugins" + os.sep in p[len(project):]) else 3
    return (scope, 0 if name.startswith("base") else 1, p.count(os.sep), p)


def build_derived(engine, project_dir, eng_table, proj_table, specdb):
    t0 = time.perf_counter()
    classes = {}
    structs = {}
    enums = {}
    umeta = {}
    ini_files = []
    for table in (eng_table, proj_table):
        for path, (mt, sz, mod, res) in table.items():
            if res is None:
                continue
            if path.endswith(".ini"):
                ini_files.append(path)
                continue
            for c in res["classes"]:
                c["module"] = mod
                c["file"] = path
                for pr in c["props"]:
                    pr["owner"] = c["name"]
                    pr["file"] = path
                classes[c["name"]] = c
            for s in res.get("structs", ()):
                s["file"] = path
                structs[s["name"]] = s
            for e in res["enums"]:
                e["file"] = path
                e["module"] = mod
                enums[e["name"]] = e
            for k, n in res.get("umeta", {}).items():
                umeta[k] = umeta.get(k, 0) + n
    # effective config + props via parent chain
    eff = {}

    def resolve(name, depth=0):
        r = eff.get(name)
        if r is not None:
            return r
        c = classes.get(name)
        if c is None or depth > 64:
            return (None, (), frozenset())
        pcfg, pprops, pflags = resolve(c["parent"], depth + 1) if c.get("parent") else (None, (), frozenset())
        cfg = c["config"] or pcfg
        flags = pflags | frozenset(f for f in c["flags"] if f not in ("abstract", "deprecated"))
        if c["props"]:
            own = {p["name"].lower() for p in c["props"]}
            props = tuple(p for p in pprops if p["name"].lower() not in own) + tuple(c["props"])
        else:
            props = pprops
        r = (cfg, props, flags)
        eff[name] = r
        return r

    config_classes = {}
    config_names = {}
    referenced = set()
    for name, c in classes.items():
        cfg, props, flags = resolve(name)
        if c["config"]:
            config_names[c["config"]] = config_names.get(c["config"], 0) + 1
        if not cfg or not c.get("module"):
            continue
        if not props and not c["config"]:
            continue
        section = c.get("section_override") or "/Script/%s.%s" % (c["module"], name[1:])
        config_classes[section.lower()] = {
            "section": section, "class": name, "parent": c["parent"], "module": c["module"],
            "file": c["file"], "line": c["line"], "config": cfg, "flags": sorted(flags),
            "doc": c["doc"], "display": c["display"], "props": props, "own_config": bool(c["config"]),
            "own_props": len(c["props"]),
        }
        for p in props:
            if p.get("type"):
                referenced.update(_IDENT_RE.findall(p["type"]))
    # referenced structs/enums, 3 levels deep
    keep_structs = {}
    keep_enums = {}
    frontier = set(referenced)
    for _ in range(3):
        nxt = set()
        for ident in frontier:
            if ident in enums and ident not in keep_enums:
                keep_enums[ident] = enums[ident]
            s = structs.get(ident)
            if s is not None and ident not in keep_structs:
                keep_structs[ident] = s
                for p in s["props"]:
                    if p.get("type"):
                        nxt.update(_IDENT_RE.findall(p["type"]))
        frontier = nxt
    # ini aggregation
    ini_files.sort(key=lambda p: _ini_sort_key(p, engine, project_dir))
    sections = {}
    for path in ini_files:
        table = eng_table if path in eng_table else proj_table
        for ent in table[path][3]:
            if ent[0] == "section":
                sname = ent[1]
                s = sections.get(sname.lower())
                if s is None:
                    s = sections[sname.lower()] = {"name": sname, "keys": {}, "occ": []}
                if len(s["occ"]) < OCC_CAP:
                    s["occ"].append((path, ent[2]))
                continue
            _k, sname, key, op, value, line = ent
            s = sections.get(sname.lower())
            if s is None:
                s = sections[sname.lower()] = {"name": sname, "keys": {}, "occ": []}
            key = ini.strip_key(key)
            lk = key.lower()
            k = s["keys"].get(lk)
            if k is None:
                k = s["keys"][lk] = {"name": key, "occ": [], "n": 0}
            k["n"] += 1
            if len(k["occ"]) < OCC_CAP:
                k["occ"].append((path, line, op, value[:240]))
    d = {
        "version": CACHE_VERSION,
        "engine": engine,
        "project": project_dir,
        "config_classes": config_classes,
        "class_names": {n.lower(): (c.get("module"), c["file"], c["line"]) for n, c in classes.items()},
        "structs": keep_structs,
        "enums": keep_enums,
        "sections": sections,
        "config_names": config_names,
        "umeta": umeta,
        "specs": specdb,
        "built": time.time(),
    }
    d["build_seconds"] = time.perf_counter() - t0
    return d


# ---------------------------------------------------------------- cache io

def _load(path):
    try:
        with open(path, "rb") as f:
            d = pickle.load(f)
        if isinstance(d, dict) and d.get("version") == CACHE_VERSION:
            return d
    except Exception:
        pass
    return None


def _save(path, obj):
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "wb") as f:
        pickle.dump(obj, f, protocol=pickle.HIGHEST_PROTOCOL)
    os.replace(tmp, path)


def derived_path(engine, project_dir):
    return os.path.join(cache_dir(), "derived-%s.pickle" % _h(engine, project_dir))


def files_path(root):
    return os.path.join(cache_dir(), "files-%s.pickle" % _h(root))


def load_derived(engine, project_dir):
    return _load(derived_path(engine, project_dir))


class Indexer:
    """Owns the per-scope file tables; produces derived indexes."""

    def __init__(self, engine, project_dir, log=None):
        self.engine = norm(engine) if engine else None
        self.project = norm(project_dir) if project_dir else None
        self.log = log or (lambda m: None)
        self.eng_table = None
        self.proj_table = None
        self.specdb = None

    def _load_tables(self):
        if self.eng_table is None:
            d = _load(files_path(self.engine)) if self.engine else None
            self.eng_table = d["table"] if d else {}
            self._eng_loaded = bool(d)
        if self.proj_table is None:
            d = _load(files_path(self.project)) if self.project else None
            self.proj_table = d["table"] if d else {}

    def refresh(self, engine_too=True):
        """Full validation: walk, reparse changes, rebuild derived if needed. Returns (derived or None, stats)."""
        t0 = time.perf_counter()
        self._load_tables()
        tl = time.perf_counter()
        changed = 0
        if engine_too and self.engine:
            self.eng_table, n = refresh_scope(engine_roots(self.engine), self.eng_table, self.log)
            if n:
                _save(files_path(self.engine), {"version": CACHE_VERSION, "table": self.eng_table})
            changed += n
        if self.project:
            self.proj_table, n = refresh_scope(project_roots(self.project), self.proj_table, self.log)
            if n:
                _save(files_path(self.project), {"version": CACHE_VERSION, "table": self.proj_table})
            changed += n
        dpath = derived_path(self.engine, self.project)
        stats = {"load_tables": tl - t0, "changed": changed}
        d = self.rebuild_derived() if changed or not os.path.exists(dpath) else None
        self.release()
        stats["total"] = time.perf_counter() - t0
        return d, stats

    def release(self):
        """Drop the engine file table: only a derived-index rebuild reads it, and it is the bulk of this
        process (UE 5.6: 38k headers, ~60 MB of objects); reloading its pickle takes ~0.1 s."""
        self.eng_table = None

    def rebuild_derived(self):
        if self.specdb is None:
            self.specdb = specs.build_spec_db(self.engine) if self.engine else {
                "macros": {}, "meta": {}, "parents": {}, "mismatches": []}
        d = build_derived(self.engine, self.project, self.eng_table or {}, self.proj_table or {}, self.specdb)
        _save(derived_path(self.engine, self.project), d)
        self.log("derived index built in %.2fs" % d["build_seconds"])
        return d

    def update_project_file(self, path):
        """Incremental re-scan of one project file (didSave / didChangeWatchedFiles)."""
        self._load_tables()
        p = norm(path)
        if not self.project or not os.path.normcase(p).startswith(os.path.normcase(self.project)):
            return None
        kind = "ini" if p.lower().endswith(".ini") else ("h" if p.endswith(".h") else None)
        if kind is None:
            return None
        if not os.path.exists(p):
            if self.proj_table.pop(p, None) is None:
                return None
        else:
            old = self.proj_table.get(p)
            mod = old[2] if old else _module_for(p)
            if kind == "h" and not mod:
                return None
            if kind == "ini" and os.sep + "config" + os.sep not in os.path.normcase(p).lower():
                return None
            st = os.stat(p)
            self.proj_table[p] = (st.st_mtime_ns, st.st_size, mod if kind == "h" else None, _parse_one(p, kind))
        _save(files_path(self.project), {"version": CACHE_VERSION, "table": self.proj_table})
        d = self.rebuild_derived()
        self.release()
        return d


def _module_for(path):
    d = os.path.dirname(path)
    while True:
        try:
            for n in os.listdir(d):
                if n.endswith(".Build.cs"):
                    return n[:-9]
        except OSError:
            return None
        nd = os.path.dirname(d)
        if nd == d:
            return None
        d = nd
