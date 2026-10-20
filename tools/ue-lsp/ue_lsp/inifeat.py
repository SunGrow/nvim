"""INI language features over the derived index. Columns are Python str indices; the server converts."""
import os
import re

from . import ini

K_CLASS, K_PROPERTY, K_VALUE, K_ENUMMEMBER, K_MODULE, K_FIELD, K_TEXT = 7, 10, 12, 20, 9, 5, 1
_IDENT_RE = re.compile(r"\b([EF][A-Z]\w*)\b")
BOOL_TYPES = {"bool"}
NUM_RE = re.compile(r"^(u?int(8|16|32|64)?|float|double|int)$")


def _fuzzy(prefix, label):
    if not prefix:
        return True
    p = prefix.lower()
    l = label.lower()
    if p in l:
        return True
    i = 0
    for ch in l:
        if ch == p[i]:
            i += 1
            if i == len(p):
                return True
    return False


def short(path):
    return os.path.basename(path)


def find_prop(cc, key):
    lk = key.lower()
    for p in cc["props"]:
        if p["name"].lower() == lk or (p.get("cvar") and p["cvar"].lower() == lk):
            return p
    return None


def enum_for_type(idx, typ):
    if not typ:
        return None
    for ident in _IDENT_RE.findall(typ):
        e = idx["enums"].get(ident)
        if e:
            return e
    return None


def struct_for_type(idx, typ):
    if not typ:
        return None
    for ident in _IDENT_RE.findall(typ):
        s = idx["structs"].get(ident)
        if s:
            return s
    return None


def _value_type(typ):
    if not typ:
        return None
    t = typ.replace("const ", "").strip()
    if t.startswith("TArray<") and t.endswith(">"):
        t = t[7:-1].strip()
    if t.startswith("TEnumAsByte<") and t.endswith(">"):
        t = t[12:-1].strip()
    return t


# ---------------------------------------------------------------- completion

