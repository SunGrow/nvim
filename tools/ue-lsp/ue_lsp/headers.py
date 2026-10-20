"""Per-header extraction of UCLASS / config UPROPERTY / UENUM data (regex streaming, no full C++ parse)."""
import re

_MACRO_RE = re.compile(rb"\b(UCLASS|USTRUCT|UINTERFACE|UENUM|UPROPERTY)\s*\(")
_CLASS_DECL_RE = re.compile(
    r"\s*(?:class|struct)\s+(?:alignas\s*\([^)]*\)\s*)?(?:[A-Z0-9_]+_API\s+)?(?:UE_DEPRECATED\s*\([^)]*\)\s*)?"
    r"(\w+)\s*(?:final\s*)?(?::\s*(?:public|protected|private)?\s*([\w:]+(?:<[^>{]*>)?))?\s*\{")
_ENUM_DECL_RE = re.compile(
    r"\s*(?:enum\s+(?:class\s+|struct\s+)?(\w+)\s*(?::\s*[\w:]+\s*)?\{|namespace\s+(\w+)\s*\{\s*enum\s+(\w+)\s*(?::\s*[\w:]+\s*)?\{)")
_CONFIG_SPEC_RE = re.compile(r"(?<![\w=\"])(config|globalconfig)(?![\w=])", re.I)
_DISPLAY_RE = re.compile(r"\bDisplayName\s*=\s*\"((?:[^\"\\]|\\.)*)\"", re.I)
_CVAR_RE = re.compile(r"\bConsoleVariable\s*=\s*\"([^\"]*)\"", re.I)
_TOOLTIP_RE = re.compile(r"\bToolTip\s*=\s*\"((?:[^\"\\]|\\.)*)\"", re.I)
_CONFIG_EQ_RE = re.compile(r"\bconfig\s*=\s*(\w+)", re.I)
_UMETA_KEY_RE = re.compile(r"UMETA\s*\(\s*(\w+)")
_META_KEYS_RE = re.compile(r"\bmeta\s*=\s*\(", re.I)
_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


def balanced(text, start):
    """text[start] is just after an opening '('. Returns index of matching ')' (or -1). Skips strings/comments."""
    depth = 1
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and text[j] != c:
                if text[j] == "\\":
                    j += 1
                elif text[j] == "\n" and c == "'":
                    break
                j += 1
            i = j
        elif c == "/" and i + 1 < n:
            nx = text[i + 1]
            if nx == "/":
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
            if nx == "*":
                j = text.find("*/", i + 2)
                i = n if j < 0 else j + 2
                continue
        i += 1
    return -1


def split_args(s):
    """Split macro args at depth-0 commas (respects parens and strings). Returns list of (text, offset)."""
    out = []
    depth = 0
    cur = 0
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == "\\":
                    j += 1
                j += 1
            i = j
        elif c == "/" and i + 1 < n and s[i + 1] == "/":
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == "/" and i + 1 < n and s[i + 1] == "*":
            j = s.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c == "," and depth == 0:
            out.append((s[cur:i], cur))
            cur = i + 1
        i += 1
    out.append((s[cur:], cur))
    return out


def doc_above(text, pos):
    """Doc comment block (/** */ or // lines) immediately above position pos."""
    ls = text.rfind("\n", 0, pos)
    if ls < 0:
        return ""
    end = ls
    k = end
    while k > 0 and text[k - 1] in " \t\r\n":
        k -= 1
    if k >= 2 and text[k - 2:k] == "*/":
        s = text.rfind("/*", 0, k - 2)
        if s < 0:
            return ""
        body = text[s + 2:k - 2]
        lines = [l.strip().lstrip("*").strip() for l in body.splitlines()]
        return "\n".join(l for l in lines if l).strip()
    # consecutive // lines
    lines = []
    while k > 0:
        lstart = text.rfind("\n", 0, k) + 1
        line = text[lstart:k].strip()
        if line.startswith("//"):
            lines.append(line.lstrip("/").strip())
            k = lstart - 1
            while k > 0 and text[k - 1] in "\r":
                k -= 1
            if k <= 0:
                break
        else:
            break
    return "\n".join(reversed(lines)).strip()


def _strip_comments(s):
    return _COMMENT_RE.sub(" ", s)


def _parse_prop_decl(text, start):
    """Parse declaration after a UPROPERTY(...) up to ';'. Returns (type, name)."""
    end = text.find(";", start)
    if end < 0 or end - start > 600:
        end = start + min(600, len(text) - start)
    decl = _strip_comments(text[start:end]).strip()
    # cut initializers
    depth = 0
    cut = len(decl)
    for i, c in enumerate(decl):
        if c in "<(":
            depth += 1
        elif c in ">)":
            depth -= 1
        elif depth == 0 and c in "={[":
            cut = i
            break
        elif depth == 0 and c == ":" and not (i + 1 < len(decl) and decl[i + 1] == ":") and not (i > 0 and decl[i - 1] == ":"):
            cut = i  # bitfield
            break
    bitfield = cut < len(decl) and decl[cut] == ":"
    head = decl[:cut].strip()
    m = re.search(r"(\w+)\s*$", head)
    if not m:
        return None, None
    name = m.group(1)
    typ = head[:m.start()].strip()
    typ = re.sub(r"\s+", " ", typ)
    for kw in ("mutable ", "static "):
        if typ.startswith(kw):
            typ = typ[len(kw):]
    if bitfield:
        typ = "bool"
    return typ, name


