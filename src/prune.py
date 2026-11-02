# SPDX-License-Identifier: MIT
import os
import shutil
from pathlib import Path
root = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'guix-impurifier'
if root.is_dir():
    for state in root.iterdir():
        descriptor = state / 'implementation'
        if descriptor.is_file() and not Path(descriptor.read_text()).exists():
            shutil.rmtree(state)
