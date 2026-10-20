"""Unit tests against the real engine and a real UE project (both read-only).

Run:  python -m unittest discover -s tests -p "test_units.py" -v   (from the ue-lsp directory)
Env:  UE_ENGINE_ROOT (default D:/UnrealEngine/UE_5.8), UE_PROJECT_DIR (required; the module is skipped without it)
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ue_lsp import cpp, engine, headers, index, ini, inifeat, specs  # noqa: E402

ENGINE = os.environ.get("UE_ENGINE_ROOT", r"D:/UnrealEngine/UE_5.8")
PROJECT = os.environ.get("UE_PROJECT_DIR", "")

if not os.path.isfile(os.path.join(PROJECT, "Config", "DefaultEngine.ini")):
    if __name__ == "__main__":
        print("skipped: set UE_PROJECT_DIR to a UE project to run these tests")
        sys.exit(0)
    raise unittest.SkipTest("set UE_PROJECT_DIR to a UE project to run these tests")
RS_H = os.path.join(ENGINE, "Engine", "Source", "Runtime", "Engine", "Classes", "Engine", "RendererSettings.h")

_SPECDB = None
_IDX = None


def specdb():
    global _SPECDB
    if _SPECDB is None:
        _SPECDB = specs.build_spec_db(ENGINE)
    return _SPECDB


def idx():
    global _IDX
    if _IDX is None:
        ix = index.Indexer(ENGINE, PROJECT)
        d, _ = ix.refresh()
        _IDX = d or index.load_derived(ix.engine, ix.project)
    return _IDX


class TestEngineLocate(unittest.TestCase):
    def test_uproject_and_engine(self):
        up = engine.find_uproject(os.path.join(PROJECT, "Config"))
        self.assertTrue(up and up.endswith(".uproject"))
        root, how = engine.resolve_engine(up)
        self.assertIsNotNone(root, how)
        self.assertEqual(os.path.normcase(os.path.normpath(root)), os.path.normcase(os.path.normpath(ENGINE)))


class TestSpecs(unittest.TestCase):
    def test_uht_table_chain(self):
        db = specdb()
        self.assertEqual(specs.table_chain("Class", db["parents"]),
                         ["Class", "ClassBase", "Struct", "Field", "Object", "Default"])
        self.assertEqual(specs.table_chain("PropertyMember", db["parents"]), ["PropertyMember", "Default"])

    def test_editanywhere(self):
        e = specdb()["macros"]["UPROPERTY"]["editanywhere"]
        self.assertEqual(e["name"], "EditAnywhere")
        self.assertEqual(e["value_type"], "None")
        self.assertTrue(e["file"].endswith("UhtPropertyMemberSpecifiers.cs"))
        with open(e["file"], encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertIn("UhtSpecifier(", lines[e["line"] - 1])
        self.assertIn("EditAnywhereSpecifier", lines[e["line"]])
        self.assertIn("edited by property windows", e["doc"])
        with open(os.path.join(ENGINE, specs.OBJMACROS_REL), encoding="utf-8", errors="replace") as f:
            om = f.read().splitlines()
        self.assertEqual(om[e["doc_line"] - 1].strip(), "EditAnywhere,")

    def test_value_types_and_default_table(self):
        m = specdb()["macros"]
        self.assertEqual(m["UCLASS"]["config"]["value_type"], "SingleString")
        self.assertEqual(m["UPROPERTY"]["meta"]["value_type"], "KeyValuePairList")
        self.assertIn("category", m["UFUNCTION"])  # from Default table
        self.assertIn("blueprintcallable", m["UFUNCTION"])
        self.assertNotIn("editanywhere", m["UFUNCTION"])
        self.assertIn("ref", m["UPARAM"])

    def test_meta_keys(self):
        meta = specdb()["meta"]
        self.assertIn("property", meta["clampmin"]["contexts"])
        self.assertIn("Specifies the minimum value", meta["clampmin"]["doc"])
        # commented-out cross reference entries still give contexts
        self.assertTrue({"class", "property", "function"} <= set(meta["displayname"]["contexts"]))
        props = cpp.meta_entries(specdb(), "UPROPERTY")
        self.assertIn("clampmax", props)
        self.assertIn("tooltip", props)  # 'any UField' group

    def test_mismatch_report_shape(self):
        mm = specdb()["mismatches"]
        names = {(k, m, n) for k, m, n, _ in mm}
        # UPARAM-only specifiers documented in UP namespace
        self.assertIn(("doc_only", "UPROPERTY", "Ref"), names)


class TestHeaders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(RS_H, "rb") as f:
            cls.res = headers.parse_header(f.read())

    def test_renderer_settings_class(self):
        c = next(c for c in self.res["classes"] if c["name"] == "URendererSettings")
        self.assertEqual(c["config"], "Engine")
        self.assertIn("defaultconfig", c["flags"])
        self.assertEqual(c["parent"], "UDeveloperSettings")
        p = next(p for p in c["props"] if p.get("cvar") == "r.GPUCrashDebugging")
        self.assertEqual(p["name"], "bGpuCrashDebugging")
        self.assertEqual(p["type"], "bool")  # uint32 bitfield

    def test_enum_values(self):
        e = next(e for e in self.res["enums"] if e["name"] == "EMobileShadingPath")
        vals = [(v["name"], v["value"], v["display"]) for v in e["values"]]
        self.assertEqual(vals[:2], [("Forward", 0, "Forward Shading"), ("Deferred", 1, "Deferred Shading")])
        with open(RS_H, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        self.assertIn("Deferred = 1", lines[e["values"][1]["line"] - 1])

    def test_enum_with_commas_in_comments(self):
        src = b"UENUM()\nenum class EX : uint8\n{\n\t/** a, b, c */\n\tA,\n\t// d, e\n\tB UMETA(DisplayName=\"Bee, really\"),\n\tC = 5,\n\tD\n};\n"
        e = headers.parse_header(src)["enums"][0]
        self.assertEqual([(v["name"], v["value"]) for v in e["values"]], [("A", 0), ("B", 1), ("C", 5), ("D", 6)])
        self.assertEqual(e["values"][1]["display"], "Bee, really")
        self.assertEqual(e["values"][3]["line"], 9)


class TestDerivedIndex(unittest.TestCase):
    def test_renderer_settings_section(self):
        cc = idx()["config_classes"]["/script/engine.renderersettings"]
        self.assertEqual(cc["class"], "URendererSettings")
        self.assertEqual(cc["config"], "Engine")
        self.assertTrue(cc["file"].endswith("RendererSettings.h"))
        p = inifeat.find_prop(cc, "r.DynamicGlobalIlluminationMethod")
        self.assertEqual(p["name"], "DynamicGlobalIllumination")

    def test_section_override_and_project_class(self):
        d = idx()
        self.assertIn("/script/windowstargetplatform.windowstargetsettings", d["config_classes"])
        self.assertIn("/script/gameflowsystem.gameflowsubsystemsettings", d["config_classes"])

    def test_ini_sections_seen(self):
        s = idx()["sections"]
        self.assertIn("systemsettings", s)
        self.assertIn("core.log", s)


class TestIniContext(unittest.TestCase):
    T = "[/Script/Engine.RendererSettings]\nr.Mob\nr.DynamicGlobalIlluminationMethod=\n; comment\n+Arr=(A=1,Bx\n[Core.Lo"

    def test_contexts(self):
        self.assertEqual(ini.context_at(self.T, 0, 5)["kind"], "section")
        c = ini.context_at(self.T, 1, 5)
        self.assertEqual((c["kind"], c["section"], c["prefix"]), ("key", "/Script/Engine.RendererSettings", "r.Mob"))
        c = ini.context_at(self.T, 2, 34)
        self.assertEqual((c["kind"], c["key"]), ("value", "r.DynamicGlobalIlluminationMethod"))
        self.assertEqual(ini.context_at(self.T, 3, 5)["kind"], "none")
        c = ini.context_at(self.T, 4, 12)
        self.assertEqual((c["kind"], c["key"], c["prefix"]), ("struct_member", "Arr", "Bx"))
        self.assertEqual(ini.context_at(self.T, 5, 8)["prefix"], "Core.Lo")

    def test_value_completion_cvar_enum(self):
        items, _ = inifeat.complete(idx(), self.T, 2, 34, "DefaultEngine.ini")
        labels = {i["label"]: i["detail"] for i in items}
        self.assertIn("1", labels)
        self.assertIn("Lumen", labels["1"])

    def test_diagnostics(self):
        t = "[/Script/Engine.RendererSettings]\nr.AllowStaticLighting=False\nbGpuCrashDebugging=True\nTotallyBogusKey=1\n[NoSuchSection_xyz]\n"
        ds = inifeat.diagnostics(idx(), t, "C:/nowhere/DefaultEngine.ini")
        self.assertEqual([(d[0], d[3]) for d in ds], [(3, 2), (4, 4)])
        p = os.path.join(PROJECT, "Config", "DefaultEngine.ini")
        with open(p, encoding="utf-8-sig") as f:
            self.assertEqual(inifeat.diagnostics(idx(), f.read(), p), [])


class TestCppContext(unittest.TestCase):
    def test_contexts(self):
        s = "UPROPERTY(EditAnywhere,\n\tmeta=(ClampMin=\"0\", Cl"
        c = cpp.context_at(s, len(s))
        self.assertEqual((c["macro"], c["where"], c["prefix"]), ("UPROPERTY", "meta", "Cl"))
        s = "UFUNCTION(BlueprintCallable, Category=\"A(b\", Bl"
        c = cpp.context_at(s, len(s))
        self.assertEqual((c["where"], c["prefix"]), ("spec", "Bl"))
        s = "UPROPERTY(EditAnywhere)\n\tint32 X"
        self.assertIsNone(cpp.context_at(s, len(s)))
        s = "UCLASS(config="
        self.assertEqual(cpp.context_at(s, len(s))["where"], "spec_value")
        s = "// UPROPERTY(Edit"
        self.assertIsNone(cpp.context_at(s, len(s)))

    def test_diagnostics(self):
        t = "UPROPERTY(EditAnywhere, Bogus, meta=(NotASpecifier))\nint X;\n// UPROPERTY(Nope)\n"
        ds = cpp.diagnostics(t, specdb())
        self.assertEqual(len(ds), 1)
        self.assertEqual(t[ds[0][0]:ds[0][1]], "Bogus")


if __name__ == "__main__":
    unittest.main()
