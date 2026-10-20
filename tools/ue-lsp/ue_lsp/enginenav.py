"""Go-to-implementation for out-of-line C++ definitions (engine and project modules).

clangd only knows definitions that live in indexed TUs. Engine modules are precompiled in an installed
build, so their .cpp files are never indexed. Given a declaration (file + name + container from clangd's
symbolInfo), this finds the definition by scanning the owning module's .cpp/.inl files.

Per module, a definition table {"Container::Name": [(file, line0, col, nparams)]} is built lazily on the
first query and cached on disk (keyed by file list + sizes + mtimes).
"""
import hashlib
import os
import pickle
import re
import threading
import time

CACHE_VERSION = 2
SRC_EXT = (".cpp", ".inl", ".cc", ".cxx")
SKIP_DIRS = {"thirdparty", "intermediate", "binaries", ".git"}

# Anchored on the literal '::' (fast literal scan); the container chain is recovered from the line prefix.
_TAIL_RE = re.compile(rb"::[ \t]*(~?\w+|operator[ \t]*[^\s(]+)[ \t]*\(")
_CHAIN_RE = re.compile(rb"((?:\w+(?:<[^<>;{}()]*>)?[ \t]*::[ \t]*)*\w+(?:<[^<>;{}()]*>)?)[ \t]*$")
_QUALIFIER_RE = re.compile(rb"\s*(?:const|noexcept(?:\s*\([^)]*\))?|override|final|volatile|&&|&|"
                           rb"->\s*[\w:<>,\s\*&]+?(?=\s*[{:])|UE_LIFETIMEBOUND|\[\[[^\]]*\]\])")


def norm(p):
    return os.path.normcase(os.path.normpath(p))


def module_root(path, stop=None):
    """Nearest ancestor directory holding a *.Build.cs file (the UBT module), or None."""
    d = os.path.dirname(os.path.abspath(path))
    stop = norm(stop) if stop else None
    while True:
        try:
            for n in os.listdir(d):
                if n.endswith(".Build.cs"):
                    return d
        except OSError:
            pass
        if stop and norm(d) == stop:
            return None
        nd = os.path.dirname(d)
        if nd == d:
            return None
        d = nd


def _balanced(data, i):
    """data[i] is just after '('. Returns index of matching ')' or -1."""
    depth = 1
    n = len(data)
    while i < n:
        c = data[i]
        if c == 40:      # (
            depth += 1
        elif c == 41:    # )
            depth -= 1
            if depth == 0:
                return i
        elif c == 59 or c == 123:   # ; {  -> not a parameter list
            return -1
        i += 1
    return -1


def count_params(params):
    s = params.strip()
    if not s or s == b"void":
        return 0
    depth = 0
    n = 1
    for c in s:
        if c in b"(<[{":
            depth += 1
        elif c in b")>]}":
            depth -= 1
        elif c == 44 and depth == 0:   # ,
            n += 1
    return n


def _is_definition(data, close):
    """After the closing ')' of a parameter list: definition if followed by '{' or a ctor-init ':'."""
    j = close + 1
    n = len(data)
    while j < n:
        m = _QUALIFIER_RE.match(data, j)
        if m and m.end() > j:
            j = m.end()
            continue
        break
    while j < n and data[j] in b" \t\r\n":
        j += 1
    if j >= n:
        return False
    c = data[j]
    if c == 123:   # {
        return True
    if c == 58 and not (j + 1 < n and data[j + 1] == 58):   # ':' but not '::'
        return True
    return False


def _line_col(data, pos, starts):
    # starts: sorted list of line start offsets
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= pos:
            lo = mid
        else:
            hi = mid - 1
    return lo, pos - starts[lo]


def _strip_templates(qual):
    return re.sub(rb"<[^<>]*>", b"", qual)


def scan_file(data):
    """[(qualified_name, line0, col, nparams)] for out-of-line definitions in a source buffer."""
    out = []
    last_pos = 0
    last_line = 0
    for m in _TAIL_RE.finditer(data):
        # Out-of-line definitions sit at namespace scope: their line is indented at most one level.
        # Calls inside function bodies are deeper, so drop them before the (Python-speed) paren walk.
        ls = data.rfind(b"\n", 0, m.start()) + 1
        ind = 0
        while ls + ind < m.start() and data[ls + ind] in b" \t":
            ind += 1
        if ind and (data[ls + ind - 1] == 32 and ind > 4 or data[ls + ind - 1] == 9 and ind > 1):
            continue
        cm = _CHAIN_RE.search(data, max(ls, m.start() - 300), m.start())
        if not cm:
            continue
        # a call through an object ('x.A::f(' / 'p->A::f(') or member access is not a definition
        k = cm.start() - 1
        while k >= ls and data[k] in b" \t":
            k -= 1
        if k >= ls and (data[k] == 46 or (data[k] == 62 and data[k - 1] == 45) or data[k] == 58):
            continue   # 'x.A::f(' / 'p->A::f(' / '::A::f(' handled by the chain; '>' of a return type is fine
        close = _balanced(data, m.end())
        if close < 0 or not _is_definition(data, close):
            continue
        qual = re.sub(rb"\s+", b"", _strip_templates(cm.group(1))) + b"::"
        name = re.sub(rb"\s+", b"", m.group(1))
        pos = m.start(1)
        last_line += data.count(b"\n", last_pos, pos)
        last_pos = pos
        line0 = last_line
        col = pos - (data.rfind(b"\n", 0, pos) + 1)
        out.append(((qual + name).decode("utf-8", "replace"), line0, col, count_params(data[m.end():close])))
    return out


