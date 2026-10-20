"""dbgeng-dap entry point.

    python dbgeng-dap.py                 # DAP over stdin/stdout (nvim-dap type='executable')
    python dbgeng-dap.py --port 4711     # DAP over TCP, one session (nvim-dap type='server')
    --log FILE                           # protocol + cdb transcript (also env DBGENG_DAP_LOG)
"""
import argparse
import os
import socket
import sys
import threading
import time

from .adapter import Session
from .dap import DapStream


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
    a = ap.parse_args(argv)
    log = make_logger(a.log)
    log(f'dbgeng-dap start pid={os.getpid()} python={sys.version.split()[0]} argv={sys.argv}')
    if a.port:
        srv = socket.create_server((a.host, a.port))
        log(f'listening on {a.host}:{a.port}')
        conn, peer = srv.accept()
        srv.close()
        log(f'client {peer}')
        stream = DapStream(conn.makefile('rb'), conn.makefile('wb'), log)
    else:
        stream = DapStream(sys.stdin.buffer, sys.stdout.buffer, log)
        sys.stdout = sys.stderr  # nothing else may write to the protocol stream
    Session(stream, log).run()
    log('dbgeng-dap exit')
    try:
        sys.stderr.flush()
    finally:
        # daemon threads may still block in stdin/socket reads; skip interpreter finalisation
        os._exit(0)


if __name__ == '__main__':
    main()
