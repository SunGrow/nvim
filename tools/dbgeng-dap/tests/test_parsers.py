"""Parser checks against real cdb output captured from MyGame -game sessions (tests/samples).

Run: python -I tests/test_parsers.py   (or python -m unittest discover -s tests)
"""
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from dbgeng_dap import parsers as P  # noqa: E402

SAMPLES = os.path.join(ROOT, 'tests', 'samples')


def sample(name):
    with open(os.path.join(SAMPLES, name), encoding='utf-8') as f:
        return f.read()


class Prompt(unittest.TestCase):
    def test_prompt(self):
        self.assertTrue(P.PROMPT_RE.search('foo\n0:000> '))
        self.assertTrue(P.PROMPT_RE.search('0:012> '))
        self.assertTrue(P.PROMPT_RE.search('x\n1:002:x86> '))
        self.assertTrue(P.PROMPT_RE.search('x\nNoTarget> '))
        self.assertFalse(P.PROMPT_RE.search('0:000> dx foo\n'))
        self.assertEqual(P.strip_prompt('a\nb\n0:000> '), 'a\nb')


class LastEvent(unittest.TestCase):
    def test_breakpoint(self):
        ev = P.parse_lastevent(sample('p1_dotlastevent.txt'))
        self.assertEqual((ev['kind'], ev['bp'], ev['pid'], ev['tid']), ('breakpoint', 0, 0xfcc0, 0x1aac))
        self.assertEqual(P.parse_lastevent(sample('p4_dotlastevent_2.txt'))['bp'], 2)

    def test_no_event(self):
        self.assertEqual(P.parse_lastevent(sample('p1_dotlastevent_2.txt'))['kind'], 'none')

    def test_break_instruction(self):
        ev = P.parse_lastevent(sample('p1_dotlastevent_3.txt'))
        self.assertEqual((ev['kind'], ev['code'], ev['first_chance'], ev['tid']), ('exception', 0x80000003, True, 0x10898))

    def test_exit(self):
        ev = P.parse_lastevent(sample('p2_dotlastevent_1.txt'))
        self.assertEqual((ev['kind'], ev['code']), ('exit', 0x80004005))

    def test_pseudo(self):
        self.assertEqual(P.parse_pseudo_reg(sample('p1_r_tpid.txt'), 'tpid'), 0xfcc0)


class Threads(unittest.TestCase):
    def test_threads(self):
        th = P.parse_threads(sample('p1_threads.txt'))
        self.assertEqual(len(th), 92)
        self.assertEqual((th[0]['index'], th[0]['tid'], th[0]['name'], th[0]['current']), (0, 0x1aac, 'GameThread', True))
        self.assertEqual(th[1]['name'], '')
        self.assertEqual(th[37]['name'], 'OnlineAsyncTaskThreadNull DefaultInstance(1)')
        th2 = P.parse_threads(sample('p1_threads_1.txt'))
        self.assertEqual(len(th2), 97)
        self.assertTrue(th2[-1]['current'])  # break-in thread after DebugBreakProcess
        self.assertEqual(th2[-1]['tid'], 0x10898)


class Stack(unittest.TestCase):
    def test_physical_frames(self):
        fr = P.parse_stack(sample('p2_kn_0n200.txt'))
        self.assertEqual(len(fr), 17)
        f2 = fr[2]
        self.assertEqual(f2['module'], 'UnrealEditor_MyGame')
        self.assertEqual(f2['function'], 'UMatchSubsystem::LoadAndIndexMatchConfigs+0xc5')
        self.assertTrue(f2['file'].endswith('MatchSubsystem.cpp'))
        self.assertEqual(f2['line'], 38)
        self.assertTrue(fr[0]['inline'])
        self.assertEqual((fr[0]['file'].endswith('Array.h'), fr[0]['line']), (True, 217))
        self.assertEqual(fr[9]['index'], 9)
        self.assertTrue(fr[9]['inline'])
        self.assertEqual(fr[0x10]['symbol'], 'ntdll!RtlUserThreadStart+0x2c')
        self.assertIsNone(fr[0x10]['file'])

    def test_inline_disabled(self):
        fr = P.parse_stack(sample('p4_kn_3_2.txt'))
        self.assertEqual([f['line'] for f in fr], [38, 530, 465])
        self.assertFalse(any(f['inline'] for f in fr))

    def test_old_k(self):
        fr = P.parse_stack(sample('eval_k_4.txt'))
        self.assertEqual(len(fr), 0)  # plain `k` has no frame numbers; the adapter always uses `kn`