def line_of(text, pos, _cache={}):
    return text.count("\n", 0, pos) + 1


def parse_header(data):
    """data: bytes. Returns dict or None when nothing relevant."""
    if b"UCLASS" not in data and b"UENUM" not in data and b"USTRUCT" not in data and b"UINTERFACE" not in data:
        return None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    classes = []
    structs = []
    enums = []
    umeta_keys = {}
    owner = None  # current class dict (for UPROPERTY ownership)
    line_cache_pos = 0
    line_cache_n = 1
    for m in re.finditer(r"\b(UCLASS|USTRUCT|UINTERFACE|UENUM|UPROPERTY)\s*\(", text):
        kind = m.group(1)
        mstart = m.start()
        # skip macro definitions / comments on the same line
        ls = text.rfind("\n", 0, mstart) + 1
        prefix = text[ls:mstart].lstrip()
        if prefix.startswith("#") or prefix.startswith("//") or prefix.startswith("*"):
            continue
        close = balanced(text, m.end())
        if close < 0:
            continue
        args = text[m.end():close]
        # incremental line counting
        if mstart >= line_cache_pos:
            line_cache_n += text.count("\n", line_cache_pos, mstart)
        else:
            line_cache_n = text.count("\n", 0, mstart) + 1
        line_cache_pos = mstart
        line = line_cache_n
        if kind == "UPROPERTY":
            if owner is None or owner.get("_kind") == "other":
                continue
            if owner["_kind"] == "struct":
                typ, name = _parse_prop_decl(text, close + 1)
                if name:
                    owner["props"].append({"name": name, "type": typ, "line": line})
                continue
            if not _CONFIG_SPEC_RE.search(_strip_meta(args)):
                continue
            typ, name = _parse_prop_decl(text, close + 1)
            if not name:
                continue
            specs = [a.strip().split("=")[0].strip().lower() for a, _ in split_args(_strip_meta(args))]
            cv = _CVAR_RE.search(args)
            tt = _TOOLTIP_RE.search(args)
            dn = _DISPLAY_RE.search(args)
            doc = doc_above(text, mstart)
            if not doc and tt:
                doc = tt.group(1)
            owner["props"].append({
                "name": name, "type": typ, "line": line, "doc": doc,
                "cvar": cv.group(1) if cv else None,
                "global": "globalconfig" in specs,
                "display": dn.group(1) if dn else None,
            })
            continue
        if kind in ("UCLASS", "UINTERFACE", "USTRUCT"):
            dm = _CLASS_DECL_RE.match(text, close + 1)
            if not dm:
                # tolerate comments / deprecation macros between macro and class keyword
                dm = _CLASS_DECL_RE.search(text, close + 1, close + 400)
            if not dm:
                owner = {"_kind": "other"}
                continue
            if kind != "UCLASS":
                owner = {"_kind": "other"}
                if kind == "USTRUCT":
                    structs.append({"name": dm.group(1), "parent": _clean_parent(dm.group(2)), "line": line,
                                    "props": [], "_kind": "struct"})
                    owner = structs[-1]
                elif kind == "UINTERFACE":
                    classes.append({"name": dm.group(1), "parent": _clean_parent(dm.group(2)), "line": line,
                                    "config": None, "flags": [], "doc": "", "display": None, "props": [],
                                    "_kind": "class"})
                    owner = classes[-1]
                continue
            sa = _strip_meta(args)
            flags = [a.strip().split("=")[0].strip().lower() for a, _ in split_args(sa) if a.strip()]
            cm = _CONFIG_EQ_RE.search(sa)
            dn = _DISPLAY_RE.search(args)
            c = {"name": dm.group(1), "parent": _clean_parent(dm.group(2)), "line": line,
                 "config": cm.group(1) if cm else None,
                 "flags": [f for f in flags if f in _CLASS_FLAGS],
                 "doc": doc_above(text, mstart), "display": dn.group(1) if dn else None,
                 "props": [], "_kind": "class"}
            classes.append(c)
            owner = c
            continue
        if kind == "UENUM":
            em = _ENUM_DECL_RE.match(text, close + 1)
            if not em:
                continue
            if em.group(1):
                ename = em.group(1)
                ns = False
            else:
                ename = em.group(2)
                ns = True
            body_start = em.end()
            body_end = _find_brace_end(text, body_start)
            if body_end < 0:
                continue
            body_line = line + text.count("\n", mstart, body_start)
            values = _parse_enum_body(text, body_start, body_end, body_line, umeta_keys)
            enums.append({"name": ename, "line": line, "doc": doc_above(text, mstart), "values": values,
                          "namespaced": ns, "flags": "flags" in args.lower()})
    if classes and "OverrideConfigSection" in text:
        for om in _OVERRIDE_SECTION_RE.finditer(text):
            ln = text.count("\n", 0, om.start()) + 1
            owner_c = None
            for c in classes:
                if c["line"] < ln:
                    owner_c = c
            if owner_c is not None:
                owner_c["section_override"] = om.group(1)
    for c in classes:
        c.pop("_kind", None)
    for c in structs:
        c.pop("_kind", None)
    if not classes and not enums and not structs:
        return None
    return {"classes": classes, "enums": enums, "structs": structs, "umeta": umeta_keys}


