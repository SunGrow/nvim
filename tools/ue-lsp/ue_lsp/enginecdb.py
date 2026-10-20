"""Synthesised compile database for engine .cpp files (go-to-implementation in the engine).

Installed engines ship full source but precompiled modules, so the project's compile_commands.json has no
engine translation units. UBT `-Mode=JsonExport` describes every module of the editor target (directory,
include paths, public definitions, dependencies). From that and the *project's* own Shared.rsp /
Definitions headers we synthesise one rsp per engine module and a compile_commands.json with one entry
per engine .cpp. A second clangd (no background index) reads it. Nothing is written outside the cache:

    <cache>/engine-cdb/compile_commands.json   entries `clang-cl @"modules/<Module>.rsp"`
    <cache>/engine-cdb/base.rsp                flags shared by all modules (from the project's Shared.rsp)
    <cache>/engine-cdb/defs/*.h                CommonDefinitions.h, AllApis.h, Definitions.<Module>.h
    <cache>/engine-cdb/target.json             raw UBT JsonExport output
    <cache>/engine-cdb/meta.json               staleness key + stats
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

SCHEMA = 3

# directory names (case-insensitive) that only build for platforms other than Win64
OTHER_PLATFORM_DIRS = frozenset(n.lower() for n in (
    "Android", "IOS", "TVOS", "VisionOS", "Linux", "LinuxArm64", "Unix", "Mac", "Apple", "Lumin", "HoloLens",
    "Switch", "PS4", "PS5", "XboxOne", "XSX", "GDK", "Dingo", "FreeBSD", "HTML5", "Wasm",
    "SteamDeck", "Orbis", "Prospero", "Posix", "Linux_AArch64", "IOSDevice",
))
SKIP_DIRS = frozenset(("thirdparty", "intermediate", "binaries", "content", "resources", "saved", "__pycache__"))
DEFAULT_CLANG_CL = "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe"

_DROP_PREFIXES = ("-W", "/W", "/w", "-Werror", "/errorReport", "-vctoolsdir", "/Z7", "/Zi", "-fstandalone-debug",
                  "-fno-eliminate-unused-debug-types", "/Yu", "/Yc", "/Fp", "/FI", "/Fo", "/sourceDependencies",
                  "/experimental:log", "-include-pch", "-fms-hotpatch")


def cache_root():
    d = os.environ.get("UE_LSP_CACHE_DIR")
    if not d:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache")
        d = os.path.join(base, "ue-lsp", "cache")
    return d


def cdb_dir():
    return os.path.join(cache_root(), "engine-cdb")


def fwd(p):
    return p.replace("\\", "/")


def norm(p):
    return os.path.normcase(os.path.normpath(p))


def _listdir(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []


def _under(path, root):
    p, r = norm(path), norm(root)
    return p == r or p.startswith(r + os.sep)


# ---------------------------------------------------------------- staleness
def engine_version(engine_root):
    try:
        with open(os.path.join(engine_root, "Engine", "Build", "Build.version"), encoding="utf-8") as f:
            v = json.load(f)
        return "%s.%s.%s-%s" % (v.get("MajorVersion"), v.get("MinorVersion"), v.get("PatchVersion"), v.get("Changelist"))
    except (OSError, ValueError):
        return "unknown"


def _project_rule_files(project_dir):
    out = []
    for sub in ("Source", "Plugins"):
        top = os.path.join(project_dir, sub)
        for dp, dns, fns in os.walk(top):
            dns[:] = [d for d in dns if d.lower() not in ("binaries", "intermediate", "content", "saved", "thirdparty")]
            for fn in fns:
                if fn.endswith((".Build.cs", ".Target.cs")):
                    out.append(os.path.join(dp, fn))
    return sorted(out)


def staleness_key(engine_root, uproject):
    parts = ["schema=%d" % SCHEMA, "engine=%s" % engine_version(engine_root), "engineroot=%s" % fwd(engine_root),
             "project=%s" % fwd(uproject)]
    files = [uproject] + _project_rule_files(os.path.dirname(uproject))
    for f in files:
        try:
            parts.append("%s:%d" % (os.path.basename(f), os.stat(f).st_mtime_ns))
        except OSError:
            parts.append("%s:missing" % os.path.basename(f))
    import hashlib
    return hashlib.sha1("\n".join(parts).encode("utf-8")).hexdigest()


def read_meta():
    try:
        with open(os.path.join(cdb_dir(), "meta.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def is_fresh(engine_root, uproject):
    m = read_meta()
    return bool(m and m.get("key") == staleness_key(engine_root, uproject)
                and os.path.isfile(os.path.join(cdb_dir(), "compile_commands.json")))


# ---------------------------------------------------------------- project inputs
def find_ubt(engine_root):
    p = os.path.join(engine_root, "Engine", "Binaries", "DotNET", "UnrealBuildTool", "UnrealBuildTool.exe")
    return p if os.path.isfile(p) else None


def editor_target_name(uproject):
    src = os.path.join(os.path.dirname(uproject), "Source")
    try:
        for n in sorted(os.listdir(src)):
            if n.endswith("Editor.Target.cs"):
                return n[:-len(".Target.cs")]
    except OSError:
        pass
    return os.path.splitext(os.path.basename(uproject))[0] + "Editor"


def _project_build_files(project_dir):
    """Return (shared_rsp, definitions_h, shared_defs_h) from a previous project build, or None."""
    base = os.path.join(project_dir, "Intermediate", "Build", "Win64", "x64")
    cands = sorted(glob.glob(os.path.join(base, "UnrealEditor", "Development", "*", "*.Shared.rsp")))
    for rsp in cands:
        d = os.path.dirname(rsp)
        defs = glob.glob(os.path.join(d, "Definitions.*.h"))
        if not defs:
            continue
        defs_h = defs[0]
        shared = None
        try:
            with open(defs_h, encoding="utf-8", errors="replace") as f:
                m = re.search(r'^#include\s+"([^"]*SharedDefinitions[^"]+)"', f.read(), re.M)
            if m:
                shared = m.group(1)
        except OSError:
            continue
        if shared and not os.path.isabs(shared):
            hits = glob.glob(os.path.join(base, "*", "Development", "*", shared))
            shared = hits[0] if hits else None
        if shared and os.path.isfile(shared):
            return rsp, defs_h, shared
    return None


def _project_driver(project_dir):
    p = os.path.join(project_dir, "compile_commands.json")
    try:
        with open(p, encoding="utf-8") as f:
            head = f.read(4096)
        m = re.search(r'"command":\s*"\\"([^"\\]+clang-cl\.exe)\\"', head)
        if m:
            return fwd(m.group(1))
    except OSError:
        pass
    return DEFAULT_CLANG_CL if os.path.isfile(DEFAULT_CLANG_CL) else "clang-cl.exe"


# ---------------------------------------------------------------- rsp synthesis
def _rsp_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return [ln.strip() for ln in f.read().splitlines() if ln.strip()]


def base_options(shared_rsp_lines, engine_root, project_dir):
    """Keep compiler-mode options of a project Shared.rsp; drop include paths, warnings, PCH and output flags."""
    out = []
    for ln in shared_rsp_lines:
        if ln.startswith(("/I", "-I")):
            continue
        if ln.startswith(("/imsvc", "-imsvc")):
            m = re.match(r'(?:/|-)imsvc\s*"?([^"]+)"?', ln)
            p = m.group(1) if m else ""
            if re.match(r"^[A-Za-z]:[\\/]", p) and not _under(p, engine_root) and not _under(p, project_dir):
                out.append(ln)  # MSVC / Windows SDK system includes
            continue
        if ln.startswith(_DROP_PREFIXES):
            continue
        if ln.startswith("@"):
            continue
        out.append(ln)
    # no __INTELLISENSE__: engine sources are written for the real build (it changes Archive, UE_DEPRECATED...)
    out += ["/TP", "/std:c++20", "-Wno-everything", "-Wno-error"]
    return out


def common_definitions(project_defs_h, shared_defs_h):
    """Header text shared by every engine module: project shared definitions with module-specific lines removed."""
    drop = re.compile(r"^\s*#\s*(?:define|undef)\s+(?:UE_IS_ENGINE_MODULE|UE_DEPRECATED_FOR\w+|UE_VALIDATE_\w+_API|"
                      r"UE_MODULE_NAME|UE_PLUGIN_NAME|IMPLEMENT_\w+)\b")
    lines = ["// ue-lsp enginecdb: derived from the project's shared definitions", "#pragma once"]
    with open(shared_defs_h, encoding="utf-8", errors="replace") as f:
        for ln in f.read().splitlines():
            if ln.startswith("#pragma once") or ln.startswith("//") or drop.match(ln):
                continue
            lines.append(ln)
    # non-API lines of the project module's own Definitions header (UE_ENABLE_INCLUDE_ORDER_*, UE_PROJECT_NAME...)
    api = re.compile(r"^\s*#\s*(?:define|undef)\s+\w+_API\b")
    with open(project_defs_h, encoding="utf-8", errors="replace") as f:
        for ln in f.read().splitlines():
            if not ln.startswith("#define") or api.match(ln) or drop.match(ln):
                continue
            lines.append(ln)
    return "\n".join(lines) + "\n"


def api_name(module):
    return re.sub(r"[^A-Za-z0-9_]", "_", module).upper() + "_API"


def all_apis(module_names):
    out = ["// ue-lsp enginecdb: every module's API macro defaults to import", "#pragma once"]
    for m in module_names:
        a = api_name(m)
        out.append("#ifndef %s\n#define %s DLLIMPORT\n#endif" % (a, a))
        out.append("#ifndef %s\n#define %s DLLIMPORT\n#endif" % (a.replace("_API", "_NON_ATTRIBUTED_API"),
                                                                   a.replace("_API", "_NON_ATTRIBUTED_API")))
    return "\n".join(out) + "\n"


def definition_line(d):
    name, eq, val = d.partition("=")
    name = name.strip()
    if not name:
        return None
    return "#undef %s\n#define %s %s" % (name, name, val if eq else "1")


def plugin_name_of(module_dir, engine_root):
    d = module_dir
    stop = norm(os.path.join(engine_root, "Engine"))
    while d and norm(d) != stop and os.path.dirname(d) != d:
        try:
            for n in os.listdir(d):
                if n.endswith(".uplugin"):
                    return n[:-len(".uplugin")]
        except OSError:
            pass
        d = os.path.dirname(d)
    return ""


def module_definitions_h(module, mod, defs_dir, plugin, public_defs):
    L = ["// ue-lsp enginecdb: Definitions for %s" % module, "#pragma once",
         '#include "%s"' % fwd(os.path.join(defs_dir, "CommonDefinitions.h")),
         '#include "%s"' % fwd(os.path.join(defs_dir, "AllApis.h")),
         "#undef UE_IS_ENGINE_MODULE", "#define UE_IS_ENGINE_MODULE 1",
         "#undef UE_VALIDATE_INTERNAL_API", "#define UE_VALIDATE_INTERNAL_API 0",
         "#undef UE_VALIDATE_EXPERIMENTAL_API", "#define UE_VALIDATE_EXPERIMENTAL_API 0",
         "#undef UE_MODULE_NAME", '#define UE_MODULE_NAME "%s"' % module,
         "#undef UE_PLUGIN_NAME", '#define UE_PLUGIN_NAME "%s"' % plugin]
    a = api_name(module)
    na = a.replace("_API", "_NON_ATTRIBUTED_API")
    L += ["#undef %s" % a, "#define %s DLLEXPORT" % a, "#undef %s" % na, "#define %s DLLEXPORT" % na]
    for d in public_defs:
        ln = definition_line(d)
        if ln:
            L.append(ln)
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------- module graph
class ModuleGraph:
    def __init__(self, modules, engine_root):
        self.m = modules
        self.engine_root = engine_root
        self._pub = {}
        inc = os.path.join(engine_root, "Engine", "Intermediate", "Build", "Win64", "UnrealEditor", "Inc")
        self.inc_root = inc
        self._gen_cache = {}
        self._tp_cache = {}
        self._shared = None

    def _short_name(self, name):
        try:
            with open(self.m[name].get("Rules", ""), encoding="utf-8", errors="replace") as f:
                m = re.search(r'ShortName\s*=\s*"(\w+)"', f.read())
            return m.group(1) if m else None
        except (OSError, KeyError):
            return None

    def gen_dirs(self, name):
        """UHT/VNI/... output dirs of a module. UHT names the folder after ShortName when the Build.cs sets one;
        engine plugins keep their output in <Plugin>/Intermediate instead of Engine/Intermediate."""
        r = self._gen_cache.get(name)
        if r is not None:
            return r
        mod = self.m.get(name) or {}
        roots = [self.inc_root]
        d = mod.get("Directory", "")
        while d and os.path.dirname(d) != d:
            if any(n.endswith(".uplugin") for n in _listdir(d)):
                roots.insert(0, os.path.join(d, "Intermediate", "Build", "Win64", "UnrealEditor", "Inc"))
                break
            d = os.path.dirname(d)
        out = []
        for key in (name, self._short_name(name)):
            if not key:
                continue
            for root in roots:
                base = os.path.join(root, key)
                for sub in _listdir(base):
                    if os.path.isdir(os.path.join(base, sub)):
                        out.append(fwd(os.path.join(base, sub)))
            if out:
                break
        out.sort()
        self._gen_cache[name] = out
        return out

    def private_definitions(self, name):
        """PrivateDefinitions.Add("X[=V]") from the Build.cs (JsonExport only exports PublicDefinitions).

        Conditions around the call are ignored, so this can over-define; e.g. SLATE_MODULE decides whether
        SLATE_SCOPE is public or protected inside Slate.
        """
        try:
            with open(self.m[name].get("Rules", ""), encoding="utf-8", errors="replace") as f:
                text = f.read()
        except (OSError, KeyError):
            return []
        text = re.sub(r"//[^\n]*", "", text)
        out = re.findall(r'PrivateDefinitions\s*\.\s*Add\s*\(\s*"([^"]+)"', text)
        for body in re.findall(r"PrivateDefinitions\s*\.\s*AddRange\s*\(([^;]*?)\)\s*;", text, re.S):
            out += re.findall(r'"([^"]+)"', body)
        return [d for d in out if re.match(r"^[A-Za-z_]\w*(=.*)?$", d)]

    def precompiled_third_party(self, name):
        """System include dirs for ThirdParty modules a precompiled-engine UBT dropped from the graph.

        With bUsePrecompiled, AddEngineThirdPartyPrivateStaticDependencies(...) adds nothing, so e.g. FBX
        never shows up in JsonExport. Read the names from the Build.cs and use ThirdParty/<Name>/**/include.
        """
        r = self._tp_cache.get(name)
        if r is not None:
            return r
        out = []
        try:
            with open(self.m[name].get("Rules", ""), encoding="utf-8", errors="replace") as f:
                text = f.read()
        except (OSError, KeyError):
            text = ""
        for call in re.findall(r"AddEngineThirdPartyPrivateStaticDependencies\s*\(([^;]*?)\)\s*;", text, re.S):
            for tp in re.findall(r'"(\w+)"', call):
                if tp in self.m:
                    continue
                top = os.path.join(self.engine_root, "Engine", "Source", "ThirdParty", tp)
                for dp, dns, _ in os.walk(top):
                    depth = dp[len(top):].count(os.sep)
                    if depth >= 3:
                        dns[:] = []
                    for dn in list(dns):
                        if dn.lower() == "include":
                            out.append(fwd(os.path.join(dp, dn)))
                            dns.remove(dn)
        self._tp_cache[name] = out
        return out

    def dep_closure(self, name):
        """Module plus everything reachable through Public/PrivateDependencyModules (what UBT uses for PCH)."""
        seen = set()
        stack = [name]
        while stack:
            n = stack.pop()
            if n in seen or n not in self.m:
                continue
            seen.add(n)
            for k in ("PublicDependencyModules", "PrivateDependencyModules"):
                stack.extend(self.m[n].get(k) or ())
        return seen

    def shared_pch_order(self):
        """Modules providing a SharedPCH, in UBT preference order (most shared-PCH dependencies first)."""
        if self._shared is None:
            sm = [n for n, m in self.m.items() if m.get("SharedPCH")]
            ss = set(sm)
            rank = []
            for n in sm:
                deps = self.dep_closure(n) & ss
                deps -= set(self.m[n].get("CircularlyReferencedModules") or ())
                rank.append((-len(deps), n))
            self._shared = [n for _, n in sorted(rank)]
        return self._shared

    def pch_for(self, name):
        """(pch_header, extra_module) for a module: its private PCH, else the preferred visible shared PCH."""
        mod = self.m[name]
        if mod.get("PCHUsage") == "NoPCHs":
            return None, None
        if mod.get("PrivatePCH"):
            return fwd(mod["PrivatePCH"]), None
        vis = self.dep_closure(name)
        for s in self.shared_pch_order():
            if s in vis and s != name:
                return fwd(self.m[s]["SharedPCH"]), s
        if mod.get("SharedPCH"):
            return fwd(mod["SharedPCH"]), None
        return None, None

    def public_closure(self, name):
        """name plus everything reachable through PublicDependencyModules / PublicIncludePathModules."""
        r = self._pub.get(name)
        if r is not None:
            return r
        seen = {}
        stack = [name]
        while stack:
            n = stack.pop()
            if n in seen or n not in self.m:
                continue
            seen[n] = True
            mod = self.m[n]
            for k in ("PublicDependencyModules", "PublicIncludePathModules"):
                for d in mod.get(k) or ():
                    if d not in seen:
                        stack.append(d)
        r = list(seen)
        self._pub[name] = r
        return r

    def visible(self, name):
        """Modules whose public interface is visible to `name`, in a stable order (self first)."""
        mod = self.m[name]
        order = [name]
        seen = {name}
        for k in ("PublicDependencyModules", "PublicIncludePathModules", "PrivateDependencyModules",
                  "PrivateIncludePathModules"):
            for d in mod.get(k) or ():
                for x in self.public_closure(d):
                    if x not in seen:
                        seen.add(x)
                        order.append(x)
        return order

    def include_dirs(self, name, extra_module=None):
        mod = self.m[name]
        sysinc, inc, seen = [], [], set()

        def add(lst, p):
            p = fwd(p)
            k = p.lower()
            if k not in seen:
                seen.add(k)
                lst.append(p)

        for p in self.gen_dirs(name):
            add(inc, p)
        for p in mod.get("PrivateIncludePaths") or ():
            add(inc, p)
        for p in mod.get("PublicIncludePaths") or ():
            add(inc, p)
        d = mod.get("Directory", "")
        internal = os.path.join(d, "Internal")
        if os.path.isdir(internal):
            add(inc, internal)
        vis = self.visible(name)
        if extra_module:  # the shared PCH's own include paths travel with it
            vis = vis + [x for x in self.visible(extra_module) if x not in vis]
        for x in vis[1:]:
            xm = self.m[x]
            for p in self.gen_dirs(x):
                add(inc, p)
            for p in xm.get("PublicIncludePaths") or ():
                add(inc, p)
            xi = os.path.join(xm.get("Directory", ""), "Internal")
            if _under(xm.get("Directory", ""), self.engine_root) and os.path.isdir(xi):
                add(inc, xi)
            for p in xm.get("PublicSystemIncludePaths") or ():
                add(sysinc, p)
        for p in mod.get("PublicSystemIncludePaths") or ():
            add(sysinc, p)
        for p in self.precompiled_third_party(name):
            add(sysinc, p)
        return inc, sysinc, vis

    def definitions(self, vis):
        out, seen = [], set()
        for x in vis:
            for d in self.m[x].get("PublicDefinitions") or ():
                if d not in seen:
                    seen.add(d)
                    out.append(d)
        return out


def engine_modules(target_json, engine_root):
    """Modules of the target whose directory is a C++ module inside Engine/Source or Engine/Plugins."""
    mods = target_json.get("Modules") or {}
    roots = [os.path.join(engine_root, "Engine", "Source"), os.path.join(engine_root, "Engine", "Plugins")]
    out = []
    for name, m in mods.items():
        d = m.get("Directory") or ""
        if m.get("Type") != "CPlusPlus" or not any(_under(d, r) for r in roots):
            continue
        parts = {p.lower() for p in re.split(r"[\\/]", d)}
        if "thirdparty" in parts or parts & OTHER_PLATFORM_DIRS:
            continue
        if os.path.isdir(d):
            out.append(name)
    return sorted(out)


def module_sources(name, mod, all_dirs):
    """.cpp files of a module (nested modules and other-platform / third-party dirs are skipped)."""
    top = mod["Directory"]
    nested = {norm(d) for n, d in all_dirs.items() if n != name and _under(d, top)}
    out = []
    for dp, dns, fns in os.walk(top):
        keep = []
        for dn in dns:
            low = dn.lower()
            if low in SKIP_DIRS or low in OTHER_PLATFORM_DIRS or norm(os.path.join(dp, dn)) in nested:
                continue
            keep.append(dn)
        dns[:] = keep
        for fn in fns:
            if fn.endswith(".cpp"):
                out.append(fwd(os.path.join(dp, fn)))
    return sorted(out)


def module_rsp(graph, name, base_path, src_root, defs_h, stub_dir=None):
    """Lines of the per-module rsp. Returns (lines, visible_modules)."""
    pch, pch_mod = graph.pch_for(name)
    inc, sysinc, vis = graph.include_dirs(name, pch_mod)
    lines = ['@"%s"' % fwd(base_path), '/I "%s"' % src_root]
    if stub_dir:
        lines.append('/I "%s"' % fwd(stub_dir))
    lines += ['/I "%s"' % p for p in inc]
    lines += ['/imsvc "%s"' % p for p in sysinc]
    lines.append('/FI"%s"' % fwd(defs_h))
    if pch:
        lines.append('/FI"%s"' % pch)
    return lines, vis


def make_stubs(stub_dir, graph, module_files):
    """Empty `<X>.gen.cpp` files for `UE_INLINE_GENERATED_CPP_BY_NAME(X)`.

    UBT's adaptive unity inlines UHT's X.gen.cpp at the end of X.cpp; installed engines keep only the
    .generated.h files, so the include would fail. Stubs exist for every .cpp whose basename has a
    generated header; they live in the cache and are on the include path of every module.
    """
    have = set()
    for name in module_files:
        for d in graph.gen_dirs(name):
            try:
                for n in os.listdir(d):
                    if n.endswith(".generated.h"):
                        have.add(n[:-len(".generated.h")])
            except OSError:
                pass
    os.makedirs(stub_dir, exist_ok=True)
    want = set()
    for files in module_files.values():
        for f in files:
            b = os.path.basename(f)[:-4]
            if b in have:
                want.add(b)
    existing = set(os.listdir(stub_dir))
    for b in want:
        if b + ".gen.cpp" not in existing:
            open(os.path.join(stub_dir, b + ".gen.cpp"), "w").close()
    return len(want)


def synthesize(target_json, engine_root, project_dir, out_dir, log=None):
    """Write base.rsp, defs/, modules/*.rsp and compile_commands.json under out_dir. Returns stats."""
    log = log or (lambda m: None)
    t0 = time.perf_counter()
    pb = _project_build_files(project_dir)
    if not pb:
        raise RuntimeError("no project build output (Intermediate/.../*.Shared.rsp) - build or gen_compile_db once")
    shared_rsp, proj_defs, shared_defs = pb
    driver = _project_driver(project_dir)
    mods = target_json["Modules"]
    names = engine_modules(target_json, engine_root)
    graph = ModuleGraph(mods, engine_root)
    defs_dir = os.path.join(out_dir, "defs")
    mod_dir = os.path.join(out_dir, "modules")
    stub_dir = os.path.join(out_dir, "stubs")
    os.makedirs(defs_dir, exist_ok=True)
    os.makedirs(mod_dir, exist_ok=True)
    _write(os.path.join(defs_dir, "CommonDefinitions.h"), common_definitions(proj_defs, shared_defs))
    _write(os.path.join(defs_dir, "AllApis.h"),
           all_apis(sorted(n for n, m in mods.items() if m.get("Type") == "CPlusPlus")))
    base = base_options(_rsp_lines(shared_rsp), engine_root, project_dir)
    base_path = os.path.join(out_dir, "base.rsp")
    _write(base_path, "\n".join(base) + "\n")
    src_root = fwd(os.path.join(engine_root, "Engine", "Source"))
    all_dirs = {n: mods[n]["Directory"] for n in names}
    module_files = {n: module_sources(n, mods[n], all_dirs) for n in names}
    module_files = {n: f for n, f in module_files.items() if f}
    nstubs = make_stubs(stub_dir, graph, module_files)
    entries = []
    nfiles = 0
    for name, files in module_files.items():
        mod = mods[name]
        dh = os.path.join(defs_dir, "Definitions.%s.h" % name)
        lines, vis = module_rsp(graph, name, base_path, src_root, dh, stub_dir)
        plugin = plugin_name_of(mod["Directory"], engine_root)
        _write(dh, module_definitions_h(name, mod, defs_dir, plugin,
                                         graph.definitions(vis) + graph.private_definitions(name)))
        rsp = fwd(os.path.join(mod_dir, name + ".rsp"))
        _write(rsp, "\n".join(lines) + "\n")
        cmd = '"%s" @"%s" ' % (driver, rsp)
        for f in files:
            entries.append({"file": f, "command": cmd, "directory": src_root})
        nfiles += len(files)
    tmp = os.path.join(out_dir, "compile_commands.json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entries, f, indent=0, separators=(",", ":"))
    os.replace(tmp, os.path.join(out_dir, "compile_commands.json"))
    stats = {"modules": len(module_files), "entries": nfiles, "stubs": nstubs,
             "synth_seconds": round(time.perf_counter() - t0, 2)}
    log("engine cdb synthesised: %s" % stats)
    return stats


def _write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# ---------------------------------------------------------------- driver
def run_ubt(engine_root, uproject, out_json, log=None, timeout=900):
    ubt = find_ubt(engine_root)
    if not ubt:
        raise RuntimeError("UnrealBuildTool.exe not found under %s" % engine_root)
    cmd = [ubt, "-Mode=JsonExport", "-project=" + uproject, editor_target_name(uproject), "Win64", "Development",
           "-OutputFile=" + out_json, "-WaitMutex"]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout, creationflags=flags)
    if r.returncode != 0 or not os.path.isfile(out_json):
        tail = r.stdout.decode("utf-8", "replace")[-600:]
        raise RuntimeError("UBT JsonExport failed (%s): %s" % (r.returncode, tail))


def _acquire_lock(path, stale=900):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        return True
    except FileExistsError:
        try:
            if time.time() - os.stat(path).st_mtime > stale:
                os.remove(path)
                return _acquire_lock(path, stale)
        except OSError:
            pass
        return False
    except OSError:
        return False


def generate(engine_root, uproject, force=False, log=None):
    """Create/refresh the engine compile database. Returns stats dict, or None when up to date / busy."""
    log = log or (lambda m: None)
    if not force and is_fresh(engine_root, uproject):
        return None
    out = cdb_dir()
    lock = os.path.join(cache_root(), "engine-cdb.lock")
    if not _acquire_lock(lock):
        log("engine cdb generation already running elsewhere")
        return None
    try:
        t0 = time.perf_counter()
        os.makedirs(out, exist_ok=True)
        key = staleness_key(engine_root, uproject)
        tj = os.path.join(out, "target.json")
        run_ubt(engine_root, uproject, tj, log)
        t_ubt = time.perf_counter() - t0
        with open(tj, encoding="utf-8") as f:
            target = json.load(f)
        stats = synthesize(target, engine_root, os.path.dirname(uproject), out, log)
        stats.update({"ubt_seconds": round(t_ubt, 2), "total_seconds": round(time.perf_counter() - t0, 2)})
        meta = {"key": key, "engine_root": fwd(engine_root), "project": fwd(uproject),
                "generated": time.strftime("%Y-%m-%dT%H:%M:%S"), "stats": stats}
        _write(os.path.join(out, "meta.json"), json.dumps(meta, indent=1))
        return stats
    finally:
        try:
            os.remove(lock)
        except OSError:
            pass


def cli(argv):
    """python ue-lsp.py --gen-engine-cdb [project_dir_or_uproject] [--force] [--engine <root>]"""
    from . import engine as eng
    args = [a for a in argv if a != "--gen-engine-cdb"]
    force = "--force" in args
    eroot = None
    if "--engine" in args:
        i = args.index("--engine")
        eroot = args[i + 1]
        del args[i:i + 2]
    pos = [a for a in args if not a.startswith("--")]
    start = pos[0] if pos else os.getcwd()
    up = start if start.lower().endswith(".uproject") else eng.find_uproject(start)
    if not up:
        print("no .uproject found from %s" % start, file=sys.stderr)
        return 2
    eroot, how = eng.resolve_engine(up, eroot)
    if not eroot:
        print("engine not found: %s" % how, file=sys.stderr)
        return 2
    stats = generate(eroot, up, force=force, log=lambda m: print(m, file=sys.stderr))
    print("up to date" if stats is None else json.dumps(stats))
    print("cdb: %s" % fwd(cdb_dir()))
    return 0


# ---------------------------------------------------------------- server entry points
def status(engine_root, uproject):
    """'missing' (no compile_commands.json), 'stale' (key differs from the current engine/project) or 'fresh'."""
    if not os.path.isfile(os.path.join(cdb_dir(), "compile_commands.json")):
        return "missing"
    return "fresh" if is_fresh(engine_root, uproject) else "stale"


def ensure_async(engine_root, uproject, log=None, on_done=None):
    """Generate/refresh the engine compile database in a daemon thread when it is missing or stale.

    Returns the started threading.Thread, or None when the database is already fresh (nothing started).
    `on_done(stats_or_None, error_or_None)` runs on that thread afterwards; errors are logged, never raised.
    """
    import threading
    if not engine_root or not uproject or status(engine_root, uproject) == "fresh":
        return None

    def work():
        stats, err = None, None
        try:
            stats = generate(engine_root, uproject, log=log)
        except Exception as e:  # UBT missing, project never built, timeout...
            err = e
            if log:
                log("engine cdb generation failed: %s" % e)
        if on_done:
            on_done(stats, err)

    t = threading.Thread(target=work, name="engine-cdb", daemon=True)
    t.start()
    return t
