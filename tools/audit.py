#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Audit the export tree and every Git object; never print matched values."""
import sys
sys.dont_write_bytecode=True
import argparse, hashlib, ipaddress, json, pathlib, re, shutil, subprocess, tempfile
import importlib.util
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from security import SecurityError, Snapshot, git, git_env, inspect_tree
PATTERNS={
 'uuid':r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b',
 'ipv4':r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
 'url':r'https?://[^\s\x27\x22<>`]+',
 'credential_literal':r'(?i)(?:token|password|uuid|public_key|private_key)\s*[:=]\s*[\x27\x22][^\x27\x22\n]+[\x27\x22]',
 'private_key':r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
 'credential_assignment':r'(?i)(?:token|password|passwd|api_key|secret|cookie|authorization|public_key|private_key|uuid|short_id|publicKey|shortId)[\x27\x22]?\s*[:=]\s*[\x27\x22][^\x27\x22\n]{4,}[\x27\x22]',
 'ssh_key':r'\bssh-(?:rsa|ed25519)\s+[A-Za-z0-9+/]+',
 'known_token':r'\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,})',
 'mac':r'\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b',
 'private_path':r'(?:/home/[^\s\x27\x22`]+|snapshots/[^\s\x27\x22`]+|/root/[^\s\x27\x22`]+|/work/[^\s\x27\x22`]+)',
 'hostname_literal':r'(?i)[\x27\x22]((?:[a-z0-9-]+\.)+(?:invalid|example|com|org|net|ru|io|info|ai))[\x27\x22]',
}
def candidates():
 names=json.loads((ROOT/'tools/publication-files.json').read_text())
 inspect_tree(ROOT,names)
 return [ROOT/name for name in names]
def scan(data,name):
 findings=[]
 for n,line in enumerate(data.decode('utf-8',errors='replace').splitlines(),1):
  for kind,pattern in PATTERNS.items():
   for match in re.finditer(pattern,line):
    value=match.group(1) if kind=='hostname_literal' else match.group()
    if kind=='ipv4':
     try:ipaddress.ip_address(value)
     except ValueError:continue
    if kind=='url' and value in ('https://','http://'):continue
    findings.append({'file':name,'line':n,'kind':kind,'value_sha256':hashlib.sha256(value.encode()).hexdigest()})
  for match in re.finditer(r'(?<![\w:])[0-9a-fA-F:]*:[0-9a-fA-F:]+(?![\w:])',line):
   value=match.group()
   try:address=ipaddress.ip_address(value)
   except ValueError:continue
   if address.version==6:findings.append({'file':name,'line':n,'kind':'ipv6','value_sha256':hashlib.sha256(value.encode()).hexdigest()})
 return findings
def key(f):return (f['file'],f['kind'],f['value_sha256'])
def validate_findings(data, name, accepted):
 try: data.decode('utf-8')
 except UnicodeDecodeError: raise SecurityError('binary publication input: ' + name)
 findings=scan(data,name)+scan(name.encode(),'<filename>:'+name)
 rejected=[f for f in findings if key(f) not in accepted]
 if rejected:
  # Hash evidence only, never a matched value or surrounding source line.
  raise SecurityError('unreviewed sensitive patterns: '+json.dumps(rejected))
 return findings


def gitleaks(executable, mode, target, report, log=False):
 args=[str(executable),mode,str(target),'--redact=100','--no-banner','--ignore-gitleaks-allow',
       '--report-format=json','--report-path='+str(report)]
 if log: args+=['--log-opts=--all --full-history']
 result=subprocess.run(args,capture_output=True,env=git_env(ROOT))
 if not report.exists():raise SecurityError('Gitleaks report missing')
 try: leaks=json.loads(report.read_text())
 except (ValueError,OSError):raise SecurityError('invalid Gitleaks report')
 if result.returncode or leaks:raise SecurityError('Gitleaks blocked publication; exit='+str(result.returncode))
 return 0


