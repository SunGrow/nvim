"""Read-only reader for UE 5.x editor (uncooked, versioned) .uasset/.umap packages. Python stdlib only.

Layout follows PackageFileSummary.cpp, ObjectResource.cpp, PropertyTag.cpp, PropertyTypeName.cpp and
UStruct::SerializeVersionedTaggedProperties of UE 5.8. Only the summary head, the name/import/export/
soft-path tables and the requested export byte ranges are read from disk.

Public API
    open_package(path, load_all=False) -> Package          (never raises; see Package.error / .unsupported)
    Package.export_props(i) -> ExportProps                 (tagged properties of export i, partial + warnings)
    Package.object_path(package_index) -> str              (import/export reference resolved to a path)
    Package.export_path(i) -> str
    display(value) -> str                                  (UE-ExportText-like rendering)
Values: bool/int/float/str, ObjRef (str subclass: object path), Struct (dict subclass with .type), list,
SetValue (list subclass), MapValue (list of (key, value)), Unparsed (opaque, with .reason).
"""
import os
import struct

PACKAGE_TAG = 0x9E2A83C1
PACKAGE_TAG_SWAPPED = 0xC1832A9E

# EUnrealEngineObjectUE5Version
UE5_NAMES_REFERENCED_FROM_EXPORT_DATA = 1001
UE5_PAYLOAD_TOC = 1002
UE5_OPTIONAL_RESOURCES = 1003
UE5_REMOVE_OBJECT_EXPORT_PACKAGE_GUID = 1005
UE5_TRACK_OBJECT_EXPORT_IS_INHERITED = 1006
UE5_ADD_SOFTOBJECTPATH_LIST = 1008
UE5_DATA_RESOURCES = 1009
UE5_SCRIPT_SERIALIZATION_OFFSET = 1010
UE5_PROPERTY_TAG_EXTENSION = 1011
UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME = 1012
UE5_METADATA_SERIALIZATION_OFFSET = 1014
UE5_VERSE_CELLS = 1015
UE5_PACKAGE_SAVED_HASH = 1016
UE5_IMPORT_TYPE_HIERARCHIES = 1018

# Package flags
PKG_FilterEditorOnly = 0x80000000
PKG_Cooked = 0x00000200
# EObjectFlags
RF_ClassDefaultObject = 0x00000010

# UE4 versions used in gates (all packages that reach here are >= this; older ones are rejected)
UE4_OLDEST_SUPPORTED = 522
UE4_ADDED_PACKAGE_SUMMARY_LOCALIZATION_ID = 516

MAX_NAMES = 5_000_000
MAX_TABLE = 5_000_000


_FORTNITE_MAIN_GUID = struct.pack("<4I", 0x601D1886, 0xAC644F84, 0xAA16D3DE, 0x0DEAC7D6).hex()  # AddDevNotesToFText = 260


class ParseError(Exception):
    pass


class ObjRef(str):
    """An object/class/soft-path reference rendered as a path string."""
    __slots__ = ()


class Struct(dict):
    """A struct value: field name -> value (arrays of static arrays as 'Name[i]'). `.type` is the struct name."""
    def __init__(self, type_name="", *a, **k):
        super().__init__(*a, **k)
        self.type = type_name


class SetValue(list):
    pass


class MapValue(list):
    """List of (key, value) tuples."""


class Unparsed:
    def __init__(self, type_name, size, reason):
        self.type = type_name
        self.size = size
        self.reason = reason

    def __repr__(self):
        return "<unparsed %s: %s>" % (self.type, self.reason)


class Prop:
    __slots__ = ("name", "type", "index", "value", "size", "guid")

    def __init__(self, name, type_name, index, value, size):
        self.name = name
        self.type = type_name
        self.index = index
        self.value = value
        self.size = size

    def __repr__(self):
        return "Prop(%s:%s=%s)" % (self.name, self.type, display(self.value))


class ExportProps:
    def __init__(self):
        self.props = []
        self.warnings = []
        self.complete = True   # False when the tag stream ended abnormally (partial)
        self.control = 0


class Export:
    __slots__ = ("index", "class_index", "super_index", "template_index", "outer_index", "name", "obj_flags",
                 "serial_size", "serial_offset", "is_inherited", "pkg_flags", "is_asset", "script_start",
                 "script_end", "_path")


class Import:
    __slots__ = ("class_package", "class_name", "outer_index", "name", "package_name")


# --------------------------------------------------------------------------------------------- reader

