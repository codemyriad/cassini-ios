import argparse, fcntl, json, os, pathlib, re, signal, subprocess, sys, time
p=argparse.ArgumentParser();p.add_argument('area');p.add_argument('label');p.add_argument('filter');a=p.parse_args()
assert re.fullmatch('[a-z0-9-]+',a.area) and re.fullmatch('[a-z0-9-]+',a.label)
lock=pathlib.Path.home()/'.aws-heavy.lock'
try:lock.mkdir()
except FileExistsError:sys.exit('AWS lock busy; no hogs started')
native=None;hogs=[];child=None

def interrupted(signum,frame):raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupted)

def foreign_gates():
    rows=[]
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines():
        fields=line.strip().split(None,2)
        if len(fields)==3:rows.append((int(fields[0]),int(fields[1]),fields[2]))
    owned={os.getpid()}
    while True:
        more={pid for pid,parent,_ in rows if parent in owned}
        if more<=owned:break
        owned|=more
    return [pid for pid,_,cmd in rows if pid not in owned and (
        re.match(r'^\S*/(?:swift-test|swift-build|xcodebuild)(?:\s|$)',cmd)
        or re.match(r'^\S*/swift\s+(?:test|build)(?:\s|$)',cmd)
        or re.match(r'^(?:/\S*/)?(?:bash|zsh|sh) \S*scripts/test[.]sh fast(?:\s|$)',cmd))]

def stop_child():
    global child
    if child is not None and child.poll() is None:
        try:os.killpg(child.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        try:child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL);child.wait()
    child=None

try:
    native=open(pathlib.Path.home()/'.cassini-heavy.lock','a+')
    try:fcntl.flock(native,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:sys.exit('Native gate busy; no hogs started')
    gates=foreign_gates()
    if gates:sys.exit('Other gate active; no hogs started: '+str(gates))
    out=pathlib.Path.home()/f'coordination/evidence/aws-ios-d88-{a.area}'/a.label
    out.mkdir(parents=True,exist_ok=True)
    head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    summary=out/'summary.json'
    rows=json.loads(summary.read_text()) if summary.exists() else []
    assert len(rows)<=3 and all(r['head']==head and r['exit']==0 and r['hogs']==6 for r in rows)
    if len(rows)==3:sys.exit('All three runs already completed; no hogs started')
    for _ in range(6):hogs.append(subprocess.Popen(['yes'],stdout=subprocess.DEVNULL))
    for i in range(len(rows),3):
        began=time.monotonic()
        target=out/f'run-{i+1}.log'
        if target.exists():target.rename(out/f'run-{i+1}.interrupted-{time.time_ns()}.log')
        with target.open('w') as log:
            child=subprocess.Popen(['swift','test','--skip-build','--filter',a.filter],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            while child.poll() is None:
                gates=foreign_gates()
                if gates:sys.exit('Another gate started; ending owned hogs and test: '+str(gates))
                if time.monotonic()-began>300:sys.exit('Test hung; ending owned processes')
                time.sleep(0.25)
            rc=child.returncode;child=None
        row=dict(run=i+1,head=head,exit=rc,hogs=6,aws_lock=True,native_lock=True,seconds=round(time.monotonic()-began,3),load=os.getloadavg())
        rows.append(row);(out/'summary.json').write_text(json.dumps(rows,indent=2)+'\n');print(row,flush=True)
        if rc:sys.exit('Test failed; stopping evidence batch')
finally:
    for h in hogs:
        if h.poll() is None:h.terminate()
    for h in hogs:h.wait()
    stop_child()
    if native is not None:native.close()
    lock.rmdir()
