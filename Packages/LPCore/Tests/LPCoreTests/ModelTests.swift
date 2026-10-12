import XCTest
@testable import LPCore

final class WheelMetricsTests: XCTestCase {
    func testHubSelectsNothing() {
        XCTAssertNil(WheelMetrics.slice(dx: 0, dy: 0))
        XCTAssertNil(WheelMetrics.slice(dx: 50, dy: -50))
        XCTAssertNotNil(WheelMetrics.slice(dx: 0, dy: -86))
    }

    func testCompassDirections() {
        let expected: [(Double, Double, Int)] = [
            (0, -100, 0), (100, -100, 1), (100, 0, 2), (100, 100, 3), (0, 100, 4), (-100, 100, 5), (-100, 0, 6), (-100, -100, 7),
        ]
        for (dx, dy, slice) in expected { XCTAssertEqual(WheelMetrics.slice(dx: dx, dy: dy), slice, "\(dx),\(dy)") }
    }

    func testBoundariesFallHalfwayBetweenDirections() {
        func at(_ degrees: Double) -> Int? {
            let a = degrees * .pi / 180
            return WheelMetrics.slice(dx: 150 * sin(a), dy: -150 * cos(a))
        }
        XCTAssertEqual(at(22.4), 0)
        XCTAssertEqual(at(22.6), 1)
        XCTAssertEqual(at(-22.4), 0)
        XCTAssertEqual(at(-22.6), 7)
        XCTAssertEqual(at(359), 0)
        XCTAssertEqual(at(180), 4)
    }
}

final class WheelArrangementTests: XCTestCase {
    private let wheel = WheelArrangement(slices: PingCatalog.standardWheel, quick: PingCatalog.standardQuick)

    func testNewItemReplacesTheSlice() {
        let next = wheel.moving(.library("bait"), to: .slice(1))
        XCTAssertEqual(next?.slices[1], "bait")
        XCTAssertFalse(next!.slices.contains("push"))
    }

    func testItemAlreadyOnTheWheelTradesPlaces() {
        let next = wheel.moving(.library("omw"), to: .slice(0))!
        XCTAssertEqual(next.slices[0], "omw")
        XCTAssertEqual(next.slices[2], "danger")
        XCTAssertEqual(Set(next.slices).count, 8)
        XCTAssertEqual(wheel.moving(.slice(2), to: .slice(0)), next)
    }

    func testQuickItem() {
        XCTAssertEqual(wheel.moving(.slice(0), to: .quick)?.quick, "danger")
        XCTAssertEqual(wheel.moving(.slice(0), to: .quick)?.slices, wheel.slices)
        let quickOnSlice = wheel.moving(.quick, to: .slice(3))!
        XCTAssertEqual(quickOnSlice.slices[3], "generic")
        XCTAssertEqual(quickOnSlice.quick, "generic")
    }

    func testMovesThatChangeNothing() {
        XCTAssertNil(wheel.moving(.slice(4), to: .slice(4)))
        XCTAssertNil(wheel.moving(.library("push"), to: .slice(1)))
        XCTAssertNil(wheel.moving(.library("generic"), to: .quick))
    }
}

final class CatalogTests: XCTestCase {
    func testCatalogsAreConsistent() {
        XCTAssertEqual(Set(PingCatalog.all.map(\.id)).count, PingCatalog.all.count)
        XCTAssertTrue(PingCatalog.standardWheel.allSatisfy(PingCatalog.contains))
        XCTAssertEqual(Set(PingCatalog.standardWheel).count, WheelMetrics.sliceCount)
        XCTAssertTrue(PingCatalog.contains(PingCatalog.standardQuick))
        XCTAssertEqual(PingCatalog.resolve("from-the-future").id, PingCatalog.standardQuick)
        XCTAssertEqual(Set(EmoteCatalog.all.map(\.slug)).count, EmoteCatalog.all.count)
        XCTAssertTrue(EmoteCatalog.standardWheel.allSatisfy(EmoteCatalog.contains))
        XCTAssertTrue(EmoteCatalog.contains(EmoteCatalog.standardQuick))
    }
}