def complete(idx, text, line, col, path=None, max_items=4000):
    ctx = ini.context_at(text, line, col)
    kind = ctx.get("kind")
    items = []
    incomplete = False
    if kind == "section":
        prefix = ctx["prefix"].rstrip("]")
        cat = ini.ini_category(path or "")
        seen = set()
        for lk, cc in idx["config_classes"].items():
            sec = cc["section"]
            if not _fuzzy(prefix, sec):
                continue
            seen.add(lk)
            rank = 0 if (cc["config"] or "").lower() == cat.lower() else 1
            rank = rank * 2 + (0 if (cc["own_props"] or cc["own_config"]) else 1)
            items.append({"label": sec, "kind": K_CLASS, "detail": "%s (config=%s)" % (cc["class"], cc["config"]),
                          "sortText": "%d%s" % (rank, sec.lower()), "filterText": "[" + sec,
                          "_edit": (line, ctx["start"], ctx["end"], "[%s]" % sec),
                          "data": {"t": "section", "s": lk}})
        for lk, s in idx["sections"].items():
            if lk in seen or not _fuzzy(prefix, s["name"]):
                continue
            items.append({"label": s["name"], "kind": K_MODULE,
                          "detail": "seen in %s" % short(s["occ"][0][0]) if s["occ"] else "ini section",
                          "sortText": "5" + s["name"].lower(), "filterText": "[" + s["name"],
                          "_edit": (line, ctx["start"], ctx["end"], "[%s]" % s["name"]),
                          "data": {"t": "section", "s": lk}})
    elif kind == "key":
        sec = (ctx.get("section") or "").lower()
        cc = idx["config_classes"].get(sec)
        prefix = ctx["prefix"]
        rest_has_eq = "=" in text.split("\n")[line][ctx["end"]:ctx["end"] + 1]
        have = set()
        if cc:
            for p in cc["props"]:
                names = [p["cvar"], p["name"]] if p.get("cvar") else [p["name"]]
                for i, nm in enumerate(names):
                    if nm.lower() in have or not _fuzzy(prefix, nm):
                        continue
                    have.add(nm.lower())
                    is_arr = (p.get("type") or "").startswith("TArray")
                    ins = nm if rest_has_eq else nm + "="
                    start = ctx["start"]
                    if is_arr and not ctx.get("op") and not rest_has_eq:
                        ins = "+" + ins
                    items.append({"label": nm, "kind": K_PROPERTY,
                                  "detail": "%s  (%s%s)" % (p.get("type"), p["owner"], ", cvar" if i == 0 and p.get("cvar") else ""),
                                  "sortText": "0%s" % nm.lower(), "filterText": nm,
                                  "_edit": (line, start, ctx["end"], ins),
                                  "data": {"t": "key", "s": sec, "k": nm.lower()}})
        s = idx["sections"].get(sec)
        if s:
            for lk, k in s["keys"].items():
                if lk in have or not _fuzzy(prefix, k["name"]):
                    continue
                have.add(lk)
                ins = k["name"] if rest_has_eq else k["name"] + "="
                items.append({"label": k["name"], "kind": K_FIELD,
                              "detail": "seen %dx, e.g. %s" % (k["n"], short(k["occ"][0][0])) if k["occ"] else "seen",
                              "sortText": "1%s" % lk, "filterText": k["name"],
                              "_edit": (line, ctx["start"], ctx["end"], ins),
                              "data": {"t": "key", "s": sec, "k": lk}})
    elif kind == "value":
        items = value_items(idx, ctx, line)
    elif kind == "struct_member":
        sec = (ctx.get("section") or "").lower()
        cc = idx["config_classes"].get(sec)
        p = find_prop(cc, ctx["key"]) if cc else None
        st = struct_for_type(idx, p.get("type")) if p else None
        if st:
            for m in st["props"]:
                if _fuzzy(ctx["prefix"], m["name"]):
                    items.append({"label": m["name"], "kind": K_FIELD, "detail": m.get("type"),
                                  "_edit": (line, ctx["start"], col, m["name"] + "="),
                                  "filterText": m["name"]})
    if len(items) > max_items:
        items = sorted(items, key=lambda x: x.get("sortText", x["label"]))[:max_items]
        incomplete = True
    return items, incomplete or kind == "section"


def value_items(idx, ctx, line):
    sec = (ctx.get("section") or "").lower()
    key = ctx.get("key") or ""
    cc = idx["config_classes"].get(sec)
    p = find_prop(cc, key) if cc else None
    items = []
    rng = (line, ctx["start"], ctx["end"])
    if p:
        is_cvar = bool(p.get("cvar")) and p["cvar"].lower() == key.lower()
        vt = _value_type(p.get("type"))
        e = enum_for_type(idx, p.get("type"))
        if vt in BOOL_TYPES:
            for v in ("True", "False"):
                items.append({"label": v, "kind": K_VALUE, "detail": "bool", "_edit": rng + (v,)})
        elif e:
            for i, v in enumerate(e["values"]):
                if v.get("hidden") or v["name"].endswith("_MAX") or v["name"] == "MAX":
                    continue
                if is_cvar and v.get("value") is not None:
                    label = str(v["value"])
                    detail = "%s::%s%s" % (e["name"], v["name"], (" — " + v["display"]) if v.get("display") else "")
                else:
                    label = v["name"]
                    detail = "%s%s" % (e["name"], (" — " + v["display"]) if v.get("display") else "")
                items.append({"label": label, "kind": K_ENUMMEMBER, "detail": detail,
                              "sortText": "%04d" % i, "filterText": "%s %s" % (label, v.get("display") or v["name"]),
                              "_edit": rng + (label,),
                              "data": {"t": "enumval", "e": e["name"], "v": v["name"]}})
    # previously seen values for this key (non-class sections and extra hints)
    s = idx["sections"].get(sec)
    k = s["keys"].get(ini.strip_key(key).lower()) if s else None
    if k and not items:
        seen = []
        for path, ln, op, val in k["occ"]:
            if val and val not in seen and len(val) < 120:
                seen.append(val)
                items.append({"label": val, "kind": K_TEXT, "detail": "seen in %s:%d" % (short(path), ln + 1),
                              "sortText": "9%02d" % len(seen), "_edit": rng + (val,)})
    if not items and p is None and k is None:
        return []
    return items


