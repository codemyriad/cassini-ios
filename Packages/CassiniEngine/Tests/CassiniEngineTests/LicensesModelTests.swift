import Foundation
import Synchronization
import Testing
import CassiniEngine

/// "Source code and notices" over a fake text reader.
@MainActor @Suite struct LicensesModelTests {
    private final class Reads: Sendable {
        let entries = Mutex<[LicenseEntry]>([])
        var list: [LicenseEntry] { entries.withLock { $0 } }
    }

    @MainActor private final class Effects { var list: [LicensesModel.Effect] = [] }

    private let reads = Reads()
    private let effects = Effects()

    private func model(failing: Set<LicenseEntry> = []) -> LicensesModel {
        let model = LicensesModel { [reads] entry in
            reads.entries.withLock { $0.append(entry) }
            if failing.contains(entry) { throw CocoaError(.fileReadNoSuchFile) }
            return "text of \(entry)"
        }
        model.onEffect = { [effects] in effects.list.append($0) }
        return model
    }

    // ports: LicensesViewModelTest#listsEveryRowAndOpensATextPane
    @Test func listsEveryRowAndOpensATextPane() async {
        let model = model()
        #expect(model.entries == [.cassini, .thirdParty, .models, .modelSources, .privacy, .sourceCode])
        await model.open(.privacy)
        #expect(model.open == LicenseText(entry: .privacy, text: "text of privacy"))
        #expect(model.opened == .privacy)
        model.closeText()
        #expect(model.open == nil)
        #expect(model.opened == nil)
        #expect(effects.list.isEmpty)
    }

    // ports: LicensesViewModelTest#sourceCodeOpensTheBrowserAndNoPane
    @Test func sourceCodeOpensTheBrowserAndNoPane() async {
        let model = model()
        await model.open(.sourceCode)
        #expect(model.open == nil)
        #expect(reads.list.isEmpty)
        #expect(effects.list == [.openURL(sourceCodeURL)])
        #expect(sourceCodeURL.absoluteString == "https://github.com/codemyriad/cassini-ios")
    }

    // ports: LicensesViewModelTest#theOpenPaneComesBackAfterProcessDeath
    @Test func theOpenPaneComesBackAfterTheAppWasClosed() async {
        let restored = model()
        await restored.restore(.models)
        #expect(restored.open == LicenseText(entry: .models, text: "text of models"))
        let nothing = model()
        await nothing.restore(nil)
        await nothing.restore(.sourceCode)
        #expect(nothing.open == nil)
        #expect(effects.list.isEmpty, "a restore never opens the browser")
    }

    @Test func aTextThatCannotBeReadOpensNothing() async {
        let model = model(failing: [.cassini])
        await model.open(.cassini)
        #expect(model.open == nil)
        #expect(model.opened == nil)
    }

    @Test func theTextPaneSplitsAtBlankLines() {
        let text = LicenseText(entry: .privacy, text: "Privacy\n\nOne line\nand the next.\n\n\n  Two  \n\n")
        #expect(text.paragraphs == ["Privacy", "One line\nand the next.", "Two"])
        #expect(LicenseEntry.cassini.isLicenceText && !LicenseEntry.privacy.isLicenceText)
    }

    @Test func aMarkdownSectionRunsToTheNextHeadingWithoutItsMarks() {
        let markdown = "# Privacy\n\nIntro\n\n## Network\n\nHosts:\n\n- `dist.gocassini.com`\n\n## Permissions\n\nMicrophone"
        #expect(LicenseTexts.section(markdown, heading: "## Network") == "Network\n\nHosts:\n\n- `dist.gocassini.com`")
        #expect(LicenseTexts.section(markdown, heading: "## Missing").isEmpty)
        #expect(LicenseTexts.plain(markdown).hasPrefix("Privacy\n\nIntro\n\nNetwork"))
    }
}
