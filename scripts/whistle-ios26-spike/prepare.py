#!/usr/bin/env python3
"""Generate public DC segment inputs and frozen Mac C-API outputs; run under the host heavy lock."""
import argparse, array, ctypes, hashlib, json, os, pathlib, shutil, struct, subprocess, wave

MODEL_SHA = 'b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb'
MAC_ARM_SHA = '99b9bd363d2e247626118e7ade04a3dc70c60ebe6bbb0e1bca50bc0bce24b0d3'
SEGMENTS = [(105984,189440),(347648,367616),(371200,413184),(416256,458240),(504320,544256),(547328,589312)]
DC = {
 'dc-quiet-jfk-v1': ('071f051241d394587c85463272e9414f133ee18c4bb835d1382b662e4154efda','eeaeee543bc328acf6f0c4557e8aba86652e0144d9763264e1e5d62a3d13f968'),
 'dc-quiet-jfk-v1-control': ('e31ed958621a39baf1d33dab6d10798695b8319e78fcaa1cb672cdb43c5f7830','6ece4c5cacfc2456cb79d0aa1b16f4aa3912fef6697912e633886d7b0da545ab'),
}
def sha(data): return hashlib.sha256(data).hexdigest()
def wav(path, rate):
 with wave.open(str(path)) as f:
  assert (f.getnchannels(),f.getsampwidth(),f.getframerate()) == (1,2,rate)
  data=array.array('h',f.readframes(f.getnframes()))
 return array.array('f',(x/32768 for x in data))
def filtered_hash(samples):
 x1=x2=y1=y2=0.; data=bytearray()
 for x in samples:
  y=0.9726138984998437*x
  y+=-1.9452277969996874*x1; y+=0.9726138984998437*x2
  y-=-1.9444776577670935*y1; y-=0.9459779362322813*y2
  if -1e-25<y<1e-25:y=0.
  x2,x1,y2,y1=x1,x,y1,y; data.extend(struct.pack('<f',y))
 return sha(data)
def main():
 p=argparse.ArgumentParser();p.add_argument('--coord',type=pathlib.Path,required=True);p.add_argument('--mac',type=pathlib.Path,required=True);p.add_argument('--assets',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 out=a.output;out.mkdir(parents=True,exist_ok=True)
 model=(a.assets/'whistle.cact').read_bytes();assert sha(model)==MODEL_SHA
 shutil.copyfile(a.assets/'whistle.cact',out/'whistle.cact')
 library=out/'mac-needle-arm64.dylib'
 subprocess.run(['xcrun','lipo',str(a.assets/'libneedle3.dylib'),'-thin','arm64','-output',str(library)],check=True)
 assert sha(library.read_bytes())==MAC_ARM_SHA,'Mac baseline must be the exact D5 engine slice'
 for key,value in [('NEEDLE_TELEMETRY','0'),('DO_NOT_TRACK','1'),('ORT_DISABLE_TELEMETRY','1')]:os.environ[key]=value
 engine=ctypes.CDLL(str(library),mode=os.RTLD_NOW|os.RTLD_LOCAL)
 engine.needle_load.argtypes=[ctypes.c_void_p,ctypes.c_ulonglong];engine.needle_load.restype=ctypes.c_int
 engine.needle_transcribe.argtypes=[ctypes.POINTER(ctypes.c_float),ctypes.c_int,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_int]
 engine.needle_last_error.restype=ctypes.c_char_p
 weights=ctypes.create_string_buffer(model);assert engine.needle_load(weights,len(model))>=0,engine.needle_last_error()
 # Compile the exact reviewed Mac #167 FIR implementation; keep its source identity in the manifest.
 source=a.mac/'Sources/CassiniVAD/fir.c';firlib=out/'fir.dylib'
 subprocess.run(['xcrun','clang','-dynamiclib','-O2','-ffp-contract=off','-I',str(a.mac/'Sources/CassiniVAD/include'),str(source),'-o',str(firlib)],check=True)
 fir=ctypes.CDLL(str(firlib));fir.cassini_fir_48k_16k.argtypes=[ctypes.POINTER(ctypes.c_float),ctypes.POINTER(ctypes.c_float),ctypes.c_int64,ctypes.c_int64,ctypes.c_int64,ctypes.POINTER(ctypes.c_float),ctypes.c_size_t]
 coefficients=json.loads((a.coord/'ux-draft/whistle/fir-48k-16k.json').read_text())['coefficients']
 taps=(ctypes.c_float*len(coefficients))(*coefficients); fixtures=[]
 def add(name,pcm,meta):
  data=pcm.tobytes();filename=name+'.f32';(out/filename).write_bytes(data)
  samples=(ctypes.c_float*len(pcm)).from_buffer(pcm);result=ctypes.create_string_buffer(1048576)
  count=engine.needle_transcribe(samples,len(pcm),None,None,1,result,len(result));assert count>=0,engine.needle_last_error()
  decoded=json.loads(result.value);fixtures.append(dict(file=filename,inputSha256=sha(data),samples=len(pcm),macResult=decoded,**meta))
 add('jfk',wav(a.coord/'ux-draft/whistle/jfk.wav',16000),{'source':'D5 public JFK 16 kHz smoke fixture'})
 for name,(wavsha,vadsha) in DC.items():
  path=a.coord/'ux-draft/dc'/f'{name}.wav';assert sha(path.read_bytes())==wavsha
  pcm=wav(path,48000);inputs=(ctypes.c_float*len(pcm)).from_buffer(pcm);n=(len(pcm)+2)//3
  result=(ctypes.c_float*n)();fir.cassini_fir_48k_16k(taps,inputs,0,len(pcm),0,result,n)
  raw=array.array('f',result);assert filtered_hash(raw[:len(raw)//512*512])==vadsha
  for i,(start,end) in enumerate(SEGMENTS):
   add(f'{name}-{i}',raw[start:end],{'sourceWavSha256':wavsha,'startSample':start,'endSample':end,'segmentOrigin':'reviewed desktop D26.1 boundaries; this engine probe does not execute iOS VAD'})
 manifest={'modelSha256':MODEL_SHA,'macEngineSha256':MAC_ARM_SHA,'firSourceSha256':sha(source.read_bytes()),'fixtures':fixtures,'scope':'Strict native engine compatibility on identical public DC segment PCM; not an iOS VAD or 3 GB device acceptance test'}
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print('Generated',len(fixtures),'native-engine fixtures; raw PCM and VAD-branch hashes verified.')
if __name__=='__main__':main()
