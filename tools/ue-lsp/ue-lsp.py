"""Entry script: `python path/to/ue-lsp/ue-lsp.py` (no install, stdio LSP)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if __name__ == "__main__":
    from ue_lsp.server import main
    sys.exit(main())
