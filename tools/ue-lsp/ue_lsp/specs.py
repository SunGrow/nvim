"""Specifier / metadata tables.

Sources (read-only):
  * EpicGames.UHT/Specifiers/*.cs  -> authoritative list of accepted specifiers + value types
  * EpicGames.UHT/Utils/UhtTables.cs -> table parent chain (Class -> ClassBase -> Struct -> Field -> Object -> Default)
  * CoreUObject/Public/UObject/ObjectMacros.h -> `///` docs for UC/UI/UF/UP/US specifiers and UM meta keys
"""
import os
import re

# Macro -> UHT specifier table (UHT table names from UhtTables.cs)
MACRO_TABLE = {
    "UCLASS": "Class",
    "UINTERFACE": "Interface",
    "UFUNCTION": "Function",
    "UDELEGATE": "Function",
    "UPROPERTY": "PropertyMember",
    "UPARAM": "PropertyArgument",
    "USTRUCT": "ScriptStruct",
    "UENUM": "Enum",
}
# Macro -> ObjectMacros.h namespace with specifier docs
MACRO_DOCNS = {
    "UCLASS": "UC", "UINTERFACE": "UI", "UFUNCTION": "UF", "UDELEGATE": "UF",
    "UPROPERTY": "UP", "UPARAM": "UP", "USTRUCT": "US", "UENUM": None, "UMETA": None,
}
# Macro -> meta contexts (UM group ids) that apply inside meta=( )
MACRO_META = {
    "UCLASS": ("field", "class"),
    "UINTERFACE": ("field", "class", "interface"),
    "UFUNCTION": ("field", "function"),
    "UDELEGATE": ("field", "function"),
    "UPROPERTY": ("field", "property"),
    "UPARAM": ("field", "property", "function"),
    "USTRUCT": ("field", "struct"),
    "UENUM": ("field", "enum"),
    "UMETA": ("field", "umeta"),
}
TAG_CTX = {
    "ClassMetadata": "class", "PropertyMetadata": "property", "FunctionMetadata": "function",
    "InterfaceMetadata": "interface", "StructMetadata": "struct", "EnumMetadata": "enum",
}

UHT_SPEC_REL = os.path.join("Engine", "Source", "Programs", "Shared", "EpicGames.UHT", "Specifiers")
UHT_TABLES_REL = os.path.join("Engine", "Source", "Programs", "Shared", "EpicGames.UHT", "Utils", "UhtTables.cs")
OBJMACROS_REL = os.path.join("Engine", "Source", "Runtime", "CoreUObject", "Public", "UObject", "ObjectMacros.h")

_ATTR_RE = re.compile(r"\[\s*UhtSpecifier\s*\((?P<args>[^\]]*)\)\s*\]")
_METHOD_RE = re.compile(r"\bstatic\s+\w+\s+(\w+)\s*\(")
_CREATE_RE = re.compile(r'CreateTables\(\s*tables\s*,\s*UhtTableNames\.(\w+)\s*,\s*"[^"]*"\s*,[^,]+,\s*(null|UhtTableNames\.(\w+))')


def parse_uht_tables(engine_root):
    """Return (specs, parents).
    specs: {table: {lower_name: {"name", "value_type", "file", "line"}}}
    parents: {table: parent_table or None}
    """
    parents = {}
    tpath = os.path.join(engine_root, UHT_TABLES_REL)
    try:
        with open(tpath, encoding="utf-8", errors="replace") as f:
            for m in _CREATE_RE.finditer(f.read()):
                parents[m.group(1)] = m.group(3)
    except OSError:
        pass
    specs = {}
    sdir = os.path.join(engine_root, UHT_SPEC_REL)
    try:
        names = sorted(os.listdir(sdir))
    except OSError:
        names = []
    for fn in names:
        if not fn.endswith(".cs"):
            continue
        path = os.path.join(sdir, fn)
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        pending = []  # attributes waiting for their method
        for i, line in enumerate(lines):
            for m in _ATTR_RE.finditer(line):
                args = m.group("args")
                ext = re.search(r"Extends\s*=\s*UhtTableNames\.(\w+)", args)
                nm = re.search(r'Name\s*=\s*"(\w+)"', args)
                vt = re.search(r"ValueType\s*=\s*UhtSpecifierValueType\.(\w+)", args)
                pending.append((ext.group(1) if ext else "Default", nm.group(1) if nm else None,
                                vt.group(1) if vt else "None", i + 1))
            if pending:
                mm = _METHOD_RE.search(line)
                if mm:
                    meth = mm.group(1)
                    for table, nm, vt, ln in pending:
                        name = nm or (meth[:-len("Specifier")] if meth.endswith("Specifier") else meth)
                        specs.setdefault(table, {})[name.lower()] = {
                            "name": name, "value_type": vt, "file": path, "line": ln}
                    pending = []
    return specs, parents


def table_chain(table, parents):
    out = []
    while table and table not in out:
        out.append(table)
        table = parents.get(table)
    return out


_NS_RE = re.compile(r"^namespace\s+(U[CIFPSM])\s*$")
_MEMBER_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*(?:UE_DEPRECATED\s*\(.*\))?\s*,?\s*(?:/\*\s*(.*?)\s*\*/)?\s*$")
_COMMENTED_MEMBER_RE = re.compile(r"^\s*//\s*([A-Za-z_]\w*)\s*,\s*\(Commented out")
_GROUP_RE = re.compile(r"^\s*//\s*Metadata usable in (.*)$")
_TAG_RE = re.compile(r"\[(\w+Metadata)\]")


