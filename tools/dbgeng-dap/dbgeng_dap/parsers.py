"""Parsers for cdb.exe (DbgEng) console output.  Pure functions; unit-tested against captured output."""
import re

# cdb prompt: "0:000> ", "1:002> ", WOW64 "0:000:x86> ", or "NoTarget> " after the target is gone.
PROMPT_RE = re.compile(r'(?:^|\n)(?:\d+:\d+(?::\w+)?|NoTarget)> $')

_NOISE_RE = re.compile(r'^\s*(\*\*\*|\*{20,}|Unable to load image|ModLoad:)')


def strip_prompt(text):
    """Remove the trailing prompt from a command response."""
    m = PROMPT_RE.search(text)
    return text[:m.start()] if m else text


def clean_lines(text):
    """Response lines without symbol-loader noise ("*** WARNING ...", the unqualified-symbol star box)."""
    return [l for l in strip_prompt(text).replace('\r', '').split('\n') if l.strip() and not _NOISE_RE.match(l)]


# ---------------------------------------------------------------- events
_LASTEVENT_RE = re.compile(r'Last event:\s*(?:([0-9a-f]+)\.([0-9a-f]+):\s*)?(.*)')


def parse_lastevent(text):
    """`.lastevent` -> {'pid': int|None, 'tid': int|None, 'desc': str, 'kind': str, ...}.

    kind: 'breakpoint' (with 'bp' id), 'exit' (with 'code'), 'exception' (with 'code', 'first_chance'),
    'none' (no event; e.g. after a step), 'other'."""
    m = _LASTEVENT_RE.search(text)
    if not m:
        return None
    pid = int(m.group(1), 16) if m.group(1) else None
    tid = int(m.group(2), 16) if m.group(2) else None
    desc = m.group(3).strip()
    ev = {'pid': pid, 'tid': tid, 'desc': desc, 'kind': 'other'}
    if desc.startswith('<no event>'):
        ev['kind'] = 'none'
    elif (b := re.match(r'Hit breakpoint (\d+)', desc)):
        ev['kind'] = 'breakpoint'
        ev['bp'] = int(b.group(1))
    elif (x := re.match(r'Exit process [0-9a-f]+:[0-9a-f]+, code ([0-9a-f]+)', desc)):
        ev['kind'] = 'exit'
        ev['code'] = int(x.group(1), 16)
    elif (e := re.search(r'- code ([0-9a-f]{8}) \((first chance|!!! second chance !!!)\)', desc)):
        ev['kind'] = 'exception'
        ev['code'] = int(e.group(1), 16)
        ev['first_chance'] = e.group(2) == 'first chance'
    return ev


def parse_pseudo_reg(text, name):
    """`r $tid` -> int ("$tid=000000000000e0b8")."""
    m = re.search(r'\$' + re.escape(name) + r'=([0-9a-f]+)', text)
    return int(m.group(1), 16) if m else None


# ---------------------------------------------------------------- threads
_THREAD_RE = re.compile(r'^\s*([.#])?\s*(\d+)\s+Id:\s+([0-9a-f]+)\.([0-9a-f]+)\s+Suspend:\s*(-?\d+)\s+Teb:\s*\S+\s+'
                        r'(\w+)(?:\s+"(.*)")?\s*$')


def parse_threads(text):
    """`~` -> [{'index', 'pid', 'tid', 'name', 'current'}]."""
    out = []
    for l in clean_lines(text):
        m = _THREAD_RE.match(l)
        if m:
            out.append({'index': int(m.group(2)), 'pid': int(m.group(3), 16), 'tid': int(m.group(4), 16),
                        'name': m.group(7) or '', 'current': m.group(1) == '.'})
    return out


# ---------------------------------------------------------------- stack
_FRAME_RE = re.compile(r'^\s*([0-9a-f]+)\s+(\(Inline Function\)|[0-9a-f`]{8,17})\s+([-0-9a-f`]{8,17})\s+(.*?)\s*$')
_SRC_RE = re.compile(r'^(.*?)\s+\[(.+) @ (\d+)\]$')


