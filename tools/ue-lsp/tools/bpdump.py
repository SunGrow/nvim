"""bpdump: dump UE 5.x editor package contents, or build the Blueprint value index.

  python -I tools/bpdump.py <asset.uasset> [--all] [--json]
  python -I tools/bpdump.py --index <project dir> [--top N] [--actors] [--cache DIR] [--workers N]
  python -I tools/bpdump.py --query <project dir> <CppClass> <Property>
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from ue_lsp import uasset, bpvalues  # noqa: E402


def peak_ram_mb():
    try:
        import ctypes
        from ctypes import wintypes

        class PMC(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                        ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]
        pmc = PMC()
        pmc.cb = ctypes.sizeof(PMC)
        k = ctypes.WinDLL("kernel32")
        k.GetCurrentProcess.restype = wintypes.HANDLE
        ps = ctypes.WinDLL("psapi")
        ps.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(PMC), wintypes.DWORD]
        ps.GetProcessMemoryInfo(k.GetCurrentProcess(), ctypes.byref(pmc), pmc.cb)
        return pmc.PeakWorkingSetSize / 1048576.0
    except Exception:
        try:
            import resource
            return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0
        except Exception:
            return -1.0


def dump_asset(path, show_all, as_json):
    pkg = uasset.open_package(path)
    s = pkg.summary
    out = {"file": path, "package": pkg.package_name, "ue4": pkg.ue4, "ue5": pkg.ue5, "error": pkg.error,
           "unsupported": pkg.unsupported, "names": len(pkg.names), "imports": len(pkg.imports),
           "softpaths": len(pkg.softpaths), "exports": []}
    for e in pkg.exports:
        cls = pkg.object_path(e.class_index)
        item = {"index": e.index + 1, "path": pkg.export_path(e.index), "class": cls,
                "super": pkg.object_path(e.super_index), "outer": pkg.object_path(e.outer_index),
                "flags": "0x%X" % e.obj_flags, "size": e.serial_size}
        interesting = show_all or e.name.startswith("Default__") or e.name.endswith("_GEN_VARIABLE") or \
            (e.outer_index == 0 and e.is_asset) or cls.endswith("BlueprintGeneratedClass")
        if interesting and e.serial_size > 0:
            r = pkg.export_props(e.index)
            item["complete"] = r.complete
            item["warnings"] = r.warnings
            item["props"] = [{"name": p.name if p.index == 0 else "%s[%d]" % (p.name, p.index), "type": p.type,
                              "value": uasset.to_json(p.value) if as_json else uasset.display(p.value)} for p in r.props]
        out["exports"].append(item)
    if as_json:
        print(json.dumps(out, indent=1, ensure_ascii=False))
        return 0
    print("%s\n  package=%s ue4=%s ue5=%s names=%d imports=%d exports=%d softpaths=%d" % (
        path, pkg.package_name, pkg.ue4, pkg.ue5, len(pkg.names), len(pkg.imports), len(pkg.exports), len(pkg.softpaths)))
    if pkg.error or pkg.unsupported:
        print("  ERROR:", pkg.error or "UNSUPPORTED: " + pkg.unsupported)
    for it in out["exports"]:
        print("  [%d] %s  (%s) size=%d" % (it["index"], it["path"], it["class"], it["size"]))
        for w in it.get("warnings", ()):
            print("      ! " + w)
        for p in it.get("props", ()):
            print("      %s : %s = %s" % (p["name"], p["type"], p["value"]))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="bpdump")
    ap.add_argument("asset", nargs="?")
    ap.add_argument("--index", metavar="PROJECT")
    ap.add_argument("--query", nargs=3, metavar=("PROJECT", "CLASS", "PROP"))
    ap.add_argument("--all", action="store_true", help="parse properties of every export")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--actors", action="store_true", help="include placed actors in .umap/external actor packages")
    ap.add_argument("--cache")
    ap.add_argument("--workers", type=int)
    a = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if a.index or a.query:
        proj = a.index or a.query[0]
        idx = bpvalues.BPIndex(proj, a.cache, include_actors=a.actors)
        t = time.perf_counter()
        st = idx.build(workers=a.workers)
        el = time.perf_counter() - t
        if a.query:
            for o in idx.overrides_for(a.query[1], a.query[2]):
                print("%s  [%s] %s = %s" % (o.asset, o.kind, o.object, o.value[:200]))
            return 0
        print(json.dumps(st, indent=1))
        print("build wall time %.2fs, peak RSS (this process) %.0f MB" % (el, peak_ram_mb()))
        print("top owners by authored values:")
        for o, np_, nv in idx.classes_with_overrides()[:a.top]:
            print("  %-60s props=%-4d values=%d" % (o, np_, nv))
        return 0
    if not a.asset:
        ap.print_help()
        return 2
    return dump_asset(a.asset, a.all, a.json)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
