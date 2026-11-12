#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Cross-check the W0.4 contract fixtures; no app imports or recordings."""
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]
LANGS={'it','fr','es','pt-BR','pt-PT'}

def read(path):return json.loads((ROOT/path).read_text())

def badge(fields,catalog):
    def output(kind,key,tint,glyph,args=None):
        text=catalog['states.badge.'+key]['en']
        for name,value in (args or {}).items():text=text.replace('{'+name+'}',str(value))
        return dict(kind=kind,text=text,tint=tint,glyph=glyph)
    if fields['lifecycle']=='recording':
        seconds=max(0,fields.get('liveMs',fields.get('durationMs',0)))//1000
        hours,rest=divmod(seconds,3600);minutes,seconds=divmod(rest,60)
        timer=f'{hours}:{minutes:02}:{seconds:02}' if hours else f'{minutes}:{seconds:02}'
        return output('recording','recording','red','dot',dict(liveBadge=timer))
    if fields['lifecycle']=='saving':return output('saving','saving','neutral','spinner')
    if fields['transcript'] in ('queued','running'):
        eta=fields.get('etaMinutes')
        key='transcribing.noEta' if type(eta) is not int or eta<0 else 'transcribing.underMinute' if eta==0 else 'transcribing'
        return output('transcribing',key,'neutral','spinner',dict(n=eta))
    if fields.get('error') is not None and fields['error'].get('action') is not None:
        return output('needsAttention','needsAttention','amber','alert')
    if fields.get('interruptedAtMs') is not None:return output('interrupted','interrupted','amber','alert')
    if fields['origin']=='received':return output('received','received','outline','incoming')
    return None

def verify():
    states=read('vectors/states/states-vectors.json')
    catalog={e['id']:e for e in read('strings/strings.json')['entries']}
    assert states['version']==3
    assert states['precedence']==['recording','saving','transcribing','needsAttention','interrupted','received','none']
    assert len({v['id'] for v in states['vectors']})==len(states['vectors'])
    assert {'recording-beats-error','interrupted-and-transcribing','received-being-written-down-once','transcribing-under-minute','transcribing-without-eta'} <= {v['id'] for v in states['vectors']}
    for vector in states['vectors']:
        assert badge(vector['fields'],catalog)==vector['badge'],vector['id']
        if 'canWriteDown' in vector:
            f=vector['fields'];expected=f['lifecycle']=='saved' and f['transcript'] in ('none','failed')
            assert vector['canWriteDown']==expected,vector['id']
    assert len(states['entryVectors'])==1
    entry=states['entryVectors'][0]
    assert entry['scope']=='import-entry' and entry['fields']=={'importing':True}
    assert entry['badge']==dict(kind='importing',text=catalog['states.badge.importing']['en'],tint='neutral',glyph='spinner')
    expected={'recording':'Recording {liveBadge}','importing':'Importing…','saving':'Saving…','transcribing':'Transcribing · {n} min','needsAttention':'Needs attention','interrupted':'Interrupted','received':'Received','transcribing.noEta':'Transcribing…','transcribing.underMinute':'Transcribing, less than a minute left'}
    for key,text in expected.items():
        e=catalog['states.badge.'+key];assert e['en']==text,key
        placeholders=set(re.findall(r'\{\w+\}',text))
        assert set(e['l10n'])==LANGS,key
        for lang,translation in e['l10n'].items():
            assert translation['text'] and set(re.findall(r'\{\w+\}',translation['text']))==placeholders,(key,lang)
            if 'plural' in e:
                assert {'one','other'} <= set(translation.get('plural',{})),(key,lang)
            for category,form in translation.get('plural',{}).items():
                assert set(re.findall(r'\{\w+\}',form))<=placeholders,(key,lang)
                if category!='one' and '{n}' in placeholders:assert '{n}' in form,(key,lang,category)
        if key.startswith('transcribing.'):
            assert 'PROVISIONAL, pending Alex' in e['note'],key
    assert catalog['states.badge.transcribing']['plural']=={'one':'Transcribing · 1 min','other':'Transcribing · {n} min'}
    assert catalog['meeting.interruptedAt']['en']=='Interrupted at {position}'
    for vector in read('vectors/format/format-vectors.json')['eta']:
        fields=dict(lifecycle='saved',transcript='running',etaMinutes=vector['minutes'],origin='own')
        assert badge(fields,catalog)['text']==vector['out'],vector
    rows=0
    for path in (ROOT/'vectors/library-vectors/expected').glob('*.json'):
        for group in json.loads(path.read_text())['groups']:
            for meeting in group['meetings']:
                result=badge(meeting,catalog)
                assert meeting['badge']==(result['text'] if result else None),(path.name,meeting['id'])
                rows+=1
    print(f'W0.4: {len(states["vectors"])} meeting vectors, 1 import entry, {rows} Library rows and five translation languages pass')

if __name__=='__main__':verify()