final class KeyTests: XCTestCase {
    func testModifiersFromEventFlags() {
        XCTAssertEqual(KeyModifiers(eventFlags: 0x0008_0000 | 0x20), .option) // Option with its device bit
        XCTAssertEqual(KeyModifiers(eventFlags: 0x0014_0000), [.control, .command])
        XCTAssertEqual(KeyModifiers(eventFlags: 0x0001_0000), []) // Caps Lock is not one of ours
    }

    func testComboTitle() {
        let combo = KeyCombo(keyCode: 35, modifiers: [.option, .control])
        XCTAssertEqual(combo.title, "⌃⌥P")
        XCTAssertEqual(combo.parts, ["⌃", "⌥", "P"])
        XCTAssertTrue(combo.isSafeGlobally)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: .shift).isSafeGlobally)
        XCTAssertEqual(KeyNames.name(200), "Key 200")
    }

    func testWhichCombosCanBeUsed() {
        XCTAssertTrue(KeyCombo(keyCode: 0).isUsable) // a bare A is allowed, if unwise
        XCTAssertTrue(KeyCombo(keyCode: 105).isUsable) // F13
        XCTAssertFalse(KeyCombo(keyCode: 49).isUsable) // Space on its own
        XCTAssertFalse(KeyCombo(keyCode: 49, modifiers: .shift).isUsable)
        XCTAssertTrue(KeyCombo(keyCode: 49, modifiers: [.control, .option]).isUsable)
        XCTAssertFalse(KeyCombo(keyCode: 56, modifiers: .command).isUsable) // Shift is not a key
        XCTAssertTrue(KeyCombo(keyCode: 0, modifiers: .shift).takesATypingKey)
        XCTAssertFalse(KeyCombo(keyCode: 105).takesATypingKey)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: .command).takesATypingKey)
        XCTAssertFalse(Trigger.modifier([]).isUsable)
        XCTAssertFalse(Trigger.sideButton(1).isUsable)
    }

    func testComboStorage() throws {
        let combo = KeyCombo(keyCode: 35, modifiers: [.option, .control])
        XCTAssertEqual(combo.storedValue, "key:35+control+option")
        XCTAssertEqual(KeyCombo(storedValue: "key:35+control+option"), combo)
        XCTAssertEqual(KeyCombo(storedValue: "key:35"), KeyCombo(keyCode: 35))
        XCTAssertNil(KeyCombo(storedValue: "key:35+hyper"))
        XCTAssertNil(KeyCombo(storedValue: "key:35+"))
        XCTAssertNil(KeyCombo(storedValue: "35"))
    }

    func testTriggerParts() {
        XCTAssertEqual(Trigger.modifier(.option).parts, ["⌥ Option"])
        XCTAssertEqual(Trigger.modifier([.shift, .control]).parts, ["⌃", "⇧"])
        XCTAssertEqual(Trigger.key(KeyCombo(keyCode: 6, modifiers: .option)).parts, ["⌥", "Z"])
        XCTAssertNil(Trigger.sideButton(3).parts)
    }

    func testHotkeyActionsHaveDistinctKeys() {
        XCTAssertEqual(Set(HotkeyAction.all.map(\.storedKey)).count, HotkeyAction.all.count)
        for action in HotkeyAction.all { XCTAssertEqual(HotkeyAction(storedKey: action.storedKey), action) }
        XCTAssertEqual(HotkeyAction.slice(.emote, 3).storedKey, "emote.3")
        XCTAssertNil(HotkeyAction(storedKey: "ping.8"))
    }

    func testTriggerStorage() throws {
        let more: [Trigger] = [.key(KeyCombo(keyCode: 12)), .key(KeyCombo(keyCode: 6, modifiers: [.option, .shift])), .modifier([.control, .option]), .sideButton(2)]
        for trigger in Trigger.modifiers + Trigger.sideButtons + more {
            XCTAssertEqual(Trigger(storedValue: trigger.storedValue), trigger)
            let data = try JSONEncoder().encode([trigger])
            XCTAssertEqual(try JSONDecoder().decode([Trigger].self, from: data), [trigger])
        }
        XCTAssertNil(Trigger(storedValue: "capslock"))
        XCTAssertNil(Trigger(storedValue: "key:56")) // a modifier key is not a key trigger
        XCTAssertNil(Trigger(storedValue: "button:0"))
        XCTAssertNil(Trigger(storedValue: ""))
        XCTAssertNil(Trigger(storedValue: "key:49")) // Space alone
        XCTAssertEqual(Trigger(storedValue: "control+option"), .modifier([.control, .option]))
    }
}

