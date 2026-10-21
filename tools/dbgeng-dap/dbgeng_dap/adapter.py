"""DAP session: maps Debug Adapter Protocol requests onto cdb.exe commands."""
import glob
import os
import queue
import re
import subprocess
import threading
import time

from . import parsers as P
from .cdb import Cdb, CdbError, debug_break_process, find_cdb, process_alive, terminate_process
from .lines import LineResolver, norm

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER_JS = os.path.join(HERE, 'dap_helper.js')

STEP_CMDS = {'p', 't', 'gu', 'pa', 'ta', 'pc', 'tc', 'pt', 'tt', 'ph', 'th', 'pct', 'tct'}
SIMPLE_SYM_RE = re.compile(r'^[A-Za-z_][\w]*(::~?[A-Za-z_]\w*)*$')
RESUME_RE = re.compile(r'^\s*(g|gc|gh|gn|gu|p|pa|pc|pct|ph|pt|t|ta|tc|tct|th|tt|wt)(\s|$)')
BLOCKED_RE = re.compile(r'^\s*(q|qq|qd|\.call|\.detach|\.restart|\.create|\.attach)(\s|$)')
NOISE_RE = re.compile(r'^\*\*\* (Unable to resolve unqualified symbol in Bp expression|Bp expression .* contains symbols '
                      r'not qualified|WARNING: Unable to verify timestamp)')
CDB_LINE_RE = re.compile(r'^(\([0-9a-f]+\.[0-9a-f]+\): |\*\*\*|ModLoad:|Breakpoint \d+ hit|First chance|'
                         r'This exception may|[0-9a-f]{8}`[0-9a-f]{8} |[A-Za-z0-9_]+!\S+:$)')

EXC_FILTERS = [
    {'filter': 'ensure', 'label': 'Suspend on ensure', 'default': True,
     'description': 'Stop when an ensure() fails (UE breaks in the ensure lambda); off: report it and continue'},
    {'filter': 'cpp_throw', 'label': 'C++ throw (first chance)', 'default': False,
     'description': 'Stop when a C++ exception is thrown (sxe eh)'},
    {'filter': 'av', 'label': 'Access violation (first chance)', 'default': True,
     'description': 'Stop on first-chance access violations (sxe av); second chance always stops'},
]
EXC_NAMES = {0x80000003: 'Break instruction (__debugbreak / check)', 0xc0000005: 'Access violation',
             0xe06d7363: 'C++ exception', 0xc0000094: 'Integer divide by zero', 0xc00000fd: 'Stack overflow',
             0xc0000409: 'Stack buffer overrun / fast fail'}


def short_module(module):
    """UnrealEditor_CoreUObject_Win64_DebugGame -> CoreUObject (UE module DLL names in cdb)."""
    m = re.sub(r'^UnrealEditor[-_]', '', module)
    return re.sub(r'[-_]Win64[-_](DebugGame|Development|Debug|Shipping|Test)$', '', m) or module


class Bp:
    def __init__(self, dap_id, kind, source=None, line=None, func=None, condition=None, hit=None):
        self.id, self.kind, self.source, self.req_line, self.line = dap_id, kind, source, line, line
        self.func, self.condition, self.hit_condition = func, condition, hit
        self.cdb_ids, self.images, self.verified, self.message, self.hits = [], set(), False, None, 0

    def dap(self):
        d = {'id': self.id, 'verified': self.verified}
        if self.kind == 'source':
            d['line'] = self.line
            d['source'] = {'path': self.source, 'name': os.path.basename(self.source)}
        if self.message:
            d['message'] = self.message
        return d


class VarNode:
    __slots__ = ('expr', 'base', 'tid', 'frame', 'ptr', 'raw', 'kind', 'cont', 'cached')

    def __init__(self, expr, tid, frame, base=None, ptr=False, raw=False, kind='dx', cont=0, cached=None):
        self.expr, self.base, self.tid, self.frame = expr, base or expr, tid, frame
        self.ptr, self.raw, self.kind, self.cont, self.cached = ptr, raw, kind, cont, cached


class EvalError(Exception):
    pass


def hit_ok(cond, n):
    c = cond.strip().replace(' ', '')
    try:
        if c.startswith('%'):
            return n % int(c[1:], 0) == 0
        for op in ('>=', '<=', '==', '>', '<'):
            if c.startswith(op):
                v = int(c[len(op):], 0)
                return {'>=': n >= v, '<=': n <= v, '==': n == v, '>': n > v, '<': n < v}[op]
        return n == int(c, 0)
    except ValueError:
        return True


def _simple_expr(e):
    return re.match(r'^[\w.\->\[\]$@]+$', e) is not None


