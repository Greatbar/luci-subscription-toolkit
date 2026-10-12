#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build two clean candidate clones with different mtimes; never commit."""
import sys
sys.dont_write_bytecode=True
import argparse, hashlib, os, pathlib, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from security import APK_NAME, Snapshot, git_env
p=argparse.ArgumentParser()
p.add_argument('--apk',default=str(ROOT/'.build/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64/staging_dir/host/bin/apk'))
a=p.parse_args()
snapshot=Snapshot(ROOT)
try:
 with tempfile.TemporaryDirectory(prefix='toolkit-repro-') as tmp:
  tmp=pathlib.Path(tmp);results=[]
  for i in (0,1):
   clone=tmp/str(i)
   subprocess.run(['git','clone','--no-hardlinks','--quiet',str(ROOT),str(clone)],check=True,capture_output=True,env=git_env(ROOT))
   for name,(data,mode) in snapshot.files.items():
    target=clone/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(mode)
    os.utime(target,(1700000000+i*86400,1700000000+i*86400))
   output=tmp/('output-'+str(i))
   subprocess.run([sys.executable,'-B',str(clone/'tools/build-podkop-tools.py'),'--apk',a.apk,'--output',str(output)],check=True)
   results.append((output/APK_NAME).read_bytes())
  if results[0]!=results[1]:raise SystemExit('FAIL: checkout mtimes affect APK')
  if results[0]!=(ROOT/'dist'/APK_NAME).read_bytes():raise SystemExit('FAIL: clean clone APK differs from release APK')
  snapshot.verify_unchanged()
  print('PASS two clean candidate clones: identical APK, SHA256 '+hashlib.sha256(results[0]).hexdigest())
finally:snapshot.close()