class Reader:
    __slots__ = ("b", "p", "base")

    def __init__(self, data, pos=0, base=0):
        self.b = data
        self.p = pos
        self.base = base  # file offset of data[0]

    def need(self, n):
        if self.p < 0 or self.p + n > len(self.b):
            raise ParseError("read past end of buffer at %d (+%d, have %d)" % (self.p + self.base, n, len(self.b) + self.base))

    def u8(self):
        self.need(1)
        v = self.b[self.p]
        self.p += 1
        return v

    def i8(self):
        v = self.u8()
        return v - 256 if v > 127 else v

    def i16(self):
        self.need(2)
        v = struct.unpack_from("<h", self.b, self.p)[0]
        self.p += 2
        return v

    def u16(self):
        self.need(2)
        v = struct.unpack_from("<H", self.b, self.p)[0]
        self.p += 2
        return v

    def i32(self):
        self.need(4)
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        return v

    def u32(self):
        self.need(4)
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def i64(self):
        self.need(8)
        v = struct.unpack_from("<q", self.b, self.p)[0]
        self.p += 8
        return v

    def u64(self):
        self.need(8)
        v = struct.unpack_from("<Q", self.b, self.p)[0]
        self.p += 8
        return v

    def f32(self):
        self.need(4)
        v = struct.unpack_from("<f", self.b, self.p)[0]
        self.p += 4
        return v

    def f64(self):
        self.need(8)
        v = struct.unpack_from("<d", self.b, self.p)[0]
        self.p += 8
        return v

    def raw(self, n):
        if n < 0:
            raise ParseError("negative length")
        self.need(n)
        v = self.b[self.p:self.p + n]
        self.p += n
        return v

    def boolean(self):
        return self.i32() != 0

    def fstring(self):
        n = self.i32()
        if n == 0:
            return ""
        if n > 0:
            if n > 1 << 24:
                raise ParseError("string too long (%d)" % n)
            raw = self.raw(n)
            return raw[:-1].decode("utf-8", "replace") if raw[-1:] == b"\0" else raw.decode("utf-8", "replace")
        n = -n
        if n > 1 << 24:
            raise ParseError("wide string too long (%d)" % n)
        raw = self.raw(n * 2)
        return raw[:-2].decode("utf-16-le", "replace")

    def utf8_string(self):
        """FUtf8String / FString with a negative-length UTF-16 fallback."""
        return self.fstring()


# --------------------------------------------------------------------------------------------- package

def _fixed_head(data):
    """Parse the summary fields we need. Returns dict. Raises ParseError / returns reason via 'unsupported'."""
    r = Reader(data)
    s = {}
    tag = r.u32()
    if tag not in (PACKAGE_TAG, PACKAGE_TAG_SWAPPED):
        raise ParseError("bad magic 0x%08X" % tag)
    if tag == PACKAGE_TAG_SWAPPED:
        s["unsupported"] = "byte-swapped package"
        return s
    legacy = r.i32()
    s["legacy"] = legacy
    if legacy >= 0:
        s["unsupported"] = "UE3-era package"
        return s
    if legacy < -9:
        s["unsupported"] = "legacy file version %d newer than supported (-9)" % legacy
        return s
    if legacy != -4:
        r.i32()
    ue4 = r.i32()
    ue5 = r.i32() if legacy <= -8 else 0
    lic = r.i32()
    s.update(ue4=ue4, ue5=ue5, licensee=lic)
    if ue4 == 0 and ue5 == 0 and lic == 0:
        s["unsupported"] = "unversioned package"
        return s
    if ue4 < UE4_OLDEST_SUPPORTED:
        s["unsupported"] = "UE4 package version %d older than supported (%d)" % (ue4, UE4_OLDEST_SUPPORTED)
        return s
    if ue5 and ue5 < UE5_ADD_SOFTOBJECTPATH_LIST:
        s["unsupported"] = "UE5 package version %d older than supported (%d)" % (ue5, UE5_ADD_SOFTOBJECTPATH_LIST)
        return s
    if ue5 > UE5_IMPORT_TYPE_HIERARCHIES + 8:
        s["unsupported"] = "UE5 package version %d newer than known (%d)" % (ue5, UE5_IMPORT_TYPE_HIERARCHIES)
        return s
    if ue5 >= UE5_PACKAGE_SAVED_HASH:
        r.raw(20)
        s["total_header_size"] = r.i32()
    # custom versions
    n = r.i32()
    if n < 0 or n > 4096:
        raise ParseError("bad custom version count %d" % n)
    cv = {}
    for _ in range(n):
        g = r.raw(16)
        cv[g.hex()] = r.i32()
    s["custom_versions"] = cv
    if ue5 < UE5_PACKAGE_SAVED_HASH:
        s["total_header_size"] = r.i32()
    s["package_name"] = r.fstring()
    flags = r.u32()
    s["package_flags"] = flags
    if flags & PKG_Cooked:
        s["unsupported"] = "cooked package"
        return s
    s["name_count"] = r.i32()
    s["name_offset"] = r.i32()
    if ue5 >= UE5_ADD_SOFTOBJECTPATH_LIST:
        s["softpath_count"] = r.i32()
        s["softpath_offset"] = r.i32()
    else:
        s["softpath_count"] = s["softpath_offset"] = 0
    if not flags & PKG_FilterEditorOnly and ue4 >= UE4_ADDED_PACKAGE_SUMMARY_LOCALIZATION_ID:
        s["localization_id"] = r.fstring()
    s["gatherable_count"] = r.i32()
    s["gatherable_offset"] = r.i32()
    s["export_count"] = r.i32()
    s["export_offset"] = r.i32()
    s["import_count"] = r.i32()
    s["import_offset"] = r.i32()
    return s