class Session:
    def __init__(self, stream, log, exit_fn=None):
        self.s, self.log = stream, log
        self.exit_fn = exit_fn       # ends the process once the client was told the session is over
        self.finished = False
        self.cdb = None
        self.slock = threading.RLock()
        self.work = queue.Queue()
        self.cfg = {}
        self.launched = False
        self.pid = None
        self.main_tid = None
        self.cur_tid, self.cur_frame = None, 0
        self.resolver = None
        self.modules = {}            # norm(image path) -> (base, end, path)
        self.source_bps = {}         # norm(source) -> [Bp]
        self.func_bps = []
        self.cdb_owner = {}          # cdb bp id -> Bp
        self.next_dap_bp, self.next_cdb_bp = 1, 1
        self.frames, self.refs = {}, {}
        self.next_frame, self.next_ref = 1, 1
        self.scope_cache, self.stack_cache, self.threads_cache = {}, {}, []
        self.pause_requested = False
        self.exc_filters = {f['filter'] for f in EXC_FILTERS if f['default']}
        self.stray_breakins = 0      # DebugBreakProcess break-ins overtaken by a real event
        self.internal = None         # dict while an internal break-in is pending
        self.terminating = False
        self.exited_sent = False
        self.engine_root = None
        self.source_map = []
        self.src_cache = {}
        self.image_names = {}        # norm(image) -> original file name
        self.anchors = {}            # norm(image) -> (simple function name, rva) for _location
        self.last_resume = None
        self.out_lines, self.out_lock, self.out_dropped = [], threading.Lock(), 0
        self.verbose = False
        self.done = threading.Event()

    # ================================================================== plumbing
    def run(self):
        threading.Thread(target=self._worker, name='dap-worker', daemon=True).start()
        threading.Thread(target=self._output_pump, name='dap-output', daemon=True).start()
        threading.Thread(target=self._reader_loop, name='dap-reader', daemon=True).start()
        self.done.wait()
        self.flush_output()
        self.shutdown(terminate=self.launched)

    def _reader_loop(self):
        while not self.done.is_set():
            msg = self.s.read()
            if msg is None:
                break
            if msg.get('type') != 'request':
                continue
            if msg['command'] == 'pause':       # must not wait behind a busy worker
                self._safe(self.req_pause, msg)
            else:
                self.work.put(msg)
        self.work.put(None)
        self.done.set()

    def _worker(self):
        while True:
            msg = self.work.get()
            if msg is None:
                self.done.set()
                return
            self._safe(getattr(self, 'req_' + msg['command'], self.req_unknown), msg)
            if msg['command'] == 'disconnect':
                self.done.set()
                return

    def _safe(self, fn, msg):
        t0 = time.time()
        try:
            with self.slock if msg['command'] != 'pause' else _nolock():
                try:
                    body = fn(msg.get('arguments') or {})
                    self.s.respond(msg, body)
                except _Then as t:
                    self.s.respond(msg, t.body)
                    try:
                        t.after()
                    except Exception as e:
                        self.log(f'after {msg["command"]}: {e!r}')
                        self.console(f'dbgeng-dap: {msg["command"]}: {e}')
        except (CdbError, EvalError, ValueError, KeyError, OSError) as e:
            self.log(f'request {msg["command"]} failed: {e!r}')
            self.s.respond(msg, success=False, message=str(e))
        except Exception as e:  # pragma: no cover - keep the adapter alive
            import traceback
            self.log(traceback.format_exc())
            self.s.respond(msg, success=False, message=f'internal error: {e!r}')
        finally:
            self.log(f'request {msg["command"]} took {time.time() - t0:.3f}s')

    def req_unknown(self, a):
        raise ValueError('unsupported request')

    def x(self, cmd, timeout=60.0):
        return self.cdb.execute(cmd, timeout)

    # ------------------------------------------------------------------ output events
    def _on_cdb_output(self, line):
        mod = P.parse_modload(line)
        if mod:
            self._module_loaded(*mod)
            if not self.verbose:
                return
        if NOISE_RE.match(line) and not self.verbose:
            return
        with self.out_lock:
            if len(self.out_lines) > 4000:
                self.out_dropped += 1
                return
            self.out_lines.append(('console' if CDB_LINE_RE.match(line) else 'stdout', line))

    def _output_pump(self):
        while not self.done.is_set():
            time.sleep(0.1)
            self.flush_output()

    def flush_output(self):
        with self.out_lock:
            lines, self.out_lines = self.out_lines, []
            dropped, self.out_dropped = self.out_dropped, 0
        if dropped:
            lines.append(('console', f'[dbgeng-dap: {dropped} output lines dropped (rate limit)]'))
        cat, chunk = None, []
        for c, l in lines + [(None, None)]:
            if c != cat and chunk:
                self.s.event('output', {'category': cat, 'output': '\n'.join(chunk) + '\n'})
                chunk = []
            cat = c
            if l is not None:
                chunk.append(l)

    def console(self, text):
        self.s.event('output', {'category': 'console', 'output': text.rstrip('\n') + '\n'})

    # ================================================================== initialize / launch / attach
    def req_initialize(self, a):
        self.client_lines1 = a.get('linesStartAt1', True)
        return {'supportsConfigurationDoneRequest': True, 'supportsConditionalBreakpoints': True,
                'supportsHitConditionalBreakpoints': True, 'supportsFunctionBreakpoints': True,
                'supportsEvaluateForHovers': True, 'supportsTerminateRequest': True,
                'supportTerminateDebuggee': True, 'exceptionBreakpointFilters': EXC_FILTERS,
                'supportsSetVariable': False, 'supportsStepBack': False, 'supportsLogPoints': False}

    def _common_start(self, a, cmdline, cwd, env):
        self.cfg = a
        self.verbose = bool(a.get('verbose'))
        self.source_map = list((a.get('sourceMap') or {}).items())
        self.cdb = Cdb(log=self.log)
        self.cdb.on_output = self._on_cdb_output
        self.cdb.on_stop = self._on_stop
        self.cdb.on_exit = self._on_cdb_exit
        t0 = time.time()
        startup = self.cdb.start(cmdline, cwd=cwd, env=env, timeout=float(a.get('startupTimeout', 120)))
        for l in startup.split('\n'):
            mod = P.parse_modload(l)
            if mod:
                self.modules[norm(mod[2])] = mod
        self.pid = P.parse_pseudo_reg(self.x('r $tpid'), 'tpid')
        if not self.pid:
            raise CdbError('cdb has no target process:\n' + startup[-2000:])
        setup = []
        if not a.get('inlineFrames', False):
            setup.append('.inline 0')
        setup += ['.lines -e', 'l+t', 'l-s', 'sxd eh']
        for nv in self._natvis_list(a):
            setup.append(f'.nvload {nv}')
        setup.append(f'.scriptload {HELPER_JS}')
        for c in setup + list(a.get('initCommands') or []):
            out = self.x(c)
            if c.startswith(('.nvload', '.scriptload')) or c in (a.get('initCommands') or []):
                self.console(f'{c}\n{out.strip()}')
        th = P.parse_threads(self.x('~'))
        self.main_tid = th[0]['tid'] if th else None
        self.cur_tid = P.parse_pseudo_reg(self.x('r $tid'), 'tid')
        self.cur_frame = 0
        self.console(f'dbgeng-dap: cdb ready in {time.time() - t0:.2f}s (pid {self.pid}, '
                     f'{"inline frames on" if a.get("inlineFrames") else "inline frames off"})')

    def _natvis_list(self, a):
        nv = list(a.get('natvis') or [])
        if isinstance(a.get('natvis'), str):
            nv = [a['natvis']]
        if self.engine_root and a.get('autoNatvis', True):
            ue = os.path.join(self.engine_root, 'Engine', 'Extras', 'VisualStudioDebugging', 'Unreal.natvis')
            if os.path.isfile(ue) and norm(ue) not in {norm(x) for x in nv}:
                nv.insert(0, ue)
        return nv

    def _detect_engine(self, program):
        if self.cfg.get('engineRoot'):
            return self.cfg['engineRoot']
        p = norm(program or '')
        i = p.find('\\engine\\binaries\\')
        return program[:i] if i >= 0 else None

    def req_launch(self, a):
        self.cfg = a
        self.launched = True
        program = a.get('program')
        if not program or not os.path.isfile(program):
            raise ValueError(f'program not found: {program!r}')
        self.engine_root = self._detect_engine(program)
        cdb = find_cdb(a.get('cdbPath'))
        args = a.get('args') or []
        sym = a.get('symbolPath') or self._default_sympath(program, args)
        opts = [cdb, '-lines', '-hd'] + (['-y', sym] if sym else []) + list(a.get('cdbArgs') or [])
        cmdline = subprocess.list2cmdline(opts) + ' ' + subprocess.list2cmdline([program])
        cmdline += ' ' + (args if isinstance(args, str) else subprocess.list2cmdline([str(x) for x in args]))
        env = None
        if a.get('env'):
            env = dict(os.environ)
            env.update({k: str(v) for k, v in a['env'].items()})
        self.console(f'dbgeng-dap: {cmdline}')
        self._common_start(a, cmdline, a.get('cwd') or os.path.dirname(program), env)
        return _then(self, {}, lambda: self.s.event('initialized'))

    def req_attach(self, a):
        self.cfg = a
        self.launched = False
        pid = int(str(a.get('processId') or a.get('pid') or 0), 0)
        if not pid:
            raise ValueError('attach needs processId')
        cdb = find_cdb(a.get('cdbPath'))
        prog = a.get('program') or _process_image(pid)
        self.engine_root = self._detect_engine(prog)
        sym = a.get('symbolPath') or (self._default_sympath(prog, []) if prog else '')
        opts = [cdb, '-lines'] + (['-y', sym] if sym else []) + list(a.get('cdbArgs') or []) + ['-p', str(pid)]
        cmdline = subprocess.list2cmdline(opts)
        self.console(f'dbgeng-dap: {cmdline}')
        self._common_start(a, cmdline, None, None)
        return _then(self, {}, lambda: self.s.event('initialized'))

    def _default_sympath(self, program, args):
        dirs = [os.path.dirname(program)]
        argl = args.split() if isinstance(args, str) else [str(x) for x in args]
        for x in argl:
            x = x.strip('"')
            if x.lower().endswith('.uproject') and os.path.isfile(x):
                b = os.path.join(os.path.dirname(x), 'Binaries', 'Win64')
                if os.path.isdir(b):
                    dirs.append(b)
        return ';'.join(dict.fromkeys(dirs))

    def req_configurationDone(self, a):
        if self.cfg.get('stopOnEntry'):
            return _then(self, {}, lambda: self.s.event('stopped', {
                'reason': 'entry', 'threadId': self.cur_tid or self.main_tid, 'allThreadsStopped': True}))
        return _then(self, {}, lambda: self._resume('g'))

    # ================================================================== run control
    def _clear_stop_state(self):
        self.frames.clear()
        self.refs.clear()
        self.scope_cache.clear()
        self.stack_cache.clear()

    def _resume(self, cmd):
        self.last_resume = cmd.split()[0] if cmd.strip() else cmd
        self._clear_stop_state()
        self.cdb.resume(cmd)

    def _thread(self, tid):
        if tid and tid != self.cur_tid:
            self.x(f'~~[0x{tid:x}]s')
            self.cur_tid, self.cur_frame = tid, 0

    def _ctx(self, tid, frame):
        self._thread(tid)
        if frame != self.cur_frame:
            self.x(f'.frame 0n{frame}')
            self.cur_frame = frame

    def req_continue(self, a):
        return _then(self, {'allThreadsContinued': True}, lambda: self._resume('g'))

    def _step(self, a, cmd):
        self._thread(a.get('threadId'))
        return _then(self, {}, lambda: self._resume(cmd))

    def req_next(self, a):
        return self._step(a, 'p')

    def req_stepIn(self, a):
        return self._step(a, 't')

    def req_stepOut(self, a):
        return self._step(a, 'gu')

    def req_pause(self, a):
        if self.cdb and self.cdb.running and self.pid:
            self.pause_requested = True
            ok, err = debug_break_process(self.pid)
            if not ok:
                self.pause_requested = False
                raise CdbError(f'DebugBreakProcess failed (error {err})')
        return {}

    def _on_stop(self, text):
        """cdb printed a prompt after g/p/t/gu: the target stopped (cdb-stop thread)."""
        if self.terminating:
            return
        try:
            ev = P.parse_lastevent(self.x('.lastevent')) or {'kind': 'other', 'desc': '', 'tid': None}
        except CdbError as e:
            self.log(f'stop: .lastevent failed {e!r}')
            return
        internal = self.internal
        if internal is not None:
            mine = ev['kind'] == 'exception' and ev.get('code') == 0x80000003 and not self.pause_requested
            internal['real'] = not mine
            if not mine:
                self.stray_breakins += 1
            internal['event'].set()
            if mine:
                return
        with self.slock:
            self._handle_stop(text, ev)

    def _handle_stop(self, text, ev):
        self.flush_output()
        self._clear_stop_state()
        if ev['kind'] == 'exit' or 'No runnable debuggees' in text:
            self._target_exited(ev.get('code', 0))
            return
        tid = P.parse_pseudo_reg(self.x('r $tid'), 'tid') or ev.get('tid')
        self.cur_tid, self.cur_frame = tid, 0
        body = {'threadId': tid, 'allThreadsStopped': True}
        breakin = ev['kind'] == 'exception' and ev.get('code') == 0x80000003 and self._is_breakin_thread(tid)
        if breakin and not self.pause_requested and self.stray_breakins > 0:
            self.stray_breakins -= 1
            self.log('swallowing a stale DebugBreakProcess break-in')
            self._resume('g')
            return
        if self.pause_requested and not breakin:
            self.stray_breakins += 1
        ensure = (ev['kind'] == 'exception' and ev.get('code') == 0x80000003 and not breakin
                  and not self.pause_requested and self._is_ensure())
        if ensure and 'ensure' not in self.exc_filters:
            top = P.parse_stack(self.x('kn 1'))
            where = (f'{os.path.basename(top[0]["file"])}:{top[0]["line"]}'
                     if top and top[0]['file'] else (top[0]['symbol'] if top else '?'))
            self.console(f'ensure() failed at {where} (not suspended: "Suspend on ensure" is off)')
            self._resume('gh')
            return
        if ev['kind'] == 'breakpoint':
            bp = self.cdb_owner.get(ev['bp'])
            if bp is not None:
                bp.hits += 1
                if bp.hit_condition and not hit_ok(bp.hit_condition, bp.hits):
                    self.log(f'bp {bp.id}: hit {bp.hits} does not satisfy {bp.hit_condition!r}; continuing')
                    self._resume('g')
                    return
                body.update(reason='function breakpoint' if bp.kind == 'function' else 'breakpoint',
                            hitBreakpointIds=[bp.id])
            elif self.last_resume in STEP_CMDS:
                body['reason'] = 'step'          # gu/p use internal breakpoints (e.g. "Hit breakpoint 10000")
            else:
                body.update(reason='breakpoint', description=ev['desc'])
        elif self.pause_requested and breakin:
            body['reason'] = 'pause'
            th = P.parse_threads(self.x('~'))
            main = th[0]['tid'] if th else tid
            self._thread(main)
            body['threadId'] = main
        elif ensure:
            body.update(reason='exception', description='ensure() failed', text=ev['desc'])
        elif ev['kind'] == 'exception':
            name = EXC_NAMES.get(ev['code'], f'Exception 0x{ev["code"]:08x}')
            chance = 'first chance' if ev.get('first_chance') else 'second chance'
            body.update(reason='exception', description=f'{name} ({chance})', text=ev['desc'])
        elif ev['kind'] == 'none':
            body['reason'] = 'step'
        else:
            body.update(reason='pause', description=ev['desc'])
        self.pause_requested = False
        self.s.event('stopped', body)

    def _is_ensure(self):
        """The break instruction is the PLATFORM_BREAK in UE's ensure lambda (UE_ENSURE_IMPL2 in
        AssertionMacros.h), whose static locals are ENSURE_Static / ENSURE_bExecuted."""
        try:
            loc = self._dx('@$curframe.LocalVariables')
        except CdbError:
            return False
        return not loc.error and any(k.name == 'ENSURE_Static' for k in loc.children)

    def _is_breakin_thread(self, tid):
        st = P.parse_stack(self.x(f'~~[0x{tid:x}]kn 3'))
        return any(f['function'].startswith('DbgUiRemoteBreakin') for f in st)

    def _finish(self, event=True):
        """End the session. nvim-dap closes the adapter as soon as it sees `terminated` (or the
        disconnect response): it closes stdin and kills the process right away, which on Windows
        is TerminateProcess with exit code 1 and a "exited with 1" warning. So all cleanup happens
        before this, and the process ends right after the last message."""
        if self.finished:
            return
        self.finished = True
        self.flush_output()
        if event:
            self.s.event('terminated')
        self.done.set()
        if self.exit_fn:
            self.exit_fn()

    def _quit_cdb(self):
        try:
            self.cdb.write_raw('q')
            self.cdb.proc.wait(5)
        except Exception as e:
            self.log(f'quit cdb: {e!r}; killing cdb')
            self.cdb.kill()

    def _target_exited(self, code):
        if self.exited_sent:
            return
        self.exited_sent = True
        self.flush_output()
        self.s.event('exited', {'exitCode': code & 0xFFFFFFFF})
        self.terminating = True
        self._quit_cdb()
        self._finish()

    def _on_cdb_exit(self):
        if not self.exited_sent and not self.terminating:
            self.exited_sent = True
            self.terminating = True
            self._finish()

    def with_target_stopped(self, fn):
        """Run fn() with the target stopped; break in (and resume afterwards) if it is running."""
        if not self.cdb.running:
            return fn()
        ev = threading.Event()
        self.internal = {'event': ev, 'real': False}
        try:
            ok, err = debug_break_process(self.pid)
            if not ok or not ev.wait(15) or not self.cdb.wait_stopped(15):
                raise CdbError('could not break into the running target')
        finally:
            real = self.internal['real']
            self.internal = None
        try:
            return fn()
        finally:
            if not real:
                self.cdb.resume('g')

    def shutdown(self, terminate):
        if self.cdb is None or not self.cdb.alive:
            if terminate and self.launched and self.pid and process_alive(self.pid):
                terminate_process(self.pid)
            return
        self.terminating = True
        try:
            if terminate:
                if self.cdb.running and self.pid:
                    terminate_process(self.pid)
                    self.cdb.wait_stopped(15)
                self.cdb.write_raw('q')
            else:
                if self.cdb.running and self.pid:
                    debug_break_process(self.pid)
                    self.cdb.wait_stopped(15)
                self.cdb.write_raw('qd')
            self.cdb.proc.wait(20)
        except Exception as e:
            self.log(f'shutdown: {e!r}; killing cdb')
            self.cdb.kill()
        if terminate and self.launched and self.pid and process_alive(self.pid):
            terminate_process(self.pid)

    def req_disconnect(self, a):
        terminate = a.get('terminateDebuggee', self.launched)
        self.shutdown(terminate)
        raise _Then({}, lambda: self._finish(event=False))

    def req_terminate(self, a):
        self.shutdown(True)
        self.exited_sent = True
        raise _Then({}, self._finish)

    # ================================================================== breakpoints
    def _resolver(self):
        if self.resolver is None:
            sym = self.cfg.get('symbolPath') or ''
            self.resolver = LineResolver([], sym)
            self.log(f'dbghelp: {self.resolver.dll_path}')
        return self.resolver

    def candidate_images(self, source):
        """Images (DLL/EXE on disk) that may contain code of `source`.

        UE layout: <root>/Source/[Runtime|Editor|Developer|...]/<Module>/... -> <root>/Binaries/Win64/*-<Module>*.dll
        plus already-loaded modules from <root>/Binaries and the program image."""
        parts = os.path.normpath(source).split(os.sep)
        found = []
        for i in range(len(parts) - 1, 0, -1):
            if parts[i].lower() != 'source':
                continue
            root = os.sep.join(parts[:i])
            bindir = os.path.join(root, 'Binaries', 'Win64')
            mods = [m for m in parts[i + 1:min(i + 5, len(parts) - 1)]]
            if os.path.isdir(bindir):
                for m in mods:
                    for pat in (f'*-{m}.dll', f'*-{m}-Win64-*.dll', f'{m}.dll', f'{m}.exe'):
                        found += glob.glob(os.path.join(bindir, pat))
            break
        prog = self.cfg.get('program')
        if prog and os.path.isfile(prog):
            found.append(prog)
        for extra in self.cfg.get('breakpointImages') or []:
            found += glob.glob(extra)
        seen, out = set(), []
        for f in found:
            k = norm(f)
            if k not in seen and os.path.isfile(f) and os.path.isfile(os.path.splitext(f)[0] + '.pdb'):
                seen.add(k)
                out.append(f)
        return out

    def _set_cdb_bp(self, bp, location):
        cid = self.next_cdb_bp
        self.next_cdb_bp += 1
        cond = ''
        if bp.condition:
            cond = ' /w "%s"' % bp.condition.replace('\\', '\\\\').replace('"', '\\"')
        out = self.x(f'bu{cid}{cond} {location}')
        if P.is_cdb_error(out):
            self.log(f'bu failed: {out.strip()}')
            return None, out.strip()
        bp.cdb_ids.append(cid)
        self.cdb_owner[cid] = bp
        return cid, None

    def _location(self, img, mod, rva):
        """A module-qualified bp expression for img+rva.  Module!Function+off resolves only when that module
        loads; a bare Module+off is re-evaluated as an unqualified symbol on every module load (slow, noisy).
        Functions whose names MASM cannot parse (lambdas, templates, operators) are addressed relative to
        another function of the same image (an anchor)."""
        r = self._resolver()
        fn, disp = r.function_of(img, rva)
        k = norm(img)
        if fn and SIMPLE_SYM_RE.match(fn):
            self.anchors.setdefault(k, (fn, rva - disp))
            return f'{mod}!{fn}+0x{disp:x}'
        if k in self.anchors:
            afn, arva = self.anchors[k]
            d = rva - arva
            return f'{mod}!{afn}{"+" if d >= 0 else "-"}0x{abs(d):x}'
        return f'{mod}+0x{rva:x}'

    def _bind_source(self, bp):
        images = self.candidate_images(bp.source)
        hits = []
        for img in images:
            try:
                ln, rvas = self._resolver().resolve(img, bp.source, bp.req_line)
            except OSError as e:
                self.log(f'resolve {img}: {e!r}')
                continue
            if rvas:
                hits.append((img, ln, rvas))
        if not hits:
            where = ', '.join(os.path.basename(i) for i in images) or 'no candidate module found'
            bp.message = f'No code at or after line {bp.req_line} ({where})'
            return
        hits.sort(key=lambda h: norm(h[0]) not in self.modules)  # loaded image first
        bp.line = hits[0][1]
        errors = []
        for img, ln, rvas in hits:
            mod = P.cdb_module_name(img)
            for rva in rvas:
                # Module!Function+off resolves only when that module loads; plain Module+off is re-evaluated
                # (as an unqualified symbol) on every module load, so use it only for unparsable names.
                loc = self._location(img, mod, rva)
                cid, err = self._set_cdb_bp(bp, loc)
                if cid:
                    bp.images.add(norm(img))
                    self.image_names[norm(img)] = os.path.basename(img)
                elif err:
                    errors.append(err)
        if not bp.cdb_ids:
            bp.message = 'cdb rejected the breakpoint: ' + '; '.join(errors)[:300]

    def _refresh_verified(self, bps):
        if not any(bp.cdb_ids for bp in bps):
            return
        bl = P.parse_bl(self.x('bl'))
        for bp in bps:
            if not bp.cdb_ids:
                continue
            res = [bl.get(c) for c in bp.cdb_ids]
            ok = [r for r in res if r and r['resolved']]
            bp.verified = bool(ok)
            if ok:
                bp.message = None
                if bp.kind == 'source' and ok[0]['line']:
                    bp.line = ok[0]['line']
            elif bp.kind == 'source':
                bp.message = 'Pending: module not loaded yet (' + ', '.join(
                    sorted(self.image_names.get(i, os.path.basename(i)) for i in bp.images)) + ')'
            else:
                bp.message = 'Pending: symbol not resolved yet (use Module!Function for deferred resolution)'

    def _clear_bps(self, bps):
        ids = [c for bp in bps for c in bp.cdb_ids]
        for i in range(0, len(ids), 32):
            self.x('bc ' + ' '.join(str(c) for c in ids[i:i + 32]))
        for c in ids:
            self.cdb_owner.pop(c, None)

    def req_setBreakpoints(self, a):
        src = a['source'].get('path')
        if not src:
            raise ValueError('source.path required')
        src = os.path.normpath(src)

        def apply():
            old = self.source_bps.pop(norm(src), [])
            self._clear_bps(old)
            bps = []
            for b in a.get('breakpoints') or []:
                bp = Bp(self.next_dap_bp, 'source', src, int(b['line']), condition=b.get('condition') or None,
                        hit=b.get('hitCondition') or None)
                self.next_dap_bp += 1
                self._bind_source(bp)
                bps.append(bp)
            self._refresh_verified(bps)
            self.source_bps[norm(src)] = bps
            return {'breakpoints': [bp.dap() for bp in bps]}
        return self.with_target_stopped(apply)

    def req_setFunctionBreakpoints(self, a):
        def apply():
            self._clear_bps(self.func_bps)
            bps = []
            for b in a.get('breakpoints') or []:
                bp = Bp(self.next_dap_bp, 'function', func=b['name'], condition=b.get('condition') or None,
                        hit=b.get('hitCondition') or None)
                self.next_dap_bp += 1
                cid, err = self._set_cdb_bp(bp, b['name'])
                if err:
                    bp.message = err[:300]
                bps.append(bp)
            self._refresh_verified(bps)
            self.func_bps = bps
            return {'breakpoints': [bp.dap() for bp in bps]}
        return self.with_target_stopped(apply)

    def req_setExceptionBreakpoints(self, a):
        on = set(a.get('filters') or [])
        self.exc_filters = on

        def apply():
            self.x('sxe eh' if 'cpp_throw' in on else 'sxd eh')
            self.x('sxe av' if 'av' in on else 'sxd av')
            return {}
        return self.with_target_stopped(apply)

    def _module_loaded(self, base, end, path):
        """ModLoad line while running (cdb-reader thread): deferred `bu` breakpoints in it resolve now."""
        k = norm(path)
        self.modules[k] = (base, end, path)
        for bp in [b for bps in self.source_bps.values() for b in bps]:
            if not bp.verified and k in bp.images:
                bp.verified, bp.message = True, None
                self.s.event('breakpoint', {'reason': 'changed', 'breakpoint': bp.dap()})

    # ================================================================== threads / stack
    def req_threads(self, a):
        if not self.cdb or self.cdb.running or not self.cdb.alive:
            th = self.threads_cache
        else:
            th = P.parse_threads(self.x('~'))
            self.threads_cache = th
        return {'threads': [{'id': t['tid'], 'name': (f'{t["name"]} ' if t['name'] else '') +
                             f'[{t["index"]}] 0x{t["tid"]:x}'} for t in th]}

    def _stack(self, tid, count):
        c = self.stack_cache.get(tid)
        if c is None or (c[0] < count and len(c[1]) >= c[0]):
            c = (count, P.parse_stack(self.x(f'~~[0x{tid:x}]kn 0n{count}')))
            self.stack_cache[tid] = c
        return c[1]

    def map_source(self, path):
        if not path:
            return None
        if path in self.src_cache:
            return self.src_cache[path]
        res = None
        if os.path.isfile(path):
            res = path
        else:
            for frm, to in self.source_map:
                if norm(path).startswith(norm(frm)):
                    cand = os.path.normpath(to + path[len(frm):])
                    if os.path.isfile(cand):
                        res = cand
                        break
            if res is None and self.engine_root:
                i = norm(path).find('\\engine\\')
                if i >= 0:
                    cand = os.path.join(self.engine_root, path[i + 1:])
                    if os.path.isfile(cand):
                        res = cand
        self.src_cache[path] = res
        return res

    def req_stackTrace(self, a):
        if self.cdb.running:
            raise CdbError('target is running')
        tid = a['threadId']
        start = a.get('startFrame') or 0
        levels = a.get('levels') or 0
        want = start + (levels if levels else 200)
        frames = self._stack(tid, want)
        out = []
        for f in frames[start:want]:
            fid = self.next_frame
            self.next_frame += 1
            self.frames[fid] = (tid, f['index'])
            src = self.map_source(f['file'])
            # with a source file the function says it all; without, keep a short module name
            name = re.sub(r'\+0x[0-9a-f]+$', '', f['function']) if f['file'] else (
                f'{short_module(f["module"])}!{f["function"]}' if f['module'] else f['symbol'])
            d = {'id': fid, 'name': name, 'line': f['line'] or 0, 'column': 1 if f['line'] else 0}
            if src:
                d['source'] = {'name': os.path.basename(src), 'path': src}
            elif f['file']:
                d['source'] = {'name': os.path.basename(f['file']), 'path': f['file'],
                               'presentationHint': 'deemphasize'}
            else:
                d['presentationHint'] = 'subtle'
            out.append(d)
        total = len(frames) if len(frames) < want else want + 1
        return {'stackFrames': out, 'totalFrames': total}

    # ================================================================== variables
    def _frame_of(self, fid):
        if fid and fid in self.frames:
            return self.frames[fid]
        return self.cur_tid, 0

    def new_ref(self, node):
        r = self.next_ref
        self.next_ref += 1
        self.refs[r] = node
        return r

    def req_scopes(self, a):
        tid, idx = self._frame_of(a.get('frameId'))
        return {'scopes': [
            {'name': 'Locals', 'presentationHint': 'locals', 'expensive': False,
             'variablesReference': self.new_ref(VarNode('@$curframe.LocalVariables', tid, idx, kind='locals'))},
            {'name': 'Registers', 'presentationHint': 'registers', 'expensive': True,
             'variablesReference': self.new_ref(VarNode('', tid, idx, kind='regs'))}]}

    def _dx(self, expr, cont=0, timeout=30.0):
        c = f' -c {cont}' if cont else ''
        return P.parse_dx(self.x(f'dx -r1{c} {expr}', timeout))

    def _locals(self, tid, idx):
        key = (tid, idx)
        if key not in self.scope_cache:
            self._ctx(tid, idx)
            params = self._dx('@$curframe.Parameters')
            loc = self._dx('@$curframe.LocalVariables')
            kids, names = [], set()
            for root in (params, loc):
                for k in root.children if not root.error else []:
                    if k.name not in names:
                        names.add(k.name)
                        kids.append(k)
            members = set()
            if 'this' in names:
                th = self._dx('this')
                members = {P.display_name(k.name) for k in th.children if not th.error}
            self.scope_cache[key] = (kids, names, members)
        return self.scope_cache[key]

    def req_variables(self, a):
        if self.cdb.running:
            raise CdbError('target is running')
        node = self.refs.get(a['variablesReference'])
        if node is None:
            return {'variables': []}
        if node.kind == 'regs':
            self._ctx(node.tid, node.frame)
            return {'variables': [{'name': n, 'value': '0x' + v, 'variablesReference': 0, 'evaluateName': '@' + n}
                                  for n, v in P.parse_registers(self.x('r'))]}
        if node.kind == 'locals':
            kids = self._locals(node.tid, node.frame)[0]
            parent = node
        else:
            if node.cached is not None and not node.cont:
                root = node.cached
            else:
                self._ctx(node.tid, node.frame)
                root = self._dx(node.expr, node.cont)
                if root.error:
                    return {'variables': [{'name': '<error>', 'value': root.error, 'variablesReference': 0}]}
            kids = root.children
            parent = node
        out, seen = [], {}
        ordinal = node.cont
        for k in kids:
            v = self._make_var(parent, k, ordinal)
            if P.classify_child(k.name)[0] == 'index':
                ordinal += 1
            n = v['name']
            seen[n] = seen.get(n, 0) + 1
            if seen[n] > 1:
                v['name'] = f'{n} ({seen[n]})'
            out.append(v)
        start, count = a.get('start') or 0, a.get('count') or 0
        if count:
            out = out[start:start + count]
        return {'variables': out}

    def _child_expr(self, parent, k, ordinal):
        """-> (dx expression to expand the child, composable base expression, evaluateName, raw flag)."""
        kind, member = P.classify_child(k.name)
        if parent.kind == 'locals':
            if re.match(r'^[A-Za-z_]\w*$', k.name):
                return k.name, k.name, k.name, False
            e = f'@$dapkid(@$curframe.LocalVariables, "{k.name}", -1)'
            return e, e, e, False
        pb = parent.base
        pe = pb if _simple_expr(pb) else f'({pb})'
        if kind in ('field', 'static'):
            if P.strip_type(k.type) == member and not member.endswith('*'):   # base-class sub-object
                ref = f'({pb})' if parent.ptr else f'&({pb})'
                base = f'(*({member}*){ref})'
                return base + ',nd', base, base, False
            op = '->' if parent.ptr else '.'
            e = f'{pe}{op}{member}'
            return e, e, e, False
        if kind == 'raw':
            return f'{pe},!', pb, f'{pe},!', True
        if kind == 'index':
            idx = k.name[1:-1]
            e = f'@$dapkid({pb}, "{k.name}", {ordinal})'
            return e, e, f'{pe}[{idx}]', False
        if kind == 'more':
            return parent.expr, parent.base, None, parent.raw
        name = k.name.replace('\\', '\\\\').replace('"', '\\"')
        e = f'@$dapkid({pb}, "{name}", -1)'
        return e, e, e, False

    def _make_var(self, parent, k, ordinal):
        kind, _ = P.classify_child(k.name)
        expr, base, ev_name, raw = self._child_expr(parent, k, ordinal)
        value = k.value if k.value is not None else ('{' + P.strip_type(k.type) + '}' if k.type else '')
        ref = 0
        if kind == 'more':
            ref = self.new_ref(VarNode(parent.expr, parent.tid, parent.frame, base=parent.base, ptr=parent.ptr,
                                       raw=parent.raw, cont=ordinal))
            return {'name': '[more]', 'value': '...', 'variablesReference': ref}
        if P.has_children(k) and expr:
            ref = self.new_ref(VarNode(expr, parent.tid, parent.frame, base=base,
                                       ptr=P.looks_pointer(k.value, k.type) and kind != 'raw', raw=raw))
        v = {'name': P.display_name(k.name), 'value': value, 'type': P.strip_type(k.type), 'variablesReference': ref}
        if ev_name:
            v['evaluateName'] = ev_name
        return v

    # ================================================================== evaluate
    def _prepare(self, expression, context, tid, idx):
        e = expression.strip()
        if context == 'repl' or e.startswith(('@', '(', '*', '&', '-', '!')) or '!' in e or '::' in e \
                or re.match(r'^\d', e):
            if context == 'repl':
                m = re.match(r'^([A-Za-z_]\w*)', e)
                if m and m.group(1) != 'this':
                    _, names, members = self._locals(tid, idx)
                    if m.group(1) not in names and m.group(1) in members:
                        return 'this->' + e
            return e
        m = re.match(r'^([A-Za-z_]\w*)', e)
        if not m:
            return e
        root = m.group(1)
        _, names, members = self._locals(tid, idx)
        if root == 'this' or root in names:
            return e
        if root in members:
            return 'this->' + e
        raise EvalError(f"'{root}' is not a local or member in this frame")

    def req_evaluate(self, a):
        expr, ctx = a.get('expression', ''), a.get('context', 'repl')
        if ctx == 'repl' and expr.strip()[:1] in ('`', '.', '!'):
            return self._raw(expr.strip()[1:] if expr.strip().startswith('`') else expr.strip())
        if self.cdb.running:
            raise CdbError('target is running')
        tid, idx = self._frame_of(a.get('frameId'))
        e = self._prepare(expr, ctx, tid, idx)
        self._ctx(tid, idx)
        root = self._dx(e)
        if root.error:
            raise EvalError(root.error)
        ref = 0
        if root.children or P.has_children(root):
            ref = self.new_ref(VarNode(e, tid, idx, ptr=P.looks_pointer(root.value, root.type),
                                       cached=root if root.children else None))
        value = root.value if root.value is not None else '{' + P.strip_type(root.type) + '}'
        return {'result': value, 'type': P.strip_type(root.type), 'variablesReference': ref}

    def _raw(self, cmd):
        if BLOCKED_RE.match(cmd):
            raise EvalError(f'"{cmd.split()[0]}" is not allowed through the adapter (use disconnect/terminate)')
        if RESUME_RE.match(cmd):
            if self.cdb.running:
                raise CdbError('target is running')

            def go():
                self.s.event('continued', {'threadId': self.cur_tid or 0, 'allThreadsContinued': True})
                self._resume(cmd)
            return _then(self, {'result': '', 'variablesReference': 0}, go)
        if self.cdb.running:
            raise CdbError('target is running (pause first)')
        out = self.x(cmd, timeout=float(self.cfg.get('rawCommandTimeout', 120)))
        if cmd.startswith(('.frame', '~', '.cxr', '.ecxr', '.thread')):
            self.cur_tid = P.parse_pseudo_reg(self.x('r $tid'), 'tid')
            self.cur_frame = -1
        return {'result': out.rstrip(), 'variablesReference': 0}


class _NoResp:
    pass


_NORESP = _NoResp()


class _nolock:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _then(session, body, after):
    """Respond first, then run `after` (resume/event) so the response precedes resulting events."""
    raise _Then(body, after)


class _Then(Exception):
    def __init__(self, body, after):
        super().__init__('then')
        self.body, self.after = body, after


def _process_image(pid):
    try:
        r = subprocess.run(['powershell', '-NoProfile', '-Command', f'(Get-Process -Id {pid}).Path'],
                           capture_output=True, text=True, timeout=20, creationflags=0x08000000)
        p = r.stdout.strip()
        return p if p and os.path.isfile(p) else None
    except Exception:
        return None
