#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Audit the export tree and every Git object; never print matched values."""
import argparse, hashlib, ipaddress, json, pathlib, re, shutil, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
IGNORED={'.git','.build','dist','node_modules','__pycache__','test-results','playwright-report'}
PATTERNS={
 'uuid':r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b',
 'ipv4':r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
 'url':r'https?://[^\s\x27\x22<>`]+',
 'credential_literal':r'(?i)(?:token|password|uuid|public_key|private_key)\s*[:=]\s*[\x27\x22][^\x27\x22\n]+[\x27\x22]',
 'private_key':r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
 'private_path':r'(?:/home/[^\s\x27\x22`]+|snapshots/[^\s\x27\x22`]+|/root/[^\s\x27\x22`]+|/work/[^\s\x27\x22`]+)',
 'hostname_literal':r'(?i)[\x27\x22]((?:[a-z0-9-]+\.)+(?:invalid|example|com|org|net|ru|io|info|ai))[\x27\x22]',
}
def candidates():
 return sorted(p for p in ROOT.rglob('*') if p.is_file() and not any(part in IGNORED for part in p.relative_to(ROOT).parts))
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
def main():
 p=argparse.ArgumentParser();p.add_argument('--gitleaks',required=True);p.add_argument('--history',action='store_true');p.add_argument('--require-no-remotes',action='store_true');p.add_argument('--output',default='.build/audit.json');a=p.parse_args()
 executable=str(pathlib.Path(a.gitleaks).resolve());files=candidates();findings=[];errors=[]
 for path in files:
  if path.is_symlink():errors.append('unexpected symlink: '+str(path.relative_to(ROOT)))
  blob=path.read_bytes()
  try:blob.decode('utf-8')
  except UnicodeDecodeError:errors.append('unexpected binary: '+str(path.relative_to(ROOT)))
  findings+=scan(blob,str(path.relative_to(ROOT)))
  findings+=scan(str(path.relative_to(ROOT)).encode(),'<filename>:'+str(path.relative_to(ROOT)))
 allow=json.loads((ROOT/'tools/audit-allowlist.json').read_text())
 accepted={key(f) for f in allow}
 unreviewed=[f for f in findings if key(f) not in accepted]
 with tempfile.TemporaryDirectory(prefix='toolkit-audit-') as tmp:
  tmp=pathlib.Path(tmp);tree=tmp/'export';tree.mkdir()
  for path in files:
   relative=path.relative_to(ROOT);target=tree/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
  report=tmp/'gitleaks.json'
  result=subprocess.run([executable,'dir',str(tree),'--redact','--no-banner','--report-format','json','--report-path',str(report)],capture_output=True,text=True)
  leaks=json.loads(report.read_text()) if report.exists() else []
  if result.returncode!=0:errors.append('gitleaks tree failure: '+str(result.returncode))
  git_leaks=[];objects=0
  if a.history:
   result=subprocess.run([executable,'git',str(ROOT),'--log-opts=--all','--redact','--no-banner','--report-format','json','--report-path',str(report)],capture_output=True,text=True)
   git_leaks=json.loads(report.read_text()) if report.exists() else []
   if result.returncode!=0:errors.append('gitleaks history failure: '+str(result.returncode))
   inventory=subprocess.check_output(['git','cat-file','--batch-all-objects','--batch-check=%(objectname) %(objecttype)'],cwd=ROOT,text=True)
   # Audit reachable AND unreachable objects, independently of gitleaks' log traversal.
   for line in inventory.splitlines():
    oid,kind=line.split();objects+=1
    if kind not in ('blob','commit','tag'):continue
    data=subprocess.check_output(['git','cat-file',kind,oid],cwd=ROOT)
    if kind=='blob':
     # Every blob must exactly equal a reviewed exported file, otherwise refuse.
     if not any(data==path.read_bytes() for path in files):errors.append('unreviewed Git blob '+oid)
    elif scan(data,'git-'+kind):errors.append('sensitive-pattern Git metadata '+oid)
   subprocess.run(['git','fsck','--full','--no-reflogs'],cwd=ROOT,check=True,capture_output=True)
   if a.require_no_remotes and subprocess.check_output(['git','remote'],cwd=ROOT,text=True).strip():errors.append('unexpected remote')
 report_data={'files_scanned':len(files),'git_objects_scanned':objects,'pattern_findings':findings,'unreviewed':unreviewed,'gitleaks_tree_count':len(leaks),'gitleaks_history_count':len(git_leaks),'errors':errors,'ok':not errors and not unreviewed}
 output=ROOT/a.output;output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report_data,indent=2)+'\n')
 print(json.dumps({k:v for k,v in report_data.items() if k!='pattern_findings'},indent=2))
 raise SystemExit(0 if report_data['ok'] else 1)
if __name__=='__main__':main()
