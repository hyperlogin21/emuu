import Testing
import EmuuFarm
@testable import EmuuApp

@Suite struct CloneSheetTests {
    @Test func confirmButtonSaysWhatHappensToTheSource() {
        #expect(CloneInstanceSheet.confirmTitle(.copyNow) == "Clone")
        #expect(CloneInstanceSheet.confirmTitle(.hibernateCopyResume(refreeze: false)) == "Hibernate, Clone & Resume")
        #expect(CloneInstanceSheet.confirmTitle(.refuse("x")) == "Clone")
    }
}
