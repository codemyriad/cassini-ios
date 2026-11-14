import SwiftUI
import CassiniNotebook

/// "Merge Speaker 2 into…": the other speakers with their tint and speaking time; a row asks to confirm.
struct MergeSheet: View {
    let merge: MergeUI
    let sourceOrdinal: Int
    let tint: (String) -> SpeakerTint
    let send: (NamingEvent) -> Void

    private var source: String { NoteCopy.speakerLabel(merge.source, id: merge.sourceID, ordinal: sourceOrdinal) }

    var body: some View {
        List(merge.targets, id: \.byteSpeakerID) { target in
            Button { send(.mergeTarget(target.speakerID)) } label: {
                HStack(spacing: 12) {
                    SpeakerAvatar(name: target.name, tint: tint(target.speakerID))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.name(target)).foregroundStyle(Color.ink)
                        Text(RecordingCopy.compact(target.speakingTime)).font(.caption).foregroundStyle(Color.muted)
                    }
                }.frame(minHeight: HitTarget.minimum)
            }
            .accessibilityIdentifier("mergeTarget-\(target.speakerID)")
        }
        .navigationTitle(SpeakersCopy.mergeTitle(source))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .alert(merge.confirm.map { SpeakersCopy.mergeConfirmTitle(source, Self.name($0)) } ?? "",
               isPresented: Binding(get: { merge.confirm != nil }, set: { if !$0 { send(.cancelMerge) } }),
               presenting: merge.confirm) { target in
            Button(SpeakersCopy.cancel, role: .cancel) { send(.cancelMerge) }
            Button(SpeakersCopy.merge) { send(.confirmMerge) }
        } message: { target in
            Text(SpeakersCopy.mergeConfirmBody(source, Self.name(target), added: merge.addedVersion, shown: merge.shownVersion))
        }
    }

    private static func name(_ target: MergeTarget) -> String {
        NoteCopy.speakerLabel(target.name, id: target.speakerID, ordinal: target.ordinal)
    }
}

private extension MergeTarget {
    var byteSpeakerID: Data { Data(speakerID.utf8) }
}
