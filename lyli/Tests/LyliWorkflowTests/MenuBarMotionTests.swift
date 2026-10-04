import AppKit
import LyliCore
@testable import lyli

@MainActor
struct MenuBarMotionTests {
    func testReducedMotionStopsAndRestartsNativeMarquee() throws {
        let label = MenuBarScrollingLabel()
        label.setReducedMotion(false)
        label.present(text: String(repeating: "Long lyric ", count: 20), windowWidth: 80,
                      pacing: MenuBarMarquee.pacing(maxOffset: 200, averageCharWidth: 6, dwellSeconds: nil))
        let content = try require(label.layer?.sublayers?.first?.sublayers?.first)
        expectEqual(content.animation(forKey: "lyli.marquee") != nil, true)
        label.setReducedMotion(true)
        expectEqual(content.animation(forKey: "lyli.marquee") == nil, true)
        expectEqual(content.position.x, 0)
        label.setReducedMotion(false)
        expectEqual(content.animation(forKey: "lyli.marquee") != nil, true)
        label.clear()
    }

    func testReducedMotionBlocksFollowScrollClockUpdates() throws {
        let label = MenuBarScrollingLabel()
        label.setReducedMotion(true)
        let path = [MenuBarMarquee.KaraokeFillPoint(ms: 0, x: 0),
                    MenuBarMarquee.KaraokeFillPoint(ms: 10_000, x: 400)]
        label.present(text: String(repeating: "Long lyric ", count: 20), windowWidth: 80,
                      pacing: MenuBarMarquee.pacing(maxOffset: 200, averageCharWidth: 6, dwellSeconds: nil),
                      followPath: path)
        let content = try require(label.layer?.sublayers?.first?.sublayers?.first)
        label.updateKaraokeClock(positionMs: 3_000, rate: 1, playing: true, force: true)
        expectEqual(content.animation(forKey: "lyli.marquee") == nil, true)
        expectEqual(content.position.x, 0)
        label.setReducedMotion(false)
        expectEqual(content.animation(forKey: "lyli.marquee") != nil, true)
        label.setReducedMotion(true)
        label.updateKaraokeClock(positionMs: 5_000, rate: 1, playing: false, force: true)
        expectEqual(content.animation(forKey: "lyli.marquee") == nil, true)
        expectEqual(content.position.x, 0)
        label.clear()
    }
}