class Package:
    """Parsed header of one package. Construct through open_package()."""

    def __init__(self, path):
        self.path = path
        self.size = 0
        self.summary = {}
        self.names = []
        self.imports = []
        self.exports = []
        self.softpaths = []
        self.warnings = []
        self.error = None          # fatal header error string (None when header parsed)
        self.unsupported = None    # reason string for unversioned/cooked/too-new packages
        self.ue4 = 0
        self.ue5 = 0
        self.package_name = ""
        self._file = None
        self._import_paths = {}
        self._buf = None           # whole file when load_all
        self._export_cache = {}

    # ---- names
    def name_at(self, idx, number):
        if idx < 0 or idx >= len(self.names):
            raise ParseError("name index %d out of range (%d names)" % (idx, len(self.names)))
        n = self.names[idx]
        return n if number == 0 else "%s_%d" % (n, number - 1)

    def read_name(self, r):
        idx = r.i32()
        num = r.i32()
        return self.name_at(idx, num)

    # ---- object paths
    def import_path(self, i, depth=0):
        """Path of import number i (0-based)."""
        if i in self._import_paths:
            return self._import_paths[i]
        if i < 0 or i >= len(self.imports) or depth > 32:
            return "<bad-import %d>" % i
        imp = self.imports[i]
        if imp.outer_index == 0:
            p = imp.name
        else:
            outer = self.object_path(imp.outer_index, depth + 1)
            sep = "." if outer.startswith("/") and "." not in outer.rsplit("/", 1)[-1] else (":" if outer.startswith("/") and ":" not in outer else ".")
            p = outer + sep + imp.name
        self._import_paths[i] = p
        return p

    def export_path(self, i, depth=0):
        if i < 0 or i >= len(self.exports) or depth > 32:
            return "<bad-export %d>" % i
        e = self.exports[i]
        if e._path is not None:
            return e._path
        if e.outer_index == 0:
            p = (self.package_name or "") + "." + e.name
        else:
            outer = self.object_path(e.outer_index, depth + 1)
            last = outer.rsplit("/", 1)[-1]
            sep = "." if "." not in last else (":" if ":" not in last else ".")
            p = outer + sep + e.name
        e._path = p
        return p

    def object_path(self, idx, depth=0):
        """FPackageIndex -> path string. 0 -> '' (null)."""
        if idx == 0:
            return ""
        if idx < 0:
            return self.import_path(-idx - 1, depth)
        return self.export_path(idx - 1, depth)

    def object_class_name(self, idx):
        """Class name (short) of the referenced object."""
        if idx == 0:
            return ""
        if idx < 0:
            i = -idx - 1
            return self.imports[i].class_name if 0 <= i < len(self.imports) else ""
        return self.object_path(self.exports[idx - 1].class_index) if 0 <= idx - 1 < len(self.exports) else ""

    # ---- data access
    def read_range(self, offset, length):
        if self._buf is not None:
            return self._buf[offset:offset + length]
        with open(self.path, "rb") as f:
            f.seek(offset)
            return f.read(length)

    def export_props(self, i):
        if i in self._export_cache:
            return self._export_cache[i]
        res = _read_export_props(self, i)
        self._export_cache[i] = res
        return res


