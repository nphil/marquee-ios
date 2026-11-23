import Testing
@testable import MarqueeCore

struct OrbDimmingTests {
    @Test func theOrbDimsOnceItHasSatForTheDwell() {
        #expect(!OrbDimming.isDimmed(overContent: true, panelOpen: false, idle: 3.99))
        #expect(OrbDimming.isDimmed(overContent: true, panelOpen: false, idle: 4))
        #expect(OrbDimming.isDimmed(overContent: true, panelOpen: false, idle: 60))
    }

    @Test func anOpenPanelKeepsTheOrbBright() {
        #expect(!OrbDimming.isDimmed(overContent: true, panelOpen: true, idle: 60))
    }

    @Test func anOrbNotOverContentKeepsItsLook() {
        #expect(!OrbDimming.isDimmed(overContent: false, panelOpen: false, idle: 60))
    }

    @Test func dimmedMeansLessLightNotInvisible() {
        #expect(OrbDimming.dimmedOpacity > 0 && OrbDimming.dimmedOpacity < 1)
    }
}
