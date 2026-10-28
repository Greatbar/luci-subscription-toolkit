#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Focused lock/receipt tests. No router, network or native backend calls."""
import fcntl,json,os,subprocess,sys,tempfile,time,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class Scheduler(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='toolkit-scheduler-');self.root=Path(self.tmp.name);self.base=self.root/'state';self.base.mkdir(mode=0o700);self.etc=self.root/'etc';self.etc.mkdir(mode=0o700)
  self.worker=self.root/'worker.py';self.worker.write_text('''import os,json,sys,time,fcntl
from pathlib import Path
b=Path(os.environ['TEST_BASE']);kind=sys.argv[2]
with (b/'exclusive').open('a') as f:
 fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
 with (b/'calls').open('a') as calls:calls.write(kind+'\\n')
 (b/'started').write_text(kind)
 time.sleep(float(os.environ.get('TEST_SECONDS','0')))
 state={'state':'control_checked' if kind=='health' else 'pending','last_success':int(time.time()),'apply_blocked_reason':'outside_window' if kind=='due' else None}
 (b/'status.json').write_text(json.dumps(state))
 if os.environ.get('TEST_FAIL'):print('{"ok":false,"error":"subscription_unavailable_or_invalid"}');sys.exit(1)
 print('{"ok":true}')
''')
  s=(ROOT/'root/usr/libexec/podkop-tools/task').read_text().replace('/tmp/podkop-tools',str(self.base)).replace('/etc/podkop-tools',str(self.etc)).replace('!= 0 ];','!= '+str(os.getuid())+' ];').replace('ucode /usr/libexec/podkop-tools/backend.uc',sys.executable+' '+str(self.worker)+' ignored')
  self.task=self.root/'task';self.task.write_text(s);self.env={**os.environ,'TEST_BASE':str(self.base)};self.children=[]
 def tearDown(self):
  for p in self.children:
   if p.poll() is None:p.terminate();p.communicate(timeout=10)
  self.tmp.cleanup()
 def start(self,kind,**env):
  p=subprocess.Popen(['sh',str(self.task),kind],env={**self.env,**env},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);self.children.append(p);return p
 def done(self,p,code=0):
  out,err=p.communicate(timeout=12);self.assertEqual(p.returncode,code,(out,err));return json.loads(out)
 def until(self,path):
  deadline=time.monotonic()+4
  while not path.exists():
   if time.monotonic()>deadline:self.fail('timed out waiting for '+str(path))
   time.sleep(.02)
 def receipts(self,family):return [json.loads(p.read_text()) for p in (self.base/'scheduler').glob(family+'-*.json')]
 def schedule(self,hour='3',enabled='1'):
  bindir=self.root/'bin';bindir.mkdir(exist_ok=True)
  uci=bindir/'uci';uci.write_text('''#!/bin/sh
case "$3" in
 podkop_tools.main.enabled) printf '%s\\n' "$SCHEDULE_ENABLED";;
 podkop_tools.main.fetch_hours) printf '6\\n';;
 podkop_tools.main.health_minutes) printf '1\\n';;
 podkop_tools.main.apply_hour) printf '%s\\n' "$SCHEDULE_HOUR";;
 *) exit 1;;
esac
''');uci.chmod(0o755)
  cron=bindir/'crontab';cron.write_text('#!/bin/sh\nif [ "$1" = -l ]; then cat "$SCHEDULE_CRON"; else cat > "$SCHEDULE_CRON"; fi\n');cron.chmod(0o755)
  cronfile=self.root/'crontab';cronfile.write_text('7 * * * * unrelated-job\n')
  (self.base/'history-ready').touch()
  init=self.root/'init';init.write_text((ROOT/'root/etc/init.d/podkop-tools').read_text().replace('/tmp/podkop-tools',str(self.base)))
  result=subprocess.run(['sh','-c','. "$1"; reload_service','test-init',str(init)],env={**self.env,'PATH':str(bindir)+':'+os.environ['PATH'],'SCHEDULE_ENABLED':enabled,'SCHEDULE_HOUR':hour,'SCHEDULE_CRON':str(cronfile)},capture_output=True,text=True)
  return result,cronfile.read_text()
 def test_due_rechecks_cooldown_inside_configured_night_window(self):
  result,cron=self.schedule('3');self.assertEqual(result.returncode,0,result.stderr)
  due=[line.split()[:5] for line in cron.splitlines() if '/task due ' in line]
  def matches(field,value):return field=='*' or str(value) in field.split(',') or field.startswith('*/') and value%int(field[2:])==0
  ticks=[(h,m) for h in range(24) for m in range(60) if any(matches(f[0],m) and matches(f[1],h) for f in due)]
  # Yesterday's apply completed at 03:43:34: 03:44 is the first safe
  # minute today. A single 03:43 tick loses the whole permitted hour.
  self.assertTrue(any(h==3 and 44<=m<=49 for h,m in ticks));self.assertTrue(all(h==3 for h,m in ticks))
  # Priority due jobs must leave three consecutive minute slots for the
  # existing health policy to confirm an outage (three samples over 120s).
  self.assertTrue(any(all((3,m+k) not in ticks for k in range(3)) for m in range(58)))
  self.assertIn('7 * * * * unrelated-job',cron)
 def test_invalid_night_hour_preserves_existing_crontab(self):
  for hour in ('24','-1','bad'):
   result,cron=self.schedule(hour);self.assertNotEqual(result.returncode,0,hour)
   self.assertEqual(cron,'7 * * * * unrelated-job\n')
 def test_disabled_automation_keeps_only_unrelated_cron(self):
  result,cron=self.schedule(enabled='0');self.assertEqual(result.returncode,0,result.stderr)
  self.assertEqual(cron.strip(),'7 * * * * unrelated-job')
 def test_check_waits_for_health_and_coalesces_fetch(self):
  health=self.start('health',TEST_SECONDS='2');self.until(self.base/'started')
  check=self.start('check');self.until(self.base/'waiting-fetch')
  self.done(self.start('fetch'),1);self.done(health);self.done(check)
  self.assertEqual((self.base/'calls').read_text().splitlines(),['health','check'])
  r=self.receipts('fetch');self.assertEqual(sorted(x['result'] for x in r),['skipped','success']);self.assertTrue(any(x['reason']=='duplicate' for x in r));self.assertTrue(any(x['wait_seconds']>=1 for x in r))
 def test_waiting_due_yields_health_and_both_important_families_run(self):
  with (self.base/'job.lock').open('w') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX)
   due=self.start('due');check=self.start('check');self.until(self.base/'waiting-due');self.until(self.base/'waiting-fetch')
   self.assertEqual(self.done(self.start('health'),1)['error'],'priority_waiting')
   self.done(self.start('due'),1);fcntl.flock(lock,fcntl.LOCK_UN)
  self.done(due);self.done(check);self.assertEqual(sorted((self.base/'calls').read_text().splitlines()),['check','due'])
  self.assertTrue(any(x['reason']=='outside_window' and x['result']=='skipped' for x in self.receipts('due')))
 def test_bounded_wait_and_stale_marker(self):
  # Shorten only the deadline in this fixture; production remains 90 seconds.
  self.task.write_text(self.task.read_text().replace('queued_mono + 90','queued_mono + 2'))
  with (self.base/'job.lock').open('w') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX);t=time.monotonic();self.done(self.start('check'),1);self.assertLess(time.monotonic()-t,4)
  self.assertEqual(self.receipts('fetch')[0]['reason'],'lock_timeout');self.assertFalse((self.base/'waiting-fetch').exists())
  (self.base/'waiting-fetch').write_text('99999999 1\n');self.done(self.start('health'))
 def test_interrupted_wait_cleans_priority(self):
  with (self.base/'job.lock').open('w') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX);p=self.start('due');self.until(self.base/'waiting-due');p.terminate();out,err=p.communicate(timeout=4);self.assertEqual(p.returncode,143,(out,err))
  self.assertFalse((self.base/'waiting-due').exists());r=self.receipts('due')[0];self.assertEqual((r['result'],r['reason']),('failed','interrupted'));self.done(self.start('health'))
 def test_failure_and_bounded_private_receipts(self):
  self.done(self.start('fetch',TEST_FAIL='1'),1);r=self.receipts('fetch')[0];self.assertEqual((r['result'],r['reason']),('failed','subscription_unavailable_or_invalid'))
  for i in range(52):(self.base/'scheduler'/f'due-1-{i}.json').write_text('{}')
  self.done(self.start('due'));self.assertLessEqual(len(self.receipts('due')),48)
  latest=max((self.base/'scheduler').glob('due-*.json'),key=lambda p:p.stat().st_mtime);self.assertEqual(latest.stat().st_mode&0o777,0o600)
if __name__=='__main__':unittest.main()
