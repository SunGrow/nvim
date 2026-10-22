"""Source file:line -> code address resolution with dbghelp (ctypes, in the adapter process).

cdb's own `bp `file:line`` fails with "Ambiguous symbol error" whenever a line maps to more than one
address (loops, inlining, template instantiations), so the adapter reads the PDB line table itself.

The adapter opens each candidate image (DLL/EXE on disk) in a private dbghelp session at a fake base,
enumerates every line record of the requested source file once (cached per image+file), and returns
RVAs.  The caller adds the real module base (from cdb `lm`) or emits a deferred `bu module+rva`.
"""
import ctypes
import ctypes.wintypes as wt
import os
import threading

SYMOPT_UNDNAME = 0x2
SYMOPT_DEFERRED_LOADS = 0x4
SYMOPT_LOAD_LINES = 0x10
SYMOPT_FAIL_CRITICAL_ERRORS = 0x200
SYMOPT_NO_PROMPTS = 0x80000
ESLFLAG_FULLPATH = 0x1

MAX_PATH = 260


class SRCCODEINFOW(ctypes.Structure):
    _fields_ = [('SizeOfStruct', wt.DWORD), ('Key', ctypes.c_void_p), ('ModBase', ctypes.c_uint64),
                ('Obj', ctypes.c_wchar * (MAX_PATH + 1)), ('FileName', ctypes.c_wchar * (MAX_PATH + 1)),
                ('LineNumber', wt.DWORD), ('Address', ctypes.c_uint64)]


class IMAGEHLP_MODULEW64(ctypes.Structure):
    _fields_ = [('SizeOfStruct', wt.DWORD), ('BaseOfImage', ctypes.c_uint64), ('ImageSize', wt.DWORD),
                ('TimeDateStamp', wt.DWORD), ('CheckSum', wt.DWORD), ('NumSyms', wt.DWORD),
                ('SymType', wt.DWORD), ('ModuleName', ctypes.c_wchar * 32), ('ImageName', ctypes.c_wchar * 256),
                ('LoadedImageName', ctypes.c_wchar * 256), ('LoadedPdbName', ctypes.c_wchar * 256),
                ('CVSig', wt.DWORD), ('CVData', ctypes.c_wchar * (MAX_PATH * 3)), ('PdbSig', wt.DWORD),
                ('PdbSig70', ctypes.c_byte * 16), ('PdbAge', wt.DWORD), ('PdbUnmatched', wt.BOOL),
                ('DbgUnmatched', wt.BOOL), ('LineNumbers', wt.BOOL), ('GlobalSymbols', wt.BOOL),
                ('TypeInfo', wt.BOOL), ('SourceIndexed', wt.BOOL), ('Publics', wt.BOOL),
                ('MachineType', wt.DWORD), ('Reserved', wt.DWORD)]


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [('SizeOfStruct', wt.ULONG), ('TypeIndex', wt.ULONG), ('Reserved', ctypes.c_uint64 * 2),
                ('Index', wt.ULONG), ('Size', wt.ULONG), ('ModBase', ctypes.c_uint64), ('Flags', wt.ULONG),
                ('Value', ctypes.c_uint64), ('Address', ctypes.c_uint64), ('Register', wt.ULONG),
                ('Scope', wt.ULONG), ('Tag', wt.ULONG), ('NameLen', wt.ULONG), ('MaxNameLen', wt.ULONG),
                ('Name', ctypes.c_wchar * 1024)]


class SYMBOL_INFOW_HDR(ctypes.Structure):
    _fields_ = SYMBOL_INFOW._fields_[:-1] + [('Name', ctypes.c_wchar * 1)]


ENUMLINES_CB = ctypes.WINFUNCTYPE(wt.BOOL, ctypes.POINTER(SRCCODEINFOW), ctypes.c_void_p)
ENUMSYM_CB = ctypes.WINFUNCTYPE(wt.BOOL, ctypes.POINTER(SYMBOL_INFOW_HDR), wt.ULONG, ctypes.c_void_p)


def norm(p):
    return os.path.normcase(os.path.normpath(p)).replace('/', '\\') if p else ''