def _parse_header(pkg, data):
    s = _fixed_head(data)
    pkg.summary = s
    pkg.ue4 = s.get("ue4", 0)
    pkg.ue5 = s.get("ue5", 0)
    pkg.package_name = s.get("package_name", "")
    if "unsupported" in s:
        pkg.unsupported = s["unsupported"]
        return
    ue5 = pkg.ue5
    hdr = s["total_header_size"]
    if hdr <= 0 or hdr > pkg.size:
        raise ParseError("bad TotalHeaderSize %d (file %d)" % (hdr, pkg.size))
    if len(data) < hdr:
        raise ParseError("short header read")
    # ---- name map
    n = s["name_count"]
    if n < 0 or n > MAX_NAMES or s["name_offset"] <= 0:
        raise ParseError("bad name table (count=%d offset=%d)" % (n, s["name_offset"]))
    r = Reader(data, s["name_offset"])
    names = []
    for _ in range(n):
        names.append(r.fstring())
        r.u32()  # case-preserving + non-case hashes (UE4 >= NAME_HASHES_SERIALIZED)
    pkg.names = names
    # ---- soft object path list
    c = s["softpath_count"]
    if c:
        if c < 0 or c > MAX_TABLE:
            raise ParseError("bad soft object path count")
        r = Reader(data, s["softpath_offset"])
        sp = []
        for _ in range(c):
            pkgn = pkg.read_name(r)
            asset = pkg.read_name(r)
            sub = r.utf8_string()
            path = pkgn
            if asset and asset != "None":
                path += "." + asset
            if sub:
                path += ":" + sub
            sp.append(path if pkgn != "None" else "")
        pkg.softpaths = sp
    # ---- imports
    n = s["import_count"]
    if n < 0 or n > MAX_TABLE:
        raise ParseError("bad import count %d" % n)
    r = Reader(data, s["import_offset"])
    for _ in range(n):
        imp = Import()
        imp.class_package = pkg.read_name(r)
        imp.class_name = pkg.read_name(r)
        imp.outer_index = r.i32()
        imp.name = pkg.read_name(r)
        imp.package_name = pkg.read_name(r)  # UE4 >= NON_OUTER_PACKAGE_IMPORT
        if ue5 >= UE5_OPTIONAL_RESOURCES:
            r.boolean()
        pkg.imports.append(imp)
    # ---- exports
    n = s["export_count"]
    if n < 0 or n > MAX_TABLE:
        raise ParseError("bad export count %d" % n)
    r = Reader(data, s["export_offset"])
    for i in range(n):
        e = Export()
        e.index = i
        e.class_index = r.i32()
        e.super_index = r.i32()
        e.template_index = r.i32()
        e.outer_index = r.i32()
        e.name = pkg.read_name(r)
        e.obj_flags = r.u32()
        e.serial_size = r.i64()
        e.serial_offset = r.i64()
        r.boolean()  # bForcedExport
        r.boolean()  # bNotForClient
        r.boolean()  # bNotForServer
        if ue5 < UE5_REMOVE_OBJECT_EXPORT_PACKAGE_GUID:
            r.raw(16)
        e.is_inherited = r.boolean() if ue5 >= UE5_TRACK_OBJECT_EXPORT_IS_INHERITED else False
        e.pkg_flags = r.u32()
        r.boolean()  # bNotAlwaysLoadedForEditorGame
        e.is_asset = r.boolean()
        if ue5 >= UE5_OPTIONAL_RESOURCES:
            r.boolean()  # bGeneratePublicHash
        r.raw(20)  # preload dependency ints
        if ue5 >= UE5_SCRIPT_SERIALIZATION_OFFSET:
            e.script_start = r.i64()
            e.script_end = r.i64()
        else:
            e.script_start = e.script_end = 0
        e._path = None
        pkg.exports.append(e)


def open_package(path, load_all=False):
    """Open a package and parse its header tables. Never raises: check .error / .unsupported."""
    pkg = Package(path)
    try:
        pkg.size = os.path.getsize(path)
        with open(path, "rb") as f:
            if pkg.size < 32:
                raise ParseError("file too small (%d bytes)" % pkg.size)
            if load_all:
                data = f.read()
                pkg._buf = data
            else:
                head = f.read(4096)
                total = 0
                try:
                    h = _fixed_head(head)
                    total = h.get("total_header_size", 0)
                except ParseError:
                    pass
                if total > len(head) and total <= pkg.size:
                    f.seek(0)
                    head = f.read(total)
                data = head
        _parse_header(pkg, data)
    except ParseError as ex:
        pkg.error = str(ex)
    except (OSError, struct.error, UnicodeError, MemoryError, OverflowError) as ex:
        pkg.error = "%s: %s" % (type(ex).__name__, ex)
    return pkg


# --------------------------------------------------------------------------------------------- type names

class TNode:
    __slots__ = ("name", "kids")

    def __init__(self, name, kids):
        self.name = name
        self.kids = kids

    def __str__(self):
        if not self.kids:
            return self.name
        return "%s(%s)" % (self.name, ",".join(str(k) for k in self.kids))


def _read_type(pkg, r, depth=0):
    if depth > 16:
        raise ParseError("type name too deep")
    name = pkg.read_name(r)
    cnt = r.i32()
    if cnt < 0 or cnt > 16:
        raise ParseError("bad type inner count %d" % cnt)
    return TNode(name, [_read_type(pkg, r, depth + 1) for _ in range(cnt)])


def _leaf_name(node):
    """Name of a path-like node: 'Vector(CoreUObject(Script))' -> 'Vector'."""
    return node.name


def _path_of(node):
    """Reassemble '/Script/CoreUObject.Vector' from 'Vector(CoreUObject,Script)' style type paths."""
    if not node.kids:
        return node.name
    # AddPath builds: Name(Outer1,Outer2,...) with outers listed outermost-first
    outers = [k.name for k in node.kids]
    if outers and outers[0].startswith("/"):
        return outers[0] + "." + node.name
    return "/".join(outers) + "." + node.name if outers else node.name


