import Testing
import CassiniNotebook

@Suite struct JobFailureTests {
    // ports: JobFailureTest#noTwoFailuresShareAStoredCode
    @Test func noTwoFailuresShareAStoredCode() {
        let codes = JobFailure.allCases.map(\.code)
        #expect(codes.count == Set(codes).count)
        for failure in JobFailure.allCases { #expect(JobFailure(code: failure.code) == failure) }
    }

    // ports: JobFailureTest#anInstallFailureOfTheDownloadIsNotTheCoreInstallFailure
    @Test func aDownloadFailureCodeCarriesItsPrefix() {
        #expect(JobFailure.download(.install).code == "DOWNLOAD_INSTALL")
        #expect(JobFailure.downloadError("DOWNLOAD_INSTALL") == .install)
        #expect(JobFailure.downloadError(JobFailure.save.code) == nil)
        #expect(JobFailure.documentRefused(.unknownFormat).code == "DOCUMENT_UNKNOWN_FORMAT")
    }

    // ports: JobFailureTest#everyDownloadCodeReadsBack
    @Test func everyDownloadCodeReadsBack() {
        for error in DownloadError.allCases {
            #expect(JobFailure.downloadError(JobFailure.download(error).code) == error)
        }
        #expect(JobFailure.downloadError(JobFailure.checkpointMismatch.code) == nil)
    }
}
