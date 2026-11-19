import Foundation
import Testing
import ArgumentParser
@testable import emuu

@Suite struct CloneInstanceCommandTests {
    @Test func parsesSourceNameAndOptions() throws {
        let c = try #require(try EmuuCLI.parseAsRoot(["clone-instance", "phone", "phone2"]) as? CloneInstance)
        #expect(c.source == "phone" && c.name == "phone2")
        #expect(!c.stopSource && !c.coldBoot && c.port == nil && c.displayName == nil)
        let full = try #require(try EmuuCLI.parseAsRoot(["clone-instance", "phone", "phone2", "--stop-source", "--cold-boot",
                                                         "--port", "5584", "--display-name", "phone copy", "--json"]) as? CloneInstance)
        #expect(full.stopSource && full.coldBoot && full.port == 5584 && full.displayName == "phone copy" && full.json)
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["clone-instance", "phone"]) }
    }

    @Test func goldenCloneIsUnchanged() throws {
        let c = try #require(try EmuuCLI.parseAsRoot(["clone", "base", "dev1"]) as? Clone)
        #expect(c.golden == "base" && c.name == "dev1")
    }
}
