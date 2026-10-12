#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
"""No network transfers: real sing-box readiness with AX6S integer-only sleep.

The delayed launcher ensures the test fails if polling spins through rejected
fractional sleeps before the process can listen. Temporary lab-only wrappers
are restored even on assertion failure. Never accesses the router.
"""
import pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];NAME='subscription-toolkit-test-main'
def run(*args,check=True):
 r=subprocess.run(['docker','exec',NAME,*args],capture_output=True,text=True)
 if check and r.returncode:raise RuntimeError(r.stdout+r.stderr)
 return r
def copy(path,target):subprocess.run(['docker','exec','-i',NAME,'sh','-c','cat > "$1.toolkit-copy" && chmod "$2" "$1.toolkit-copy" && mv "$1.toolkit-copy" "$1"','copy',target,oct(path.stat().st_mode & 0o777)[2:]],input=path.read_bytes(),check=True,capture_output=True)
run('mkdir','-p','/tmp/podkop-tools/job','/etc/podkop-tools','/etc/config','/usr/libexec/podkop-tools')
source=ROOT/'root'
copy(source/'etc/config/podkop_tools','/etc/config/podkop_tools')
copy(source/'usr/libexec/podkop-tools/model.uc','/usr/libexec/podkop-tools/model.uc')
copy(ROOT/'.build/sing-box-1.14.2-linux-amd64-musl/sing-box','/usr/bin/sing-box')
with tempfile.TemporaryDirectory() as tmp:
 tmp=pathlib.Path(tmp)
 prefix=(source/'usr/libexec/podkop-tools/backend.uc').read_text().split('let command = ARGV')[0]
 (tmp/'test.uc').write_text(prefix+'''\nlet success=false;try{ start_probe({type:'direct'});success=true;}catch(e){}stop_probe();if(!success)die('readiness_failed_with_integer_only_sleep');print('PASS integer-only sleep readiness and cleanup\\n');\n''')
 (tmp/'sleep').write_text('#!/bin/sh\ncase "$*" in *.*) echo fractional_sleep_rejected >/tmp/fractional-sleep-rejected; exit 1;; esac\nexec /bin/busybox sleep "$@"\n')
 (tmp/'timeout').write_text('#!/bin/sh\nif [ "$*" = "-s TERM 240 /usr/bin/sing-box run -c /tmp/podkop-tools/job/probe.json" ]; then /bin/sleep 1; fi\nexec /usr/bin/timeout-podkop-test-original "$@"\n')
 run('mv','/bin/sleep','/bin/sleep-podkop-test-original');run('mv','/usr/bin/timeout','/usr/bin/timeout-podkop-test-original')
 try:
  copy(tmp/'sleep','/bin/sleep');copy(tmp/'timeout','/usr/bin/timeout');copy(tmp/'test.uc','/tmp/integer-sleep-readiness.uc')
  run('chmod','755','/bin/sleep','/usr/bin/timeout')
  r=run('ucode','/tmp/integer-sleep-readiness.uc',check=False);print(r.stdout+r.stderr,end='')
  assert r.returncode==0,'readiness failed with AX6S sleep contract'
  assert run('test','!','-e','/tmp/fractional-sleep-rejected',check=False).returncode==0
 finally:
  run('rm','/bin/sleep','/usr/bin/timeout');run('mv','/bin/sleep-podkop-test-original','/bin/sleep');run('mv','/usr/bin/timeout-podkop-test-original','/usr/bin/timeout')
  run('rm','-rf','/tmp/podkop-tools/job','/tmp/fractional-sleep-rejected')
