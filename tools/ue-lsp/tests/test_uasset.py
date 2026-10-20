"""Tests for ue_lsp.uasset / ue_lsp.bpvalues.

Synthetic byte buffers only (no files). Project-specific asset tests live in tests/local/ (not in git).
Run:  python -I tests/test_uasset.py      (from ue-lsp)
"""
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ue_lsp import uasset, bpvalues  # noqa: E402


def fs(s):
    b = s.encode("utf-8") + b"\0"
    return struct.pack("<i", len(b)) + b


class Builder:
    """Builds a fake 5.8 package context + tag stream bytes."""

    def __init__(self):
        self.names = ["None"]

    def n(self, name):
        if name not in self.names:
            self.names.append(name)
        return struct.pack("<ii", self.names.index(name), 0)

    def type(self, name, *kids):
        out = self.n(name) + struct.pack("<i", len(kids))
        for k in kids:
            out += k if isinstance(k, bytes) else self.type(k)
        return out

    def tag(self, name, typ, data, flags=0):
        return self.n(name) + typ + struct.pack("<i", len(data)) + bytes([flags]) + data

    def end(self):
        return self.n("None")

    def package(self):
        p = uasset.Package("<mem>")
        p.names = self.names
        p.ue4, p.ue5 = 522, 1018
        p.package_name = "/Game/T"
        p.summary = {"package_flags": 0, "custom_versions": {uasset._FORTNITE_MAIN_GUID: 260}}
        return p


def parse(b, data, warnings=None):
    pkg = b.package()
    ctx = uasset._Ctx(pkg, warnings if warnings is not None else [])
    r = uasset.Reader(data)
    return uasset._read_tag_stream(ctx, r, len(data))


