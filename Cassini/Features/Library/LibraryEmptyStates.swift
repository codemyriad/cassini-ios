import SwiftUI
import CassiniNotebook

/// What the Library says instead of rows: an empty library with Record and Import, a search that found nothing, a
/// library that could not be opened, or a Starred filter with nothing (iOS extra).
struct LibraryEmptyStateView: View {
    let state: LibraryEmptyState
    let record: () -> Void
    let importAudio: () -> Void

    var body: some View {
        switch state {
        case .empty:
            VStack(spacing: 22) {
                illustration
                message(LibraryCopy.emptyTitle, LibraryCopy.emptyBody)
                HStack(spacing: 12) {
                    Button(LibraryCopy.record, systemImage: "mic.fill", action: record).buttonStyle(.borderedProminent)
                    Button(LibraryCopy.importAudio, systemImage: "square.and.arrow.down", action: importAudio).buttonStyle(.bordered)
                }
                .controlSize(.large).tint(.ember)
            }
            .frame(maxWidth: .infinity).padding(.bottom, 22)
        case .noMatch(let query):
            banner(LibraryCopy.noMatchTitle(query), LibraryCopy.noMatchBody, tone: .plain, symbol: "magnifyingglass")
                .accessibilityIdentifier("libraryNoMatch")
        case .unavailable:
            banner(LibraryCopy.unavailableTitle, LibraryCopy.unavailableBody, tone: .error, symbol: "exclamationmark.triangle")
                .accessibilityIdentifier("libraryUnavailable")
        case .noStarred:
            VStack(spacing: 18) {
                illustration
                message(LibraryCopy.noStarredTitle, LibraryCopy.noStarredBody)
            }.frame(maxWidth: .infinity).padding(.bottom, 22)
        }
    }

    private var illustration: some View {
        ZStack {
            Circle().fill(Color.ember.opacity(0.06)).frame(width: 148, height: 148)
            Circle().stroke(Color.ember.opacity(0.1), lineWidth: 1).frame(width: 180, height: 180)
            OrbitMark(size: 88)
        }
        .padding(.top, 24).accessibilityHidden(true)
    }

    private func message(_ title: String, _ body: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(.title2, design: .serif)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            Text(body).font(.subheadline).foregroundStyle(Color.muted)
        }
        .multilineTextAlignment(.center)
    }

    private func banner(_ title: String, _ body: String, tone: Tone, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tone.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.subheadline).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.ink).padding(16)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityElement(children: .combine)
    }
}
