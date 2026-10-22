"""Project-wide index of authored property values in Blueprint / data assets (no editor needed).

    idx = BPIndex(project_dir, cache_dir=None, engine=None, include_actors=False)
    idx.build(workers=None, log=None)            -> stats dict (also idx.stats())
    idx.overrides_for("AMyActor", "Speed")       -> [Override, ...]   declared-owner lookup
    idx.overrides_in_asset(path_or_game_path)    -> [Override, ...]
    idx.stats()                                  -> dict

What counts as an authored value (read from tagged-property export data):
  * Blueprint CDO (Default__X_C): delta-serialized against the parent CDO, so what is present is the override set;
  * component templates (X_C:Name_GEN_VARIABLE), `kind` "component" (own SCS node) or "component-override"
    (inherited component, i.e. an InheritableComponentHandler record);
  * plain asset instances of project C++ classes, UDataAsset descendants and BP-defined classes (kind "asset");
  * with include_actors: actor instances inside .umap / __ExternalActors__ packages (kind "actor").
Attribution: the object's class is walked up the BP chain to the first /Script class; the property is assigned to
the nearest declaring class (UPROPERTY scan of that header, using the ue-lsp class index) or to the BP that
declares it (Blueprint.NewVariables), else it is filed under the first native class with `owner_note="unresolved"`.
"""
import hashlib
import os
import pickle
import re
import time
from collections import namedtuple

from . import headers, uasset

CACHE_VERSION = 4
Override = namedtuple("Override", "asset object kind value type prop owner owner_note cls")
# asset: /Game package path; object: CDO class name / component variable / asset name / actor name;
# kind: cdo|component|component-override|asset|actor; value: display string; cls: object's class path


def default_cache_dir():
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache")
    return os.path.join(base, "ue-lsp", "cache")


def _h(*parts):
    return hashlib.sha1("|".join(os.path.normcase(os.path.abspath(p)) if p else "" for p in parts).encode()).hexdigest()[:16]


# ------------------------------------------------------------------------------------------ per-asset extraction

_COMPILER_PROPS = {"UberGraphFrame", "bHasScriptImplementedTick", "bHasScriptImplementedPaint"}  # set by BP compile, not authored


def _props_out(res, only=None):
    out = []
    for p in res.props:
        if p.name in _COMPILER_PROPS:
            continue
        v = p.value
        bad = isinstance(v, uasset.Unparsed)
        out.append((p.name, p.index, p.type, uasset.display(v)[:4000], bad))
    return out


def _is_bpgc(cls_path):
    return cls_path.endswith("BlueprintGeneratedClass")


def _is_bp(cls_path):
    return cls_path.endswith("Blueprint") and cls_path.startswith("/Script/")


