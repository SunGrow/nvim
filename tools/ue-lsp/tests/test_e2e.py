"""End-to-end test: spawn the server over stdio and drive it like an editor would.

Run:  python tests/test_e2e.py            (from the ue-lsp directory)
Env:  UE_PROJECT_DIR (required; skipped without it); UE_LSP_E2E_KEEP_CACHE=1 to reuse the user cache
      instead of a fresh temp cache (then the "cold" phase is not cold).
Documents are opened in memory only; nothing is written to the project.
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from ue_lsp.server import path_to_uri  # noqa: E402

PROJECT = os.environ.get("UE_PROJECT_DIR", "")

if not os.path.isfile(os.path.join(PROJECT, "Config", "DefaultEngine.ini")):
    if __name__ == "__main__":
        print("skipped: set UE_PROJECT_DIR to a UE project to run these tests")
        sys.exit(0)
    raise unittest.SkipTest("set UE_PROJECT_DIR to a UE project to run these tests")


def _module_dir():
    src = os.path.join(PROJECT, "Source")
    for d in sorted(os.listdir(src)):
        if any(f.endswith(".Build.cs") for f in os.listdir(os.path.join(src, d))):
            return os.path.join(src, d)
    raise unittest.SkipTest("no game module under Source/")
TIMINGS = {}


class Client:
    def __init__(self, cache_dir):
        env = dict(os.environ)
        if cache_dir:
            env["UE_LSP_CACHE_DIR"] = cache_dir
        self.t0 = time.perf_counter()
        self.p = subprocess.Popen([sys.executable, os.path.join(ROOT, "ue-lsp.py")], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.next_id = 1
        self.responses = {}
        self.notes = []
        self.cv = threading.Condition()
        self.stderr = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: self.stderr.extend(self.p.stderr), daemon=True).start()

    def _read(self):
        f = self.p.stdout
        while True:
            length = None
            while True:
                line = f.readline()
                if not line:
                    return
                line = line.strip()
                if not line:
                    break
                k, _, v = line.partition(b":")
                if k.lower() == b"content-length":
                    length = int(v)
            msg = json.loads(f.read(length))
            with self.cv:
                if "id" in msg and "method" not in msg:
                    self.responses[msg["id"]] = msg
                else:
                    self.notes.append(msg)
                self.cv.notify_all()

    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
        self.p.stdin.flush()

    def request(self, method, params, timeout=120):
        mid = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        end = time.time() + timeout
        with self.cv:
            while mid not in self.responses:
                if not self.cv.wait(timeout=max(0.01, end - time.time())) and time.time() > end:
                    raise TimeoutError(method)
            msg = self.responses.pop(mid)
        if "error" in msg:
            raise RuntimeError(msg["error"])
        return msg["result"]

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def wait_diag(self, uri, timeout=60):
        end = time.time() + timeout
        with self.cv:
            while True:
                for n in reversed(self.notes):
                    if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri:
                        return n["params"]["diagnostics"]
                if time.time() > end:
                    return None
                self.cv.wait(timeout=0.1)

    def close(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
            self.p.wait(timeout=10)
        for f in (self.p.stdin, self.p.stdout, self.p.stderr):
            try:
                f.close()
            except Exception:
                pass


INI_URI = path_to_uri(os.path.join(PROJECT, "Config", "DefaultEngine.ini"))
CPP_URI = path_to_uri(os.path.join(_module_dir(), "__ue_lsp_e2e_inmemory.h"))
EXTRA = ("\n[/Script/Engine.Rend\n[/Script/Engine.RendererSettings]\nr.Mobile.Sha\n"
         "r.DynamicGlobalIlluminationMethod=\nMobileShadingPath=\nNotARealKey=1\n")
CPP = ("#pragma once\nUCLASS(config=Game)\nclass UFoo : public UObject\n{\n\tGENERATED_BODY()\n"
       "\tUPROPERTY(EditAnywhere, Bogus, meta=(Cl\n")


def ini_text():
    with open(os.path.join(PROJECT, "Config", "DefaultEngine.ini"), encoding="utf-8-sig") as f:
        return f.read().replace("\r\n", "\n") + EXTRA


def open_docs(c):
    c.notify("textDocument/didOpen", {"textDocument": {"uri": INI_URI, "languageId": "dosini", "version": 1,
                                                       "text": ini_text()}})
    c.notify("textDocument/didOpen", {"textDocument": {"uri": CPP_URI, "languageId": "cpp", "version": 1,
                                                       "text": CPP}})


def init(c):
    return c.request("initialize", {"processId": os.getpid(), "rootUri": path_to_uri(PROJECT),
                                    "capabilities": {"textDocument": {"completion": {"completionItem": {"snippetSupport": True}}}},
                                    "initializationOptions": {"indexWaitSeconds": 2.0}})


def line_of(text, needle):
    for i, l in enumerate(text.split("\n")):
        if l == needle:
            return i
    raise AssertionError(needle)


class E2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keep = os.environ.get("UE_LSP_E2E_KEEP_CACHE") == "1"
        cls.cache = None if cls.keep else tempfile.mkdtemp(prefix="ue-lsp-e2e-")
        # ---- cold
        c = Client(cls.cache)
        init(c)
        c.notify("initialized", {})
        open_docs(c)
        text = ini_text()
        ln = line_of(text, "r.Mobile.Sha")
        while True:
            r = c.request("textDocument/completion", {"textDocument": {"uri": INI_URI},
                                                      "position": {"line": ln, "character": 12}}, timeout=900)
            if r and r["items"]:
                break
            time.sleep(0.2)
        TIMINGS["cold_spawn_to_first_ini_completion_s"] = round(time.perf_counter() - c.t0, 3)
        c.close()
        # ---- warm
        cls.c = c = Client(cls.cache)
        init(c)
        TIMINGS["warm_spawn_to_initialize_result_ms"] = round((time.perf_counter() - c.t0) * 1000, 1)
        c.notify("initialized", {})
        open_docs(c)
        r = c.request("textDocument/completion", {"textDocument": {"uri": INI_URI},
                                                  "position": {"line": ln, "character": 12}})
        TIMINGS["warm_spawn_to_first_ini_completion_ms"] = round((time.perf_counter() - c.t0) * 1000, 1)
        cls.first_warm_items = len(r["items"])
        cls.text = text

    @classmethod
    def tearDownClass(cls):
        cls.c.close()
        if cls.cache:
            shutil.rmtree(cls.cache, ignore_errors=True)
        print("\nTIMINGS " + json.dumps(TIMINGS, indent=1))

    def comp(self, uri, line, ch):
        return self.c.request("textDocument/completion", {"textDocument": {"uri": uri},
                                                          "position": {"line": line, "character": ch}})

    def test_1_warm_first_completion_nonempty(self):
        self.assertGreater(self.first_warm_items, 0)

    def test_ini_section_completion(self):
        ln = line_of(self.text, "[/Script/Engine.Rend")
        r = self.comp(INI_URI, ln, len("[/Script/Engine.Rend"))
        labels = [i["label"] for i in r["items"]]
        self.assertIn("/Script/Engine.RendererSettings", labels)
        it = next(i for i in r["items"] if i["label"] == "/Script/Engine.RendererSettings")
        self.assertEqual(it["textEdit"]["newText"], "[/Script/Engine.RendererSettings]")
        res = self.c.request("completionItem/resolve", it)
        self.assertIn("URendererSettings", res["documentation"]["value"])

    def test_ini_key_completion(self):
        ln = line_of(self.text, "r.Mobile.Sha")
        r = self.comp(INI_URI, ln, 12)
        labels = [i["label"] for i in r["items"]]
        self.assertIn("r.Mobile.ShadingPath", labels)

    def test_ini_value_completion(self):
        ln = line_of(self.text, "r.DynamicGlobalIlluminationMethod=")
        r = self.comp(INI_URI, ln, len("r.DynamicGlobalIlluminationMethod="))
        self.assertIn("Lumen", " ".join(i.get("detail", "") for i in r["items"]))
        ln = line_of(self.text, "MobileShadingPath=")
        r = self.comp(INI_URI, ln, len("MobileShadingPath="))
        self.assertEqual(sorted(i["label"] for i in r["items"]), ["Deferred", "Forward"])
        ln = line_of(self.text, "r.AllowStaticLighting=False")
        r = self.comp(INI_URI, ln, len("r.AllowStaticLighting="))
        self.assertEqual(sorted(i["label"] for i in r["items"]), ["False", "True"])

    def test_ini_hover_and_definition(self):
        ln = line_of(self.text, "r.AllowStaticLighting=False")
        h = self.c.request("textDocument/hover", {"textDocument": {"uri": INI_URI}, "position": {"line": ln, "character": 4}})
        v = h["contents"]["value"]
        self.assertIn("bAllowStaticLighting", v)
        self.assertIn("RendererSettings.h:", v)
        ln = line_of(self.text, "[/Script/Engine.RendererSettings]")
        h = self.c.request("textDocument/hover", {"textDocument": {"uri": INI_URI}, "position": {"line": ln, "character": 10}})
        self.assertIn("UDeveloperSettings", h["contents"]["value"])
        d = self.c.request("textDocument/definition", {"textDocument": {"uri": INI_URI}, "position": {"line": ln, "character": 10}})
        self.assertTrue(d[0]["uri"].endswith("RendererSettings.h"))

    def test_ini_diagnostics(self):
        ds = self.c.wait_diag(INI_URI)
        msgs = [(d["range"]["start"]["line"], d["message"]) for d in ds]
        ln = line_of(self.text, "NotARealKey=1")
        self.assertTrue(any(l == ln and "NotARealKey" in m for l, m in msgs), msgs)
        # no warnings for the real project content
        self.assertFalse([m for l, m in msgs if l < line_of(self.text, "[/Script/Engine.Rend") and "Unknown key" in m])

    def test_cpp_meta_completion_and_hover(self):
        lines = CPP.split("\n")
        ln = len(lines) - 2
        r = self.comp(CPP_URI, ln, len(lines[ln]))
        labels = [i["label"] for i in r["items"]]
        self.assertIn("ClampMin", labels)
        self.assertIn("ClampMax", labels)
        it = next(i for i in r["items"] if i["label"] == "ClampMin")
        res = self.c.request("completionItem/resolve", it)
        self.assertIn("minimum value", res["documentation"]["value"])
        h = self.c.request("textDocument/hover", {"textDocument": {"uri": CPP_URI},
                                                  "position": {"line": ln, "character": lines[ln].index("EditAnywhere") + 2}})
        self.assertIn("property windows", h["contents"]["value"])
        # specifier completion after a comma
        self.c.notify("textDocument/didChange", {"textDocument": {"uri": CPP_URI, "version": 2},
                                                 "contentChanges": [{"range": {"start": {"line": ln, "character": 0},
                                                                               "end": {"line": ln, "character": len(lines[ln])}},
                                                                     "text": "\tUPROPERTY(EditAnywhere, Blueprint"}]})
        r = self.comp(CPP_URI, ln, len("\tUPROPERTY(EditAnywhere, Blueprint"))
        labels = [i["label"] for i in r["items"]]
        self.assertIn("BlueprintReadWrite", labels)
        self.assertNotIn("BlueprintImplementableEvent", labels)

    def test_cpp_diagnostics(self):
        end = time.time() + 10
        while time.time() < end:
            ds = self.c.wait_diag(CPP_URI) or []
            if any("Bogus" in d["message"] for d in ds):
                break
            time.sleep(0.1)
        self.assertTrue(any("Bogus" in d["message"] for d in ds), ds)

    def test_z_latency(self):
        ln = line_of(self.text, "r.Mobile.Sha")
        lines = CPP.split("\n")
        cl = len(lines) - 2
        ini_t, cpp_t, sec_t = [], [], []
        sl = line_of(self.text, "[/Script/Engine.Rend")
        for _ in range(30):
            t = time.perf_counter()
            self.comp(INI_URI, ln, 12)
            ini_t.append((time.perf_counter() - t) * 1000)
            t = time.perf_counter()
            self.comp(INI_URI, sl, 1)
            sec_t.append((time.perf_counter() - t) * 1000)
            t = time.perf_counter()
            self.comp(CPP_URI, cl, 10)
            cpp_t.append((time.perf_counter() - t) * 1000)
        TIMINGS["ini_key_completion_median_ms"] = round(statistics.median(ini_t), 2)
        TIMINGS["ini_section_completion_all_median_ms"] = round(statistics.median(sec_t), 2)
        TIMINGS["cpp_completion_median_ms"] = round(statistics.median(cpp_t), 2)
        self.assertLess(statistics.median(ini_t), 100)


if __name__ == "__main__":
    unittest.main(verbosity=2)