class LineResolver:
    """One private dbghelp session.  dbghelp is single-threaded: every call holds self.lock."""

    def __init__(self, dbghelp_dirs=(), search_path=''):
        self.lock = threading.Lock()
        self.dll = None
        self.dll_path = None
        for d in list(dbghelp_dirs) + [os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')]:
            p = os.path.join(d, 'dbghelp.dll')
            if os.path.isfile(p):
                try:
                    self.dll = ctypes.WinDLL(p)
                    self.dll_path = p
                    break
                except OSError:
                    continue
        if not self.dll:
            raise OSError('dbghelp.dll not found')
        d = self.dll
        d.SymSetOptions.argtypes = [wt.DWORD]
        d.SymInitializeW.argtypes = [wt.HANDLE, wt.LPCWSTR, wt.BOOL]
        d.SymInitializeW.restype = wt.BOOL
        d.SymLoadModuleExW.argtypes = [wt.HANDLE, wt.HANDLE, wt.LPCWSTR, wt.LPCWSTR, ctypes.c_uint64, wt.DWORD,
                                       ctypes.c_void_p, wt.DWORD]
        d.SymLoadModuleExW.restype = ctypes.c_uint64
        d.SymEnumSourceLinesW.argtypes = [wt.HANDLE, ctypes.c_uint64, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD, wt.DWORD,
                                          ENUMLINES_CB, ctypes.c_void_p]
        d.SymEnumSourceLinesW.restype = wt.BOOL
        d.SymGetModuleInfoW64.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.POINTER(IMAGEHLP_MODULEW64)]
        d.SymGetModuleInfoW64.restype = wt.BOOL
        d.SymFromAddrW.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64),
                                   ctypes.POINTER(SYMBOL_INFOW)]
        d.SymFromAddrW.restype = wt.BOOL
        d.SymEnumSymbolsW.argtypes = [wt.HANDLE, ctypes.c_uint64, wt.LPCWSTR, ENUMSYM_CB, ctypes.c_void_p]
        d.SymEnumSymbolsW.restype = wt.BOOL
        d.SymCleanup.argtypes = [wt.HANDLE]
        d.SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES | SYMOPT_FAIL_CRITICAL_ERRORS
                        | SYMOPT_NO_PROMPTS)
        self.h = wt.HANDLE(0x0DB6E7A9)  # any unique value works when fInvadeProcess is FALSE
        if not d.SymInitializeW(self.h, search_path or None, False):
            raise OSError('SymInitializeW failed: %d' % ctypes.get_last_error())
        self.next_base = 0x100000000
        self.images = {}      # norm(image path) -> (fake base, has_lines, pdb path)
        self.cache = {}       # (norm image, norm file) -> {line: [rva, ...]}
        self.counts = {}      # (norm image, name) -> number of symbols with that name

    def _load(self, image):
        key = norm(image)
        if key in self.images:
            return self.images[key]
        size = max(os.path.getsize(image), 0x1000) + 0x10000
        base = self.next_base
        self.next_base += (size + 0xFFFFF) & ~0xFFFF
        got = self.dll.SymLoadModuleExW(self.h, None, image, None, base, size, None, 0)
        info = IMAGEHLP_MODULEW64()
        info.SizeOfStruct = ctypes.sizeof(IMAGEHLP_MODULEW64)
        ok = got and self.dll.SymGetModuleInfoW64(self.h, got, ctypes.byref(info))
        # Force the deferred PDB load by enumerating a dummy line (SymGetModuleInfo reports deferred until then).
        res = (got or 0, bool(ok), info.LoadedPdbName if ok else '')
        self.images[key] = res
        return res

    def file_lines(self, image, source):
        r"""Return {line: [rva...]} for every line record of `source` in `image` (cached).

        Full-path match first.  Installed engine builds keep the build machine's paths in their PDBs
        (e.g. D:\build\++UE5\Sync\Engine\Source\...), so the fallback enumerates by file name and keeps
        the PDB file whose path shares the longest component suffix with `source` (at least file + parent dir).
        """
        k = (norm(image), norm(source))
        with self.lock:
            if k in self.cache:
                return self.cache[k]
            base, ok, _ = self._load(image)
            out = {}
            if base:
                recs = []

                def cb(p, _ctx):
                    i = p.contents
                    if i.Address:
                        recs.append((i.FileName, i.LineNumber, i.Address - base))
                    return True
                c = ENUMLINES_CB(cb)
                self.dll.SymEnumSourceLinesW(self.h, base, None, os.path.normpath(source), 0, ESLFLAG_FULLPATH, c, None)
                if not recs:
                    self.dll.SymEnumSourceLinesW(self.h, base, None, os.path.basename(source), 0, 0, c, None)
                    want = norm(source).split(os.sep)
                    best, best_n = None, 1
                    for f in {r[0] for r in recs}:
                        have = norm(f).split(os.sep)
                        n = 0
                        while n < min(len(want), len(have)) and want[-1 - n] == have[-1 - n]:
                            n += 1
                        if n > best_n:
                            best, best_n = f, n
                    recs = [r for r in recs if r[0] == best]
                for _, ln, rva in recs:
                    out.setdefault(ln, []).append(rva)
            for v in out.values():
                v.sort()
            self.cache[k] = out
            return out

    def function_of(self, image, rva):
        """(function name, offset) containing rva, or (None, None)."""
        with self.lock:
            base, _, _ = self._load(image)
            if not base:
                return None, None
            disp = ctypes.c_uint64(0)
            si = SYMBOL_INFOW()
            si.SizeOfStruct = ctypes.sizeof(SYMBOL_INFOW_HDR)
            si.MaxNameLen = 1024
            if self.dll.SymFromAddrW(self.h, base + rva, ctypes.byref(disp), ctypes.byref(si)):
                return si.Name, disp.value
            return None, None

    def name_count(self, image, name):
        """How many symbols of `image` have this name (overloads share one).  The name is a dbghelp mask:
        only call it with plain identifiers (no * or ?)."""
        k = (norm(image), name)
        with self.lock:
            if k not in self.counts:
                base, _, _ = self._load(image)
                n = [0]

                def cb(_p, _size, _ctx):
                    n[0] += 1
                    return True
                if base:
                    self.dll.SymEnumSymbolsW(self.h, base, name, ENUMSYM_CB(cb), None)
                self.counts[k] = n[0]
            return self.counts[k]

    def resolve(self, image, source, line, max_forward=200):
        """Return (actual_line, [rva...]) for the first line >= `line` that has code, or (None, [])."""
        lines = self.file_lines(image, source)
        if not lines:
            return None, []
        for ln in range(line, line + max_forward):
            if ln in lines:
                return ln, list(lines[ln])
        return None, []

    def close(self):
        with self.lock:
            try:
                self.dll.SymCleanup(self.h)
            except Exception:
                pass