final class SemanticVersionTests: XCTestCase {
    func testParsingAndOrder() {
        XCTAssertEqual(SemanticVersion("v1.4.0")?.description, "1.4.0")
        XCTAssertNil(SemanticVersion("1.4"))
        XCTAssertNil(SemanticVersion("1.4.0-beta"))
        XCTAssertNil(SemanticVersion("1..0"))
        XCTAssertTrue(SemanticVersion("0.10.0")! > SemanticVersion("0.9.9")!)
        XCTAssertFalse(SemanticVersion("1.0.0")! > SemanticVersion("1.0.0")!)
    }
}

final class PreferencesTests: XCTestCase {
    func testRoundTrip() throws {
        var p = Preferences()
        p.ping.trigger = .key(KeyCombo(keyCode: 12, modifiers: .shift))
        p.emote.trigger = .modifier([.control, .shift])
        p.hotkeys[.toggleEnabled] = KeyCombo(keyCode: 122, modifiers: [.command, .shift])
        p.hotkeys[.slice(.ping, 2)] = KeyCombo(keyCode: 105)
        p.hotkeys[.quick(.emote)] = KeyCombo(keyCode: 14, modifiers: [.control, .option])
        p.ping.slices = ["bait", "push", "omw", "allin", "assist", "needvision", "missing", "visioncleared"]
        p.ping.duration = 4.3
        p.room.lastCode = "0123456789"
        p.emote.imported = [ImportedEmote(id: "c:" + String(repeating: "ab", count: 16), name: "mine", animated: true)]
        p.emote.slices[0] = p.emote.imported[0].id
        p.language = .chinese
        XCTAssertEqual(p.repaired(), p)
        XCTAssertEqual(try Preferences.decode(try p.encoded()), p)
    }

    func testMissingAndMalformedFieldsTakeDefaults() throws {
        let json = #"{"dragThreshold":"far","ping":{"trigger":"capslock","size":90},"sound":7,"language":"tlh"}"#
        let p = try Preferences.decode(Data(json.utf8))
        XCTAssertEqual(p.dragThreshold, 8)
        XCTAssertEqual(p.ping.trigger, .modifier(.option))
        XCTAssertEqual(p.ping.size, 90)
        XCTAssertEqual(p.sound, Preferences.Sound())
        XCTAssertEqual(p.language, .system)
        XCTAssertEqual(try Preferences.decode(Data("{}".utf8)), Preferences())
        XCTAssertThrowsError(try Preferences.decode(Data("not json".utf8)))
    }

    func testNumbersAreBroughtIntoRange() {
        var p = Preferences()
        p.sound.volume = 250
        p.ping.duration = 3.14159
        p.dragThreshold = 0
        p.ping.size = .nan
        p.room.tagColor = 9
        let r = p.repaired()
        XCTAssertEqual(r.sound.volume, 100)
        XCTAssertEqual(r.ping.duration, 3.1)
        XCTAssertEqual(r.dragThreshold, 2)
        XCTAssertEqual(r.ping.size, 60)
        XCTAssertEqual(r.room.tagColor, 0)
    }

    func testWheelsAreCompletedWithoutRepeats() {
        var p = Preferences()
        p.ping.slices = ["danger", "danger", "nonsense"]
        p.ping.quick = "nonsense"
        let r = p.repaired()
        XCTAssertEqual(r.ping.slices.count, 8)
        XCTAssertEqual(Set(r.ping.slices).count, 8)
        XCTAssertEqual(r.ping.slices[0], "danger")
        XCTAssertEqual(r.ping.slices[1], "push")
        XCTAssertEqual(r.ping.quick, "generic")
    }