def _iter_sources(root):
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            it = list(os.scandir(d))
        except OSError:
            continue
        for e in it:
            try:
                if e.is_dir(follow_symlinks=False):
                    if e.name.lower() not in SKIP_DIRS:
                        stack.append(e.path)
                elif e.name.lower().endswith(SRC_EXT):
                    st = e.stat()
                    yield e.path, st.st_size, st.st_mtime_ns
            except OSError:
                continue


class ImplFinder:
    def __init__(self, cache_dir, log=None):
        self.cache_dir = os.path.join(cache_dir, "impl")
        self.log = log or (lambda m: None)
        self.mem = {}           # module root (normcase) -> (sig, table)
        self.lock = threading.Lock()
        self.locks = {}

    def _cache_path(self, root):
        return os.path.join(self.cache_dir, hashlib.sha1(norm(root).encode()).hexdigest()[:16] + ".pickle")

    def table(self, root):
        key = norm(root)
        with self.lock:
            lk = self.locks.setdefault(key, threading.Lock())
        with lk:
            t0 = time.perf_counter()
            files = sorted(_iter_sources(root))
            sig = hashlib.sha1(repr([(norm(p), s, m) for p, s, m in files]).encode()).hexdigest()
            hit = self.mem.get(key)
            if hit and hit[0] == sig:
                return hit[1]
            cp = self._cache_path(root)
            old_files = {}
            try:
                with open(cp, "rb") as f:
                    d = pickle.load(f)
                if d.get("version") == CACHE_VERSION:
                    if d.get("sig") == sig:
                        self.mem[key] = (sig, d["table"])
                        return d["table"]
                    old_files = d.get("files", {})
            except Exception:
                pass
            per_file = {}
            rescanned = 0
            for p, s, m in files:
                o = old_files.get(p)
                if o and o[0] == s and o[1] == m:
                    per_file[p] = o
                    continue
                try:
                    with open(p, "rb") as f:
                        data = f.read()
                except OSError:
                    continue
                per_file[p] = (s, m, scan_file(data))
                rescanned += 1
            table = {}
            for p, (_s, _m, defs) in per_file.items():
                for q, l, c, n in defs:
                    table.setdefault(q, []).append((p, l, c, n))
            try:
                os.makedirs(self.cache_dir, exist_ok=True)
                tmp = cp + ".tmp%d" % os.getpid()
                with open(tmp, "wb") as f:
                    pickle.dump({"version": CACHE_VERSION, "sig": sig, "table": table, "files": per_file}, f,
                                protocol=pickle.HIGHEST_PROTOCOL)
                os.replace(tmp, cp)
            except OSError:
                pass
            self.mem[key] = (sig, table)
            self.log("impl table %s: %d files (%d scanned), %d defs in %.2fs"
                     % (root, len(files), rescanned, len(table), time.perf_counter() - t0))
            return table

    def find(self, decl_path, name, container="", nparams=None, extra_roots=()):
        """Definitions of container::name. container may be 'AActor', 'AActor::', 'UE::Foo::' or ''."""
        container = (container or "").strip().rstrip(":")
        container = re.sub(r"<[^<>]*>", "", container).replace(" ", "")
        name = name.strip()
        if container:
            q = container + "::" + name
        else:
            q = name
        roots = []
        r = module_root(decl_path)
        if r:
            roots.append(r)
        for x in extra_roots:
            if x and norm(x) not in {norm(y) for y in roots}:
                roots.append(x)
        hits = []
        for root in roots:
            tab = self.table(root)
            cands = tab.get(q, [])
            if not cands and container and "::" in container:
                # declared in a namespace but defined as 'Inner::Name' inside a 'namespace Outer {' block
                leaf = container.split("::")[-1] + "::" + name
                cands = tab.get(leaf, [])
            if not cands and not container:
                cands = []
            hits.extend(cands)
            if hits:
                break
        if nparams is not None and len(hits) > 1:
            exact = [h for h in hits if h[3] == nparams]
            if exact:
                hits = exact
        return hits


_DECL_NAME_RE_CACHE = {}


def decl_nparams(text, line0, name):
    """Parameter count of `name(` declared on/after line0 in a header text (None if not found)."""
    lines = text.split("\n")
    chunk = "\n".join(lines[line0:line0 + 12]).encode("utf-8", "replace")
    m = re.search(rb"\b" + re.escape(name.encode()) + rb"\s*\(", chunk)
    if not m:
        return None
    close = _balanced(chunk, m.end())
    if close < 0:
        return None
    return count_params(chunk[m.end():close])
