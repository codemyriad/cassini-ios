import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Half-height sheet for setting a meeting's recording date and start time (D112 / L-87).
/// Shared between the Library long-press menu and the meeting screen's "…" menu.
struct SetDateTimeSheet: View {
    let noteID: UUID
    let save: (Date, TimeZone) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(\.clock) private var clock
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate = Date()
    @State private var showsSavedFileHint = false
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(Wave6Copy.meetingSetDateTimeDateLabel,
                               selection: $selectedDate,
                               displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("setDatePicker")
                    DatePicker(Wave6Copy.meetingSetDateTimeTimeLabel,
                               selection: $selectedDate,
                               displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("setTimePicker")
                } header: {
                    if showsSavedFileHint {
                        Text(Wave6Copy.meetingSetDateTimePrefillSavedHint)
                            .font(.subheadline)
                            .foregroundStyle(Color.muted)
                            .textCase(nil)
                            .accessibilityIdentifier("setDateTimeSavedHint")
                    }
                }
            }
            .paperListBackground()
            .navigationTitle(Wave6Copy.meetingSetDateTimeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LibraryCopy.cancel) { dismiss() }
                        .accessibilityIdentifier("setDateTimeCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LibraryCopy.save) {
                        save(selectedDate, calendar.timeZone)
                        dismiss()
                    }
                    .accessibilityIdentifier("setDateTimeSave")
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let note = library.note(noteID) {
                let prefill = SetMeetingDatePrefill.of(note: note, now: clock.now, calendar: calendar)
                selectedDate = prefill.date
                showsSavedFileHint = prefill.showsSavedFileHint
            } else {
                selectedDate = clock.now
                showsSavedFileHint = false
            }
        }
    }
}