    func testAnEmoteThatWasRemovedLeavesTheWheel() {
        var p = Preferences()
        let gone = "c:" + String(repeating: "0", count: 32)
        p.emote.slices[3] = gone
        p.emote.quick = gone
        let r = p.repaired()
        XCTAssertEqual(r.emote.slices, EmoteCatalog.standardWheel)
        XCTAssertEqual(r.emote.quick, EmoteCatalog.standardQuick)
    }

    func testImportedEmotesAreKeptTidy() {
        var p = Preferences()
        let id = "c:" + String(repeating: "1f", count: 16)
        p.emote.imported = [
            ImportedEmote(id: id, name: "   ", animated: false),
            ImportedEmote(id: id, name: "twice", animated: false),
            ImportedEmote(id: "c:XYZ", name: "bad id", animated: false),
        ]
        let r = p.repaired()
        XCTAssertEqual(r.emote.imported.count, 1)
        XCTAssertEqual(r.emote.imported[0].name, "1f1f1f")
    }

    func testKeyConflicts() {
        var p = Preferences()
        XCTAssertNil(p.keyConflict)
        p.emote.trigger = .modifier(.option)
        XCTAssertEqual(p.keyConflict, .init(first: .pingTrigger, second: .emoteTrigger))
        XCTAssertFalse(p.repaired().emote.isOn)
        p.emote.isOn = false
        XCTAssertNil(p.keyConflict)

        // ⌥ and ⌥⇧ are different triggers, and a key trigger only clashes with the very same combination.
        var q = Preferences()
        q.emote.trigger = .modifier([.option, .shift])
        XCTAssertNil(q.keyConflict)
        q.emote.trigger = .key(KeyCombo(keyCode: 35))
        XCTAssertNil(q.keyConflict)
        q.emote.trigger = .key(KeyCombo(keyCode: 35, modifiers: [.control, .option]))
        XCTAssertEqual(q.keyConflict, .init(first: .emoteTrigger, second: .hotkey(.toggleEnabled)))
        XCTAssertNil(q.repaired().hotkeys[.toggleEnabled])
        XCTAssertTrue(q.repaired().emote.isOn)
    }

    func testTwoShortcutsCannotShareACombination() {
        var p = Preferences()
        let combo = KeyCombo(keyCode: 46, modifiers: [.control, .option])
        p.hotkeys[.toggleMute] = combo
        p.hotkeys[.slice(.ping, 0)] = combo
        XCTAssertEqual(p.keyConflict, .init(first: .hotkey(.toggleMute), second: .hotkey(.slice(.ping, 0))))
        let r = p.repaired()
        XCTAssertEqual(r.hotkeys[.toggleMute], combo)
        XCTAssertNil(r.hotkeys[.slice(.ping, 0)])
        XCTAssertNil(r.keyConflict)
    }

    func testUnusableKeysAreDropped() {
        var p = Preferences()
        p.hotkeys[.toggleEnabled] = KeyCombo(keyCode: 49, modifiers: .shift) // ⇧Space
        p.hotkeys[.openSettings] = KeyCombo(keyCode: 0, modifiers: .shift) // ⇧A: unwise, allowed
        p.ping.trigger = .modifier([])
        let r = p.repaired()
        XCTAssertNil(r.hotkeys[.toggleEnabled])
        XCTAssertEqual(r.hotkeys[.openSettings], KeyCombo(keyCode: 0, modifiers: .shift))
        XCTAssertEqual(r.ping.trigger, .modifier(.option))
    }

    func testAClearedShortcutStaysCleared() throws {
        var p = Preferences()
        p.hotkeys[.toggleEnabled] = nil
        XCTAssertNil(try Preferences.decode(try p.encoded()).hotkeys[.toggleEnabled])
        // A file without the table gets the standard shortcuts, or the pause shortcut of the older format.
        XCTAssertEqual(try Preferences.decode(Data("{}".utf8)).hotkeys, .standard)
        let old = try Preferences.decode(Data(#"{"pauseShortcut":{"keyCode":46,"modifiers":9}}"#.utf8))
        XCTAssertEqual(old.hotkeys[.toggleEnabled], KeyCombo(keyCode: 46, modifiers: [.control, .command]))
    }
}
