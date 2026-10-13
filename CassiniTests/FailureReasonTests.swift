import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

/// A package error that reaches the screen is worded from the Failures table, not in the package's English.
@Suite struct FailureReasonTests {
    @Test func aDamagedNoteIsWordedFromTheFailuresTable() throws {
        #expect(FailureReason.of(RepositoryError.invalidDocument)
                == String(localized: "This note’s details are not supported or are damaged. Its files have been kept.", table: "Failures"))
        let italian = try #require(Bundle.main.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(italian.localizedString(forKey: "This note’s details are not supported or are damaged. Its files have been kept.",
                                        value: nil, table: "Failures").hasPrefix("I dettagli"))
    }

    @Test func anyOtherErrorKeepsTheSystemsWords() {
        let error = CocoaError(.fileWriteOutOfSpace)
        #expect(FailureReason.of(error) == error.localizedDescription)
    }
}