def extract_asset(path, keep_modules=frozenset(), da_paths=frozenset(), want_actors=False):
    """Extract the record for one package. Never raises."""
    rec = {"pkg": "", "status": "failed", "reason": None, "warn": 0, "bp_classes": [], "bp_vars": {}, "objects": [],
           "warn_samples": []}
    try:
        pkg = uasset.open_package(path)
        rec["pkg"] = pkg.package_name
        if pkg.unsupported:
            rec["status"] = "unsupported"
            rec["reason"] = pkg.unsupported
            return rec
        if pkg.error:
            rec["reason"] = pkg.error
            return rec
        ex = pkg.exports
        cls_paths = [pkg.object_path(e.class_index) for e in ex]
        bpgc = {i for i, c in enumerate(cls_paths) if _is_bpgc(c)}
        warns = []

        def get(i):
            r = pkg.export_props(i)
            if r.warnings or not r.complete:
                warns.extend(r.warnings or ["incomplete tag stream in " + ex[i].name])
            return r

        scs_templates = set()
        for i in bpgc:
            rec["bp_classes"].append((pkg.export_path(i), pkg.object_path(ex[i].super_index)))
        if bpgc:
            for i, e in enumerate(ex):
                c = cls_paths[i]
                if c == "/Script/Engine.SCS_Node":
                    r = pkg.export_props(i)
                    for p in r.props:
                        if p.name == "ComponentTemplate" and p.value:
                            scs_templates.add(str(p.value))
                elif _is_bp(c) and e.outer_index == 0:
                    r = get(i)
                    names = []
                    for p in r.props:
                        if p.name == "NewVariables" and isinstance(p.value, list):
                            for s in p.value:
                                if isinstance(s, uasset.Struct) and "VarName" in s:
                                    names.append(str(s["VarName"]))
                    if bpgc:
                        for gi in bpgc:
                            rec["bp_vars"][pkg.export_path(gi)] = names
        for i, e in enumerate(ex):
            c = cls_paths[i]
            if e.serial_size <= 0:
                continue
            if bpgc:
                if e.name.startswith("Default__") and e.class_index > 0 and (e.class_index - 1) in bpgc:
                    r = get(i)
                    rec["objects"].append(("cdo", pkg.export_path(e.class_index - 1).rsplit(".", 1)[-1], c, _props_out(r)))
                elif e.name.endswith("_GEN_VARIABLE") and e.outer_index > 0 and (e.outer_index - 1) in bpgc:
                    r = get(i)
                    kind = "component" if pkg.export_path(i) in scs_templates else "component-override"
                    rec["objects"].append((kind, e.name[:-len("_GEN_VARIABLE")], c, _props_out(r)))
                continue
            # non-Blueprint package
            if e.outer_index == 0 and e.is_asset and not _is_bp(c) and not _is_bpgc(c):
                keep = (not c.startswith("/Script/") and c != "") or (c.startswith("/Script/") and (
                    c.split(".", 1)[0][len("/Script/"):] in keep_modules or c in da_paths))
                if keep:
                    r = get(i)
                    rec["objects"].append(("asset", e.name, c, _props_out(r)))
            elif want_actors and e.outer_index != 0 and not c.startswith("/Script/Engine.") and c:
                # actor instances placed in a level: class is a project native class or a BP class
                modname = c.split(".", 1)[0][len("/Script/"):] if c.startswith("/Script/") else None
                if (modname is None and not e.name.startswith("Default__")) or (modname in keep_modules):
                    outer = ex[e.outer_index - 1] if e.outer_index > 0 else None
                    if outer is not None and pkg.object_path(outer.class_index).endswith(("/Script/Engine.Level", "/Script/Engine.World", "/Script/Engine.PersistentLevel")):
                        r = get(i)
                        rec["objects"].append(("actor", e.name, c, _props_out(r)))
            elif want_actors and e.outer_index == 0 and e.is_asset is False and c and not c.startswith("/Script/Engine."):
                pass
        rec["warn"] = len(warns)
        rec["warn_samples"] = warns[:3]
        rec["status"] = "ok" if not warns else "partial"
    except Exception as ex_:  # never let one asset kill the scan
        rec["status"] = "failed"
        rec["reason"] = "%s: %s" % (type(ex_).__name__, ex_)
    return rec


def _scan_chunk(args):
    paths, keep_modules, da_paths, want_actors = args
    return [(p, extract_asset(p, keep_modules, da_paths, want_actors)) for p in paths]


# ------------------------------------------------------------------------------------------ native owners

