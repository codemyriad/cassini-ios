import Foundation
import Testing
import CassiniEngine

/// D54: the model requests' User-Agent, in the decision's iOS form.
@Suite struct ModelUserAgentTests {
    @Test func theDecisionsExample() {
        let system = OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 0)
        #expect(ModelUserAgent.string(version: "0.1.0", system: system, build: "2") == "CassiniTalk/0.1.0 (iOS 18.2; build 2)")
    }

    @Test(arguments: [((26, 0, 0), "26.0"), ((26, 1, 0), "26.1"), ((26, 0, 1), "26.0.1"), ((27, 2, 3), "27.2.3")])
    func theSystemVersionIsWrittenAsIOSWritesIt(version: (Int, Int, Int), expected: String) {
        let system = OperatingSystemVersion(majorVersion: version.0, minorVersion: version.1, patchVersion: version.2)
        #expect(ModelUserAgent.systemVersion(system) == expected)
    }

    /// A development version goes out as it is, never a stale literal.
    @Test func aDevelopmentVersionIsSentAsItIs() {
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(ModelUserAgent.string(version: "0.2.0-dev", system: system, build: "17")
                == "CassiniTalk/0.2.0-dev (iOS 26.1; build 17)")
    }
}
