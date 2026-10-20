"""Debug Adapter Protocol framing (Content-Length headers) over a pair of binary streams."""
import json
import threading


class DapStream:
    def __init__(self, rfile, wfile, log=None):
        self.r, self.w = rfile, wfile
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
        self.log('<- ' + json.dumps(msg)[:2000])
        return msg

    def send(self, msg):
        with self.wlock:
            self.seq += 1
            msg['seq'] = self.seq
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
