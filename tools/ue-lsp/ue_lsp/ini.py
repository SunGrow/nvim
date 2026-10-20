"""UE ini parsing helpers (syntax: [Section], Key=, +Key=, -Key=, .Key=, !Key=, ; comments, (A=1,B=2) structs)."""
import re

OPS = "+-.!@*"
_SECTION_RE = re.compile(r"^\s*\[(.*?)\]?\s*$")
_KEY_RE = re.compile(r"^\s*([+\-.!@*]?)([^=;\s][^=]*?)\s*=(.*)$")


def strip_key(k):
    """Normalise a key for lookup: drop array index suffix `Key[0]` and surrounding spaces."""
    k = k.strip()
    i = k.find("[")
    if i > 0:
        k = k[:i]
    return k


def iter_ini(text):
    """Yield ("section", name, lineno0, raw) / ("key", section, key, op, value, lineno0) entries."""
    section = None
    for i, line in enumerate(text.splitlines()):
        s = line.lstrip()
        if not s or s[0] == ";" or s[0] == "#":
            continue
        if s[0] == "[":
            j = s.find("]")
            section = s[1:j] if j > 0 else s[1:].rstrip()
            yield ("section", section, i)
            continue
        m = _KEY_RE.match(line)
        if m and section is not None:
            yield ("key", section, m.group(2).strip(), m.group(1), m.group(3).strip(), i)
        elif section is not None and s[0] in OPS and "=" not in s:
            # bare "!Key" / "-Key" clear forms
            yield ("key", section, s[1:].strip(), s[0], "", i)


def ini_category(path):
    """'.../BaseEngine.ini' -> 'Engine'; 'DefaultGame.ini' -> 'Game'."""
    name = re.split(r"[\\/]", path)[-1]
    if name.lower().endswith(".ini"):
        name = name[:-4]
    for p in ("Base", "Default"):
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name


def context_at(text, line, col):
    """Determine ini completion context at (line, col) (0-based, col in str index).

    Returns dict with kind in {"section", "key", "value", "none"} plus section, key, prefix, range info.
    """
    lines = text.split("\n")
    if line >= len(lines):
        return {"kind": "none"}
    cur = lines[line].rstrip("\r")
    col = min(col, len(cur))
    before = cur[:col]
    sb = before.lstrip()
    indent = len(before) - len(sb)
    if sb.startswith(";") or sb.startswith("#"):
        return {"kind": "none"}
    section = None
    section_line = None
    for i in range(line - 1, -1, -1):
        s = lines[i].lstrip()
        if s.startswith("["):
            j = s.find("]")
            section = s[1:j] if j > 0 else s[1:].rstrip()
            section_line = i
            break
    if sb.startswith("["):
        close = cur.find("]", indent)
        end = close + 1 if close >= 0 else len(cur.rstrip())
        return {"kind": "section", "prefix": sb[1:], "start": indent, "end": max(end, col)}
    eq = before.find("=")
    if eq < 0:
        op = sb[:1] if sb[:1] and sb[:1] in OPS else ""
        kstart = indent + len(op)
        # replace through end of key token (up to '=' or eol)
        rest = cur[kstart:]
        req = rest.find("=")
        kend = kstart + (req if req >= 0 else len(rest.rstrip()))
        return {"kind": "key", "section": section, "section_line": section_line, "prefix": before[kstart:],
                "start": kstart, "end": max(kend, col), "op": op}
    keypart = before[:eq].strip()
    op = keypart[:1] if keypart[:1] and keypart[:1] in OPS else ""
    key = strip_key(keypart[len(op):])
    vstart = eq + 1
    value_before = before[vstart:]
    # struct value: inside ( ... ) -> report member context
    depth = 0
    last_sep = -1
    for i, c in enumerate(value_before):
        if c == "(":
            depth += 1
            last_sep = i
        elif c == ")":
            depth -= 1
        elif c == "," and depth > 0:
            last_sep = i
    if depth > 0:
        seg = value_before[last_sep + 1:]
        seq = seg.find("=")
        if seq < 0:
            return {"kind": "struct_member", "section": section, "key": key, "prefix": seg.strip(),
                    "start": vstart + last_sep + 1 + (len(seg) - len(seg.lstrip())), "end": col}
        return {"kind": "none"}
    vtrim = value_before.lstrip()
    s = col - len(vtrim)
    rest = cur[col:]
    m = re.match(r"[^\s;]*", rest)
    return {"kind": "value", "section": section, "key": key, "op": op, "prefix": vtrim, "start": s,
            "end": col + (m.end() if m else 0)}


def word_at(text, line, col):
    """Return (kind, word, section, start, end) for hover/definition in an ini document."""
    lines = text.split("\n")
    if line >= len(lines):
        return None
    cur = lines[line].rstrip("\r")
    s = cur.lstrip()
    indent = len(cur) - len(s)
    if not s or s[0] in ";#":
        return None
    if s.startswith("["):
        j = cur.find("]", indent)
        name = cur[indent + 1:j if j > 0 else len(cur)].strip()
        return ("section", name, name, indent, j + 1 if j > 0 else len(cur))
    section = None
    for i in range(line - 1, -1, -1):
        t = lines[i].lstrip()
        if t.startswith("["):
            j = t.find("]")
            section = t[1:j] if j > 0 else t[1:].rstrip()
            break
    eq = cur.find("=")
    op = s[0] if s[0] in OPS else ""
    kstart = indent + len(op)
    kend = eq if eq >= 0 else len(cur.rstrip())
    if col <= kend or eq < 0:
        return ("key", strip_key(cur[kstart:kend]), section, kstart, kend)
    return ("value", cur[eq + 1:].strip(), section, eq + 1, len(cur))