_OVERRIDE_SECTION_RE = re.compile(r"OverrideConfigSection\s*\([^)]*\)[^{;]*\{[^}]*?InOutSectionName\s*=\s*TEXT\(\s*\"([^\"]+)\"", re.S)

_CLASS_FLAGS = {"defaultconfig", "globaluserconfig", "projectuserconfig", "perobjectconfig",
                "configdonotcheckdefaults", "abstract", "deprecated", "perplatformconfig", "editorconfig"}


def _clean_parent(p):
    if not p:
        return None
    p = p.split("<")[0]
    return p.split("::")[-1]


def _strip_meta(args):
    """Remove meta=( ... ) groups so their contents don't look like specifiers."""
    out = []
    i = 0
    while True:
        m = _META_KEYS_RE.search(args, i)
        if not m:
            out.append(args[i:])
            break
        out.append(args[i:m.start()])
        e = balanced(args, m.end())
        if e < 0:
            break
        i = e + 1
    return "".join(out)


def _find_brace_end(text, start):
    depth = 1
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        elif c == "/" and i + 1 < n:
            if text[i + 1] == "/":
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
            if text[i + 1] == "*":
                j = text.find("*/", i + 2)
                i = n if j < 0 else j + 2
                continue
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            i = j
        i += 1
    return -1


_ENTRY_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*(?:=\s*([^,]*?))?\s*(UMETA\s*\((.*)\))?\s*$", re.S)
_INT_RE = re.compile(r"^\(?\s*(-?(?:0x[0-9a-fA-F]+|\d+))[uUlL]*\s*\)?$")
_SHIFT_RE = re.compile(r"^\(?\s*1[uU]?\s*<<\s*(\d+)\s*\)?$")


def _parse_enum_body(text, start, end, base_line, umeta_keys):
    body = text[start:end]
    values = []
    counter = 0
    known = {}
    cur_line = base_line
    last_off = 0
    for raw, off in split_args(body):
        lead = off + len(raw) - len(raw.lstrip())
        cur_line += body.count("\n", last_off, lead)
        last_off = lead
        # leading comments are docs; trailing // comment belongs to next entry in UE style mostly - keep simple
        doc_parts = re.findall(r"/\*\*?(.*?)\*/|//+([^\n]*)", raw, re.S)
        code = _strip_comments(raw).strip()
        if not code or code.startswith("#"):
            # preprocessor lines inside enums: strip them
            code = "\n".join(l for l in code.splitlines() if not l.strip().startswith("#")).strip()
            if not code:
                continue
        code = "\n".join(l for l in code.splitlines() if not l.strip().startswith("#")).strip()
        m = _ENTRY_RE.match(code)
        if not m:
            continue
        name = m.group(1)
        expr = (m.group(2) or "").strip()
        val = None
        if expr:
            im = _INT_RE.match(expr)
            sm = _SHIFT_RE.match(expr)
            if im:
                val = int(im.group(1), 0)
            elif sm:
                val = 1 << int(sm.group(1))
            elif expr in known and known[expr] is not None:
                val = known[expr]
        else:
            val = counter if counter is not None else None
        counter = (val + 1) if val is not None else None
        known[name] = val
        disp = None
        hidden = False
        if m.group(3):
            um = m.group(4)
            dm = _DISPLAY_RE.search(um)
            disp = dm.group(1) if dm else None
            hidden = bool(re.search(r"\bHidden\b", um, re.I))
            for a, _o in split_args(um):
                k = a.split("=")[0].strip()
                if k.isidentifier():
                    umeta_keys[k] = umeta_keys.get(k, 0) + 1
        doc = " ".join((a or b).strip(" *\n\t") for a, b in doc_parts).strip()
        if not doc and m.group(3):
            tm = _TOOLTIP_RE.search(m.group(4))
            if tm:
                doc = tm.group(1)
        stripped = len(raw) - len(raw.lstrip())
        code_off = raw.find(name, stripped)
        eline = cur_line + raw.count("\n", stripped, max(code_off, stripped))
        values.append({"name": name, "value": val, "display": disp, "hidden": hidden, "doc": doc, "line": eline})
    return values