def resolve(idx, item):
    d = item.get("data") or {}
    t = d.get("t")
    md = None
    if t == "section":
        md = section_md(idx, d["s"])
    elif t == "key":
        md = key_md(idx, d["s"], d["k"], None)
    elif t == "enumval":
        e = idx["enums"].get(d["e"])
        if e:
            for v in e["values"]:
                if v["name"] == d["v"]:
                    md = "**%s::%s** = %s\n\n%s\n\n_%s:%d_" % (e["name"], v["name"], v.get("value"),
                                                              v.get("doc") or v.get("display") or "",
                                                              short(e["file"]), v["line"])
    if md:
        item["documentation"] = {"kind": "markdown", "value": md}
    return item


# ---------------------------------------------------------------- hover / definition

def section_md(idx, lsec, cur_path=None):
    cc = idx["config_classes"].get(lsec)
    s = idx["sections"].get(lsec)
    out = []
    if cc:
        out.append("**%s** : %s" % (cc["class"], cc.get("parent") or "?"))
        flags = ", ".join(["config=%s" % cc["config"]] + cc["flags"])
        out.append("`%s` · module `%s`%s" % (flags, cc["module"], (" · “%s”" % cc["display"]) if cc.get("display") else ""))
        if cc.get("doc"):
            out += ["", cc["doc"]]
        out += ["", "%d config properties · _%s:%d_" % (len(cc["props"]), cc["file"], cc["line"])]
    if s and s["occ"]:
        out += ["", "Seen in: " + ", ".join("%s:%d" % (short(p), l + 1) for p, l in s["occ"][:6]
                                             if not cur_path or os.path.normcase(p) != os.path.normcase(cur_path))]
    return "\n".join(out) if out else None


def key_md(idx, lsec, key, cur_path):
    cc = idx["config_classes"].get(lsec)
    p = find_prop(cc, key) if cc else None
    out = []
    if p:
        out.append("**%s** `%s`" % (p["name"], p.get("type")))
        extra = ["owner `%s`" % p["owner"]]
        if p.get("cvar"):
            extra.append("cvar `%s`" % p["cvar"])
        if p.get("global"):
            extra.append("globalconfig")
        out.append(" · ".join(extra))
        doc = (p.get("doc") or "").replace("\\n", "\n")
        if doc:
            out += ["", doc]
        e = enum_for_type(idx, p.get("type"))
        if e:
            vals = [v for v in e["values"] if not v.get("hidden")][:24]
            out += ["", "Values: " + ", ".join("`%s`%s" % (v["name"], ("=%s" % v["value"]) if v.get("value") is not None else "") for v in vals)]
        out += ["", "_%s:%d_" % (p["file"], p["line"])]
    s = idx["sections"].get(lsec)
    k = s["keys"].get(ini.strip_key(key).lower()) if s else None
    if k and k["occ"]:
        chain = ["`%s%s=%s` — %s:%d" % (op, k["name"], val, short(path), ln + 1) for path, ln, op, val in k["occ"]
                 if not cur_path or os.path.normcase(path) != os.path.normcase(cur_path)]
        if chain:
            out += ["", "Value chain (Base → Default, indexed files):", ""] + ["%d. %s" % (i + 1, c) for i, c in enumerate(chain)]
    return "\n".join(out) if out else None