def _group_ctx(desc):
    d = desc.strip()
    if d.startswith("any UField"):
        return "field"
    if d.startswith("UCLASS"):
        return "class"
    if d.startswith("USTRUCT"):
        return "struct"
    if d.startswith("UPROPERTY"):
        return "property"
    if d.startswith("UFUNCTION"):
        return "function"
    if d.startswith("UINTERFACE"):
        return "interface"
    return "field"


def parse_object_macros(engine_root):
    """Parse ObjectMacros.h.
    Returns {"spec_docs": {ns: {lower: {"name","doc","value_hint","line"}}},
             "meta": {lower: {"name","doc","contexts":[...],"line"}}, "file": path}
    """
    path = os.path.join(engine_root, OBJMACROS_REL)
    out = {"spec_docs": {}, "meta": {}, "file": path}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    ns = None
    depth = 0
    in_enum = False
    doc = []
    group = None
    pending_refs = []  # (name, group, doc, line) for commented-out members
    for i, raw in enumerate(lines):
        line = raw.strip()
        if ns is None:
            m = _NS_RE.match(line)
            if m:
                ns = m.group(1)
                depth = 0
                in_enum = False
                doc = []
                group = None
            continue
        if line.startswith("{"):
            depth += 1
            if depth == 2:
                in_enum = True
                doc = []
            continue
        if line.startswith("}"):
            depth -= 1
            if depth == 1:
                in_enum = False
            if depth <= 0:
                ns = None
            continue
        if not in_enum:
            gm = _GROUP_RE.match(raw)
            if gm and ns == "UM":
                group = _group_ctx(gm.group(1))
            continue
        if line.startswith("///") or (line.startswith("//") and _TAG_RE.search(line) and not _COMMENTED_MEMBER_RE.match(raw)):
            doc.append(line.lstrip("/").strip())
            continue
        cm = _COMMENTED_MEMBER_RE.match(raw)
        if cm:
            if ns == "UM":
                pending_refs.append((cm.group(1), group, " ".join(doc), i + 1, list(doc)))
            doc = []
            continue
        if not line or line.startswith("//") or line.startswith("enum"):
            continue
        mm = _MEMBER_RE.match(raw)
        if not mm:
            continue
        name = mm.group(1)
        hint = (mm.group(2) or "").strip()
        text = "\n".join(doc).strip()
        if ns == "UM":
            ctxs = {group or "field"}
            for t in _TAG_RE.findall(text):
                if t in TAG_CTX:
                    ctxs.add(TAG_CTX[t])
            ent = out["meta"].setdefault(name.lower(), {"name": name, "doc": text, "contexts": [], "line": i + 1})
            for c in ctxs:
                if c not in ent["contexts"]:
                    ent["contexts"].append(c)
            if not ent["doc"]:
                ent["doc"] = text
        else:
            out["spec_docs"].setdefault(ns, {})[name.lower()] = {
                "name": name, "doc": text, "value_hint": hint, "line": i + 1}
        doc = []
    for name, grp, _d, ln, dl in pending_refs:
        text = "\n".join(dl).strip()
        ent = out["meta"].setdefault(name.lower(), {"name": name, "doc": text, "contexts": [], "line": ln})
        ctxs = {grp or "field"} | {TAG_CTX[t] for t in _TAG_RE.findall(text) if t in TAG_CTX}
        for c in ctxs:
            if c not in ent["contexts"]:
                ent["contexts"].append(c)
        if not ent["doc"]:
            ent["doc"] = text
    return out


def build_spec_db(engine_root):
    specs, parents = parse_uht_tables(engine_root)
    om = parse_object_macros(engine_root)
    macros = {}
    for macro, table in MACRO_TABLE.items():
        chain = table_chain(table, parents)
        merged = {}
        for t in reversed(chain):  # child overrides parent
            for k, v in specs.get(t, {}).items():
                merged[k] = dict(v, table=t)
        nsdocs = om["spec_docs"].get(MACRO_DOCNS.get(macro) or "", {})
        for k, v in merged.items():
            d = nsdocs.get(k)
            if d is None:  # fall back: any namespace doc with the same name
                for ns in ("UC", "UI", "UF", "UP", "US"):
                    d = om["spec_docs"].get(ns, {}).get(k)
                    if d:
                        break
            v["doc"] = d["doc"] if d else ""
            v["doc_line"] = d["line"] if d else None
        macros[macro] = merged
    # mismatches: documented in ObjectMacros.h namespace but not accepted by UHT table chain, and vice versa
    mismatches = []
    for macro, ns in (("UCLASS", "UC"), ("UINTERFACE", "UI"), ("UFUNCTION", "UF"),
                      ("UPROPERTY", "UP"), ("USTRUCT", "US")):
        accepted = macros[macro]
        docs = om["spec_docs"].get(ns, {})
        own = specs.get(MACRO_TABLE[macro], {})
        for k, d in sorted(docs.items()):
            if k not in accepted:
                mismatches.append(("doc_only", macro, d["name"], "%s:%d" % (om["file"], d["line"])))
        for k, v in sorted(own.items()):
            if k not in docs:
                mismatches.append(("uht_only", macro, v["name"], "%s:%d" % (v["file"], v["line"])))
    return {
        "macros": macros,
        "meta": om["meta"],
        "meta_file": om["file"],
        "parents": parents,
        "mismatches": mismatches,
    }
