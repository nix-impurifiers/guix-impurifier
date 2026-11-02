# SPDX-License-Identifier: MIT
import argparse
import os
import pwd
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--owner')
parser.add_argument('implementation', type=Path)
args = parser.parse_args()
implementation = args.implementation.resolve(strict=True)
if not str(implementation).startswith('/gnu/store/') or implementation.parent != Path('/gnu/store'):
    parser.error('select an installed Guix store package')
subprocess.run(['guix', 'gc', '--references', str(implementation)], check=True, stdout=subprocess.DEVNULL)
if args.owner:
    if os.geteuid() != 0:
        parser.error('--owner requires root')
    owner = pwd.getpwnam(args.owner)
    def drop():
        os.initgroups(owner.pw_name, owner.pw_gid)
        os.setgid(owner.pw_gid)
        os.setuid(owner.pw_uid)
else:
    drop = None
with tempfile.TemporaryDirectory(prefix='guix-impurifier-') as staging:
    for index, name in enumerate(['sdk-root', 'nix-root']):
        link = implementation / name
        target = os.readlink(link)
        command = ['nix-store', '--realise', target, '--add-root', f'{staging}/{index}', '--indirect']
        cache = implementation / ('sdk-cache' if name == 'sdk-root' else 'cache')
        if cache.is_dir():
            command += ['--option', 'substituters', cache.as_uri()]
            if os.geteuid() == 0:
                command += ['--option', 'require-sigs', 'false']
        subprocess.run(command, check=True)
        subprocess.run(['impurifier-register-root', str(link)], check=True, preexec_fn=drop)