def parse_stack(text):
    """`kn` -> [{'index', 'sp', 'ret', 'inline', 'symbol', 'module', 'function', 'file', 'line'}]."""
    frames = []
    for l in clean_lines(text):
        m = _FRAME_RE.match(l)
        if not m or l.lstrip().startswith('#'):
            continue
        site = m.group(4)
        f = {'index': int(m.group(1), 16), 'sp': m.group(2), 'ret': m.group(3),
             'inline': m.group(2) == '(Inline Function)', 'file': None, 'line': None}
        s = _SRC_RE.match(site)
        if s:
            site, f['file'], f['line'] = s.group(1), s.group(2), int(s.group(3))
        f['symbol'] = site
        if '!' in site:
            f['module'], f['function'] = site.split('!', 1)
        else:
            f['module'], f['function'] = '', site
        frames.append(f)
    return frames


# ---------------------------------------------------------------- dx
class DxNode:
    __slots__ = ('name', 'value', 'type', 'indent', 'children', 'error')

    def __init__(self, name, value=None, type_=None, indent=0, error=None):
        self.name, self.value, self.type, self.indent = name, value, type_, indent
        self.children, self.error = [], error

    def __repr__(self):
        return f'DxNode({self.name!r}, {self.value!r}, {self.type!r}, kids={len(self.children)})'


_TYPE_RE = re.compile(r'\s?\[Type: (.*)\]\s*$')


def parse_dx_line(line):
    indent = len(line) - len(line.lstrip(' '))
    s = line.strip()
    t = None
    m = _TYPE_RE.search(s)
    if m:
        t = m.group(1)
        s = s[:m.start()].rstrip()
    i = s.find(' : ')
    if i >= 0:
        name, value = s[:i].rstrip(), s[i + 3:].strip()
    elif s.endswith(' :'):
        name, value = s[:-2].rstrip(), ''
    else:
        name, value = s, None
    return DxNode(name, value, t, indent)


def parse_dx(text):
    """`dx -rN expr` -> root DxNode (children nested by indentation) or DxNode with .error set."""
    lines = clean_lines(text)
    for l in lines:
        if l.startswith('Error:') or l.startswith('Error evaluating'):
            return DxNode('', error=l.split(':', 1)[1].strip() if ':' in l else l)
    if not lines:
        return DxNode('', error='no output')
    root = parse_dx_line(lines[0])
    stack = [root]
    for l in lines[1:]:
        n = parse_dx_line(l)
        while len(stack) > 1 and stack[-1].indent >= n.indent:
            stack.pop()
        if n.indent <= stack[0].indent:  # unexpected dedent: continuation text of the root value
            continue
        stack[-1].children.append(n)
        stack.append(n)
    return root


_FIELD_RE = re.compile(r'^\[([+=])0x[0-9a-f]+\]\s+(.+)$')
_INDEX_RE = re.compile(r'^\[(0x[0-9a-f]+|\d+)\]$')
_IDENT_RE = re.compile(r'^[A-Za-z_]\w*$')

PRIMITIVES = {'bool', 'char', 'signed char', 'unsigned char', 'wchar_t', 'char8_t', 'char16_t', 'char32_t', 'short',
              'unsigned short', 'int', 'unsigned int', 'long', 'unsigned long', '__int64', 'unsigned __int64',
              'float', 'double', 'long double', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'int64',
              'uint64', 'TCHAR', 'ANSICHAR', 'WIDECHAR', 'UTF8CHAR', 'SIZE_T', 'size_t'}


def classify_child(name):
    """-> ('field', member) | ('static', member) | ('index', None) | ('raw', None) | ('more', None) | ('synthetic', name)."""
    m = _FIELD_RE.match(name)
    if m:
        return ('field' if m.group(1) == '+' else 'static'), m.group(2).strip()
    if _INDEX_RE.match(name):
        return 'index', None
    if name in ('[<Raw View>]', '[Raw View]'):
        return 'raw', None
    if name.startswith('[...]'):
        return 'more', None
    return 'synthetic', name


