"""Launcher: works with `python -I` (isolated mode drops the script dir from sys.path, so add it back)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dbgeng_dap.__main__ import main  # noqa: E402

if __name__ == '__main__':
    main()