class TestSynthetic(unittest.TestCase):
    def test_scalars(self):
        b = Builder()
        d = b.tag("Count", b.type("IntProperty"), struct.pack("<i", 42))
        d += b.tag("Speed", b.type("FloatProperty"), struct.pack("<f", 1.5))
        d += b.tag("Big", b.type("DoubleProperty"), struct.pack("<d", 2.25))
        d += b.tag("U", b.type("UInt16Property"), struct.pack("<H", 65535))
        d += b.tag("I8", b.type("Int8Property"), struct.pack("<b", -3))
        d += b.tag("L", b.type("Int64Property"), struct.pack("<q", -(1 << 40)))
        d += b.tag("bOn", b.type("BoolProperty"), b"", 0x10)
        d += b.tag("bOff", b.type("BoolProperty"), b"", 0)
        d += b.tag("Label", b.type("NameProperty"), b.n("Hello"))
        d += b.tag("Str", b.type("StrProperty"), fs("plain"))
        d += b.end()
        props, complete = parse(b, d)
        self.assertTrue(complete)
        v = {p.name: p.value for p in props}
        self.assertEqual(v["Count"], 42)
        self.assertAlmostEqual(v["Speed"], 1.5)
        self.assertEqual(v["Big"], 2.25)
        self.assertEqual(v["U"], 65535)
        self.assertEqual(v["I8"], -3)
        self.assertEqual(v["L"], -(1 << 40))
        self.assertIs(v["bOn"], True)
        self.assertIs(v["bOff"], False)
        self.assertEqual(v["Label"], "Hello")
        self.assertEqual(v["Str"], "plain")

    def test_wide_string(self):
        r = uasset.Reader(struct.pack("<i", -3) + "h\u00e9".encode("utf-16-le") + b"\0\0")
        self.assertEqual(r.fstring(), "h\u00e9")

    def test_name_number_suffix(self):
        b = Builder()
        b.names.append("Foo")
        d = b.tag("N", b.type("NameProperty"), struct.pack("<ii", b.names.index("Foo"), 3)) + b.end()
        props, _ = parse(b, d)
        self.assertEqual(props[0].value, "Foo_2")

    def test_enum_and_byte(self):
        b = Builder()
        d = b.tag("E", b.type("EnumProperty", "EMode", "ByteProperty"), b.n("EMode::Fast"))
        d += b.tag("B", b.type("ByteProperty"), bytes([7]))
        d += b.tag("BE", b.type("ByteProperty", "EMode"), b.n("EMode::Slow"))
        d += b.end()
        props, _ = parse(b, d)
        self.assertEqual([p.value for p in props], ["EMode::Fast", 7, "EMode::Slow"])

    def test_native_vector_double_and_float(self):
        b = Builder()
        st = b.type("StructProperty", "Vector")
        d = b.tag("Loc", st, struct.pack("<3d", 1, 2, 3), 0x08)
        d += b.tag("Loc3f", st, struct.pack("<3f", 4, 5, 6), 0x08)
        d += b.end()
        props, _ = parse(b, d)
        self.assertEqual(dict(props[0].value), {"X": 1.0, "Y": 2.0, "Z": 3.0})
        self.assertEqual(props[1].value["Z"], 6.0)
        self.assertEqual(uasset.display(props[0].value), "(X=1,Y=2,Z=3)")

    def test_native_quat_rotator_vec2(self):
        b = Builder()
        d = b.tag("Q", b.type("StructProperty", "Quat"), struct.pack("<4d", 0, 0, 0, 1), 0x08)
        d += b.tag("R", b.type("StructProperty", "Rotator"), struct.pack("<3d", 10, 20, 30), 0x08)
        d += b.tag("V2", b.type("StructProperty", "Vector2D"), struct.pack("<2d", 1, 2), 0x08)
        d += b.end()
        props, _ = parse(b, d)
        self.assertEqual(props[0].value["W"], 1.0)
        self.assertEqual(props[1].value["Y"], 20.0)
        self.assertEqual(props[2].value["Y"], 2.0)

    def test_native_color_guid_intpoint(self):
        b = Builder()
        d = b.tag("C", b.type("StructProperty", "Color"), bytes([1, 2, 3, 4]), 0x08)
        d += b.tag("LC", b.type("StructProperty", "LinearColor"), struct.pack("<4f", 1, 0.5, 0, 1), 0x08)
        d += b.tag("G", b.type("StructProperty", "Guid"), struct.pack("<4I", 1, 2, 3, 4), 0x08)
        d += b.tag("P", b.type("StructProperty", "IntPoint"), struct.pack("<ii", -1, 9), 0x08)
        d += b.end()
        props, _ = parse(b, d)
        self.assertEqual((props[0].value["B"], props[0].value["A"]), (1, 4))
        self.assertEqual(props[1].value["G"], 0.5)
        self.assertEqual(props[2].value["Guid"], "00000001000000020000000300000004")
        self.assertEqual(dict(props[3].value), {"X": -1, "Y": 9})

    def test_tagged_struct_gameplay_tag_and_array(self):
        b = Builder()
        inner = b.tag("TagName", b.type("NameProperty"), b.n("A.B.C")) + b.end()
        d = b.tag("Tag", b.type("StructProperty", "GameplayTag"), inner)
        arr = struct.pack("<i", 2) + b.n("x") + b.n("y")
        d += b.tag("Names", b.type("ArrayProperty", "NameProperty"), arr)
        d += b.end()
        props, complete = parse(b, d)
        self.assertTrue(complete)
        self.assertEqual(uasset.display(props[0].value), "A.B.C")
        self.assertEqual(props[1].value, ["x", "y"])
        self.assertEqual(uasset.display(props[1].value), '("x","y")')

    def test_set_map(self):
        b = Builder()
        st = struct.pack("<ii", 0, 2) + struct.pack("<i", 5) + struct.pack("<i", 6)
        d = b.tag("S", b.type("SetProperty", "IntProperty"), st)
        mp = struct.pack("<ii", 0, 1) + b.n("k") + struct.pack("<f", 2.0)
        d += b.tag("M", b.type("MapProperty", "NameProperty", "FloatProperty"), mp)
        d += b.end()
        props, _ = parse(b, d)
        self.assertEqual(list(props[0].value), [5, 6])
        self.assertEqual(list(props[1].value), [("k", 2.0)])

    def test_text_forms(self):
        b = Builder()
        base = struct.pack("<Ib", 0, 0) + fs("NS") + fs("KEY") + fs("Source text") + fs("")
        inv = struct.pack("<Ib", 0, -1) + struct.pack("<i", 1) + fs("Invariant")
        none = struct.pack("<Ib", 0, -1) + struct.pack("<i", 0)
        tbl = struct.pack("<Ib", 0, 11) + b.n("MyTable") + fs("Entry")
        d = b.tag("A", b.type("TextProperty"), base) + b.tag("B", b.type("TextProperty"), inv)
        d += b.tag("C", b.type("TextProperty"), none) + b.tag("D", b.type("TextProperty"), tbl) + b.end()
        props, _ = parse(b, d)
        self.assertEqual([p.value for p in props], ["Source text", "Invariant", "", "LOCTABLE(MyTable, Entry)"])

    def test_unknown_type_skipped_by_size(self):
        b = Builder()
        d = b.tag("Weird", b.type("FancyNewProperty"), b"\x01\x02\x03\x04\x05")
        d += b.tag("After", b.type("IntProperty"), struct.pack("<i", 7)) + b.end()
        w = []
        props, complete = parse(b, d, w)
        self.assertTrue(complete)
        self.assertIsInstance(props[0].value, uasset.Unparsed)
        self.assertEqual(props[1].value, 7)
        self.assertTrue(w)

    def test_unknown_native_struct_skipped(self):
        b = Builder()
        d = b.tag("X", b.type("StructProperty", "MovieSceneFloatChannel"), b"\xAA" * 10, 0x08)
        d += b.tag("After", b.type("IntProperty"), struct.pack("<i", 1)) + b.end()
        props, complete = parse(b, d)
        self.assertTrue(complete)
        self.assertIsInstance(props[0].value, uasset.Unparsed)
        self.assertEqual(props[1].value, 1)

    def test_truncated_only_parse_errors(self):
        b = Builder()
        d = b.tag("A", b.type("IntProperty"), struct.pack("<i", 1)) + b.tag("B", b.type("IntProperty"), struct.pack("<i", 2))
        for cut in range(0, len(d)):
            ctx = uasset._Ctx(b.package(), [])
            try:
                uasset._read_tag_stream(ctx, uasset.Reader(d[:cut]), cut)
            except uasset.ParseError:
                pass  # the only allowed escape; export_props catches it

    def test_object_refs_resolve(self):
        b = Builder()
        pkg = b.package()
        imp = uasset.Import()
        imp.class_package, imp.class_name, imp.outer_index, imp.name, imp.package_name = "/Script/CoreUObject", "Package", 0, "/Script/Engine", "None"
        imp2 = uasset.Import()
        imp2.class_package, imp2.class_name, imp2.outer_index, imp2.name, imp2.package_name = "/Script/CoreUObject", "Class", -1, "Actor", "None"
        pkg.imports = [imp, imp2]
        self.assertEqual(pkg.object_path(-2), "/Script/Engine.Actor")
        self.assertEqual(pkg.object_path(0), "")

    def test_garbage_files(self):
        with tempfile.TemporaryDirectory() as d:
            cases = (("a.uasset", b""), ("b.uasset", b"\x00" * 100),
                     ("c.uasset", struct.pack("<I", uasset.PACKAGE_TAG) + b"\xff" * 60),
                     ("d.uasset", struct.pack("<IiiiI", uasset.PACKAGE_TAG, -8, 0, 0, 0) + b"\0" * 64))
            for name, data in cases:
                p = os.path.join(d, name)
                with open(p, "wb") as f:
                    f.write(data)
                pk = uasset.open_package(p)
                self.assertTrue(pk.error or pk.unsupported, name)
            # unversioned detection: legacy -8, all version fields zero
            pk = uasset.open_package(os.path.join(d, "d.uasset"))
            self.assertIn("unversioned", pk.unsupported or "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