def hover(idx, text, line, col, path=None):
    w = ini.word_at(text, line, col)
    if not w:
        return None
    kind, word, section, s, e = w
    if kind == "section":
        md = section_md(idx, word.lower(), path)
    elif kind == "key":
        md = key_md(idx, (section or "").lower(), word, path)
    else:
        md = None
        cc = idx["config_classes"].get((section or "").lower())
        lines = text.split("\n")
        cur = lines[line]
        eq = cur.find("=")
        key = ini.strip_key(cur[:eq].lstrip().lstrip(ini.OPS))
        p = find_prop(cc, key) if cc else None
        en = enum_for_type(idx, p.get("type")) if p else None
        if en:
            val = word.strip()
            for v in en["values"]:
                if v["name"] == val or str(v.get("value")) == val:
                    md = "**%s::%s** = %s\n\n%s" % (en["name"], v["name"], v.get("value"),
                                                   v.get("doc") or v.get("display") or "")
        elif p:
            md = "`%s` (%s)" % (p.get("type"), p["name"])
    if not md:
        return None
    return md, (line, s, e)


def definition(idx, text, line, col, path=None):
    w = ini.word_at(text, line, col)
    if not w:
        return None
    kind, word, section, s, e = w
    lsec = (word if kind == "section" else (section or "")).lower()
    cc = idx["config_classes"].get(lsec)
    if kind == "section":
        if cc:
            return [(cc["file"], cc["line"])]
        sec = idx["sections"].get(lsec)
    elif kind == "key":
        p = find_prop(cc, word) if cc else None
        if p:
            return [(p["file"], p["line"])]
        sec = idx["sections"].get(lsec)
        if sec:
            k = sec["keys"].get(word.lower())
            if k:
                locs = [(pth, ln + 1) for pth, ln, _o, _v in k["occ"]
                        if not path or os.path.normcase(pth) != os.path.normcase(path)]
                return locs[:1] or None
        return None
    else:
        return None
    if sec:
        locs = [(pth, ln + 1) for pth, ln in sec["occ"] if not path or os.path.normcase(pth) != os.path.normcase(path)]
        return locs[:1] or None
    return None


# ---------------------------------------------------------------- diagnostics

def _seen_elsewhere(occ, path):
    if not occ:
        return False
    if not path:
        return True
    np = os.path.normcase(os.path.normpath(path))
    return any(os.path.normcase(o[0]) != np for o in occ)


def diagnostics(idx, text, path=None):
    """Returns list of (line, start, end, severity, message). severity: 2 warning, 4 hint."""
    out = []
    cc = None
    sec_key = None
    cvar_section = False
    lines = text.split("\n")
    for i, raw in enumerate(lines):
        line = raw.rstrip("\r")
        s = line.lstrip()
        if not s or s[0] in ";#":
            continue
        indent = len(line) - len(s)
        if s[0] == "[":
            j = s.find("]")
            name = s[1:j] if j > 0 else s[1:]
            sec_key = name.lower()
            cc = idx["config_classes"].get(sec_key)
            cvar_section = bool(cc) and any(p.get("cvar") for p in cc["props"])
            if cc is None and " " not in name:
                sec = idx["sections"].get(sec_key)
                if not (sec and _seen_elsewhere(sec["occ"], path)):
                    msg = "Unknown section: no config class and not seen in other indexed ini files"
                    if name.startswith("/Script/"):
                        cls = name.split(".")[-1]
                        cn = idx["class_names"].get(("u" + cls).lower()) or idx["class_names"].get(("a" + cls).lower())
                        if cn:
                            msg = "Section class %s exists but has no config properties" % cls
                    out.append((i, indent, indent + len(s.rstrip()), 4, msg))
            continue
        if cc is None:
            continue
        eq = line.find("=")
        op = s[0] if s[0] in ini.OPS else ""
        kraw = line[indent + len(op):eq if eq >= 0 else len(line)]
        key = ini.strip_key(kraw)
        if not key:
            continue
        if find_prop(cc, key):
            continue
        if cvar_section and "." in key:
            continue
        sec = idx["sections"].get(sec_key)
        k = sec["keys"].get(key.lower()) if sec else None
        if k and _seen_elsewhere(k["occ"], path):
            continue
        st = indent + len(op) + (len(kraw) - len(kraw.lstrip()))
        out.append((i, st, st + len(key), 2,
                    "Unknown key '%s' for %s: not a config property of %s (or parents), not seen in other indexed ini files"
                    % (key, cc["section"], cc["class"])))
    return out
