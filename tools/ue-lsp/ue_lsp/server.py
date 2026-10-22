"""stdio Language Server for Unreal Engine config (.ini) and reflection macros (C++)."""
import json
import os
import queue
import sys
import threading
import time
from urllib.parse import quote, unquote, urlparse

from . import cpp, engine, index, inifeat

SERVER_NAME = "ue-lsp"


def _tb():
    import traceback  # lazy: importing traceback costs ~40ms at startup
    return traceback.format_exc()
VERSION = "0.1.0"


def uri_to_path(uri):
    p = urlparse(uri)
    if p.scheme != "file":
        return None
    path = unquote(p.path)
    if os.name == "nt" and len(path) > 2 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    return os.path.normpath(path)


def _read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except (OSError, TypeError):
        return None


def path_to_uri(path):
    path = os.path.abspath(path).replace("\\", "/")
    if not path.startswith("/"):
        path = "/" + path
    return "file://" + quote(path, safe="/:")


class Document:
    __slots__ = ("uri", "path", "text", "version", "lang", "_lines")

    def __init__(self, uri, text, version, lang):
        self.uri = uri
        self.path = uri_to_path(uri)
        self.text = text
        self.version = version
        self.lang = lang
        self._lines = None

    @property
    def lines(self):
        if self._lines is None:
            self._lines = self.text.split("\n")
        return self._lines

    def set_text(self, text):
        self.text = text
        self._lines = None


