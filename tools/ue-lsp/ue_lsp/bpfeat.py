"""Blueprint/asset value features for C++ headers: code lens + hover on UPROPERTY declarations.

Data comes from bpvalues.BPIndex (authored values read from .uasset files). This module only maps
header text positions to (class, property) and formats results.
"""
import os
import re

from . import headers

_MACRO_RE = re.compile(r"\b(UCLASS|USTRUCT|UINTERFACE|UPROPERTY)\s*\(")
_NAME_TAIL_RE = re.compile(r"(\w+)\s*(?:=|\{|\[|:(?!:)|;)")

MAX_HOVER_ROWS = 15


def property_decls(text):
    """[(class_name, prop_name, line0, col_start, col_end)] for UPROPERTYs declared in UCLASS bodies."""
    out = []
    owner = None
    for m in _MACRO_RE.finditer(text):
        ls = text.rfind("\n", 0, m.start()) + 1
        prefix = text[ls:m.start()].lstrip()
        if prefix.startswith(("#", "//", "*")):
            continue
        close = headers.balanced(text, m.end())
        if close < 0:
            continue
        kind = m.group(1)
        if kind in ("UCLASS", "UINTERFACE", "USTRUCT"):
            dm = headers._CLASS_DECL_RE.match(text, close + 1) or headers._CLASS_DECL_RE.search(text, close + 1, close + 400)
            owner = dm.group(1) if dm and kind == "UCLASS" else None
            continue
        if owner is None:
            continue
        _typ, name = headers._parse_prop_decl(text, close + 1)
        if not name:
            continue
        semi = text.find(";", close + 1)
        seg_end = semi if 0 <= semi - close < 600 else close + 600
        pos = -1
        for nm in re.finditer(r"\b%s\b" % re.escape(name), text[close + 1:seg_end]):
            pos = close + 1 + nm.start()
        if pos < 0:
            continue
        line0 = text.count("\n", 0, pos)
        col = pos - (text.rfind("\n", 0, pos) + 1)
        out.append((owner, name, line0, col, col + len(name)))
    return out


def decl_at(text, line0, col):
    """(class, prop) when the cursor is on a UPROPERTY declaration line (anywhere on the name's line)."""
    for c, p, l, s, e in property_decls(text):
        if l == line0:
            return c, p, l, s, e
    return None


def short_asset(pkg):
    return pkg.rsplit("/", 1)[-1] if pkg else "?"


def rows(overrides):
    """Stable, de-duplicated list of dicts for clients (picker) and hover."""
    seen = set()
    out = []
    for o in sorted(overrides, key=lambda o: (o.asset, o.object, o.prop)):
        k = (o.asset, o.object, o.prop, o.value)
        if k in seen:
            continue
        seen.add(k)
        out.append({"asset": o.asset, "name": short_asset(o.asset), "object": o.object, "kind": o.kind,
                    "prop": o.prop, "value": o.value, "type": o.type})
    return out


def _cell(s, n=80):
    s = str(s).replace("|", "\\|").replace("\n", " ")
    return s if len(s) <= n else s[:n - 1] + "…"


def hover_md(cls, prop, rs):
    if not rs:
        return None
    lines = ["**Blueprint/asset values** of `%s::%s` (%d)" % (cls, prop, len(rs)), "",
             "| Asset | Object | Value |", "|---|---|---|"]
    for r in rs[:MAX_HOVER_ROWS]:
        obj = "CDO" if r["object"] in ("CDO", "") else r["object"]
        lines.append("| %s | %s | `%s` |" % (_cell(r["name"], 40), _cell(obj, 30), _cell(r["value"])))
    if len(rs) > MAX_HOVER_ROWS:
        lines.append("")
        lines.append("…and %d more (code lens / `<leader>Uv` lists all)" % (len(rs) - MAX_HOVER_ROWS))
    return "\n".join(lines)


def lens_title(rs):
    if len(rs) == 1:
        r = rs[0]
        v = r["value"] if len(r["value"]) <= 40 else r["value"][:39] + "…"
        return "BP: %s = %s" % (r["name"], v)
    return "%d BP values" % len(rs)


def lenses(text, lookup):
    """lookup(cls, prop) -> rows. Returns [(line0, col_start, col_end, cls, prop, rows)]."""
    out = []
    for c, p, l, s, e in property_decls(text):
        rs = lookup(c, p)
        if rs:
            out.append((l, s, e, c, p, rs))
    return out


def is_header(path):
    return os.path.splitext(path or "")[1].lower() in (".h", ".hpp", ".inl")
