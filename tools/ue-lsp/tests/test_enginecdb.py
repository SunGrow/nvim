"""Unit tests for ue_lsp.enginecdb (rsp synthesis); synthetic module graph in a temp dir, no engine needed."""
import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ue_lsp import enginecdb as ec  # noqa: E402


def mk(root, rel, text=""):
    p = os.path.join(root, *rel.split("/"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    return p


class Fake(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.src = os.path.join(self.root, "Engine", "Source")
        core = mk(self.root, "Engine/Source/Runtime/Core/Core.Build.cs", "")
        mk(self.root, "Engine/Source/Runtime/Core/Public/CoreSharedPCH.h")
        mk(self.root, "Engine/Source/Runtime/Core/Internal/CoreInternal.h")
        mk(self.root, "Engine/Source/Runtime/Core/Private/A.cpp")
        mk(self.root, "Engine/Source/Runtime/Foo/Public/Foo.h")
        mk(self.root, "Engine/Source/Runtime/Foo/Private/Foo.cpp")
        mk(self.root, "Engine/Source/Runtime/Foo/Private/Android/Skip.cpp")
        mk(self.root, "Engine/Source/Runtime/Foo/Private/ThirdParty/Skip.cpp")
        foo = mk(self.root, "Engine/Source/Runtime/Foo/Foo.Build.cs",
                 'PrivateDefinitions.Add("FOO_MODULE");\n// PrivateDefinitions.Add("COMMENTED");\n'
                 'PrivateDefinitions.AddRange(new string[] { "A=1", "B" });\n'
                 'AddEngineThirdPartyPrivateStaticDependencies(Target, "Zlib2");\n')
        mk(self.root, "Engine/Source/ThirdParty/Zlib2/1.0/include/zlib.h")
        mk(self.root, "Engine/Source/ThirdParty/Zlib2/1.0/lib/x.lib")
        mk(self.root, "Engine/Source/Runtime/Bar/Public/Bar.h")
        mk(self.root, "Engine/Source/Runtime/Bar/Private/Bar.cpp")
        mk(self.root, "Engine/Source/Runtime/Bar/Nested/Inner/Inner.Build.cs")
        mk(self.root, "Engine/Source/Runtime/Bar/Nested/Inner/Private/In.cpp")
        # UHT output: plain module folder and a ShortName folder
        inc = "Engine/Intermediate/Build/Win64/UnrealEditor/Inc"
        mk(self.root, inc + "/Foo/UHT/Foo.generated.h")
        mk(self.root, inc + "/BarShort/UHT/Bar.generated.h")
        mk(self.root, "Engine/Source/Runtime/Bar/Bar.Build.cs", 'ShortName = "BarShort";\n')

        def d(*p):
            return os.path.join(self.src, "Runtime", *p)

        self.mods = {
            "Core": {"Type": "CPlusPlus", "Directory": d("Core"), "Rules": core, "PCHUsage": "UseExplicitOrSharedPCHs",
                     "SharedPCH": d("Core", "Public", "CoreSharedPCH.h"), "PublicIncludePaths": [d("Core", "Public")],
                     "PrivateIncludePaths": [d("Core", "Private")], "PublicDefinitions": ["WITH_CORE=1", "FLAG"],
                     "PublicDependencyModules": [], "PublicIncludePathModules": [], "PrivateDependencyModules": [],
                     "PrivateIncludePathModules": [], "PublicSystemIncludePaths": []},
            "Foo": {"Type": "CPlusPlus", "Directory": d("Foo"), "Rules": foo, "PCHUsage": "UseExplicitOrSharedPCHs",
                    "PublicIncludePaths": [d("Foo", "Public")], "PrivateIncludePaths": [d("Foo", "Private")],
                    "PublicDefinitions": ["FOO_PUB=2"], "PublicDependencyModules": ["Core"],
                    "PublicIncludePathModules": ["Core"], "PrivateDependencyModules": ["Bar"],
                    "PrivateIncludePathModules": [], "PublicSystemIncludePaths": []},
            "Bar": {"Type": "CPlusPlus", "Directory": d("Bar"), "Rules": os.path.join(d("Bar"), "Bar.Build.cs"),
                    "PCHUsage": "UseExplicitOrSharedPCHs", "PublicIncludePaths": [d("Bar", "Public")],
                    "PrivateIncludePaths": [], "PublicDefinitions": ["BAR_PUB"], "PublicDependencyModules": ["Core"],
                    "PublicIncludePathModules": ["Core"], "PrivateDependencyModules": [], "PrivateIncludePathModules": [],
                    "PublicSystemIncludePaths": ["C:/sys/inc"]},
            "Inner": {"Type": "CPlusPlus", "Directory": d("Bar", "Nested", "Inner"), "Rules": "", "PCHUsage": "NoPCHs",
                      "PublicIncludePaths": [], "PrivateIncludePaths": []},
            "LinuxOnly": {"Type": "CPlusPlus", "Directory": d("Linux", "X"), "PublicIncludePaths": []},
            "Ext": {"Type": "External", "Directory": d("Ext")},
            "TP": {"Type": "CPlusPlus", "Directory": os.path.join(self.src, "ThirdParty", "TP")},
            "Proj": {"Type": "CPlusPlus", "Directory": os.path.join(self.root, "Proj", "Source", "Proj")},
        }
        self.graph = ec.ModuleGraph(self.mods, self.root)

    def tearDown(self):
        self.tmp.cleanup()


class TestPure(unittest.TestCase):
    def test_api_name_and_definition_line(self):
        self.assertEqual(ec.api_name("CoreUObject"), "COREUOBJECT_API")
        self.assertEqual(ec.definition_line("A=1"), "#undef A\n#define A 1")
        self.assertEqual(ec.definition_line("FLAG"), "#undef FLAG\n#define FLAG 1")
        self.assertEqual(ec.definition_line('S="x y"'), '#undef S\n#define S "x y"')
        self.assertIsNone(ec.definition_line("=3"))

    def test_base_options_filters(self):
        lines = ["/X", "-Werror", "-Wshadow", "/W4", "/wd4244", "/Z7", "-fstandalone-debug", '/I "../Foo"',
                 '/imsvc "ThirdParty/RapidJSON"', '/imsvc "C:/Program Files/MSVC/INCLUDE"',
                 '/imsvc "D:/UE/Engine/Source/ThirdParty/X"', '/FI"x.h"', '/Yu"p.h"', '/Fp"p.pch"',
                 "-vctoolsdir undefined", "/c", '@"nested.rsp"', "/DSAL_NO_ATTRIBUTE_DECLARATIONS=1"]
        out = ec.base_options(lines, "D:/UE", "D:/Proj")
        for good in ("/X", "/c", "/DSAL_NO_ATTRIBUTE_DECLARATIONS=1", '/imsvc "C:/Program Files/MSVC/INCLUDE"',
                     "/TP", "/std:c++20"):
            self.assertIn(good, out)
        for bad in ("-Werror", "-Wshadow", "/W4", "/wd4244", "/Z7", "-fstandalone-debug", '/I "../Foo"',
                    '/imsvc "ThirdParty/RapidJSON"', '/imsvc "D:/UE/Engine/Source/ThirdParty/X"', '/FI"x.h"',
                    '/Yu"p.h"', '/Fp"p.pch"', "-vctoolsdir undefined", '@"nested.rsp"'):
            self.assertNotIn(bad, out)
        self.assertNotIn("/D__INTELLISENSE__", out)  # changes engine headers (Archive, UE_DEPRECATED)

    def test_common_definitions_strips_module_specific_lines(self):
        with tempfile.TemporaryDirectory() as t:
            sd = mk(t, "Shared.h", "#pragma once\n#define WITH_EDITOR 1\n#define ENGINE_API DLLIMPORT\n"
                                   "#define UE_IS_ENGINE_MODULE 0\n#define UE_VALIDATE_INTERNAL_API 1\n")
            pd = mk(t, "Def.h", '#include "Shared.h"\n#undef X_API\n#define UE_PROJECT_NAME P\n'
                                '#define UE_MODULE_NAME "P"\n#define X_API DLLEXPORT\n#define UE_ENABLE_X 0\n')
            text = ec.common_definitions(pd, sd)
        self.assertIn("#define WITH_EDITOR 1", text)
        self.assertIn("#define ENGINE_API DLLIMPORT", text)
        self.assertIn("#define UE_PROJECT_NAME P", text)
        self.assertIn("#define UE_ENABLE_X 0", text)
        for bad in ("UE_IS_ENGINE_MODULE", "UE_VALIDATE_INTERNAL_API", "UE_MODULE_NAME", "X_API DLLEXPORT"):
            self.assertNotIn(bad, text)


class TestGraph(Fake):
    def test_engine_modules_filter(self):
        names = ec.engine_modules({"Modules": self.mods}, self.root)
        self.assertEqual(names, ["Bar", "Core", "Foo", "Inner"])  # not Linux, External, ThirdParty, project

    def test_module_sources_skip_platform_thirdparty_and_nested(self):
        dirs = {n: self.mods[n]["Directory"] for n in ("Core", "Foo", "Bar", "Inner")}
        foo = [os.path.basename(f) for f in ec.module_sources("Foo", self.mods["Foo"], dirs)]
        self.assertEqual(foo, ["Foo.cpp"])
        bar = ec.module_sources("Bar", self.mods["Bar"], dirs)
        self.assertEqual([os.path.basename(f) for f in bar], ["Bar.cpp"])  # Nested/Inner belongs to Inner
        self.assertTrue(all("\\" not in f for f in bar))

    def test_include_dirs_transitive_and_generated(self):
        inc, sysinc, vis = self.graph.include_dirs("Foo")
        root = self.root.replace("\\", "/")
        norm = [p.replace(root, "") for p in inc]
        self.assertTrue(norm[0].endswith("/Inc/Foo/UHT"), norm[0])  # own generated dir first
        self.assertIn("/Engine/Source/Runtime/Foo/Private", norm)
        self.assertIn("/Engine/Source/Runtime/Foo/Public", norm)
        self.assertIn("/Engine/Source/Runtime/Core/Public", norm)
        self.assertIn("/Engine/Source/Runtime/Core/Internal", norm)  # Internal dir of an engine dependency
        self.assertIn("/Engine/Source/Runtime/Bar/Public", norm)  # private dependency
        self.assertTrue(any(p.endswith("/Inc/BarShort/UHT") for p in norm))  # ShortName output folder
        self.assertEqual(len(set(p.lower() for p in inc)), len(inc))
        self.assertIn("C:/sys/inc", sysinc)
        self.assertTrue(any(p.endswith("ThirdParty/Zlib2/1.0/include") for p in sysinc))  # precompiled 3rd party
        self.assertEqual(vis[0], "Foo")

    def test_private_dependency_public_closure_only(self):
        self.mods["Bar"]["PrivateDependencyModules"] = ["Inner"]
        g = ec.ModuleGraph(self.mods, self.root)
        self.assertNotIn("Inner", g.visible("Foo"))  # Foo -> Bar(private) -> Inner(private): not visible
        self.mods["Bar"]["PublicDependencyModules"] = ["Inner"]
        g = ec.ModuleGraph(self.mods, self.root)
        self.assertIn("Inner", g.visible("Foo"))

    def test_definitions_collect_public_defs_of_visible(self):
        _, _, vis = self.graph.include_dirs("Foo")
        defs = self.graph.definitions(vis)
        self.assertEqual(defs[0], "FOO_PUB=2")
        for d in ("WITH_CORE=1", "FLAG", "BAR_PUB"):
            self.assertIn(d, defs)

    def test_private_definitions_from_build_cs(self):
        self.assertEqual(self.graph.private_definitions("Foo"), ["FOO_MODULE", "A=1", "B"])
        self.assertEqual(self.graph.private_definitions("Core"), [])

    def test_pch_selection(self):
        pch, extra = self.graph.pch_for("Foo")
        self.assertTrue(pch.endswith("Core/Public/CoreSharedPCH.h"))
        self.assertEqual(extra, "Core")
        self.assertEqual(self.graph.pch_for("Inner"), (None, None))  # NoPCHs
        self.mods["Foo"]["PrivatePCH"] = os.path.join(self.src, "Runtime", "Foo", "Private", "FooPCH.h")
        g = ec.ModuleGraph(self.mods, self.root)
        self.assertTrue(g.pch_for("Foo")[0].endswith("Foo/Private/FooPCH.h"))
        self.assertIsNone(g.pch_for("Foo")[1])

    def test_module_definitions_header(self):
        text = ec.module_definitions_h("Foo", self.mods["Foo"], "C:/d", "MyPlugin", ["A=1", "B"])
        self.assertIn("#define FOO_API DLLEXPORT", text)
        self.assertIn("#define FOO_NON_ATTRIBUTED_API DLLEXPORT", text)
        self.assertIn('#define UE_MODULE_NAME "Foo"', text)
        self.assertIn('#define UE_PLUGIN_NAME "MyPlugin"', text)
        self.assertIn("#define UE_IS_ENGINE_MODULE 1", text)
        self.assertIn("#undef A\n#define A 1", text)
        self.assertIn("#undef B\n#define B 1", text)
        self.assertLess(text.index("AllApis.h"), text.index("FOO_API DLLEXPORT"))

    def test_all_apis_guarded(self):
        text = ec.all_apis(["Foo", "Core"])
        self.assertIn("#ifndef FOO_API\n#define FOO_API DLLIMPORT\n#endif", text)
        self.assertIn("#ifndef CORE_NON_ATTRIBUTED_API", text)

    def test_module_rsp_layout_and_stubs(self):
        files = {"Foo": [os.path.join(self.mods["Foo"]["Directory"], "Private", "Foo.cpp")],
                 "Bar": [os.path.join(self.mods["Bar"]["Directory"], "Private", "Bar.cpp")]}
        stubs = os.path.join(self.root, "stubs")
        self.assertEqual(ec.make_stubs(stubs, self.graph, files), 2)  # Foo.generated.h and Bar.generated.h exist
        self.assertEqual(sorted(os.listdir(stubs)), ["Bar.gen.cpp", "Foo.gen.cpp"])
        self.assertEqual(ec.make_stubs(stubs, self.graph, files), 2)  # idempotent
        lines, vis = ec.module_rsp(self.graph, "Foo", "C:/c/base.rsp", "S:/Source", "C:/c/defs/Definitions.Foo.h", stubs)
        self.assertEqual(lines[0], '@"C:/c/base.rsp"')
        self.assertEqual(lines[1], '/I "S:/Source"')
        self.assertTrue(lines[2].startswith('/I "') and lines[2].endswith('stubs"'))
        self.assertEqual(lines[-2], '/FI"C:/c/defs/Definitions.Foo.h"')  # definitions before the PCH
        self.assertTrue(lines[-1].startswith('/FI"') and lines[-1].endswith('CoreSharedPCH.h"'))
        self.assertTrue(any(ln.startswith('/imsvc "') for ln in lines))
        self.assertTrue(all("\\" not in ln for ln in lines))

    def test_synthesize_end_to_end_with_fake_project(self):
        proj = os.path.join(self.root, "Proj")
        b = os.path.join(proj, "Intermediate", "Build", "Win64", "x64")
        mk(b, "UnrealEditor/Development/Proj/Proj.Shared.rsp", '/X\n/I "."\n-Werror\n/imsvc "C:/MSVC/INCLUDE"\n')
        mk(b, "UnrealEditor/Development/Proj/Definitions.Proj.h",
           '#include "SharedDefinitions.Ed.h"\n#define UE_PROJECT_NAME P\n')
        mk(b, "ProjEditor/Development/Ed/SharedDefinitions.Ed.h", "#pragma once\n#define WITH_EDITOR 1\n")
        mk(proj, "compile_commands.json",
           '[{"file":"a.cpp","command":"\\"C:/LLVM/bin/clang-cl.exe\\" @\\"x.rsp\\" "}]')
        out = os.path.join(self.root, "out")
        stats = ec.synthesize({"Modules": self.mods}, self.root, proj, out)
        self.assertEqual(stats["modules"], 4)
        with open(os.path.join(out, "compile_commands.json"), encoding="utf-8") as f:
            cdb = json.load(f)
        self.assertEqual(sorted(os.path.basename(e["file"]) for e in cdb), ["A.cpp", "Bar.cpp", "Foo.cpp", "In.cpp"])
        e0 = cdb[0]
        self.assertTrue(e0["command"].startswith('"C:/LLVM/bin/clang-cl.exe" @"'))
        self.assertEqual(e0["directory"], ec.fwd(self.src))
        self.assertTrue(os.path.isfile(os.path.join(out, "modules", "Foo.rsp")))
        with open(os.path.join(out, "defs", "CommonDefinitions.h"), encoding="utf-8") as f:
            self.assertIn("#define WITH_EDITOR 1", f.read())
        with open(os.path.join(out, "base.rsp"), encoding="utf-8") as f:
            base = f.read()
        self.assertIn('/imsvc "C:/MSVC/INCLUDE"', base)
        self.assertNotIn("-Werror", base)


class TestStaleness(unittest.TestCase):
    def test_key_changes_with_project_files_and_version(self):
        with tempfile.TemporaryDirectory() as t:
            eng = os.path.join(t, "UE")
            ver = {"MajorVersion": 5, "MinorVersion": 8, "PatchVersion": 3, "Changelist": 1}
            mk(eng, "Engine/Build/Build.version", json.dumps(ver))
            up = mk(t, "P/P.uproject", "{}")
            bcs = mk(t, "P/Source/P/P.Build.cs", "x")
            k1 = ec.staleness_key(eng, up)
            self.assertEqual(k1, ec.staleness_key(eng, up))
            os.utime(bcs, ns=(1, 2_000_000_000))
            k2 = ec.staleness_key(eng, up)
            self.assertNotEqual(k1, k2)
            ver["PatchVersion"] = 4
            mk(eng, "Engine/Build/Build.version", json.dumps(ver))
            k3 = ec.staleness_key(eng, up)
            self.assertNotEqual(k2, k3)
            mk(t, "P/Source/P.Target.cs", "y")  # new rule file
            self.assertNotEqual(k3, ec.staleness_key(eng, up))

    def test_status_and_ensure_async_fresh_returns_none(self):
        with tempfile.TemporaryDirectory() as t:
            old = os.environ.get("UE_LSP_CACHE_DIR")
            os.environ["UE_LSP_CACHE_DIR"] = t
            try:
                eng = os.path.join(t, "UE")
                mk(eng, "Engine/Build/Build.version", "{}")
                up = mk(t, "P/P.uproject", "{}")
                self.assertEqual(ec.status(eng, up), "missing")
                mk(ec.cdb_dir(), "compile_commands.json", "[]")
                self.assertEqual(ec.status(eng, up), "stale")
                mk(ec.cdb_dir(), "meta.json", json.dumps({"key": ec.staleness_key(eng, up)}))
                self.assertEqual(ec.status(eng, up), "fresh")
                self.assertIsNone(ec.ensure_async(eng, up))
                self.assertIsNone(ec.ensure_async(None, up))
            finally:
                if old is None:
                    os.environ.pop("UE_LSP_CACHE_DIR", None)
                else:
                    os.environ["UE_LSP_CACHE_DIR"] = old


if __name__ == "__main__":
    unittest.main()