class Server:
    def __init__(self, rfile, wfile, log=None):
        self.rfile = rfile
        self.wfile = wfile
        self.wlock = threading.Lock()
        self.queue = queue.Queue()
        self.docs = {}
        self.idx = None
        self.idx_ready = threading.Event()
        self.idx_checked = threading.Event()  # cache validated or index rebuilt (load_index finished)
        self.indexer = None
        self.utf16 = True
        self.snippets = False
        self.opts = {}
        self.shutdown = False
        self.timers = {}
        self.engine = None
        self.project = None
        self.t_start = time.perf_counter()
        self.logf = log
        self.bp = None              # bpvalues.BPIndex once built
        self.bp_lock = threading.Lock()
        self.bp_building = False
        self.bp_built_at = 0.0
        self.bp_idx = None          # header index self.bp's native classes were read with
        self.bp_memo = {}
        self.impl = None            # enginenav.ImplFinder (lazy)
        self.req_id = 0

    # ------------------------------------------------------------ io
    def log(self, msg):
        line = "[ue-lsp %.3fs] %s" % (time.perf_counter() - self.t_start, msg)
        try:
            sys.stderr.write(line + "\n")
            sys.stderr.flush()
        except Exception:
            pass

    def send(self, obj):
        data = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        with self.wlock:
            self.wfile.write(b"Content-Length: %d\r\n\r\n" % len(data))
            self.wfile.write(data)
            self.wfile.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params):
        """Fire-and-forget server->client request (responses are ignored by dispatch)."""
        self.req_id += 1
        self.send({"jsonrpc": "2.0", "id": "ue-lsp-%d" % self.req_id, "method": method, "params": params})

    def reader(self):
        try:
            while True:
                length = None
                while True:
                    line = self.rfile.readline()
                    if not line:
                        self.queue.put(None)
                        return
                    line = line.strip()
                    if not line:
                        break
                    k, _, v = line.partition(b":")
                    if k.strip().lower() == b"content-length":
                        length = int(v.strip())
                if length is None:
                    continue
                body = self.rfile.read(length)
                self.queue.put(json.loads(body.decode("utf-8")))
        except Exception:
            self.queue.put(None)

    def run(self):
        threading.Thread(target=self.reader, daemon=True).start()
        while True:
            msg = self.queue.get()
            if msg is None:
                break
            if callable(msg):
                try:
                    msg()
                except Exception:
                    self.log(_tb())
                continue
            self.dispatch(msg)
            if msg.get("method") == "exit":
                break

    def dispatch(self, msg):
        method = msg.get("method")
        mid = msg.get("id")
        handler = getattr(self, "on_" + (method or "").replace("/", "_").replace("$", "S"), None)
        if method is None:
            return  # response to a server request; ignored
        try:
            result = handler(msg.get("params") or {}) if handler else None
            if mid is not None:
                if handler is None:
                    self.send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unhandled " + method}})
                else:
                    self.send({"jsonrpc": "2.0", "id": mid, "result": result})
        except Exception as e:
            self.log(_tb())
            if mid is not None:
                self.send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}})

    # ------------------------------------------------------------ positions
    def to_idx(self, line_text, ch):
        if not self.utf16:
            return min(ch, len(line_text))
        if line_text.isascii():
            return min(ch, len(line_text))
        n = 0
        for i, c in enumerate(line_text):
            if n >= ch:
                return i
            n += 2 if ord(c) > 0xFFFF else 1
        return len(line_text)

    def to_ch(self, line_text, i):
        if not self.utf16 or line_text.isascii():
            return i
        return sum(2 if ord(c) > 0xFFFF else 1 for c in line_text[:i])

    def pos_in(self, doc, pos):
        line = pos["line"]
        lt = doc.lines[line] if line < len(doc.lines) else ""
        return line, self.to_idx(lt, pos["character"])

    def mk_range(self, doc, line, s, e):
        lt = doc.lines[line] if line < len(doc.lines) else ""
        return {"start": {"line": line, "character": self.to_ch(lt, s)},
                "end": {"line": line, "character": self.to_ch(lt, e)}}

    def offset_of(self, doc, line, col):
        lines = doc.lines
        return sum(len(l) + 1 for l in lines[:line]) + col

    def pos_of_offset(self, doc, off):
        line = doc.text.count("\n", 0, off)
        ls = doc.text.rfind("\n", 0, off) + 1
        return line, off - ls

    # ------------------------------------------------------------ lifecycle
    def on_initialize(self, p):
        self.opts = p.get("initializationOptions") or {}
        caps = p.get("capabilities") or {}
        encs = (caps.get("general") or {}).get("positionEncodings") or []
        self.utf16 = "utf-32" not in encs
        cc = ((caps.get("textDocument") or {}).get("completion") or {}).get("completionItem") or {}
        self.snippets = bool(cc.get("snippetSupport"))
        root = None
        if p.get("rootUri"):
            root = uri_to_path(p["rootUri"])
        elif p.get("rootPath"):
            root = p["rootPath"]
        for wf in p.get("workspaceFolders") or []:
            root = root or uri_to_path(wf["uri"])
        up = engine.find_uproject(root) if root else None
        self.project = os.path.dirname(up) if up else None
        self.engine, how = engine.resolve_engine(up, self.opts.get("enginePath"))
        self.log("project=%s engine=%s (%s)" % (self.project, self.engine, how))
        threading.Thread(target=self.load_index, daemon=True).start()
        lens_caps = (((caps.get("workspace") or {}).get("codeLens") or {}).get("refreshSupport"))
        self.lens_refresh = bool(lens_caps)
        if self.project and self.engine and self.opt("engineCdb", default=True):
            try:
                from . import enginecdb
                up = engine.find_uproject(self.project)
                enginecdb.ensure_async(self.engine, up, log=self.log,
                                       on_done=lambda st, err: self.log("engine cdb: %s" % (err or st or "fresh")))
            except Exception:
                self.log(_tb())
        result = {
            "capabilities": {
                "textDocumentSync": {"openClose": True, "change": 2, "save": {"includeText": False}},
                "completionProvider": {"triggerCharacters": ["[", "=", "(", ",", " ", "."], "resolveProvider": True},
                "hoverProvider": True,
                "definitionProvider": True,
                "codeLensProvider": {"resolveProvider": False},
                "executeCommandProvider": {"commands": ["ue.findImpl", "ue.bpValues", "ue.bpValuesAt"]},
            },
            "serverInfo": {"name": SERVER_NAME, "version": VERSION},
        }
        if not self.utf16:
            result["capabilities"]["positionEncoding"] = "utf-32"
        return result

    def opt(self, *path, default=True):
        cur = self.opts
        for k in path:
            if not isinstance(cur, dict) or k not in cur:
                return default
            cur = cur[k]
        return cur

    def load_index(self):
        try:
            self._load_index()
        finally:
            self.idx_checked.set()

    def _load_index(self):
        t0 = time.perf_counter()
        d = index.load_derived(self.engine and index.norm(self.engine), self.project and index.norm(self.project))
        if d is not None:
            self.idx = d
            self.idx_ready.set()
            self.log("warm index loaded in %.3fs" % (time.perf_counter() - t0))
            self.queue.put(self.republish)
        self.indexer = index.Indexer(self.engine, self.project, log=self.log)
        if d is not None and not self.opt("validateCache", default=True):
            return
        try:
            nd, stats = self.indexer.refresh(engine_too=True)
        except Exception:
            self.log(_tb())
            self.idx_ready.set()
            return
        if nd is not None:
            self.idx = nd
            self.log("index (re)built: %s" % stats)
            self.queue.put(self.republish)
        else:
            self.log("cache validated, no changes (%.2fs)" % stats["total"])
        self.idx_ready.set()

    def wait_index(self):
        if self.idx is None:
            self.idx_ready.wait(timeout=float(self.opt("indexWaitSeconds", default=2.0)))
        return self.idx

    def on_initialized(self, p):
        if self.project and self.opt("blueprints", "enabled", default=True):
            def later():
                # after validation, not the warm load: both read the engine file table, and
                # loading it twice at once leaves ~60 MB more resident in this process
                self.idx_checked.wait(timeout=120)
                self.ensure_bp()
            threading.Thread(target=later, daemon=True).start()
        return None

    # ------------------------------------------------------------ blueprint values
    def ensure_bp(self, max_age=None):
        """(Re)build the Blueprint value index in the background; warm rebuilds only rescan changed assets."""
        if not self.project:
            return
        if max_age is not None and time.perf_counter() - self.bp_built_at < max_age:
            return
        with self.bp_lock:
            if self.bp_building:
                return
            self.bp_building = True

        def work():
            try:
                from . import bpvalues
                t0 = time.perf_counter()
                # native classes come from the header index: reuse the previous build's while that index is
                # unchanged (reading them means loading the engine file table, ~60 MB for a moment)
                prev = self.bp if self.bp is not None and self.bp_idx is self.idx else None
                idx_now = self.idx
                ix = bpvalues.BPIndex(self.project, engine=self.engine, classes=prev and prev._classes)
                st = ix.build(log=self.log, prev=prev)
                self.bp_idx = idx_now
                changed = self.bp is None or ix._by_owner is not self.bp._by_owner
                self.bp = ix
                if changed:
                    self.bp_memo = {}
                self.bp_built_at = time.perf_counter()
                self.log("bp index: %d files, %d rescanned, %d values in %.2fs"
                         % (st.get("files", 0), st.get("rescanned", 0), st.get("properties", 0), time.perf_counter() - t0))
                if changed and self.lens_refresh:
                    self.request("workspace/codeLens/refresh", None)
            except Exception:
                self.log(_tb())
            finally:
                self.bp_building = False
        threading.Thread(target=work, daemon=True).start()

    def bp_rows(self, cls, prop):
        if self.bp is None:
            return []
        k = (cls, prop)
        r = self.bp_memo.get(k)
        if r is None:
            from . import bpfeat
            r = bpfeat.rows(self.bp.overrides_for(cls, prop))
            self.bp_memo[k] = r
        return r

    def on_textDocument_codeLens(self, p):
        doc = self._doc(p)
        if not doc or self.kind_of(doc) != "cpp" or not self.opt("blueprints", "codeLens", default=True):
            return []
        from . import bpfeat
        if not bpfeat.is_header(doc.path):
            return []
        self.ensure_bp(max_age=float(self.opt("blueprints", "refreshSeconds", default=60)))
        if self.bp is None:
            return []
        out = []
        for l, s, e, c, prop, rs in bpfeat.lenses(doc.text, self.bp_rows):
            out.append({"range": self.mk_range(doc, l, s, e),
                        "command": {"title": bpfeat.lens_title(rs), "command": "ue.bpValues",
                                    "arguments": [{"class": c, "prop": prop}]}})
        return out

    def on_workspace_executeCommand(self, p):
        cmd = p.get("command")
        args = (p.get("arguments") or [{}])[0] or {}
        if cmd == "ue.findImpl":
            return self.find_impl(args)
        if cmd == "ue.bpValues":
            return {"class": args.get("class"), "prop": args.get("prop"),
                    "rows": self.bp_rows(args.get("class") or "", args.get("prop") or "")}
        if cmd == "ue.bpValuesAt":
            from . import bpfeat
            path = uri_to_path(args.get("uri") or "")
            doc = self.docs.get(args.get("uri"))
            text = doc.text if doc else _read_text(path)
            hit = bpfeat.decl_at(text or "", int(args.get("line", -1)), 0)
            if not hit:
                return None
            return {"class": hit[0], "prop": hit[1], "rows": self.bp_rows(hit[0], hit[1])}
        return None

    def find_impl(self, a):
        """Out-of-line definition(s) of a declaration: {uri, line, name, container} -> Location[]."""
        from . import enginenav
        if self.impl is None:
            from . import bpvalues
            self.impl = enginenav.ImplFinder(bpvalues.default_cache_dir(), log=self.log)
        path = uri_to_path(a.get("uri") or "")
        name = a.get("name") or ""
        if not path or not name:
            return []
        doc = self.docs.get(a.get("uri"))
        text = doc.text if doc else _read_text(path)
        n = enginenav.decl_nparams(text or "", int(a.get("line", 0)), name) if text else None
        t0 = time.perf_counter()
        hits = self.impl.find(path, name, a.get("container") or "", n)
        self.log("findImpl %s::%s -> %d hit(s) in %.3fs" % (a.get("container"), name, len(hits), time.perf_counter() - t0))
        return [{"uri": path_to_uri(f), "range": {"start": {"line": l, "character": c},
                                                  "end": {"line": l, "character": c + len(name)}}}
                for f, l, c, _n in hits]

    def on_shutdown(self, p):
        self.shutdown = True
        return None

    def on_exit(self, p):
        return None

    # ------------------------------------------------------------ documents
    def kind_of(self, doc):
        lang = (doc.lang or "").lower()
        path = (doc.path or doc.uri).lower()
        if path.endswith(".ini") or lang in ("dosini", "ini"):
            return "ini"
        if lang in ("cpp", "c", "objcpp") or path.endswith((".h", ".hpp", ".cpp", ".inl")):
            return "cpp"
        return None

    def on_textDocument_didOpen(self, p):
        td = p["textDocument"]
        doc = Document(td["uri"], td.get("text", ""), td.get("version"), td.get("languageId"))
        self.docs[td["uri"]] = doc
        self.schedule_diag(doc, 0.0)

    def on_textDocument_didChange(self, p):
        doc = self.docs.get(p["textDocument"]["uri"])
        if not doc:
            return
        for ch in p.get("contentChanges", []):
            if "range" not in ch:
                doc.set_text(ch["text"])
                continue
            r = ch["range"]
            sl, sc = self.pos_in(doc, r["start"])
            el, ec = self.pos_in(doc, r["end"])
            so = self.offset_of(doc, sl, sc)
            eo = self.offset_of(doc, el, ec)
            doc.set_text(doc.text[:so] + ch["text"] + doc.text[eo:])
        doc.version = p["textDocument"].get("version")
        self.schedule_diag(doc, 0.25)

    def on_textDocument_didClose(self, p):
        uri = p["textDocument"]["uri"]
        self.docs.pop(uri, None)
        self.notify("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": []})

    def on_textDocument_didSave(self, p):
        doc = self.docs.get(p["textDocument"]["uri"])
        if doc and doc.path:
            self.rescan(doc.path)

    def on_workspace_didChangeWatchedFiles(self, p):
        for ch in p.get("changes", []):
            path = uri_to_path(ch["uri"])
            if path:
                self.rescan(path)

    def rescan(self, path):
        if not self.indexer or not self.project:
            return

        def work():
            try:
                d = self.indexer.update_project_file(path)
            except Exception:
                self.log(_tb())
                return
            if d is not None:
                self.idx = d
                self.queue.put(self.republish)
        threading.Thread(target=work, daemon=True).start()

    def schedule_diag(self, doc, delay):
        old = self.timers.pop(doc.uri, None)
        if old:
            old.cancel()
        if delay <= 0:
            self.publish(doc)
            return
        t = threading.Timer(delay, lambda: self.queue.put(lambda: self.publish(doc)))
        t.daemon = True
        self.timers[doc.uri] = t
        t.start()

    def republish(self):
        for doc in list(self.docs.values()):
            self.publish(doc)

    def publish(self, doc):
        if self.docs.get(doc.uri) is not doc or self.idx is None:
            return
        k = self.kind_of(doc)
        diags = []
        if k == "ini" and self.opt("ini", "diagnostics", default=True):
            for line, s, e, sev, msg in inifeat.diagnostics(self.idx, doc.text, doc.path):
                diags.append({"range": self.mk_range(doc, line, s, e), "severity": sev, "source": SERVER_NAME,
                              "message": msg})
        elif k == "cpp" and self.opt("cpp", "diagnostics", default=True):
            for s, e, msg in cpp.diagnostics(doc.text, self.idx["specs"]):
                line, col = self.pos_of_offset(doc, s)
                diags.append({"range": self.mk_range(doc, line, col, col + (e - s)), "severity": 2,
                              "source": SERVER_NAME, "message": msg})
        self.notify("textDocument/publishDiagnostics", {"uri": doc.uri, "version": doc.version, "diagnostics": diags})

    # ------------------------------------------------------------ features
    def _doc(self, p):
        return self.docs.get(p["textDocument"]["uri"])

    def on_textDocument_completion(self, p):
        doc = self._doc(p)
        if not doc:
            return None
        k = self.kind_of(doc)
        idx = self.wait_index()
        if idx is None:
            return {"isIncomplete": True, "items": []}
        line, col = self.pos_in(doc, p["position"])
        if k == "ini":
            if not self.opt("ini", "completion", default=True):
                return None
            items, inc = inifeat.complete(idx, doc.text, line, col, doc.path)
            return {"isIncomplete": inc, "items": [self._item(doc, it) for it in items]}
        if k == "cpp":
            if not self.opt("cpp", "completion", default=True):
                return None
            return self.cpp_completion(doc, idx, line, col)
        return None

    def _item(self, doc, it):
        ed = it.pop("_edit", None)
        if ed:
            line, s, e, text = ed
            it["textEdit"] = {"range": self.mk_range(doc, line, s, e), "newText": text}
        return it

    def cpp_completion(self, doc, idx, line, col):
        off = self.offset_of(doc, line, col)
        ctx = cpp.context_at(doc.text, off)
        if not ctx or ctx["where"] in ("string", "nested"):
            return None
        specdb = idx["specs"]
        macro = ctx["macro"]
        items = []
        sl, sc = self.pos_of_offset(doc, ctx.get("start", off))
        rng = self.mk_range(doc, line, sc, col) if sl == line else None
        if ctx["where"] == "spec" and macro != "UMETA":
            for lk, e in spec_items(specdb, macro):
                ins = e["name"]
                fmt = 1
                if lk == "meta":
                    ins, fmt = ("meta=($1)", 2) if self.snippets else ("meta=(", 1)
                elif e.get("value_type") not in (None, "None", "OptionalString", "OptionalEqualsKeyValuePairList"):
                    ins = e["name"] + "="
                it = {"label": e["name"], "kind": 14, "detail": "%s · %s" % (macro, e.get("value_type")),
                      "insertTextFormat": fmt, "filterText": e["name"],
                      "data": {"t": "spec", "m": macro, "k": lk}}
                if rng:
                    it["textEdit"] = {"range": rng, "newText": ins}
                else:
                    it["insertText"] = ins
                items.append(it)
        elif ctx["where"] == "meta" or (ctx["where"] == "spec" and macro == "UMETA"):
            for lk, e in sorted(cpp.meta_entries(specdb, macro, idx.get("umeta")).items()):
                it = {"label": e["name"], "kind": 10, "detail": "meta · " + ",".join(e.get("contexts", [])),
                      "filterText": e["name"], "data": {"t": "meta", "m": macro, "k": lk}}
                if rng:
                    it["textEdit"] = {"range": rng, "newText": e["name"]}
                else:
                    it["insertText"] = e["name"]
                items.append(it)
        elif ctx["where"] == "spec_value" and ctx.get("key", "").lower() == "config" and macro == "UCLASS":
            for name, n in sorted(idx.get("config_names", {}).items(), key=lambda x: -x[1]):
                it = {"label": name, "kind": 12, "detail": "used by %d classes" % n}
                if rng:
                    it["textEdit"] = {"range": rng, "newText": name}
                items.append(it)
        return {"isIncomplete": False, "items": items}

    def on_completionItem_resolve(self, item):
        idx = self.idx
        if idx is None:
            return item
        d = item.get("data") or {}
        t = d.get("t")
        if t == "spec":
            e = idx["specs"]["macros"].get(d["m"], {}).get(d["k"])
            if e:
                item["documentation"] = {"kind": "markdown", "value": cpp.spec_doc_md(d["m"], e, idx["specs"])}
        elif t == "meta":
            e = cpp.meta_entries(idx["specs"], d["m"], idx.get("umeta")).get(d["k"])
            if e:
                item["documentation"] = {"kind": "markdown", "value": cpp.meta_doc_md(e)}
        else:
            inifeat.resolve(idx, item)
        return item

    def on_textDocument_hover(self, p):
        doc = self._doc(p)
        if not doc:
            return None
        idx = self.wait_index()
        if idx is None:
            return None
        line, col = self.pos_in(doc, p["position"])
        k = self.kind_of(doc)
        if k == "ini":
            r = inifeat.hover(idx, doc.text, line, col, doc.path)
            if not r:
                return None
            md, (l, s, e) = r
            return {"contents": {"kind": "markdown", "value": md}, "range": self.mk_range(doc, l, s, e)}
        if k == "cpp" and self.opt("cpp", "hover", default=True):
            off = self.offset_of(doc, line, col)
            ws, we = cpp.word_range(doc.text, off)
            if ws == we:
                return self.bp_hover(doc, line)
            word = doc.text[ws:we]
            ctx = cpp.context_at(doc.text, ws)
            if not ctx:
                return self.bp_hover(doc, line)
            specdb = idx["specs"]
            md = None
            if ctx["where"] == "spec" and ctx["macro"] != "UMETA":
                e = specdb["macros"].get(ctx["macro"], {}).get(word.lower())
                if e:
                    md = cpp.spec_doc_md(ctx["macro"], e, specdb)
            elif ctx["where"] in ("meta", "spec"):
                e = cpp.meta_entries(specdb, ctx["macro"], idx.get("umeta")).get(word.lower())
                if e:
                    md = cpp.meta_doc_md(e)
            if md:
                return {"contents": {"kind": "markdown", "value": md},
                        "range": self.mk_range(doc, line, col - (off - ws), col + (we - off))}
            if ctx.get("where") not in ("spec", "meta"):
                return self.bp_hover(doc, line)
        return None

    def bp_hover(self, doc, line):
        if self.bp is None or not self.opt("blueprints", "hover", default=True):
            return None
        from . import bpfeat
        if not bpfeat.is_header(doc.path):
            return None
        hit = bpfeat.decl_at(doc.text, line, 0)
        if not hit:
            return None
        c, prop, l, s, e = hit
        md = bpfeat.hover_md(c, prop, self.bp_rows(c, prop))
        if not md:
            return None
        return {"contents": {"kind": "markdown", "value": md}, "range": self.mk_range(doc, l, s, e)}

    def on_textDocument_definition(self, p):
        doc = self._doc(p)
        if not doc or self.kind_of(doc) != "ini":
            return None
        idx = self.wait_index()
        if idx is None:
            return None
        line, col = self.pos_in(doc, p["position"])
        locs = inifeat.definition(idx, doc.text, line, col, doc.path)
        if not locs:
            return None
        return [{"uri": path_to_uri(f), "range": {"start": {"line": max(0, l - 1), "character": 0},
                                                  "end": {"line": max(0, l - 1), "character": 0}}} for f, l in locs]


def spec_items(specdb, macro):
    return sorted(specdb["macros"].get(macro, {}).items())


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if "--gen-engine-cdb" in argv:
        from . import enginecdb
        return enginecdb.cli(argv)
    if "--version" in argv:
        print(VERSION)
        return 0
    if "--index" in argv:  # build/validate cache from the command line: --index <project_dir> [engine_root]
        i = argv.index("--index")
        proj = argv[i + 1] if len(argv) > i + 1 else os.getcwd()
        up = engine.find_uproject(proj)
        eng = argv[i + 2] if len(argv) > i + 2 else None
        eroot, how = engine.resolve_engine(up, eng)
        t = time.perf_counter()
        ix = index.Indexer(eroot, os.path.dirname(up) if up else None, log=lambda m: print(m, file=sys.stderr))
        d, stats = ix.refresh()
        print("engine=%s (%s) project=%s stats=%s total=%.2fs" % (eroot, how, up, stats, time.perf_counter() - t))
        return 0
    srv = Server(sys.stdin.buffer, sys.stdout.buffer)
    srv.run()
    return 0
