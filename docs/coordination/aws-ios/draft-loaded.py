import fcntl, glob, json, os, pathlib, re, subprocess, sys, time
root=pathlib.Path.cwd(); label=sys.argv[1]
out=pathlib.Path.home()/'coordination/evidence/aws-ios-d88-draft'/label
out.mkdir(parents=True,exist_ok=True)
name='ts-cassini-ios-d88-draft-iphone-1'
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j']))
udid=next((d['udid'] for ds in devices['devices'].values() for d in ds if d['name']==name),None)
if not udid:
    udid=subprocess.check_output(['xcrun','simctl','create',name,'iPhone 17','com.apple.CoreSimulator.SimRuntime.iOS-27-0'],text=True).strip()
# The normal test script's worktree lease, so other heavy runs leave this clone alone.
lease=root.parent/'.test-cache/sim-leases'/udid
lease.parent.mkdir(parents=True,exist_ok=True);lease.touch()
plan=glob.glob(str(root/'DerivedData.noindex/Build/Products/*.only-CassiniUITests.xctestrun'))[0]
lock=pathlib.Path.home()/'.aws-heavy.lock'
try: lock.mkdir()
except FileExistsError: sys.exit('AWS heavy lock busy; no hogs started')
native=open(pathlib.Path.home()/'.cassini-heavy.lock','a+')
try: fcntl.flock(native, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    native.close(); lock.rmdir(); sys.exit('Another native gate is active; no hogs started')
commands=subprocess.check_output(['ps','-axo','command='],text=True).splitlines()
if any(re.match(r'^\S*(?:/swift-test|/swift)\s+(?:test|--)', c) or re.match(r'^(?:/\S*/)?(?:bash|zsh|sh) scripts/test[.]sh fast(?: |$)',c) for c in commands):
    native.close(); lock.rmdir(); sys.exit('A package gate is active; no hogs started')
hogs=[]; rows=[]
try:
    for _ in range(6): hogs.append(subprocess.Popen(['yes'],stdout=subprocess.DEVNULL))
    for i in range(3):
        if i==0: subprocess.run(['xcrun','simctl','shutdown',udid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)
        subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],stdout=subprocess.DEVNULL,check=True,timeout=300)
        lease.touch();start=time.monotonic()
        cmd=['xcodebuild','test-without-building','-xctestrun',plan,'-destination','platform=iOS Simulator,id='+udid,'-parallel-testing-enabled','NO','-only-testing:CassiniUITests/NoteScreenTests/testTheDraftFollowsItsEndBelowTheFixedCard','-only-testing:CassiniUITests/ScreenshotTests/test03Transcribing','-collect-test-diagnostics','never','-resultBundlePath',str(out/f'run-{i+1}.xcresult')]
        log=out/f'run-{i+1}.log'
        with log.open('w') as f:
            p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=600,env=dict(os.environ,TEST_RUNNER_CASSINI_SCREENSHOTS='1'))
        passed=re.findall(r"Test Case .* passed \(",log.read_text())
        row=dict(run=i+1,fresh_boot=i==0,exit=p.returncode,passed=len(passed),seconds=round(time.monotonic()-start,2),load=os.getloadavg())
        rows.append(row);(out/'summary.json').write_text(json.dumps(rows,indent=2)+'\n');print(row,flush=True)
finally:
    for p in hogs:p.terminate()
    for p in hogs:p.wait()
    native.close()
    lock.rmdir()
    subprocess.run(['xcrun','simctl','shutdown',udid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)
