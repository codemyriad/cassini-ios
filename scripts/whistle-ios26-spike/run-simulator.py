#!/usr/bin/env python3
"""Run only on an explicitly available iOS26 simulator, with an owned disposable device and no audio I/O."""
import argparse,json,pathlib,subprocess,time
BUNDLE='io.codemyriad.cassini.whistlespike'
def main():
 p=argparse.ArgumentParser();p.add_argument('--build',type=pathlib.Path,required=True);p.add_argument('--fixtures',type=pathlib.Path,required=True);a=p.parse_args()
 runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j']))['runtimes']
 runtime=next(x for x in runtimes if x['isAvailable'] and x['version']=='26.0')
 app=a.build/'ios-sim-arm64/WhistleProbe.app'
 name='cassini-whistle-ios26-spike'
 device=subprocess.check_output(['xcrun','simctl','create',name,'com.apple.CoreSimulator.SimDeviceType.iPad-9th-generation',runtime['identifier']],text=True).strip()
 try:
  subprocess.run(['xcrun','simctl','boot',device],check=True)
  subprocess.run(['xcrun','simctl','bootstatus',device,'-b'],check=True,timeout=300)
  subprocess.run(['xcrun','simctl','install',device,str(app)],check=True)
  container=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,BUNDLE,'data'],text=True).strip())
  path=container/'Documents/report.json'
  subprocess.run(['xcrun','simctl','launch','--terminate-running-process',device,BUNDLE],check=True)
  deadline=time.monotonic()+600
  while not path.exists():
   if time.monotonic()>=deadline:raise TimeoutError('native probe did not publish its result')
   # Event/condition polling with an upper bound, not a fixed completion sleep.
   time.sleep(.2)
  actual=json.loads(path.read_text());(a.build/'simulator-result.json').write_text(json.dumps(actual,indent=2)+'\n')
  assert 'error' not in actual,actual
  assert '26.0' in actual['osVersion'],actual['osVersion']
  expected=json.loads((a.fixtures/'manifest.json').read_text())['fixtures'];assert len(actual['results'])==len(expected)
  differences=[]
  for gold,got in zip(expected,actual['results']):
   assert got['file']==gold['file'] and got['inputSha256']==gold['inputSha256']
   mac=gold['macResult'];ios=got['result']
   # No punctuation/case folding or unapproved cross-platform text tolerance.
   for key in ['text','language']:
    if ios.get(key)!=mac.get(key):differences.append({'file':gold['file'],'field':key,'mac':mac.get(key),'ios':ios.get(key)})
   left=mac.get('words',[]);right=ios.get('words',[])
   if len(left)!=len(right):differences.append({'file':gold['file'],'field':'wordCount','mac':len(left),'ios':len(right)});continue
   for i,(l,r) in enumerate(zip(left,right)):
    if l['word']!=r['word']:differences.append({'file':gold['file'],'word':i,'mac':l['word'],'ios':r['word']})
    for key in ['start','end']:
     if abs(l[key]-r[key])>.080001:differences.append({'file':gold['file'],'word':i,'field':key,'mac':l[key],'ios':r[key]})
  comparison={'runtimeVersion':runtime['version'],'runtimeBuild':runtime['buildversion'],'deviceType':'iPad 9th generation simulator; not a 3GB iPad8 device','fixtures':len(expected),'differences':differences,'scope':'Native recognizer on identical committed DC segment inputs; iOS VAD and real-device/3GB memory gates remain separate'}
  (a.build/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
  assert not differences, 'native text/timing differs; see comparison.json'
  print('Native iOS26 simulator probe matches the frozen pinned Mac engine on every supplied input.')
 finally:
  subprocess.run(['xcrun','simctl','shutdown',device],check=False)
  subprocess.run(['xcrun','simctl','delete',device],check=False)
if __name__=='__main__':main()
