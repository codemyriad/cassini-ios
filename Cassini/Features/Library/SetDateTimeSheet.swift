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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate = Date()
    @State private var showsSavedFileHint = false
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityBody
                } else {
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
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("setDateTimeSavedHint")
                            }
                        }
                    }
                    .paperListBackground()
                }
            }
            .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "" : Wave6Copy.meetingSetDateTimeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text(LibraryCopy.cancel)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                    .accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("setDateTimeCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save(selectedDate, calendar.timeZone)
                        dismiss()
                    } label: {
                        Text(LibraryCopy.save)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                    .accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("setDateTimeSave")
                }
            }
        }
        .accessibilityIdentifier("setDateTimeSheet")
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .compactDragIndicator()
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

    private var accessibilityBody: some View {
        let cardShape = RoundedRectangle(cornerRadius: Radius.field)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Wave6Copy.meetingSetDateTimeTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("setDateTimeTitle")
                if showsSavedFileHint {
                    Text(Wave6Copy.meetingSetDateTimePrefillSavedHint)
                        .font(.subheadline)
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setDateTimeSavedHint")
                }
                VStack(alignment: .leading, spacing: 14) {
                    accessibilityPickerRow(Wave6Copy.meetingSetDateTimeDateLabel,
                                           displayedComponents: .date,
                                           identifier: "setDatePicker")
                    Rectangle().fill(Color.lineSoft).frame(height: 1).accessibilityHidden(true)
                    accessibilityPickerRow(Wave6Copy.meetingSetDateTimeTimeLabel,
                                           displayedComponents: .hourAndMinute,
                                           identifier: "setTimePicker")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardShape.fill(Color.card))
                .overlay(cardShape.strokeBorder(Color.lineSoft, lineWidth: 1))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.paper.ignoresSafeArea())
    }

    private func accessibilityPickerRow(_ label: String,
                                        displayedComponents: DatePickerComponents,
                                        identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker(selection: $selectedDate, displayedComponents: displayedComponents) {
                EmptyView()
            }
            .labelsHidden()
            .datePickerStyle(.compact)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
