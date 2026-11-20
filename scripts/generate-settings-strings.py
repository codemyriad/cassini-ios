#!/usr/bin/env python3
"""Compile the pinned shared Phase 2 settings strings into native localization assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
STRINGS_PIN = Path('contracts/shared-strings/UPSTREAM.json')
SOURCE = Path('Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges/strings/strings.json')
OUTPUT = Path('Cassini/Resources/Strings/SettingsPhase2.xcstrings')
LOOKUP = Path('Cassini/Strings/SettingsPhase2Copy.swift')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
PROPERTIES = {'settings.phone.group.transcripts': 'transcripts',
 'settings.phone.group.meetings': 'meetings',
 'settings.phone.group.app': 'app',
 'settings.tab.transcription': 'transcription',
 'common.speakers': 'speakers',
 'common.savedVoices': 'savedVoices',
 'models.status.on': 'on',
 'settings.answer.off': 'off',
 'savedVoices.peopleCount': 'peopleCount',
 'settings.phone.backup': 'backup',
 'settings.phone.backup.answer.icloud': 'icloud',
 'settings.phone.trash.ios': 'trash',
 'library.meetingCount': 'meetingCount',
 'settings.phone.audioHours': 'audioHours',
 'settings.phone.libraryStats': 'libraryStats',
 'settings.phone.language': 'language',
 'about.nameVersion': 'nameVersion',
 'settings.phone.aboutRow.subtitle': 'aboutSubtitle',
 'settings.phone.transcription.forNew': 'forNew',
 'models.whistle.name': 'whistle',
 'models.whistle.description.short': 'whistleDescription',
 'models.parakeetUltra.name': 'parakeet',
 'models.parakeetUltra.description.short': 'parakeetDescription',
 'models.builtIn': 'builtIn',
 'models.download': 'download',
 'models.keepTranscript': 'keepTranscript',
 'settings.phone.transcription.afterRecording': 'afterRecording',
 'settings.phone.transcription.rightAway': 'rightAway',
 'settings.phone.transcription.rightAway.subtitle': 'rightAwaySubtitle',
 'settings.phone.transcription.goingOnline': 'goingOnline',
 'models.whereFrom': 'whereFrom',
 'settings.phone.transcription.online': 'online',
 'settings.phone.speakers.whoIsSpeaking': 'whoIsSpeaking',
 'models.tellSpeakersApart.name': 'tellApart',
 'models.tellSpeakersApart.description.short': 'tellApartDescription',
 'models.recogniseVoices.name': 'recognise',
 'settings.phone.speakers.recognise.subtitle': 'recogniseDescription',
 'settings.phone.speakers.runsOnDevice.iphone': 'runsOnIphone',
 'settings.phone.speakers.runsOnDevice.ipad': 'runsOnIpad',
 'settings.phone.speakers.autoName': 'autoName',
 'settings.phone.speakers.autoName.subtitle': 'autoNameSubtitle',
 'about.title': 'about',
 'about.version': 'version',
 'about.tagline.iphone': 'taglineIphone',
 'about.tagline.ipad': 'taglineIpad',
 'about.help': 'help',
 'about.help.subtitle': 'helpSubtitle',
 'about.reportProblem': 'reportProblem',
 'about.reportProblem.subtitle': 'reportProblemSubtitle',
 'about.privacy': 'privacy',
 'about.privacy.subtitle.iphone': 'privacyIphone',
 'about.privacy.subtitle.ipad': 'privacyIpad',
 'about.licencesNotices': 'licences',
 'about.licencesNotices.subtitle': 'licencesSubtitle',
 'about.sourceCode': 'sourceCode',
 'about.licenceLine.phone': 'licenceLine',
 'backup.meetings.switch': 'backupMeetings',
 'backup.meetings.switch.subtitle': 'backupMeetingsSubtitle',
 'backup.savedVoices.switch': 'backupVoices',
 'backup.savedVoices.switch.description.iphone': 'backupVoicesDescriptionIphone',
 'backup.savedVoices.switch.description.ipad': 'backupVoicesDescriptionIpad',
 'settings.moreDetail': 'moreDetail',
 'backup.moreDetail.row': 'backupMoreDetailRow',
 'backup.ownCopy.heading': 'ownCopy',
 'backup.ownCopy.zip.subtitle': 'zipSubtitle',
 'backup.info.included.heading': 'backupIncludedHeading',
 'backup.info.included.iosLead': 'backupIncludedLead',
 'backup.info.row.meetings': 'backupRowMeetings',
 'backup.info.row.meetings.detail': 'backupRowMeetingsDetail',
 'backup.info.row.settings': 'backupRowSettings',
 'backup.info.row.settings.detail': 'backupRowSettingsDetail',
 'backup.info.row.savedVoices.choice': 'backupRowVoicesDetail',
 'backup.info.row.models': 'backupRowModels',
 'backup.info.row.models.detail.iphone': 'backupRowModelsDetail',
 'backup.info.status.included': 'backupIncluded',
 'backup.info.status.notIncluded': 'backupExcluded',
 'backup.notice.title': 'backupNoticeTitle',
 'backup.notice.body.iphone': 'backupNoticeBodyIphone',
 'backup.notice.body.ipad': 'backupNoticeBodyIpad',
 'backup.notice.keep': 'backupNoticeKeep',
 'backup.notice.leaveOut': 'backupNoticeLeaveOut',
 'backup.info.who.heading': 'backupWho',
 'backup.info.who.icloud.detail': 'backupWhoIcloud',
 'backup.info.who.computer': 'backupWhoComputer',
 'backup.info.who.computer.detail': 'backupWhoComputerDetail',
 'backup.info.who.zip': 'backupWhoZip',
 'backup.info.who.zip.detail': 'backupWhoZipDetail',
 'backup.info.cassiniNever': 'backupCassiniNever',
 'firstRun.howTo.phone': 'firstRunHowTo',
 'voices.setup.title': 'voicesTitle',
 'voices.setup.body.phone': 'voicesBody',
 'voices.setup.privacy.phone': 'voicesPrivacy',
 'voices.setup.enable.phone': 'voicesEnable',
 'common.notNow': 'notNow',
 'voices.setup.kindness': 'voicesKindness',
 'voices.setup.changeLater.phone': 'voicesChangeLater',
 'voices.rememberDefault.title': 'rememberDefault',
 'voices.rememberDefault.subtitle': 'rememberDefaultSubtitle',
 'models.offer.title.iphone': 'offerTitleIphone',
 'models.offer.title.ipad': 'offerTitleIpad',
 'models.offer.body.iphone': 'offerBodyIphone',
 'models.offer.body.ipad': 'offerBodyIpad',
 'models.offer.part.speech': 'offerSpeech',
 'models.offer.part.tellApart': 'offerTellApart',
 'models.offer.part.recognise': 'offerRecognise',
 'models.offer.spaceNeeded': 'offerSpace',
 'models.offer.whereFrom.link': 'whereFromLink',
 'models.offer.download': 'offerDownload',
 'models.offer.notNow': 'offerNotNow',
 'savedVoices.row.options.a11y': 'voiceOptions',
 'savedVoices.row.rename': 'voiceRename',
 'savedVoices.row.forgetEllipsis': 'voiceForget',
 'savedVoices.howToAdd.short': 'voicesHowToAdd',
 'savedVoices.forgetEveryone': 'forgetEveryone',
 'savedVoices.privacy.phone': 'savedVoicesPrivacy',
 'trash.phone.intro': 'trashIntro',

}
PLURALS = {"savedVoices.peopleCount", "library.meetingCount", "settings.phone.audioHours"}

IDS = set(PROPERTIES)


def outputs(root=ROOT):
    pin_path = root / STRINGS_PIN
    pin = json.loads(pin_path.read_text())
    if (pin.get('repository') != 'https://github.com/codemyriad/cassini-ux'
            or not re.fullmatch(r'[a-f0-9]{40}', pin.get('commit', ''))
            or pin.get('path') != 'strings/strings.json'
            or pin.get('vendored_path') != SOURCE.as_posix()):
        raise ValueError('Invalid immutable Phase 2 settings string pin')
    source = root / SOURCE
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != pin.get('sha256'):
        raise ValueError('Phase 2 settings string pin/hash mismatch')
    selected = [entry for entry in json.loads(source.read_text())['entries'] if entry['id'] in IDS]
    if len(selected) != len(IDS) or {entry['id'] for entry in selected} != IDS:
        raise ValueError('Missing or duplicate Phase 2 settings string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        if 'ios' not in entry.get('platforms', []):
            raise ValueError(f'Entry is not declared for iOS: {entry["id"]}')
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            placeholders = set(re.findall(r'\{\w+\}', value))
            expected_placeholders = set(re.findall(r'\{\w+\}', entry['en']))
            if (not isinstance(value, str) or not value.strip()
                    or placeholders != expected_placeholders or '%' in value):
                raise ValueError(f'Placeholder drift: {entry["id"]} {language}')
            if entry['id'] in PLURALS:
                forms = translation['plural']
                expected = {'one', 'other'} if language == 'en' else {'one', 'many', 'other'}
                if set(forms) != expected:
                    raise ValueError(f'Plural drift: {entry["id"]} {language}')
                locales[language] = {'variations': {'plural': {
                    category: {'stringUnit': {'state': 'translated', 'value': value.replace('{n}', '%lld')}}
                    for category, value in forms.items()}}}
            else:
                locales[language] = {'stringUnit': {'state': 'translated', 'value': value}}
        strings[entry['id']] = {
            'comment': f'Generated from cassini-ux {pin["commit"]}, {entry["id"]}.',
            'extractionState': 'manual',
            'localizations': locales,
        }
    catalog = (json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'},
                          ensure_ascii=False, indent=2) + '\n').encode()
    lines = [
        f'// Generated from cassini-ux {pin["commit"]}; do not edit.',
        'import Foundation',
        'import CassiniNotebook',
        '',
        '/// Shared Phase 2 settings copy, resolved using the current app language.',
        'enum SettingsPhase2Copy {',
    ]
    for key, name in sorted(PROPERTIES.items()):
        if key in PLURALS:
            english = next(e['en'] for e in selected if e['id'] == key).replace('{n}', r'\(count)')
            lines += [f'    static func {name}(_ count: Int) -> String {{',
                      f'        String(localized: "{key}", defaultValue: "{english}", table: "SettingsPhase2")', '    }']
        else:
            lines += [f'    static var {name}: String {{',
                      f'        String(localized: "{key}", table: "SettingsPhase2")', '    }']
    lines += ['}', '']
    return {OUTPUT: catalog, LOOKUP: '\n'.join(lines).encode()}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-settings-strings.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if generated outputs are out of date')
    args = parser.parse_args()
    if args.check:
        check()
        return
    for path, content in outputs().items():
        target = ROOT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


if __name__ == '__main__':
    main()