def audit_snapshot(snapshot, executable, history=True, require_no_remotes=False):
 accepted={key(f) for f in json.loads(snapshot.files['tools/audit-allowlist.json'][0])}
 findings=[]
 for name,(data,mode) in snapshot.files.items():findings+=validate_findings(data,name,accepted)
 with tempfile.TemporaryDirectory(prefix='toolkit-audit-') as tmp:
  tmp=pathlib.Path(tmp);export=tmp/'export';snapshot.export(export)
  spec=importlib.util.spec_from_file_location('synthetic_fixtures',export/'tools/generate-fixtures.py')
  generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)
  current_fixtures=generator.fixture_bytes();historical_fixtures=generator.fixture_bytes(legacy_tls=True)
  for name,data in current_fixtures.items():
   if snapshot.files['tests/fixtures/'+name][0]!=data:raise SecurityError('synthetic fixture byte mismatch: '+name)
  gitleaks(executable,'dir',export,tmp/'tree-gitleaks.json')
  objects=0
  if history:
   # Git alternates/grafts/shallow sources would invalidate complete local coverage.
   for path in ['objects/info/alternates','info/grafts','shallow','refs/replace']:
    if (snapshot.root/'.git'/path).exists():raise SecurityError('unsupported Git history indirection: '+path)
   paths={}
   for commit in git(snapshot.root,'rev-list','--all').decode().splitlines():
    for line in git(snapshot.root,'ls-tree','-rz',commit).split(b'\0'):
     if not line:continue
     header,name=line.split(b'\t',1);mode,kind,oid=header.split()
     if mode not in (b'100644',b'100755'):raise SecurityError('nonregular historical Git entry: '+name.decode())
     paths.setdefault(oid.decode(),set()).add(name.decode())
   store=tmp/'objects';store.mkdir()
   inventory=git(snapshot.root,'cat-file','--batch-all-objects','--batch-check=%(objectname) %(objecttype)').decode()
   for line in inventory.splitlines():
    oid,kind=line.split();objects+=1
    data=git(snapshot.root,'cat-file',kind,oid)
    if kind=='blob':
     if oid not in paths:raise SecurityError('unattributed Git blob: '+oid)
     for name in paths[oid]:
      validate_findings(data,name,accepted)
      if name.startswith('tests/fixtures/'):
       basename=name.removeprefix('tests/fixtures/')
       if basename not in current_fixtures or data not in (current_fixtures[basename],historical_fixtures[basename]):
        raise SecurityError('unproven historical fixture bytes: '+name)
     (store/(oid+'.blob')).write_bytes(data)
    elif kind in ('commit','tag'):
     # Only the explicitly anonymous reserved commit identity is acceptable.
     for identity in re.findall(rb'(?:author|committer|tagger) ([^\n]+)',data):
      if not re.fullmatch(rb'LuCI Subscription Toolkit contributors <maintainers@example\.invalid> \d+ [+-]\d{4}',identity):
       raise SecurityError('unreviewed Git author metadata: '+oid)
     if scan(data,'git-'+kind):raise SecurityError('sensitive-pattern Git metadata: '+oid)
     (store/(oid+'.'+kind)).write_bytes(data)
    elif kind=='tree':
     for entry in git(snapshot.root,'ls-tree','-z',oid).split(b'\0'):
      if not entry:continue
      header,name=entry.split(b'\t',1);mode,typ,target=header.split()
      if mode not in (b'040000',b'100644',b'100755'):raise SecurityError('nonregular Git tree object: '+oid)
      validate_findings(name,name.decode(),accepted)
   gitleaks(executable,'dir',store,tmp/'objects-gitleaks.json')
   gitleaks(executable,'git',snapshot.root,tmp/'history-gitleaks.json',log=True)
   git(snapshot.root,'fsck','--full','--no-reflogs')
   if require_no_remotes and git(snapshot.root,'remote').strip():raise SecurityError('unexpected remote')
  snapshot.verify_unchanged()
 return {'files_scanned':len(snapshot.files),'git_objects_scanned':objects,'pattern_findings':findings,
         'unreviewed':[],'gitleaks_tree_count':0,'gitleaks_history_count':0,'errors':[],
         'candidate_tree':snapshot.tree,'ok':True}


def main():
 p=argparse.ArgumentParser();p.add_argument('--gitleaks',required=True);p.add_argument('--history',action='store_true');p.add_argument('--require-no-remotes',action='store_true');p.add_argument('--output',default='.build/audit.json');a=p.parse_args()
 snapshot=Snapshot(ROOT)
 try:report=audit_snapshot(snapshot,a.gitleaks,a.history,a.require_no_remotes)
 finally:snapshot.close()
 output=ROOT/a.output;output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({k:v for k,v in report.items() if k!='pattern_findings'},indent=2))


if __name__=='__main__':
 try:main()
 except (SecurityError,OSError,ValueError) as e:
  print('BLOCKED: '+(str(e) if isinstance(e,SecurityError) else type(e).__name__),file=sys.stderr)
  raise SystemExit(1)
