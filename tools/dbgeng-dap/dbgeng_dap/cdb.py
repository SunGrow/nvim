"""Prompt-synchronised cdb.exe driver.

cdb only reads the next command after it printed its prompt ("0:000> "), so every command is written
after the previous prompt.  Two modes:
  * command mode: the target is stopped; execute() writes one command and returns its output.
  * run mode: resume() writes g/p/t/gu; output is streamed to on_output line by line until the next prompt,
    which means the target stopped again -> on_stop(text) is called on a fresh thread.
"""
import ctypes
import os
import subprocess
import threading
import time

from .parsers import PROMPT_RE, strip_prompt

CREATE_NO_WINDOW = 0x08000000


class CdbError(Exception):
    pass


class Cdb:
    def __init__(self, log=None):
        self.proc = None
        self.log = log or (lambda m: None)
        self.lock = threading.RLock()        # serialises execute()/resume()
        self.cv = threading.Condition()      # guards everything below
        self.buf = ''
        self.mode = 'start'                  # start | cmd | run | idle | dead
        self.response = None
        self.stale = False                   # a timed-out command's prompt is still pending
        self.on_output = None                # f(line) while running
        self.on_stop = None                  # f(text) when a run ends at a prompt
        self.on_exit = None                  # f() when cdb exits
        self.startup_text = ''

    # ------------------------------------------------------------------ process
    def start(self, cmdline, cwd=None, env=None, timeout=120):
        self.log(f'spawn: {cmdline}')
        self.proc = subprocess.Popen(cmdline, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, cwd=cwd or None, env=env,
                                     creationflags=CREATE_NO_WINDOW)
        threading.Thread(target=self._reader, name='cdb-reader', daemon=True).start()
        with self.cv:
            end = time.time() + timeout
            while self.mode == 'start':
                if not self.cv.wait(max(0.0, end - time.time())) and time.time() >= end:
                    raise CdbError('cdb did not reach its first prompt within %ds' % timeout)
            if self.mode == 'dead':
                raise CdbError('cdb exited during startup:\n' + self.startup_text[-3000:])
        return self.startup_text

    @property
    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    @property
    def running(self):
        return self.mode == 'run'

    def _reader(self):
        out = self.proc.stdout
        while True:
            try:
                b = out.read1(65536)
            except (OSError, ValueError):
                b = b''
            if not b:
                break
            text = b.decode('utf-8', 'replace').replace('\r', '')
            stop_text = None
            lines_out = []
            with self.cv:
                self.buf += text
                prompt = PROMPT_RE.search(self.buf[-200:]) is not None
                if self.mode == 'run':
                    # stream complete lines; keep the partial tail for prompt detection
                    if prompt:
                        body = strip_prompt(self.buf)
                        lines_out = body.split('\n')
                        stop_text = self._run_text + body
                        self._run_text = ''
                        self.buf = ''
                        self.mode = 'idle'
                        self.cv.notify_all()
                    elif '\n' in self.buf:
                        head, self.buf = self.buf.rsplit('\n', 1)
                        lines_out = head.split('\n')
                        self._run_text = (self._run_text + head + '\n')[-200000:]
                elif prompt:
                    if self.mode == 'start':
                        self.startup_text = self.buf
                        self.mode = 'idle'
                    elif self.mode == 'cmd':
                        if self.stale:   # the late prompt of a timed-out command: drop it
                            self.stale = False
                        else:
                            self.response = self.buf
                            self.mode = 'idle'
                    self.buf = ''
                    self.cv.notify_all()
                elif self.mode == 'start':
                    self.startup_text = self.buf
            if lines_out and self.on_output:
                for l in lines_out:
                    if l.strip():
                        try:
                            self.on_output(l)
                        except Exception as e:  # never kill the reader
                            self.log(f'on_output error {e!r}')
            if stop_text is not None:
                self.log('<< (stop) ' + stop_text[-1500:].replace('\n', '\n   '))
                if self.on_stop:
                    threading.Thread(target=self.on_stop, args=(stop_text,), name='cdb-stop', daemon=True).start()
        with self.cv:
            self.mode = 'dead'
            self.cv.notify_all()
        self.log('cdb exited')
        if self.on_exit:
            self.on_exit()

    # ------------------------------------------------------------------ commands
    def _write(self, s):
        self.proc.stdin.write((s + '\n').encode('utf-8'))
        self.proc.stdin.flush()

    def execute(self, cmd, timeout=60.0):
        """Run one command while the target is stopped; return its output (prompt stripped)."""
        with self.lock:
            with self.cv:
                if self.mode == 'dead':
                    raise CdbError('cdb is not running')
                if self.mode == 'run':
                    raise CdbError('target is running')
                if self.stale:  # wait for the previous (timed-out) command to finish
                    self.mode = 'cmd'
                    end = time.time() + timeout
                    while self.stale and self.mode != 'dead' and time.time() < end:
                        self.cv.wait(0.5)
                    if self.stale:
                        raise CdbError('cdb is still busy with a previous command')
                self.mode = 'cmd'
                self.response = None
                self.buf = ''
                t0 = time.time()
                self._write(cmd)
                end = t0 + timeout
                while self.response is None and self.mode == 'cmd' and time.time() < end:
                    self.cv.wait(0.5)
                if self.mode == 'dead':
                    raise CdbError('cdb exited')
                if self.response is None:
                    self.stale = True
                    self.log(f'>> {cmd}  TIMEOUT after {timeout}s')
                    raise CdbError(f'cdb command timed out after {timeout:.0f}s: {cmd}')
                out = strip_prompt(self.response)
                self.log(f'>> {cmd}  [{time.time() - t0:.2f}s]\n   ' + out[-3000:].replace('\n', '\n   '))
                return out

    def resume(self, cmd):
        """Write an execution command (g, p, t, gu, ...); returns immediately, on_stop fires at the next prompt."""
        with self.lock:
            with self.cv:
                if self.mode == 'dead':
                    raise CdbError('cdb is not running')
                if self.mode == 'run':
                    raise CdbError('target is already running')
                self.mode = 'run'
                self._run_text = ''
                self.buf = ''
                self.log(f'>> {cmd}  (resume)')
                self._write(cmd)

    def wait_stopped(self, timeout):
        with self.cv:
            end = time.time() + timeout
            while self.mode == 'run' and time.time() < end:
                self.cv.wait(0.2)
            return self.mode != 'run'

    def write_raw(self, s):
        """Write without waiting (used for 'q' during shutdown)."""
        try:
            self._write(s)
        except OSError:
            pass

    def kill(self):
        if self.proc and self.proc.poll() is None:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(self.proc.pid)], capture_output=True,
                           creationflags=CREATE_NO_WINDOW)


