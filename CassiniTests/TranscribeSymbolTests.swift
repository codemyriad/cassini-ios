import Testing
import UIKit
@testable import Cassini

/// Transcribe's menu icon is a symbol the running iOS has (it runs on the default runtime and on the iOS 18 leg).
@MainActor @Suite struct TranscribeSymbolTests {
    @Test func theSymbolExistsOnThisSystem() {
        #expect(UIImage(systemName: TranscribeSymbol.name) != nil)
    }
}
