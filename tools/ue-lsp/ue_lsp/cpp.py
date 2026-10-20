"""C++ reflection-macro context detection, completion, hover and diagnostics."""
import re

from .headers import balanced, split_args, _strip_meta

MACROS = ("UPROPERTY", "UFUNCTION", "UCLASS", "USTRUCT", "UENUM", "UINTERFACE", "UPARAM", "UMETA", "UDELEGATE")
_MACRO_RE = re.compile(r"\b(UPROPERTY|UFUNCTION|UCLASS|USTRUCT|UENUM|UINTERFACE|UPARAM|UMETA|UDELEGATE)\s*\(")
_META_OPEN_RE = re.compile(r"\bmeta\s*=\s*$", re.I)
_IDENT_TAIL_RE = re.compile(r"[A-Za-z_]\w*$")
WINDOW = 12000


def _in_comment(text, pos):
    ls = text.rfind("\n", 0, pos) + 1
    pre = text[ls:pos].lstrip()
    if pre.startswith("//") or pre.startswith("#"):
        return True
    if "//" in text[ls:pos] and not '"' in text[ls:pos]:
        return True
    return text.rfind("/*", 0, pos) > text.rfind("*/", 0, pos)


def context_at(text, offset):
    """Return the macro context at offset, or None.

    {"macro", "where": "spec"|"spec_value"|"meta"|"meta_value"|"nested", "prefix", "start", "key"}
    """
    lo = max(0, offset - WINDOW)
    m = None
    for mm in _MACRO_RE.finditer(text, lo, offset):
        if not _in_comment(text, mm.start()):
            m = mm
    if m is None:
        return None
    macro = m.group(1)
    # frames: [kind, seg_start]
    frames = [["macro", m.end()]]
    i = m.end()
    n = offset
    while i < n:
        c = text[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < len(text) and text[j] != c and text[j] != "\n":
                if text[j] == "\\":
                    j += 1
                j += 1
            if j >= n:
                return {"macro": macro, "where": "string"}
            i = j + 1
            continue
        if c == "/" and i + 1 < len(text) and text[i + 1] in "/*":
            if text[i + 1] == "/":
                j = text.find("\n", i)
            else:
                j = text.find("*/", i + 2)
                j = -1 if j < 0 else j + 2
            if j < 0 or j > n:
                return None
            i = j
            continue
        if c == "(":
            seg = text[frames[-1][1]:i]
            kind = "meta" if _META_OPEN_RE.search(seg) and frames[-1][0] == "macro" else "nested"
            frames.append([kind, i + 1])
        elif c == ")":
            frames.pop()
            if not frames:
                return None  # macro closed before cursor
        elif c == ",":
            frames[-1][1] = i + 1
        elif c in ";{}":
            return None
        i += 1
    kind, seg_start = frames[-1]
    seg = text[seg_start:offset]
    if kind == "nested":
        return {"macro": macro, "where": "nested"}
    eq = seg.find("=")
    if eq >= 0:
        key = seg[:eq].strip()
        val = seg[eq + 1:]
        vstripped = val.lstrip()
        tm = _IDENT_TAIL_RE.search(vstripped)
        prefix = tm.group(0) if tm else ""
        return {"macro": macro, "where": "spec_value" if kind == "macro" else "meta_value", "key": key,
                "prefix": prefix, "start": offset - len(prefix)}
    tm = _IDENT_TAIL_RE.search(seg)
    prefix = tm.group(0) if tm else ""
    if seg[:len(seg) - len(prefix)].strip():
        return {"macro": macro, "where": "nested"}  # e.g. `Foo Bar|`
    return {"macro": macro, "where": "spec" if kind == "macro" else "meta", "prefix": prefix,
            "start": offset - len(prefix)}


def word_range(text, offset):
    s = offset
    while s > 0 and (text[s - 1].isalnum() or text[s - 1] == "_"):
        s -= 1
    e = offset
    while e < len(text) and (text[e].isalnum() or text[e] == "_"):
        e += 1
    return s, e


# ---------------------------------------------------------------- lookups

def spec_entries(specdb, macro):
    return specdb["macros"].get(macro, {})


def meta_entries(specdb, macro, umeta_counts=None):
    ctxs = set(_META_CTX.get(macro, ("field",)))
    out = {}
    for k, v in specdb["meta"].items():
        if ctxs.intersection(v["contexts"]) or "field" in v["contexts"]:
            out[k] = v
    if macro == "UMETA" and umeta_counts:
        for k, n in umeta_counts.items():
            lk = k.lower()
            if lk not in out:
                out[lk] = {"name": k, "doc": "Observed in %d UMETA() uses in indexed headers." % n,
                           "contexts": ["umeta"], "line": None}
    return out


from .specs import MACRO_META as _META_CTX, MACRO_TABLE  # noqa: E402


def spec_doc_md(macro, e, specdb):
    lines = ["**%s** — `%s` specifier" % (e["name"], macro)]
    if e.get("value_type") and e["value_type"] != "None":
        lines.append("Value: `%s`" % e["value_type"])
    if e.get("doc"):
        lines += ["", e["doc"]]
    src = []
    if e.get("file"):
        src.append("UHT table `%s` (%s:%d)" % (e.get("table"), e["file"].split("\\")[-1].split("/")[-1], e["line"]))
    if e.get("doc_line"):
        src.append("ObjectMacros.h:%d" % e["doc_line"])
    if src:
        lines += ["", "_" + "; ".join(src) + "_"]
    return "\n".join(lines)


def meta_doc_md(e):
    lines = ["**%s** — meta key" % e["name"]]
    if e.get("doc"):
        lines += ["", e["doc"]]
    if e.get("line"):
        lines += ["", "_ObjectMacros.h:%d (UM: %s)_" % (e["line"], ", ".join(e.get("contexts", [])))]
    return "\n".join(lines)


_STOP_RE = re.compile(r"[;{}]")
_STR_RE = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def _mask_strings(s):
    return _STR_RE.sub(lambda m: " " * len(m.group(0)), s)


def diagnostics(text, specdb, max_items=500):
    """Unknown specifier warnings. Returns list of (start_offset, end_offset, message)."""
    out = []
    for m in _MACRO_RE.finditer(text):
        macro = m.group(1)
        if macro == "UMETA":
            continue
        if _in_comment(text, m.start()):
            continue
        ls = text.rfind("\n", 0, m.start()) + 1
        if text[ls:m.start()].lstrip().startswith("#"):
            continue
        # skip if line is part of a #define continuation
        if ls >= 2 and text[ls - 2] == "\\":
            continue
        table = specdb["macros"].get(macro)
        if not table:
            continue
        close = balanced(text, m.end())
        args = text[m.end():close] if close >= 0 else text[m.end():]
        # unclosed macro (user is typing) or runaway match: stop at the first ; { } and
        # skip the trailing, possibly half-typed, argument
        cut = _STOP_RE.search(_mask_strings(args))
        partial = close < 0 or cut is not None
        if cut is not None:
            args = args[:cut.start()]
        segs = split_args(args)
        if partial:
            segs = segs[:-1]
        for a, off in segs:
            key = a.split("=", 1)[0]
            ks = key.strip()
            if not ks:
                continue
            if not re.match(r"^[A-Za-z_]\w*$", ks):
                continue
            if ks.lower() in table:
                continue
            s = m.end() + off + (len(key) - len(key.lstrip()))
            out.append((s, s + len(ks), "Unknown %s specifier '%s' (not accepted by UHT table '%s' or its parents)" % (
                macro, ks, MACRO_TABLE[macro])))
            if len(out) >= max_items:
                return out
    return out