class Dx(unittest.TestCase):
    def test_tarray(self):
        r = P.parse_dx(sample('eval_dx_LoadedConfigs.txt'))
        self.assertIsNone(r.error)
        self.assertEqual((r.name, r.value), ('LoadedConfigs', 'Num=3, Max=4'))
        self.assertEqual(r.type, 'TArray<UMatchDataAsset *,TSizedDefaultAllocator<32> >')
        self.assertEqual([k.name for k in r.children], ['[<Raw View>]', '[0x0]', '[0x1]', '[0x2]'])
        self.assertEqual(r.children[1].value, '0x1fdfeffce40')
        self.assertEqual(r.children[1].type, 'ElementType')
        self.assertIsNone(r.children[0].value)

    def test_r2_nested(self):
        r = P.parse_dx(sample('eval_dx_r2_LoadedConfigs.txt'))
        e0 = r.children[1]
        names = [P.display_name(k.name) for k in e0.children]
        self.assertIn('MatchId', names)
        tid = [k for k in e0.children if P.display_name(k.name) == 'MatchId'][0]
        self.assertEqual((tid.value, tid.type), ('1', 'int'))
        ids = [[k.value for k in e.children if P.display_name(k.name) == 'MatchId'][0] for e in r.children[1:]]
        self.assertEqual(ids, ['1', '100597', '100596'])

    def test_this_members(self):
        r = P.parse_dx(sample('p2_dx_r1_this.txt'))
        self.assertTrue(P.looks_pointer(r.value, r.type))
        kinds = [(P.classify_child(k.name), k.type) for k in r.children]
        self.assertEqual(kinds[0], (('field', 'UObject'), 'UObject'))           # base class sub-object
        self.assertEqual(kinds[1][0], ('synthetic', 'StaticClassFlags'))
        self.assertEqual(kinds[4][0], ('static', 'StaticClassFlags'))
        tcm = r.children[5]
        self.assertEqual(P.display_name(tcm.name), 'MatchConfigMap')
        self.assertIsNone(tcm.value)
        self.assertTrue(P.has_children(tcm))

    def test_locals(self):
        r = P.parse_dx(sample('p2_dx_r1_curframedotLocalVariables.txt'))  # has a '*** WARNING' line first
        self.assertEqual(r.name, '@$curframe.LocalVariables')
        self.assertEqual([k.name for k in r.children], ['<begin>$L0', 'Config', 'LoadedConfigs', 'MatchId', 'this'])
        self.assertFalse(P.has_children(r.children[1]))      # value unavailable
        self.assertTrue(P.has_children(r.children[2]))       # TArray
        self.assertTrue(P.has_children(r.children[4]))       # this pointer

    def test_error_box(self):
        r = P.parse_dx(sample('p2_dx_Bogus123.txt'))
        self.assertEqual(r.error, "Unable to bind name 'Bogus123'")
        self.assertEqual(P.parse_dx(sample('eval_dx_LoadedConfigsdotNum.txt')).error, 'Unspecified error (0x80004005)')

    def test_scalar(self):
        r = P.parse_dx(sample('eval_dx_LoadedConfigs_0_MatchId.txt'))
        self.assertEqual((r.name, r.value, r.type), ('LoadedConfigs[0]->MatchId', '1', 'int'))
        self.assertFalse(P.has_children(r))
        b = P.parse_dx(sample('p2_dx_LoadedConfigsdotArrayNum_0.txt'))
        self.assertEqual((b.value, b.type), ('true', None))

    def test_raw_view(self):
        r = P.parse_dx(sample('p2_dx_r1_LoadedConfigs.txt'))  # `dx -r1 LoadedConfigs,!`
        self.assertEqual([P.classify_child(k.name)[0] for k in r.children], ['synthetic', 'field', 'field', 'field'])
        self.assertEqual(r.children[2].value, '3')

    def test_script_child(self):
        r = P.parse_dx(sample('p3_dx_r1_dapkid_LoadedConfigs_0x1_1.txt'))
        tid = [k for k in r.children if P.display_name(k.name) == 'MatchId'][0]
        self.assertEqual(tid.value, '100597')
        s = P.parse_dx(sample('p3_dx_r1_dapkid_dapkid_LoadedConfigs_0x1_1_MatchId_1.txt'))
        self.assertEqual((s.value, s.type), ('0x188f5', None))
        self.assertFalse(P.has_children(s))

    def test_base_class_nested(self):
        r = P.parse_dx(sample('p2_dx_r2_this_MatchConfigMap.txt'))
        base = r.children[0]
        kind, member = P.classify_child(base.name)
        self.assertEqual(kind, 'field')
        self.assertEqual(P.strip_type(base.type), member)
        self.assertEqual([k.name for k in base.children], ['[<Raw View>]', '[Pairs]'])
        self.assertEqual(P.classify_child('[Pairs]'), ('synthetic', '[Pairs]'))

    def test_has_children_enum(self):
        n = P.parse_dx_line('    [=0x7ffc1933b718] StaticClassFlags : CLASS_Intrinsic (268435456) [Type: EClassFlags]')
        self.assertFalse(P.has_children(n))
        n = P.parse_dx_line('    [+0x048] LevelPath        : nullptr ({...}) [Type: TSoftObjectPtr<UWorld>]')
        self.assertTrue(P.has_children(n))
        n = P.parse_dx_line('    [+0x0a8] CinematicMasters : nullptr [Type: TObjectPtr<UCinematicMastersDataAsset>]')
        self.assertFalse(P.has_children(n))


