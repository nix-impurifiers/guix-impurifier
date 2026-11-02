# SPDX-License-Identifier: MIT
import fcntl
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

implementation = Path(__file__).resolve().parent
config = json.loads((implementation / 'application.json').read_text())
for link in ['sdk-root', 'nix-root']:
    subprocess.run([config['registerRoot'], str(implementation / link)], check=True)
program = str((implementation / 'nix-root').resolve() / 'bin' / config['program'])
environment = os.environ.copy()
os.environ['PATH'] = config['nixBin'] + ':' + os.environ.get('PATH', '')
if config.get('hardware'):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('engine', implementation / 'engine.py')
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    root = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'guix-impurifier'
    state = root / hashlib.sha256(os.fsencode(implementation)).hexdigest()
    state.mkdir(parents=True, exist_ok=True)
    (state / 'implementation').write_text(str(implementation))
    manifest = engine.validate({'name': 'guix-hardware', 'version': '1', 'priority': 5,
        'installable': str((implementation / 'nix-root').resolve()), 'hardware': config['hardware']}, 'guix-impurifier')
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        snapshot = engine.hardware_snapshots([manifest], state)['guix-hardware']
        subprocess.run(['nix-store', '--realise', snapshot, '--add-root', str(state / ('library-' + hashlib.sha256(snapshot.encode()).hexdigest())), '--indirect'], check=True, stdout=subprocess.DEVNULL)
    environment['LD_LIBRARY_PATH'] = snapshot + (':' + environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    if config['hardware'].get('preload'):
        environment['LD_PRELOAD'] = ' '.join(snapshot + '/' + name for name in config['hardware']['preload'])
os.execve(program, [program, *sys.argv[1:]], environment)