class NativeOwners:
    """Maps (native /Script class, property) -> declaring C++ class using the ue-lsp class index + header scan."""

    def __init__(self, classes, store=None):
        self.classes = classes or {}
        self.store = store if store is not None else {}   # class name -> (file, mtime, size, frozenset)
        self.dirty = False
        self._by_leaf = {}
        for n, c in self.classes.items():
            if len(n) > 1 and n[0] in "AUF" and n[1].isupper():
                self._by_leaf.setdefault(n[1:], []).append(n)

    def cpp_name(self, script_path):
        """'/Script/Engine.StaticMeshComponent' -> 'UStaticMeshComponent' (or None)."""
        if not script_path.startswith("/Script/") or "." not in script_path:
            return None
        mod, leaf = script_path[len("/Script/"):].split(".", 1)
        cands = self._by_leaf.get(leaf, [])
        for n in cands:
            if self.classes[n].get("module") == mod:
                return n
        return cands[0] if cands else None

    def chain(self, name):
        out = []
        seen = set()
        while name and name in self.classes and name not in seen:
            seen.add(name)
            out.append(name)
            name = self.classes[name].get("parent")
        return out

    def declared(self, name):
        c = self.classes.get(name)
        if not c:
            return frozenset()
        f = c.get("file")
        try:
            st = os.stat(f)
        except OSError:
            return frozenset()
        hit = self.store.get(name)
        if hit and hit[0] == f and hit[1] == st.st_mtime_ns and hit[2] == st.st_size:
            return hit[3]
        names = set()
        try:
            with open(f, "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
            names = _scan_class_props(text, name)
        except OSError:
            pass
        fs = frozenset(names)
        self.store[name] = (f, st.st_mtime_ns, st.st_size, fs)
        self.dirty = True
        return fs

    def owner_of(self, script_path, prop):
        """Declaring C++ class name for prop on a native class, or None."""
        n = self.cpp_name(script_path)
        if n is None:
            return None, None
        for cn in self.chain(n):
            if prop in self.declared(cn):
                return cn, n
        return None, n


_CLASS_BODY_CACHE_RE = {}


def _scan_class_props(text, name):
    m = re.search(r"\b(?:class|struct)\s+(?:[A-Z0-9_]+_API\s+)?" + re.escape(name) + r"\b[^;{]*\{", text)
    if not m:
        return set()
    end = headers._find_brace_end(text, m.end())
    body = text[m.end():end if end > 0 else len(text)]
    out = set()
    for pm in re.finditer(r"\bUPROPERTY\s*\(", body):
        close = headers.balanced(body, pm.end())
        if close < 0:
            continue
        _t, n = headers._parse_prop_decl(body, close + 1)
        if n:
            out.add(n)
    return out


# ------------------------------------------------------------------------------------------ index

class BPIndex:
    def __init__(self, project_dir, cache_dir=None, engine=None, include_actors=False, classes=None):
        self.project = os.path.abspath(project_dir)
        self.cache_dir = os.path.join(cache_dir or default_cache_dir(), "bp")
        self.engine = engine
        self.include_actors = include_actors
        self._classes = classes
        self._records = {}       # file path -> record, while attributing
        self._sig = None         # (classes/settings signature, asset files signature) it was built from
        self._by_owner = {}      # (owner, prop) -> [Override]
        self._by_asset = {}      # pkg path / normcase file path -> [Override]
        self._stats = {}
        self._bp_super = {}

    # ---- helpers
    def _content_roots(self):
        roots = [os.path.join(self.project, "Content")]
        pl = os.path.join(self.project, "Plugins")
        if os.path.isdir(pl):
            for dp, dn, fn in os.walk(pl):
                if "Content" in dn:
                    roots.append(os.path.join(dp, "Content"))
                dn[:] = [d for d in dn if d.lower() not in ("source", "binaries", "intermediate", "content", ".git")]
        return [r for r in roots if os.path.isdir(r)]

    def _walk(self):
        out = {}
        stack = self._content_roots()
        while stack:
            d = stack.pop()
            try:
                it = list(os.scandir(d))
            except OSError:
                continue
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    elif e.name.endswith((".uasset", ".umap")):
                        st = e.stat()
                        out[os.path.normpath(e.path)] = (st.st_size, st.st_mtime_ns)
                except OSError:
                    continue
        return out

    def _load_classes(self):
        if self._classes is not None:
            return self._classes
        classes = {}
        try:
            from . import index as idx
            eng = self.engine
            if not eng:
                from . import engine as eng_mod
                up = eng_mod.find_uproject(self.project)
                eng = eng_mod.resolve_engine(up, None)[0] if up else None
            for root in (eng, self.project):
                if not root:
                    continue
                d = idx._load(idx.files_path(idx.norm(root)))
                for path, (mt, sz, mod, res) in (d["table"].items() if d else ()):
                    if not res or not path.endswith(".h"):
                        continue
                    for c in res["classes"]:
                        classes[c["name"]] = {"name": c["name"], "parent": c.get("parent"), "module": mod,
                                              "file": path, "line": c["line"]}
        except Exception:
            classes = {}
        self._classes = classes
        return self._classes

    # ---- build
    def build(self, workers=None, log=None, prev=None):
        """Scan changed assets and attribute their values. `prev`: the index this one replaces; when it was
        built from the same classes and no asset changed since, its tables are shared instead of rebuilt."""
        t0 = time.perf_counter()
        log = log or (lambda m: None)
        os.makedirs(self.cache_dir, exist_ok=True)
        classes = self._load_classes()
        owners_path = os.path.join(self.cache_dir, "owners-%s.pickle" % _h(self.project))
        store = {}
        try:
            with open(owners_path, "rb") as f:
                d = pickle.load(f)
            if d.get("version") == CACHE_VERSION:
                store = d["store"]
        except Exception:
            pass
        self.owners = NativeOwners(classes, store)
        proj_src = os.path.normcase(os.path.join(self.project, ""))
        keep_modules = set()
        for n, c in classes.items():
            f = c.get("file", "")
            if os.path.normcase(f).startswith(proj_src) and c.get("module"):
                keep_modules.add(c["module"])
        da_paths = set()
        for n, c in classes.items():
            if "UDataAsset" in self.owners.chain(n)[1:] or n in ("UDataAsset",):
                if c.get("module"):
                    da_paths.add("/Script/%s.%s" % (c["module"], n[1:]))
        sig = hashlib.sha1(repr((CACHE_VERSION, sorted(keep_modules), sorted(da_paths), self.include_actors)).encode()).hexdigest()
        files = self._walk()
        t_walk = time.perf_counter()
        fsig = hash(frozenset(files.items()))
        self._sig = (sig, fsig)
        if prev is not None and prev._classes is classes and getattr(prev, "_sig", None) == self._sig:
            self.owners, self._by_owner, self._by_asset, self._bp_super = (
                prev.owners, prev._by_owner, prev._by_asset, prev._bp_super)
            self._stats = st = dict(prev._stats)
            st["rescanned"] = 0
            st["seconds_total"] = st["seconds_walk"] = t_walk - t0
            st["seconds_scan"] = st["seconds_attribute"] = 0.0
            return self.stats()
        cpath = os.path.join(self.cache_dir, "assets-%s.pickle" % _h(self.project))
        old = {}
        try:
            with open(cpath, "rb") as f:
                d = pickle.load(f)
            if d.get("version") == CACHE_VERSION and d.get("sig") == sig:
                old = d["table"]
        except Exception:
            pass
        todo = [p for p, (sz, mt) in files.items() if p not in old or old[p][0] != sz or old[p][1] != mt]
        table = {p: old[p] for p in files if p in old and p not in set(todo)} if todo else {p: old[p] for p in files if p in old}
        if todo:
            todo.sort()
            args = (frozenset(keep_modules), frozenset(da_paths), self.include_actors)
            results = []
            if len(todo) < 200:
                results = _scan_chunk((todo,) + args)
            else:
                from concurrent.futures import ProcessPoolExecutor
                workers = workers or max(1, min(16, (os.cpu_count() or 2) - 1))
                chunk = max(20, len(todo) // (workers * 12))
                chunks = [(todo[i:i + chunk],) + args for i in range(0, len(todo), chunk)]
                with ProcessPoolExecutor(max_workers=workers) as ex:
                    for res in ex.map(_scan_chunk, chunks):
                        results.extend(res)
            for p, rec in results:
                table[p] = (files[p][0], files[p][1], rec)
            tmp = cpath + ".tmp%d" % os.getpid()
            with open(tmp, "wb") as f:
                pickle.dump({"version": CACHE_VERSION, "sig": sig, "table": table}, f, protocol=pickle.HIGHEST_PROTOCOL)
            os.replace(tmp, cpath)
        t_scan = time.perf_counter()
        self._records = {p: v[2] for p, v in table.items()}
        del table, old
        self._attribute()
        self._records = {}  # the asset records live on in the Override rows; only attribution reads them
        if self.owners.dirty:
            tmp = owners_path + ".tmp%d" % os.getpid()
            with open(tmp, "wb") as f:
                pickle.dump({"version": CACHE_VERSION, "store": self.owners.store}, f)
            os.replace(tmp, owners_path)
        t1 = time.perf_counter()
        st = self._stats
        st["files"] = len(files)
        st["rescanned"] = len(todo)
        st["seconds_total"] = t1 - t0
        st["seconds_walk"] = t_walk - t0
        st["seconds_scan"] = t_scan - t_walk
        st["seconds_attribute"] = t1 - t_scan
        return self.stats()

    def _attribute(self):
        recs = self._records
        # BP class -> super class
        bp_super = {}
        bp_vars = {}
        for r in recs.values():
            for c, s in r["bp_classes"]:
                bp_super[c] = s
            bp_vars.update(r["bp_vars"])
        self._bp_super = bp_super
        by_owner = {}
        by_asset = {}
        status = {}
        reasons = {}
        n_obj = n_props = 0
        unresolved = set()
        kinds = {}
        owners = self.owners
        memo = {}
        for path, r in recs.items():
            status[r["status"]] = status.get(r["status"], 0) + 1
            if r["status"] in ("failed", "unsupported"):
                k = (r["reason"] or "?")
                k = re.sub(r"\d+", "N", k)[:100]
                reasons[k] = reasons.get(k, 0) + 1
                continue
            for kind, label, cls, props in r["objects"]:
                n_obj += 1
                kinds[kind] = kinds.get(kind, 0) + 1
                # resolve class chain: BP classes until /Script
                bps = []
                c = cls
                guard = 0
                while c and not c.startswith("/Script/") and guard < 64:
                    bps.append(c)
                    c = bp_super.get(c, "")
                    guard += 1
                native = c if c.startswith("/Script/") else None
                if native is None:
                    unresolved.add(cls)
                for (pname, pidx, ptype, disp, bad) in props:
                    n_props += 1
                    key = (cls, pname)
                    own = memo.get(key)
                    if own is None:
                        own = None
                        for b in bps:
                            if pname in bp_vars.get(b, ()):
                                own = ("BP:" + b, "bp-variable")
                                break
                        if own is None and native:
                            decl, first = owners.owner_of(native, pname)
                            if decl:
                                own = (decl, None)
                            else:
                                own = (first or native, "unresolved")
                        if own is None:
                            own = (cls, "unresolved")
                        memo[key] = own
                    o = Override(r["pkg"], label, kind, disp, ptype, pname if pidx == 0 else "%s[%d]" % (pname, pidx),
                                 own[0], own[1], cls)
                    by_owner.setdefault((own[0], pname), []).append(o)
                    by_asset.setdefault(r["pkg"], []).append(o)
                    by_asset.setdefault(os.path.normcase(path), []).append(o)
        self._by_owner = by_owner
        self._by_asset = by_asset
        st = self._stats
        st["status"] = status
        st["failure_reasons"] = dict(sorted(reasons.items(), key=lambda kv: -kv[1]))
        st["objects"] = n_obj
        st["properties"] = n_props
        st["object_kinds"] = kinds
        st["unresolved_classes"] = len(unresolved)
        st["bp_classes"] = len(bp_super)
        warn = {}
        for r in recs.values():
            for w in r.get("warn_samples", ()):
                k = re.sub(r"\d+", "N", w)[:120]
                warn[k] = warn.get(k, 0) + 1
        st["warning_samples"] = dict(sorted(warn.items(), key=lambda kv: -kv[1])[:15])

    # ---- queries
    def _norm_class(self, name):
        if name.startswith("BP:"):
            return [name]
        out = [name]
        if len(name) > 1 and not (name[0] in "AUF" and name[1].isupper()):
            out += ["A" + name, "U" + name, "F" + name]
        return out

    def overrides_for(self, cpp_class, prop):
        """All authored values of `prop` declared by `cpp_class` (accepts 'AFoo' or 'Foo'; 'BP:/Game/X.X_C' for BP vars)."""
        out = []
        for n in self._norm_class(cpp_class):
            out.extend(self._by_owner.get((n, prop), ()))
        return out

    def overrides_in_asset(self, path):
        """Authored values in one asset: accepts a /Game package path or a file path."""
        if path.startswith("/Game/") or path.startswith("/") and ":" not in path and not os.path.exists(path):
            return list(self._by_asset.get(path, ()))
        return list(self._by_asset.get(os.path.normcase(os.path.normpath(path)), ()))

    def classes_with_overrides(self):
        """[(owner, prop_count, value_count)] sorted by value_count desc."""
        agg = {}
        for (o, p), v in self._by_owner.items():
            a = agg.setdefault(o, [set(), 0])
            a[0].add(p)
            a[1] += len(v)
        return sorted(((o, len(a[0]), a[1]) for o, a in agg.items()), key=lambda t: -t[2])

    def stats(self):
        return dict(self._stats)