# --------------------------------------------------------------------------------------------- values

class _Ctx:
    __slots__ = ("pkg", "warnings", "budget")

    def __init__(self, pkg, warnings):
        self.pkg = pkg
        self.warnings = warnings
        self.budget = 2_000_000  # max elements across one export (safety)


_INT_FMT = {
    "Int8Property": "<b", "Int16Property": "<h", "IntProperty": "<i", "Int64Property": "<q",
    "UInt16Property": "<H", "UInt32Property": "<I", "UInt64Property": "<Q",
    "FloatProperty": "<f", "DoubleProperty": "<d",
}
_REF_TYPES = {"ObjectProperty", "ClassProperty", "ObjectPtrProperty", "ClassPtrProperty",
              "InterfaceProperty", "WeakObjectProperty", "WeakObjectPtrProperty"}
_SOFT_TYPES = {"SoftObjectProperty", "SoftClassProperty"}
_NATIVE_FLOAT_STRUCTS = {
    # name -> (fields, count) ; read as doubles when size matches 8*n, floats when 4*n
    "Vector": ("XYZ", 3), "Vector3d": ("XYZ", 3), "Vector3f": ("XYZ", 3),
    "Vector2D": ("XY", 2), "Vector2d": ("XY", 2), "Vector2f": ("XY", 2),
    "Vector4": ("XYZW", 4), "Vector4d": ("XYZW", 4), "Vector4f": ("XYZW", 4),
    "Rotator": ("PYR", 3), "Rotator3d": ("PYR", 3), "Rotator3f": ("PYR", 3),
    "Quat": ("XYZW", 4), "Quat4d": ("XYZW", 4), "Quat4f": ("XYZW", 4),
    "Plane": ("XYZW", 4), "Plane4d": ("XYZW", 4), "Plane4f": ("XYZW", 4),
}
_OLD_NATIVE_STRUCTS = None  # set below
_NATIVE_FIXED_STRUCTS = {"Color", "LinearColor", "Guid", "IntPoint", "IntVector", "UintVector",
                         "IntVector4", "SoftObjectPath", "SoftClassPath", "TopLevelAssetPath",
                         "DateTime", "Timespan", "GameplayTag", "Int32Point", "UintPoint"}


_OLD_NATIVE_STRUCTS = (set(_NATIVE_FLOAT_STRUCTS) | _NATIVE_FIXED_STRUCTS | {"Box", "Box2D"}) - {"GameplayTag"}


def _enum_value(pkg, r):
    return pkg.read_name(r)


def _read_text(ctx, r):
    flags = r.u32()
    h = r.i8()
    if h == -1:
        if r.boolean():
            return r.fstring()
        return ""
    if h == 0:
        r.fstring()  # namespace
        key = r.fstring()
        src = r.fstring()
        sm = ctx.pkg.summary
        if not sm.get("package_flags", 0) & PKG_FilterEditorOnly and sm.get("custom_versions", {}).get(_FORTNITE_MAIN_GUID, 0) >= 260:
            r.fstring()  # DevNotes (FortniteMain AddDevNotesToFText), present in editor packages
        return src
    if h == 11:
        table = ctx.pkg.read_name(r)
        key = r.fstring()
        return "LOCTABLE(%s, %s)" % (table, key)
    raise ParseError("unsupported FText history type %d" % h)


