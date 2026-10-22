"""Debug Adapter Protocol framing (Content-Length headers) over a pair of binary streams."""
import json
import re
import threading


class PathMap:
    """Paths of a client on another file system (Neovim in WSL: /mnt/d/x) and this Windows adapter (D:\\x).

    `pairs`: (client prefix, Windows prefix), e.g. the project root as the client spells it (WSL's /mnt is
    case-insensitive) and its real Windows path; `wsl`: any /mnt/<drive>/ path is that drive.
    Incoming: values of the keys in IN_KEYS and items of "args"; outgoing: values of "path".
    """
    IN_KEYS = ('path', 'program', 'cwd', 'engineRoot')

    def __init__(self, pairs=(), wsl=False):
        self.pairs = sorted(((c.rstrip('/'), w.replace('/', '\\').rstrip('\\')) for c, w in pairs),
                            key=lambda p: -len(p[0]))
        self.wsl = wsl

    def to_adapter(self, p):
        for c, w in self.pairs:
            if p == c or p.startswith(c + '/'):
                return w + p[len(c):].replace('/', '\\')
        m = self.wsl and re.match(r'^/mnt/([a-zA-Z])(/.*)?$', p)
        if m:
            return m.group(1).upper() + ':' + (m.group(2) or '/').replace('/', '\\')
        return p

    def to_client(self, p):
        q = p.replace('\\', '/')
        for c, w in self.pairs:
            w = w.replace('\\', '/')
            if q.lower() == w.lower() or q.lower().startswith(w.lower() + '/'):
                return c + q[len(w):]
        m = self.wsl and re.match(r'^([a-zA-Z]):(/.*)?$', q)
        if m:
            return '/mnt/' + m.group(1).lower() + (m.group(2) or '/')
        return p

    def _walk(self, v, keys, fn):
        if isinstance(v, dict):
            for k, x in v.items():
                if k in keys and isinstance(x, str):
                    v[k] = fn(x)
                elif k == 'args' and fn == self.to_adapter and isinstance(x, list):
                    v[k] = [fn(a) if isinstance(a, str) and a.startswith('/') else a for a in x]
                else:
                    self._walk(x, keys, fn)
        elif isinstance(v, list):
            for x in v:
                self._walk(x, keys, fn)

    def incoming(self, msg):
        self._walk(msg, self.IN_KEYS, self.to_adapter)

    def outgoing(self, msg):
        self._walk(msg, ('path',), self.to_client)


class DapStream:
    def __init__(self, rfile, wfile, log=None, path_map=None):
        self.r, self.w = rfile, wfile
        self.path_map = path_map
        self.wlock = threading.Lock()
        self.seq = 0
        self.log = log or (lambda m: None)

    def read(self):
        """Next message dict, or None at EOF."""
        length = None
        while True:
            line = self.r.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                if length is not None:
                    break
                continue
            k, _, v = line.decode('ascii', 'replace').partition(':')
            if k.strip().lower() == 'content-length':
                length = int(v.strip())
        body = b''
        while len(body) < length:
            chunk = self.r.read(length - len(body))
            if not chunk:
                return None
            body += chunk
        msg = json.loads(body.decode('utf-8'))
        if self.path_map:
            self.path_map.incoming(msg)
        self.log('<- ' + json.dumps(msg)[:2000])
        return msg

    def send(self, msg):
        with self.wlock:
            self.seq += 1
            msg['seq'] = self.seq
            if self.path_map:
                self.path_map.outgoing(msg)
            data = json.dumps(msg).encode('utf-8')
            self.w.write(b'Content-Length: %d\r\n\r\n' % len(data) + data)
            self.w.flush()
        if not (msg.get('type') == 'event' and msg.get('event') == 'output'):
            self.log('-> ' + json.dumps(msg)[:2000])

    def event(self, name, body=None):
        self.send({'type': 'event', 'event': name, 'body': body or {}})

    def respond(self, req, body=None, success=True, message=None):
        m = {'type': 'response', 'request_seq': req['seq'], 'command': req['command'], 'success': success,
             'body': body or {}}
        if message:
            m['message'] = message
        self.send(m)
