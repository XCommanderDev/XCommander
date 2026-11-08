import Testing
@testable import XCommanderCore

@Suite("Release versions")
struct ReleaseVersionTests {

    @Test("tags read as versions, with or without the v")
    func parsing() {
        #expect(ReleaseVersion("v1.2.3")?.numbers == [1, 2, 3])
        #expect(ReleaseVersion("1.2")?.numbers == [1, 2, 0])
        #expect(ReleaseVersion("0.1.0-alpha.3")?.prerelease == ["alpha", "3"])
        #expect(ReleaseVersion("1.0.0+build.7")?.description == "1.0.0")
        #expect(ReleaseVersion("nightly") == nil)
        #expect(ReleaseVersion("1.2.3.4") == nil)
        #expect(ReleaseVersion("1.0.0-") == nil)
    }

    @Test("ordered the way semantic versioning orders them")
    func ordering() {
        let ordered = ["0.1.0-alpha.2", "0.1.0-alpha.10", "0.1.0-beta", "0.1.0-beta.1",
                       "0.1.0-rc.1", "0.1.0", "0.1.1", "0.2.0", "1.0.0", "10.0.0"]
            .map { ReleaseVersion($0)! }
        #expect(ordered == ordered.sorted())
        #expect(ReleaseVersion("1.2")! == ReleaseVersion("1.2.0")!)
    }
}

@Suite("Update check")
struct UpdateCheckTests {

    let tags = ["v0.1.0-alpha.1", "v0.1.0-alpha.2", "v0.2.0-beta.1", "v0.1.0", "not-a-version"]

    @Test("a tester on a prerelease is offered the newest release, prereleases included")
    func prereleaseUsersSeePrereleases() {
        #expect(UpdateCheck.newest(in: tags, current: "0.1.0-alpha.1") == "v0.2.0-beta.1")
    }

    @Test("someone on a final release is only offered final releases")
    func finalUsersSeeFinals() {
        #expect(UpdateCheck.newest(in: tags, current: "0.0.9") == "v0.1.0")
        #expect(UpdateCheck.newest(in: tags, current: "0.1.0") == nil)
    }

    @Test("nothing newer means nothing to offer")
    func upToDate() {
        #expect(UpdateCheck.newest(in: tags, current: "0.2.0-beta.1") == nil)
        #expect(UpdateCheck.newest(in: [], current: "1.0.0") == nil)
    }

    @Test("a running version that isn't a version offers nothing")
    func unknownCurrent() {
        #expect(UpdateCheck.newest(in: tags, current: "dev") == nil)
    }
}