def _read_native_struct(ctx, name, r, end, size):
    """Native/binary struct payload. size = total payload size when known (top-level), else -1."""
    pkg = ctx.pkg
    if name in _NATIVE_FLOAT_STRUCTS:
        fields, n = _NATIVE_FLOAT_STRUCTS[name]
        if name.endswith("f") and not name.endswith("Vector2f"):
            dbl = False
        elif name.endswith("f") or name.endswith("3f") or name.endswith("4f"):
            dbl = False
        elif size >= 0:
            dbl = size == 8 * n
        else:
            dbl = True
        if size >= 0 and size not in (8 * n, 4 * n):
            raise ParseError("unexpected %s payload size %d" % (name, size))
        if size < 0 and ctx.pkg.ue5 < 1004:
            dbl = False
        vals = [r.f64() if dbl else r.f32() for _ in range(n)]
        return Struct(name, zip(fields, vals))
    if name == "Box":
        dbl = size < 0 or size == 49
        rd = r.f64 if dbl else r.f32
        mn = Struct("Vector", X=rd(), Y=rd(), Z=rd())
        mx = Struct("Vector", X=rd(), Y=rd(), Z=rd())
        return Struct(name, Min=mn, Max=mx, IsValid=r.u8())
    if name == "Box2D":
        dbl = size < 0 or size == 33
        rd = r.f64 if dbl else r.f32
        mn = Struct("Vector2D", X=rd(), Y=rd())
        mx = Struct("Vector2D", X=rd(), Y=rd())
        return Struct(name, Min=mn, Max=mx, bIsValid=r.u8())
    if name == "Color":
        b, g, rr, a = r.u8(), r.u8(), r.u8(), r.u8()
        return Struct(name, B=b, G=g, R=rr, A=a)
    if name == "LinearColor":
        return Struct(name, R=r.f32(), G=r.f32(), B=r.f32(), A=r.f32())
    if name == "Guid":
        a, b, c, d = r.u32(), r.u32(), r.u32(), r.u32()
        return Struct(name, Guid="%08X%08X%08X%08X" % (a, b, c, d))
    if name in ("IntPoint", "Int32Point"):
        return Struct(name, X=r.i32(), Y=r.i32())
    if name == "UintPoint":
        return Struct(name, X=r.u32(), Y=r.u32())
    if name == "IntVector":
        return Struct(name, X=r.i32(), Y=r.i32(), Z=r.i32())
    if name == "UintVector":
        return Struct(name, X=r.u32(), Y=r.u32(), Z=r.u32())
    if name == "IntVector4":
        return Struct(name, X=r.i32(), Y=r.i32(), Z=r.i32(), W=r.i32())
    if name in ("SoftObjectPath", "SoftClassPath"):
        return _read_softpath(ctx, r)
    if name == "TopLevelAssetPath":
        p = pkg.read_name(r)
        a = pkg.read_name(r)
        return ObjRef("" if p == "None" else (p + "." + a if a != "None" else p))
    if name == "DateTime":
        return Struct(name, Ticks=r.i64())
    if name == "Timespan":
        return Struct(name, Ticks=r.i64())
    if name == "GameplayTag":
        return Struct(name, TagName=pkg.read_name(r))
    raise ParseError("no native reader for struct %s" % name)


def _read_softpath(ctx, r):
    pkg = ctx.pkg
    if pkg.softpaths:
        i = r.i32()
        if i < 0 or i >= len(pkg.softpaths):
            raise ParseError("soft object path index %d out of range" % i)
        return ObjRef(pkg.softpaths[i])
    p = pkg.read_name(r)
    a = pkg.read_name(r)
    sub = r.fstring()
    s = p if a in ("None", "") else p + "." + a
    return ObjRef(s + (":" + sub if sub else ""))


def _read_value(ctx, node, r, end, native, size, flags_bool=None):
    """Read one value of type `node`. size = payload size when known else -1. native = binary/native flag."""
    pkg = ctx.pkg
    t = node.name
    ctx.budget -= 1
    if ctx.budget < 0:
        raise ParseError("element budget exceeded")
    if t == "BoolProperty":
        return r.u8() != 0 if flags_bool is None else flags_bool
    f = _INT_FMT.get(t)
    if f is not None:
        sz = struct.calcsize(f)
        r.need(sz)
        v = struct.unpack_from(f, r.b, r.p)[0]
        r.p += sz
        return v
    if t == "ByteProperty":
        if node.kids:
            return _enum_value(pkg, r)
        if size == 8 and r.p + 8 <= end:
            return _enum_value(pkg, r)
        return r.u8()
    if t == "EnumProperty":
        if size == 8 or size < 0 or (node.kids and r.p + 8 <= end and size not in (1, 2, 4)):
            return _enum_value(pkg, r)
        return {1: r.u8, 2: r.u16, 4: r.u32}.get(size, r.u8)()
    if t == "NameProperty":
        return pkg.read_name(r)
    if t == "StrProperty":
        return r.fstring()
    if t == "TextProperty":
        return _read_text(ctx, r)
    if t in _REF_TYPES:
        return ObjRef(pkg.object_path(r.i32()))
    if t in _SOFT_TYPES:
        return _read_softpath(ctx, r)
    if t == "LazyObjectProperty":
        return Struct("Guid", Guid=r.raw(16).hex().upper())
    if t == "StructProperty":
        sname = node.kids[0].name if node.kids else ""
        if native:
            return _read_native_struct(ctx, sname, r, end, size)
        return _read_tagged_struct(ctx, sname, r, end)
    if t == "ArrayProperty":
        cnt = r.i32()
        if cnt < 0 or cnt > 10_000_000:
            raise ParseError("bad array count %d" % cnt)
        inner = node.kids[0] if node.kids else TNode("", [])
        if ctx.pkg.ue5 < UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME and inner.name == "StructProperty" and not inner.kids and cnt > 0:
            inner = _read_old_inner_struct_tag(ctx, r)
            native = inner.kids[0].name in _OLD_NATIVE_STRUCTS
        out = []
        for _ in range(cnt):
            out.append(_read_value(ctx, inner, r, end, native, -1))
        return out
    if t == "SetProperty":
        removed = r.i32()
        if removed:
            raise ParseError("set with removed entries")
        cnt = r.i32()
        if cnt < 0 or cnt > 10_000_000:
            raise ParseError("bad set count %d" % cnt)
        inner = node.kids[0] if node.kids else TNode("", [])
        return SetValue(_read_value(ctx, inner, r, end, native, -1) for _ in range(cnt))
    if t == "MapProperty":
        removed = r.i32()
        if removed:
            raise ParseError("map with removed entries")
        cnt = r.i32()
        if cnt < 0 or cnt > 10_000_000:
            raise ParseError("bad map count %d" % cnt)
        if len(node.kids) < 2:
            raise ParseError("map type without key/value types")
        kt, vt = node.kids[0], node.kids[1]
        out = MapValue()
        for _ in range(cnt):
            k = _read_value(ctx, kt, r, end, native, -1)
            v = _read_value(ctx, vt, r, end, native, -1)
            out.append((k, v))
        return out
    if t == "OptionalProperty":
        if r.u8() == 0:
            return None
        return _read_value(ctx, node.kids[0], r, end, native, -1)
    if t in ("MulticastInlineDelegateProperty", "MulticastSparseDelegateProperty", "MulticastDelegateProperty"):
        cnt = r.i32()
        if cnt < 0 or cnt > 100000:
            raise ParseError("bad delegate count")
        out = []
        for _ in range(cnt):
            obj = pkg.object_path(r.i32())
            out.append(ObjRef("%s::%s" % (obj, pkg.read_name(r))))
        return out
    if t in ("DelegateProperty",):
        obj = pkg.object_path(r.i32())
        fn = pkg.read_name(r)
        return ObjRef("%s::%s" % (obj, fn) if obj or fn != "None" else "")
    raise ParseError("unsupported property type %s" % node)


