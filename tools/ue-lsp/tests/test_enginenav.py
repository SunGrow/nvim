"""Unit tests for enginenav (out-of-line definition scanner) and bpfeat (header -> UPROPERTY mapping)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ue_lsp import bpfeat, enginenav  # noqa: E402

SRC = b"""
#include "Foo.h"

void AFoo::BeginPlay()
{
\tSuper::BeginPlay();
\tOther->AFoo::Tick(0.f);
\tif (UBar::Helper(1, 2)) { }
}

AFoo::AFoo(const FObjectInitializer& Init)
\t: Super(Init)
{
}

AFoo::~AFoo()
{
}

TArray<int32> AFoo::GetValues(int32 A,
\tTMap<int32, float> B) const
{
\treturn {};
}

template <typename T>
T TBox<T>::Get() const noexcept
{
\treturn T();
}

namespace UE::Net
{
\tbool FThing::Run(int32 X) override
\t{
\t\treturn FOther::Run(X);
\t}
}

int32 AFoo::Calc(int32 A) { return A; }
int32 AFoo::Calc(int32 A, int32 B) { return A + B; }
auto AFoo::Trailing() -> int32 { return 0; }
void AFoo::Declared();
"""


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.defs = {(q, n) for q, _l, _c, n in enginenav.scan_file(SRC)}
        self.names = {q for q, _n in self.defs}

    def test_methods_and_special_members(self):
        for q in ("AFoo::BeginPlay", "AFoo::AFoo", "AFoo::~AFoo", "AFoo::GetValues", "TBox::Get",
                  "FThing::Run", "AFoo::Trailing"):
            self.assertIn(q, self.names, q)

    def test_calls_and_declarations_are_not_definitions(self):
        for q in ("Super::BeginPlay", "AFoo::Tick", "UBar::Helper", "FOther::Run", "AFoo::Declared"):
            self.assertNotIn(q, self.names, q)

    def test_param_counts(self):
        self.assertIn(("AFoo::GetValues", 2), self.defs)
        self.assertIn(("AFoo::Calc", 1), self.defs)
        self.assertIn(("AFoo::Calc", 2), self.defs)
        self.assertIn(("AFoo::BeginPlay", 0), self.defs)

    def test_line_numbers(self):
        lines = {q: l for q, l, _c, _n in enginenav.scan_file(SRC)}
        self.assertEqual(SRC.split(b"\n")[lines["AFoo::BeginPlay"]].strip(), b"void AFoo::BeginPlay()")

    def test_finder_module_and_overloads(self):
        with tempfile.TemporaryDirectory() as d:
            mod = os.path.join(d, "Mod")
            os.makedirs(os.path.join(mod, "Public"))
            os.makedirs(os.path.join(mod, "Private"))
            open(os.path.join(mod, "Mod.Build.cs"), "w").close()
            hdr = os.path.join(mod, "Public", "Foo.h")
            with open(hdr, "w") as f:
                f.write("class AFoo {\n  int32 Calc(int32 A, int32 B);\n};\n")
            with open(os.path.join(mod, "Private", "Foo.cpp"), "wb") as f:
                f.write(SRC)
            fi = enginenav.ImplFinder(os.path.join(d, "cache"))
            self.assertEqual(enginenav.module_root(hdr), mod)
            with open(hdr) as f:
                n = enginenav.decl_nparams(f.read(), 1, "Calc")
            self.assertEqual(n, 2)
            hits = fi.find(hdr, "Calc", "AFoo::", n)
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0][3], 2)
            self.assertEqual(len(fi.find(hdr, "BeginPlay", "AFoo")), 1)
            # disk cache round trip
            fi2 = enginenav.ImplFinder(os.path.join(d, "cache"))
            self.assertEqual(len(fi2.find(hdr, "BeginPlay", "AFoo")), 1)


HDR = """
UCLASS(BlueprintType)
class GAME_API UMyAsset : public UPrimaryDataAsset
{
\tGENERATED_BODY()
public:
\tUPROPERTY(EditAnywhere, meta = (ClampMin = 0))
\tint32 MatchId = 0;

\tUPROPERTY(EditAnywhere)
\tTMap<FName, TSoftObjectPtr<UWorld>>
\t\tLevels;
};

USTRUCT()
struct FRow
{
\tUPROPERTY()
\tfloat Weight;
};
"""


class BpFeatTests(unittest.TestCase):
    def test_property_decls(self):
        d = bpfeat.property_decls(HDR)
        self.assertEqual([(c, p) for c, p, *_ in d], [("UMyAsset", "MatchId"), ("UMyAsset", "Levels")])
        lines = HDR.split("\n")
        for _c, p, l, s, e in d:
            self.assertEqual(lines[l][s:e], p)

    def test_decl_at_and_format(self):
        lines = HDR.split("\n")
        l = next(i for i, t in enumerate(lines) if "MatchId" in t)
        self.assertEqual(bpfeat.decl_at(HDR, l, 0)[:2], ("UMyAsset", "MatchId"))
        self.assertIsNone(bpfeat.decl_at(HDR, 0, 0))
        rows = [{"asset": "/Game/DA_A", "name": "DA_A", "object": "DA_A", "kind": "asset", "prop": "MatchId",
                 "value": "7", "type": "IntProperty"}]
        self.assertEqual(bpfeat.lens_title(rows), "BP: DA_A = 7")
        self.assertIn("| DA_A |", bpfeat.hover_md("UMyAsset", "MatchId", rows))
        self.assertEqual(bpfeat.lens_title(rows * 3), "3 BP values")


if __name__ == "__main__":
    unittest.main()
