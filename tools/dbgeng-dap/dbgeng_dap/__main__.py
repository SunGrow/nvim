"""dbgeng-dap entry point.

    python dbgeng-dap.py                 # DAP over stdin/stdout (nvim-dap type='executable')
    python dbgeng-dap.py --port 4711     # DAP over TCP, one session (nvim-dap type='server')
    --log FILE                           # protocol + cdb transcript (also env DBGENG_DAP_LOG)
    --wsl [--path-map CLIENT=WINDOWS]... # client in WSL: /mnt/<drive>/ paths, plus roots spelled otherwise
"""
import argparse
import os
import socket
import sys
import threading
import time

from .adapter import Session
from .dap import DapStream, PathMap


def make_logger(path):
    if not path:
        return lambda m: None
    f = open(path, 'a', encoding='utf-8', errors='replace', buffering=1)
    lock = threading.Lock()
    t0 = time.time()

    def log(m):
        with lock:
            f.write(f'{time.strftime("%H:%M:%S")} {time.time() - t0:9.3f} {m}\n')
    return log


def main(argv=None):
    ap = argparse.ArgumentParser(prog='dbgeng-dap')
    ap.add_argument('--port', type=int, default=0, help='listen on 127.0.0.1:PORT instead of stdio')
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--log', default=os.environ.get('DBGENG_DAP_LOG', ''))
    ap.add_argument('--wsl', action='store_true', help='the client sees Windows drives as /mnt/<drive>/')
    ap.add_argument('--path-map', action='append', default=[], metavar='CLIENT=WINDOWS',
                    help='a client path prefix and the Windows path it stands for')
    a = ap.parse_args(argv)
    pairs = [m.split('=', 1) for m in a.path_map if '=' in m]
    path_map = PathMap(pairs, a.wsl) if (pairs or a.wsl) else None
    log = make_logger(a.log)
    log(f'dbgeng-dap start pid={os.getpid()} python={sys.version.split()[0]} argv={sys.argv}')
    if a.port:
        srv = socket.create_server((a.host, a.port))
        log(f'listening on {a.host}:{a.port}')
        conn, peer = srv.accept()
        srv.close()
        log(f'client {peer}')
        stream = DapStream(conn.makefile('rb'), conn.makefile('wb'), log, path_map)
    else:
        stream = DapStream(sys.stdin.buffer, sys.stdout.buffer, log, path_map)
        sys.stdout = sys.stderr  # nothing else may write to the protocol stream
    def hard_exit():
        log('dbgeng-dap exit')
        try:
            sys.stderr.flush()
        finally:
            if sys.platform == 'win32':
                # nvim-dap kills the adapter (TerminateProcess, exit code 1 -> "exited with 1") as soon
                # as it reads the last message; ExitProcess (os._exit) is slow enough to lose that race.
                # Written pipe data stays readable after the process is gone.
                import ctypes
                k32 = ctypes.windll.kernel32
                k32.GetCurrentProcess.restype = ctypes.c_void_p
                k32.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint]
                k32.TerminateProcess(k32.GetCurrentProcess(), 0)
            # daemon threads may still block in stdin/socket reads; skip interpreter finalisation
            os._exit(0)

    # The session calls hard_exit itself right after its last message (see Session._finish).
    Session(stream, log, exit_fn=hard_exit).run()
    hard_exit()


if __name__ == '__main__':
    main()