def _read_tagged_struct(ctx, sname, r, end):
    props, complete = _read_tag_stream(ctx, r, end, in_struct=True)
    s = Struct(sname)
    for p in props:
        key = p.name if p.index == 0 else "%s[%d]" % (p.name, p.index)
        s[key] = p.value
    if not complete:
        raise ParseError("struct %s: tag stream not terminated" % sname)
    return s


def _read_old_inner_struct_tag(ctx, r):
    """Pre-5.4 array-of-struct inner tag (name, type, size, index, struct name+guid, has-guid)."""
    pkg = ctx.pkg
    pkg.read_name(r)
    t = pkg.read_name(r)
    r.i32()
    r.i32()
    if t != "StructProperty":
        raise ParseError("array inner tag type %s" % t)
    sname = pkg.read_name(r)
    r.raw(16)
    if r.u8():
        r.raw(16)
    return TNode("StructProperty", [TNode(sname, [])])


def _read_tag(pkg, r):
    """Read one property tag. Returns None at the terminator, else
    (name, type_node, size, index, flags) with flags bits: 8 native, 0x10 bool-true, 0x20 skipped."""
    name = pkg.read_name(r)
    if name == "None":
        return None
    if pkg.ue5 >= UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME:
        tnode = _read_type(pkg, r)
        size = r.i32()
        flags = r.u8()
        index = 0
        if flags & 0x01:
            index = r.i32()
        if flags & 0x02:
            r.raw(16)
        if flags & 0x04:
            _read_tag_ext(r)
        return name, tnode, size, index, flags
    # ---- legacy tag (LoadPropertyTagNoFullType)
    typ = pkg.read_name(r)
    size = r.i32()
    index = r.i32()
    flags = 0
    kids = []
    if typ == "StructProperty":
        sname = pkg.read_name(r)
        r.raw(16)
        kids = [TNode(sname, [])]
        if sname in _OLD_NATIVE_STRUCTS:
            flags |= 0x08
    elif typ == "BoolProperty":
        if r.u8():
            flags |= 0x10
    elif typ == "ByteProperty":
        en = pkg.read_name(r)
        kids = [TNode(en, [])] if en != "None" else []
    elif typ == "EnumProperty":
        en = pkg.read_name(r)
        kids = [TNode(en, []), TNode("ByteProperty", [])]
    elif typ in ("ArrayProperty", "SetProperty", "OptionalProperty"):
        kids = [TNode(pkg.read_name(r), [])]
    elif typ == "MapProperty":
        kids = [TNode(pkg.read_name(r), []), TNode(pkg.read_name(r), [])]
    if r.u8():
        r.raw(16)
    if pkg.ue5 >= UE5_PROPERTY_TAG_EXTENSION:
        _read_tag_ext(r)
    return name, TNode(typ, kids), size, index, flags


def _read_tag_ext(r):
    ext = r.u8()
    if ext & 0x02:
        r.u8()        # EOverriddenPropertyOperation
        r.boolean()   # bExperimentalOverridableLogic
    if ext & 0x04:
        r.boolean()   # bExperimentalExternalObjects