def display_name(name):
    kind, member = classify_child(name)
    return member if kind in ('field', 'static') else name


def strip_type(t):
    t = (t or '').strip()
    t = re.sub(r'\s*\(derived from .*\)$', '', t)
    return re.sub(r'^(class|struct|union|enum)\s+', '', t)


def looks_pointer(value, type_):
    t = strip_type(type_)
    if t.endswith('*'):
        return True
    return bool(value) and bool(re.match(r'^0x[0-9a-f]{5,}$', value.split(' ')[0])) and t not in PRIMITIVES


def has_children(node):
    """Heuristic: may this dx child be expanded?"""
    kind, member = classify_child(node.name)
    if kind in ('raw', 'more'):
        return True
    if node.children:
        return True
    v, t = node.value, strip_type(node.type)
    if v is None:
        return bool(t) and t not in PRIMITIVES
    if v in ('nullptr', '0x0', 'true', 'false', '') or v.startswith('Value unavailable') or v.startswith('Error'):
        return False
    if t in PRIMITIVES or t.rstrip(' *').strip() in ('char', 'wchar_t', 'void', 'char16_t') and t.endswith('*'):
        return False
    if re.match(r'^-?\d+(\.\d+)?(e[-+]?\d+)?$', v) or re.match(r'^\w+ \(-?\d+\)$', v) or re.match(r"^\d+ '.*'$", v):
        return False  # number, enum "NAME (123)", char "65 'A'"
    if not t and re.match(r'^0x[0-9a-f]+$', v):
        return False  # untyped number (script value)
    return True


# ---------------------------------------------------------------- registers
_REG_RE = re.compile(r'\b([a-z][a-z0-9]{1,5})=([0-9a-f]+)\b')


def parse_registers(text):
    """`r` -> [(name, value)] in display order (stops at the disassembly line)."""
    out, seen = [], set()
    for l in clean_lines(text):
        if '!' in l or re.match(r'^[0-9a-f`]{17}\s', l):
            break
        for name, val in _REG_RE.findall(l):
            if name not in seen:
                seen.add(name)
                out.append((name, val))
    return out


# ---------------------------------------------------------------- breakpoints / modules
_BL_RE = re.compile(r'^\s*(\d+)\s+([edu]+)\s+(?:([0-9a-f`]{8,17})\s+)?(?:\[(.+?) @ (\d+)\]\s+)?')


def parse_bl(text):
    """`bl` -> {id: {'flags', 'address', 'file', 'line', 'resolved'}}."""
    out = {}
    for l in clean_lines(text):
        m = _BL_RE.match(l)
        if m:
            out[int(m.group(1))] = {'flags': m.group(2), 'address': m.group(3), 'file': m.group(4),
                                    'line': int(m.group(5)) if m.group(5) else None,
                                    'resolved': 'u' not in m.group(2) and m.group(3) is not None}
    return out


_MODLOAD_RE = re.compile(r'ModLoad:\s+([0-9a-f`]+)\s+([0-9a-f`]+)\s+(.+?)\s*$')


def parse_modload(line):
    """'ModLoad: 00007ffc`19b60000 00007ffc`19c51000   D:\\x\\a.dll' -> (base, end, path) or None."""
    m = _MODLOAD_RE.search(line)
    if not m:
        return None
    return int(m.group(1).replace('`', ''), 16), int(m.group(2).replace('`', ''), 16), m.group(3)


def cdb_module_name(image_path):
    """DbgEng module name for an image: file stem with characters invalid in symbols replaced by '_'."""
    import os
    stem = os.path.splitext(os.path.basename(image_path))[0]
    return re.sub(r'[^A-Za-z0-9_]', '_', stem)


def is_cdb_error(text):
    t = strip_prompt(text)
    return bool(re.search(r"(^|\n)\s*(\^ |Couldn't resolve|Syntax error|Bp expression .* could not be resolved|"
                          r"Invalid parameter|Unable to)", t))
