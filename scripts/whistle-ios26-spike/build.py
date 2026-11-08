#!/usr/bin/env python3
"""Strict SDK26 device/simulator link. Keep every deployment warning; never edit Mach-O load commands."""
import argparse, hashlib, json, pathlib, plistlib, re, shutil, subprocess
ENGINE_REV='93e88ede867e4311c39151285e74df513e4b835b'
PINS={'ios-arm64':'e1dd5a4c59dc78aea54bcef91f4ba751ee30382adb92b8831ed2832833d76837','ios-sim-arm64':'adc37ff4a88a928e581f670b4323e7f49f6d6886e37f832b015fea0885c5e177'}
EXPORTS=['needle_load','needle_models','needle_last_error','needle_transcribe','needle_reset']
def run(cmd,log):
 p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 with log.open('a') as f:f.write('$ '+repr(cmd)+'\n'+p.stdout+'\n')
 if p.returncode:raise RuntimeError(f'failed ({p.returncode}); see {log}')
 return p.stdout

def audit(binary,sdk,log):
 # Strict linking resolves the right target/architecture; this additionally records a SDK26 stub for every import.
 imports=run(['nm','-uj',str(binary)],log).splitlines(); index={}
 for stub in sdk.rglob('*.tbd'):
  text=stub.read_text(errors='replace')
  for token in set(re.findall(r'[A-Za-z_$][A-Za-z0-9_$.]*',text)):
   index.setdefault(token,[]).append(str(stub.relative_to(sdk)))
 result={};missing=[]
 for symbol in imports:
  lookup=symbol
  for prefix in ['_OBJC_CLASS_$_','_OBJC_METACLASS_$_','_OBJC_EHTYPE_$_']:
   if symbol.startswith(prefix):lookup=symbol[len(prefix):]
  paths=index.get(lookup,[])
  if not paths:missing.append(symbol)
  result[symbol]=paths
 return {'imports':result,'missing':missing}

def main():
 p=argparse.ArgumentParser();p.add_argument('--xcode26',type=pathlib.Path,required=True);p.add_argument('--artifacts',type=pathlib.Path,required=True);p.add_argument('--fixtures',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parent;out=a.output;out.mkdir(parents=True,exist_ok=True)
 dev=a.xcode26/'Contents/Developer';compiler=dev/'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++';report={}
 for kind,platform,target in [('ios-arm64','iPhoneOS','arm64-apple-ios26.0'),('ios-sim-arm64','iPhoneSimulator','arm64-apple-ios26.0-simulator')]:
  archive=a.artifacts/kind/'libneedle.a';assert hashlib.sha256(archive.read_bytes()).hexdigest()==PINS[kind]
  sdk=next(x for x in (dev/'Platforms'/f'{platform}.platform/Developer/SDKs').iterdir() if x.name.startswith(platform+'26.0') and x.name.endswith('.sdk'))
  directory=out/kind;directory.mkdir(exist_ok=True);log=directory/'link-and-imports.log'
  app=directory/'WhistleProbe.app';framework=app/'Frameworks/WhistleProbeRuntime.framework';framework.mkdir(parents=True,exist_ok=True)
  exports=directory/'exports.txt';exports.write_text(''.join('_'+x+'\n' for x in EXPORTS))
  options=['-target',target,'-isysroot',str(sdk),'-std=c++17','-Wl,-undefined,error','-Wl,-no_weak_imports']
  library=framework/'WhistleProbeRuntime'
  run([str(compiler),*options,'-dynamiclib','-Wl,-force_load,'+str(archive),'-Wl,-exported_symbols_list,'+str(exports),'-install_name','@rpath/WhistleProbeRuntime.framework/WhistleProbeRuntime','-lc++','-o',str(library)],log)
  executable=app/'WhistleProbe'
  run([str(compiler),*options,'-fobjc-arc',str(root/'driver.mm'),'-framework','Foundation','-framework','UIKit','-lc++','-o',str(executable)],log)
  frameworkInfo={'CFBundleExecutable':'WhistleProbeRuntime','CFBundleIdentifier':'io.codemyriad.cassini.whistlespike.runtime','CFBundlePackageType':'FMWK','CFBundleVersion':'1','CFBundleShortVersionString':'3.3.0','MinimumOSVersion':'26.0'}
  appInfo={'CFBundleExecutable':'WhistleProbe','CFBundleIdentifier':'io.codemyriad.cassini.whistlespike','CFBundlePackageType':'APPL','CFBundleName':'Whistle compatibility probe','CFBundleVersion':'1','CFBundleShortVersionString':'0.0.1','MinimumOSVersion':'26.0','UIDeviceFamily':[1,2],'UILaunchScreen':{}}
  for path,info in [(framework/'Info.plist',frameworkInfo),(app/'Info.plist',appInfo)]:path.write_bytes(plistlib.dumps(info))
  for filename in ['whistle.cact','manifest.json']+[x['file'] for x in json.loads((a.fixtures/'manifest.json').read_text())['fixtures']]:shutil.copyfile(a.fixtures/filename,app/filename)
  checks={}
  for binary in [library,executable]:
   checks[binary.name]=audit(binary,sdk,log)
   assert not checks[binary.name]['missing'],checks[binary.name]['missing']
  buildCommands={binary.name:run(['xcrun','vtool','-show-build',str(binary)],log) for binary in [library,executable]}
  for binary in [library,executable]:run(['otool','-L',str(binary)],log)
  if kind=='ios-sim-arm64':
   for path in [framework,app]:run(['codesign','--force','--sign','-','--timestamp=none',str(path)],log)
  assert hashlib.sha256(archive.read_bytes()).hexdigest()==PINS[kind], 'original archive changed'
  report[kind]={'sourceArchiveSha256':PINS[kind],'sourceRevision':ENGINE_REV,'sdk':str(sdk),'target':target,'buildVersion':buildCommands,'symbolChecks':checks,'app':str(app),'deviceExecution':'not performed' if kind=='ios-arm64' else 'separate simulator run required'}
 (out/'build-report.json').write_text(json.dumps(report,indent=2)+'\n')
 print('Strict SDK26 links and complete imported-symbol audits passed for both targets.')
if __name__=='__main__':main()
