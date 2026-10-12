#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
from pathlib import Path
import subprocess,hashlib,shutil,os,tempfile
root=Path(__file__).resolve().parents[1];apk=root/'.build/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64/staging_dir/host/bin/apk'
results=[]
with tempfile.TemporaryDirectory(prefix='toolkit-repro-') as tmp:
 for i in (0,1):
  clone=Path(tmp)/str(i);shutil.copytree(root,clone,ignore=shutil.ignore_patterns('.build','dist','node_modules','.git','__pycache__'))
  for p in sorted(clone.rglob('*'),reverse=True):os.utime(p,(1700000000+i*86400,1700000000+i*86400))
  subprocess.run(['python3',str(clone/'tools/build-podkop-tools.py'),'--apk',str(apk),'--output',str(root/'.build'/f'repro-{i}')],check=True)
  results.append(hashlib.sha256(next((root/'.build'/f'repro-{i}').glob('*.apk')).read_bytes()).hexdigest())
print(results)
assert results[0]==results[1],'APK bytes depend on checkout mtimes'