class Misc(unittest.TestCase):
    def test_bl(self):
        pend = P.parse_bl(sample('p1_bl.txt'))
        self.assertEqual(sorted(pend), [0, 1])
        self.assertFalse(pend[0]['resolved'])
        res = P.parse_bl(sample('p1_bl_1.txt'))
        self.assertTrue(res[0]['resolved'])
        self.assertEqual((res[0]['line'], res[1]['line']), (38, 40))
        self.assertTrue(res[1]['file'].endswith('MatchSubsystem.cpp'))

    def test_registers(self):
        regs = dict(P.parse_registers(sample('p1_r.txt')))
        self.assertEqual(regs['rip'], '00007ffc1cb9b715')
        self.assertEqual(regs['r8'], '000002870132b440')
        self.assertEqual(regs['efl'], '00000202')
        self.assertNotIn('mov', regs)

    def test_modload(self):
        base, end, path = P.parse_modload(
            'ModLoad: 00007ffc`19b60000 00007ffc`19c51000   D:\\Projects\\MyGame\\Binaries\\Win64\\UnrealEditor-MyGame.dll')
        self.assertEqual((base, end), (0x7ffc19b60000, 0x7ffc19c51000))
        self.assertTrue(path.endswith('UnrealEditor-MyGame.dll'))
        self.assertEqual(P.cdb_module_name(path), 'UnrealEditor_MyGame')

    def test_cdb_error(self):
        self.assertFalse(P.is_cdb_error("*** Bp expression 'UnrealEditor_MyGame+0x3b715' contains symbols "
                                        "not qualified with module name.\n0:000> "))
        self.assertTrue(P.is_cdb_error("Couldn't resolve error at 'Foo::Bar'\n0:000> "))


if __name__ == '__main__':
    unittest.main(verbosity=2)
