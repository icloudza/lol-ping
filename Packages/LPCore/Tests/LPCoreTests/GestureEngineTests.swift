import CoreGraphics
import XCTest
@testable import LPCore

final class GestureEngineTests: XCTestCase {
    private var engine = GestureEngine()
    private var clock: TimeInterval = 100

    override func setUp() {
        engine = GestureEngine()
        clock = 100
        configure { $0.emote = .init(trigger: .modifier(.control)) }
    }

    private func configure(_ change: (inout GestureConfig) -> Void) {
        var c = engine.config
        change(&c)
        _ = engine.apply(c)
    }

    @discardableResult
    private func send(_ event: InputEvent) -> GestureOutcome {
        clock += 0.01
        return engine.handle(event, at: clock)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    func testOrdinaryClicksAreLeftAlone() {
        XCTAssertFalse(send(.buttonDown(.primary, at: p(5, 5))).consume)
        XCTAssertFalse(send(.buttonUp(.primary, at: p(5, 5))).consume)
        XCTAssertFalse(engine.isGestureActive)
    }

    func testDraggingWithTheTriggerOpensTheWheelWhereThePressWas() {
        send(.modifiers(.option))
        XCTAssertTrue(send(.buttonDown(.primary, at: p(100, 100))).consume)
        XCTAssertEqual(send(.moved(to: p(105, 100))).actions, []) // not far enough yet
        let opened = send(.moved(to: p(130, 100)))
        XCTAssertFalse(opened.consume)
        XCTAssertEqual(opened.actions, [.wheelOpened(.ping, at: p(100, 100)), .wheelMoved(to: p(130, 100))])
        XCTAssertEqual(send(.moved(to: p(220, 90))).actions, [.wheelMoved(to: p(220, 90))])
        let released = send(.buttonUp(.primary, at: p(220, 90)))
        XCTAssertTrue(released.consume)
        XCTAssertEqual(released.actions, [.wheelReleased(at: p(220, 90))])
        XCTAssertFalse(engine.isGestureActive)
    }

    func testEachWheelAnswersToItsOwnKey() {
        send(.modifiers(.control))
        send(.buttonDown(.primary, at: p(10, 10)))
        XCTAssertEqual(send(.moved(to: p(60, 10))).actions.first, .wheelOpened(.emote, at: p(10, 10)))
    }

    func testBothKeysHeldStartsNothing() {
        send(.modifiers([.control, .option]))
        XCTAssertFalse(send(.buttonDown(.primary, at: p(10, 10))).consume)
    }

    func testAWheelThatIsOffNeverOpens() {
        configure { $0.emote.trigger = nil }
        send(.modifiers(.control))
        XCTAssertFalse(send(.buttonDown(.primary, at: p(10, 10))).consume)
    }

    func testTriggerClickIsReplayedAsAClick() {
        send(.modifiers(.option))
        XCTAssertTrue(send(.buttonDown(.primary, at: p(10, 10))).consume)
        let up = send(.buttonUp(.primary, at: p(12, 11)))
        XCTAssertTrue(up.consume)
        XCTAssertEqual(up.replays, [.down(.primary, at: p(10, 10)), .up(.primary, at: p(12, 11))])
        XCTAssertEqual(up.actions, [])
    }

    func testTriggerClickSendsTheQuickItemWhenAskedTo() {
        configure { $0.ping.clickSends = true }
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 20)))
        let up = send(.buttonUp(.primary, at: p(11, 21)))
        XCTAssertTrue(up.consume)
        XCTAssertEqual(up.actions, [.quickSent(.ping, at: p(10, 20))])
        XCTAssertEqual(up.replays, [])
    }

    func testLettingGoOfTheKeyBeforeDraggingHandsThePressBack() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        XCTAssertEqual(send(.modifiers([])).replays, [.down(.primary, at: p(10, 10))])
        XCTAssertFalse(send(.buttonUp(.primary, at: p(10, 10))).consume) // the real release completes the click
    }

    func testLettingGoOfTheKeyWithTheWheelOpenCancels() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        send(.moved(to: p(80, 10)))
        XCTAssertEqual(send(.modifiers([])).actions, [.cancelled])
        let up = send(.buttonUp(.primary, at: p(80, 10)))
        XCTAssertTrue(up.consume)
        XCTAssertEqual(up.actions, [])
    }

    func testRightClickCancelsAndItsReleaseIsSwallowedOnce() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        send(.moved(to: p(80, 10)))
        let down = send(.buttonDown(.secondary, at: p(80, 10)))
        XCTAssertTrue(down.consume)
        XCTAssertEqual(down.actions, [.cancelled])
        XCTAssertTrue(send(.buttonUp(.secondary, at: p(80, 10))).consume)
        XCTAssertTrue(send(.buttonUp(.primary, at: p(80, 10))).consume)
        XCTAssertFalse(send(.buttonDown(.secondary, at: p(80, 10))).consume)
        XCTAssertFalse(send(.buttonUp(.secondary, at: p(80, 10))).consume)
    }

    func testEscapeCancelsAndIsNotTyped() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        send(.moved(to: p(80, 10)))
        let esc = send(.keyDown(KeyNames.escape, isRepeat: false))
        XCTAssertTrue(esc.consume)
        XCTAssertEqual(esc.actions, [.cancelled])
        XCTAssertTrue(send(.keyUp(KeyNames.escape)).consume)
        send(.buttonUp(.primary, at: p(80, 10)))
        XCTAssertFalse(send(.keyDown(KeyNames.escape, isRepeat: false)).consume) // Esc is ordinary again
    }

    func testPauseShortcutTogglesEvenWhileOff() {
        send(.modifiers([.control, .option]))
        let off = send(.keyDown(35, isRepeat: false))
        XCTAssertTrue(off.consume)
        XCTAssertEqual(off.actions, [.enabledChanged(false)])
        XCTAssertEqual(send(.keyDown(35, isRepeat: true)).actions, [])
        XCTAssertTrue(send(.keyUp(35)).consume)
        send(.modifiers(.option))
        XCTAssertFalse(send(.buttonDown(.primary, at: p(1, 1))).consume) // off: Option + click is just a click
        send(.buttonUp(.primary, at: p(1, 1)))
        send(.modifiers([.control, .option]))
        XCTAssertEqual(send(.keyDown(35, isRepeat: false)).actions, [.enabledChanged(true)])
    }

    func testPauseShortcutNeedsExactlyItsModifiers() {
        send(.modifiers([.control, .option, .shift]))
        XCTAssertFalse(send(.keyDown(35, isRepeat: false)).consume)
    }

    func testPausingMidGestureCancelsIt() {
        configure { $0.hotkeys = [KeyCombo(keyCode: 35, modifiers: .option): .toggleEnabled]; $0.emote.trigger = nil }
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        send(.moved(to: p(80, 10)))
        XCTAssertEqual(send(.keyDown(35, isRepeat: false)).actions, [.cancelled, .enabledChanged(false)])
        XCTAssertTrue(send(.buttonUp(.primary, at: p(80, 10))).consume)
    }

    func testSuspendedPassesEverything() {
        _ = engine.setSuspended(true)
        send(.modifiers([.control, .option]))
        let key = send(.keyDown(35, isRepeat: false))
        XCTAssertFalse(key.consume)
        XCTAssertEqual(key.actions, [])
        send(.keyUp(35))
        send(.modifiers(.option))
        XCTAssertFalse(send(.buttonDown(.primary, at: p(1, 1))).consume)
    }

    func testATriggerUsedInAnotherShortcutDoesNotStartAGesture() {
        send(.modifiers(.option))
        send(.keyDown(48, isRepeat: false)) // ⌥Tab
        send(.keyUp(48))
        XCTAssertFalse(send(.buttonDown(.primary, at: p(1, 1))).consume)
        send(.buttonUp(.primary, at: p(1, 1)))
        send(.modifiers([]))
        send(.modifiers(.option))
        XCTAssertTrue(send(.buttonDown(.primary, at: p(1, 1))).consume)
    }

    func testSideButtonDragsOnItsOwn() {
        configure { $0.ping.trigger = .sideButton(3) }
        XCTAssertTrue(send(.buttonDown(.other(3), at: p(10, 10))).consume)
        XCTAssertEqual(send(.moved(to: p(80, 10))).actions.first, .wheelOpened(.ping, at: p(10, 10)))
        XCTAssertEqual(send(.buttonUp(.other(3), at: p(80, 10))).actions, [.wheelReleased(at: p(80, 10))])
        // Without a drag it is still the Back button.
        send(.buttonDown(.other(3), at: p(10, 10)))
        XCTAssertEqual(send(.buttonUp(.other(3), at: p(10, 10))).replays, [.down(.other(3), at: p(10, 10)), .up(.other(3), at: p(10, 10))])
        XCTAssertFalse(send(.buttonDown(.other(4), at: p(10, 10))).consume)
    }

    func testAKeyTriggerNeverTypes() {
        configure { $0.ping.trigger = .key(KeyCombo(keyCode: 12)) } // Q
        XCTAssertTrue(send(.keyDown(12, isRepeat: false)).consume)
        XCTAssertTrue(send(.keyDown(12, isRepeat: true)).consume)
        XCTAssertTrue(send(.buttonDown(.primary, at: p(10, 10))).consume)
        send(.moved(to: p(80, 10)))
        XCTAssertEqual(send(.buttonUp(.primary, at: p(80, 10))).actions, [.wheelReleased(at: p(80, 10))])
        XCTAssertTrue(send(.keyUp(12)).consume)
    }

    func testAKeyTriggerWithModifiersLeavesTheBareKeyAlone() {
        configure { $0.ping.trigger = .key(KeyCombo(keyCode: 6, modifiers: .option)) } // ⌥Z
        XCTAssertFalse(send(.keyDown(6, isRepeat: false)).consume) // a plain Z still types
        send(.keyUp(6))
        send(.modifiers(.option))
        XCTAssertTrue(send(.keyDown(6, isRepeat: false)).consume)
        XCTAssertTrue(send(.buttonDown(.primary, at: p(10, 10))).consume)
        XCTAssertEqual(send(.moved(to: p(80, 10))).actions.first, .wheelOpened(.ping, at: p(10, 10)))
        // Letting go of ⌥ first ends the gesture, and the key keeps quiet until it comes up.
        XCTAssertEqual(send(.modifiers([])).actions, [.cancelled])
        XCTAssertTrue(send(.keyDown(6, isRepeat: true)).consume)
        XCTAssertTrue(send(.keyUp(6)).consume)
    }

    func testSeveralModifiersCanBeOneTrigger() {
        configure { $0.ping.trigger = .modifier(.option); $0.emote.trigger = .modifier([.option, .shift]) }
        send(.modifiers([.option, .shift]))
        send(.buttonDown(.primary, at: p(10, 10)))
        XCTAssertEqual(send(.moved(to: p(60, 10))).actions.first, .wheelOpened(.emote, at: p(10, 10)))
        send(.buttonUp(.primary, at: p(60, 10)))
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        XCTAssertEqual(send(.moved(to: p(60, 10))).actions.first, .wheelOpened(.ping, at: p(10, 10)))
        // Another modifier joining mid-drag doesn't close the wheel.
        XCTAssertEqual(send(.modifiers([.option, .command])).actions, [])
        XCTAssertEqual(send(.buttonUp(.primary, at: p(60, 10))).actions, [.wheelReleased(at: p(60, 10))])
    }

    func testAKeyTriggerWinsOverTheModifiersItIsHeldWith() {
        configure { $0.ping.trigger = .modifier(.option); $0.emote.trigger = .key(KeyCombo(keyCode: 6, modifiers: .option)) }
        send(.modifiers(.option))
        XCTAssertTrue(send(.keyDown(6, isRepeat: false)).consume)
        send(.buttonDown(.primary, at: p(10, 10)))
        XCTAssertEqual(send(.moved(to: p(60, 10))).actions.first, .wheelOpened(.emote, at: p(10, 10)))
    }

    func testHotkeysFireOncePerPress() {
        let combo = KeyCombo(keyCode: 18, modifiers: [.control, .option]) // ⌃⌥1
        configure { $0.hotkeys[combo] = .slice(.ping, 0); $0.hotkeys[KeyCombo(keyCode: 105)] = .openSettings }
        send(.modifiers([.control, .option]))
        let down = send(.keyDown(18, isRepeat: false))
        XCTAssertTrue(down.consume)
        XCTAssertEqual(down.actions, [.hotkey(.slice(.ping, 0))])
        XCTAssertEqual(send(.keyDown(18, isRepeat: true)).actions, [])
        XCTAssertTrue(send(.keyUp(18)).consume)
        send(.modifiers([]))
        XCTAssertFalse(send(.keyDown(18, isRepeat: false)).consume) // a bare 1 is just a 1
        send(.keyUp(18))
        XCTAssertEqual(send(.keyDown(105, isRepeat: false)).actions, [.hotkey(.openSettings)]) // a bare F13 can be a shortcut
    }

    func testOnlySomeHotkeysWorkWhilePaused() {
        let send1 = KeyCombo(keyCode: 18, modifiers: [.control, .option])
        configure { $0.hotkeys[send1] = .quick(.ping); $0.hotkeys[KeyCombo(keyCode: 105)] = .openSettings }
        _ = engine.setEnabled(false)
        send(.modifiers([.control, .option]))
        let quiet = send(.keyDown(18, isRepeat: false))
        XCTAssertFalse(quiet.consume) // paused: the key goes to whatever app is in front
        XCTAssertEqual(quiet.actions, [])
        send(.keyUp(18))
        send(.modifiers([]))
        XCTAssertEqual(send(.keyDown(105, isRepeat: false)).actions, [.hotkey(.openSettings)])
    }

    func testAStalledGestureIsGivenUp() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        send(.moved(to: p(80, 10)))
        XCTAssertEqual(engine.checkStall(now: clock + 5).actions, [])
        XCTAssertEqual(engine.checkStall(now: clock + 10.5).actions, [.cancelled])
        XCTAssertTrue(send(.buttonDown(.primary, at: p(10, 10))).consume) // the lost release doesn't block a new gesture
        XCTAssertTrue(engine.isGestureActive)
    }

    func testResyncForgetsWhatTheSystemSaysIsUp() {
        send(.modifiers(.option))
        _ = engine.resync(modifiers: []) { _ in false }
        XCTAssertFalse(send(.buttonDown(.primary, at: p(1, 1))).consume)
    }

    func testResyncDuringAGestureCountsAsReleasingTheKey() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        send(.moved(to: p(80, 10)))
        XCTAssertEqual(engine.resync(modifiers: []) { _ in false }.actions, [.cancelled])
    }

    func testTurningOffMidGestureCancelsAndStillOwnsTheRelease() {
        send(.modifiers(.option))
        send(.buttonDown(.primary, at: p(10, 10)))
        XCTAssertEqual(engine.setEnabled(false).actions, [.cancelled])
        XCTAssertTrue(send(.buttonUp(.primary, at: p(10, 10))).consume)
    }

    /// The rule everything else rests on: over any sequence, a consumed press is never followed by a delivered
    /// release of the same button unless the press was replayed first.
    func testNoAppIsEverLeftWithHalfAClick() {
        var rng = SystemRandomNumberGenerator()
        let buttons: [PointerButton] = [.primary, .secondary]
        for _ in 0..<300 {
            engine = GestureEngine()
            configure { $0.emote = .init(trigger: .modifier(.control), clickSends: Bool.random(using: &rng)); $0.ping.clickSends = Bool.random(using: &rng) }
            var down: [PointerButton: Bool] = [:]      // physically down
            var delivered: [PointerButton: Bool] = [:] // the app underneath believes it is down
            for _ in 0..<60 {
                let event: InputEvent
                switch Int.random(in: 0..<7, using: &rng) {
                case 0: event = .modifiers([[], .option, .control, [.option, .control]].randomElement(using: &rng)!)
                case 1: event = .keyDown([35, 53, 48].randomElement(using: &rng)!, isRepeat: false)
                case 2: event = .keyUp([35, 53, 48].randomElement(using: &rng)!)
                case 3, 4:
                    let b = buttons.randomElement(using: &rng)!
                    if down[b] == true {
                        event = .buttonUp(b, at: p(.random(in: 0...300, using: &rng), 50))
                    } else {
                        event = .buttonDown(b, at: p(.random(in: 0...300, using: &rng), 50))
                    }
                default: event = .moved(to: p(.random(in: 0...300, using: &rng), 50))
                }
                let out = send(event)
                for replay in out.replays {
                    switch replay {
                    case .down(let b, _):
                        XCTAssertNotEqual(delivered[b], true, "a press replayed onto a button already down")
                        delivered[b] = true
                    case .up(let b, _):
                        XCTAssertEqual(delivered[b], true, "a release replayed without its press")
                        delivered[b] = false
                    }
                }
                switch event {
                case .buttonDown(let b, _):
                    down[b] = true
                    if !out.consume { delivered[b] = true }
                case .buttonUp(let b, _):
                    down[b] = false
                    if !out.consume {
                        XCTAssertEqual(delivered[b], true, "a release delivered for a press that was withheld")
                        delivered[b] = false
                    }
                default:
                    break
                }
            }
        }
    }
}