def _read_tag_stream(ctx, r, end, in_struct=False):
    """Reads tags until the None terminator. Returns (props, complete)."""
    props = []
    pkg = ctx.pkg
    while True:
        if r.p + 8 > end:
            return props, False
        tag = _read_tag(pkg, r)
        if tag is None:
            return props, True
        name, tnode, size, index, flags = tag
        if size < 0 or r.p + size > end:
            raise ParseError("tag '%s' size %d overruns its region" % (name, size))
        data_start = r.p
        data_end = data_start + size
        native = bool(flags & 0x08)
        if flags & 0x20:
            value = Unparsed(str(tnode), size, "skipped serialize")
        else:
            try:
                if tnode.name == "BoolProperty":
                    value = bool(flags & 0x10)
                else:
                    sub = Reader(r.b, data_start, r.base)
                    value = _read_value(ctx, tnode, sub, data_end, native, size)
                    if sub.p != data_end:
                        raise ParseError("read %d of %d bytes" % (sub.p - data_start, size))
            except (ParseError, struct.error, IndexError, ValueError) as ex:
                value = Unparsed(str(tnode), size, str(ex))
                ctx.warnings.append("%s (%s): %s" % (name, tnode, ex))
        r.p = data_end
        props.append(Prop(name, str(tnode), index, value, size))


def _read_export_props(pkg, i):
    res = ExportProps()
    if i < 0 or i >= len(pkg.exports):
        res.warnings.append("export index %d out of range" % i)
        res.complete = False
        return res
    e = pkg.exports[i]
    try:
        if e.serial_size <= 0:
            return res
        if pkg.ue5 >= UE5_SCRIPT_SERIALIZATION_OFFSET and e.script_end > e.script_start >= 0:
            start = e.serial_offset + e.script_start
            end = e.serial_offset + e.script_end
        else:
            start = e.serial_offset
            end = e.serial_offset + e.serial_size
        if start < 0 or end > pkg.size or start > end:
            raise ParseError("export range [%d,%d) outside file (%d)" % (start, end, pkg.size))
        buf = pkg.read_range(start, end - start)
        if len(buf) != end - start:
            raise ParseError("short read of export data")
        r = Reader(buf, 0, start)
        ctx = _Ctx(pkg, res.warnings)
        if pkg.ue5 >= UE5_PROPERTY_TAG_EXTENSION:
            ctl = r.u8()          # EClassSerializationControlExtension
            res.control = ctl
            if ctl & 0x02:
                r.u8()            # overridable-serialization operation
        props, complete = _read_tag_stream(ctx, r, len(buf))
        res.props = props
        res.complete = complete
        if not complete:
            res.warnings.append("tag stream ended without terminator at +%d of %d" % (r.p, len(buf)))
    except (ParseError, struct.error, IndexError, OSError) as ex:
        res.complete = False
        res.warnings.append("export %d (%s): %s" % (i, e.name, ex))
    return res


# --------------------------------------------------------------------------------------------- display

def _fmt_float(v):
    if v != v:
        return "nan"
    if v in (float("inf"), float("-inf")):
        return "inf" if v > 0 else "-inf"
    s = "%.6f" % v
    s = s.rstrip("0").rstrip(".") if "." in s else s
    return "0" if s in ("-0", "") else s


def display(v, top=True):
    """Render a value roughly like UE ExportText."""
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, float):
        return _fmt_float(v)
    if isinstance(v, ObjRef):
        return v if top else ('"%s"' % v)
    if isinstance(v, str):
        return v if top else '"%s"' % v
    if isinstance(v, Struct):
        if v.type == "GameplayTag" and "TagName" in v:
            return "(TagName=\"%s\")" % v["TagName"] if not top else str(v["TagName"])
        if v.type == "Guid" and "Guid" in v:
            return v["Guid"]
        return "(" + ",".join("%s=%s" % (k, display(x, False)) for k, x in v.items()) + ")"
    if isinstance(v, MapValue):
        return "(" + ",".join("(%s,%s)" % (display(k, False), display(x, False)) for k, x in v) + ")"
    if isinstance(v, list):
        return "(" + ",".join(display(x, False) for x in v) + ")"
    if v is None:
        return "None"
    if isinstance(v, Unparsed):
        return repr(v)
    return str(v)


def to_json(v):
    """JSON-serializable form of a value."""
    if isinstance(v, bool) or v is None or isinstance(v, (int, str)):
        return str(v) if isinstance(v, ObjRef) else v
    if isinstance(v, float):
        return v if v == v and v not in (float("inf"), float("-inf")) else str(v)
    if isinstance(v, Struct):
        d = {k: to_json(x) for k, x in v.items()}
        d["$struct"] = v.type
        return d
    if isinstance(v, MapValue):
        return [[to_json(k), to_json(x)] for k, x in v]
    if isinstance(v, list):
        return [to_json(x) for x in v]
    if isinstance(v, Unparsed):
        return {"$unparsed": v.type, "reason": v.reason}
    return str(v)