# ---------------------------------------------------------------------- process helpers (kernel32)
_k32 = ctypes.WinDLL('kernel32', use_last_error=True)
_k32.OpenProcess.restype = ctypes.c_void_p
_k32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
_k32.DebugBreakProcess.argtypes = [ctypes.c_void_p]
_k32.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint]
_k32.CloseHandle.argtypes = [ctypes.c_void_p]
_k32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]


def debug_break_process(pid):
    h = _k32.OpenProcess(0x1F0FFF, False, pid)
    if not h:
        return False, ctypes.get_last_error()
    try:
        ok = _k32.DebugBreakProcess(h)
        return bool(ok), ctypes.get_last_error()
    finally:
        _k32.CloseHandle(h)


def terminate_process(pid, code=1):
    h = _k32.OpenProcess(0x0001 | 0x1000, False, pid)  # PROCESS_TERMINATE | QUERY_LIMITED_INFORMATION
    if not h:
        return False
    try:
        return bool(_k32.TerminateProcess(h, code))
    finally:
        _k32.CloseHandle(h)


def process_alive(pid):
    h = _k32.OpenProcess(0x1000, False, pid)
    if not h:
        return False
    try:
        code = ctypes.c_uint32()
        return bool(_k32.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259  # STILL_ACTIVE
    finally:
        _k32.CloseHandle(h)


def find_cdb(explicit=None):
    """cdb.exe from the launch config, the WinDbg (Store) package, or the Windows SDK."""
    if explicit:
        if os.path.isfile(explicit):
            return explicit
        raise CdbError(f'cdbPath does not exist: {explicit}')
    # WinDbg (Store) package root from the AppModel repository (fast; WindowsApps itself cannot be listed)
    try:
        import winreg
        key = (r'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel'
               r'\Repository\Packages')
        roots = []
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as k:
            i = 0
            while True:
                try:
                    name = winreg.EnumKey(k, i)
                except OSError:
                    break
                i += 1
                if name.startswith('Microsoft.WinDbg_') and '_x64_' in name:
                    try:
                        with winreg.OpenKey(k, name) as sk:
                            roots.append(winreg.QueryValueEx(sk, 'PackageRootFolder')[0])
                    except OSError:
                        pass
        for root in sorted(roots, reverse=True):
            p = os.path.join(root, 'amd64', 'cdb.exe')
            if os.path.isfile(p):
                return p
    except OSError:
        pass
    try:
        r = subprocess.run(['powershell', '-NoProfile', '-Command',
                            '(Get-AppxPackage Microsoft.WinDbg | Sort-Object Version -Descending | '
                            'Select-Object -First 1).InstallLocation'],
                           capture_output=True, text=True, timeout=90, creationflags=CREATE_NO_WINDOW)
        loc = r.stdout.strip()
        if loc and os.path.isfile(os.path.join(loc, 'amd64', 'cdb.exe')):
            return os.path.join(loc, 'amd64', 'cdb.exe')
    except Exception:
        pass
    for base in (os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'), os.environ.get('ProgramFiles', '')):
        p = os.path.join(base, 'Windows Kits', '10', 'Debuggers', 'x64', 'cdb.exe')
        if os.path.isfile(p):
            return p
    raise CdbError('cdb.exe not found: install WinDbg (winget install Microsoft.WinDbg) or set cdbPath')
