"""Cut real cdb command outputs out of cdbdrv-style transcripts into tests/samples/*.txt.

Transcript format (cdbdrv.py): '   12.3s  > <command>   [0.05s]' followed by the output indented by 12 spaces.
Usage: python extract_samples.py <transcript> <prefix> "<command>" [...]
"""
import os
import re
import sys

HEAD = re.compile(r'^\s*\d+\.\d+s  > (.*?)   \[\d+\.\d+s\]')


def blocks(path):
    cur, out = None, []
    for line in open(path, encoding='utf-8', errors='replace'):
        m = HEAD.match(line)
        if m:
            if cur is not None:
                yield cur, out
            cur, out = m.group(1), []
        elif re.match(r'^\s*\d+\.\d+s  ', line):
            if cur is not None:
                yield cur, out
            cur, out = None, []
        elif cur is not None:
            out.append(line[12:] if line.startswith(' ' * 12) else line.lstrip('\n'))
    if cur is not None:
        yield cur, out


def main():
    src, prefix, *cmds = sys.argv[1:]
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'samples')
    os.makedirs(here, exist_ok=True)
    seen = {}
    for cmd, lines in blocks(src):
        if cmd in cmds:
            n = seen.get(cmd, 0)
            seen[cmd] = n + 1
            safe = cmd.replace('~', 'threads').replace('|', 'procs').replace('.', 'dot')
            name = prefix + '_' + re.sub(r'[^A-Za-z0-9]+', '_', safe).strip('_') + (f'_{n}' if n else '') + '.txt'
            with open(os.path.join(here, name), 'w', encoding='utf-8', newline='\n') as f:
                f.write(''.join(lines))
            print(name, len(lines))


if __name__ == '__main__':
    main()
