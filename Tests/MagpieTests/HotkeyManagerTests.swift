import Carbon.HIToolbox
import XCTest
@testable import Magpie

/// The Carbon handler holds an *unmanaged* pointer back to the manager, so the
/// register/unregister lifecycle is the one piece of this trigger that can
/// crash rather than merely misbehave. Whether registration succeeds depends on
/// the environment (another process may own the combination), so these only
/// assert that the lifecycle itself is safe.
final class HotkeyManagerTests: XCTestCase {
    func test_start_then_stop_is_safe() {
        let manager = HotkeyManager()
        // F13 is the preset least likely to be claimed by anything else.
        _ = manager.start(preset: .f13)
        manager.stop()
    }

    func test_start_replaces_the_previous_registration() {
        let manager = HotkeyManager()
        _ = manager.start(preset: .f13)
        _ = manager.start(preset: .optionShiftD)
        manager.stop()
    }

    func test_stop_is_idempotent() {
        let manager = HotkeyManager()
        manager.stop()
        manager.stop()
        _ = manager.start(preset: .f13)
        manager.stop()
        manager.stop()
    }

    // MARK: - Two actions at once

    /// Carbon refuses a combination that is already live anywhere in the
    /// session with `eventHotKeyExistsErr`, so a *failed* probe registration is
    /// hard evidence that the original is still held. This proves coexistence
    /// through the system rather than through the manager's own bookkeeping,
    /// which is exactly the thing under test.
    private func combinationIsHeld(_ preset: some HotkeyCombination) -> Bool {
        let probe = HotkeyManager()
        defer { probe.stop() }
        return !probe.start(.summonShelf, preset: preset)
    }

    func test_registering_a_second_action_does_not_unregister_the_first() throws {
        let manager = HotkeyManager()
        defer { manager.stop() }

        guard manager.start(.summonShelf, preset: HotkeyPreset.f13) else {
            throw XCTSkip("F13 is already claimed in this environment")
        }
        guard manager.start(.copyForChat, preset: ChatHotkeyPreset.f14) else {
            throw XCTSkip("F14 is already claimed in this environment")
        }

        XCTAssertTrue(manager.isRegistered(.summonShelf))
        XCTAssertTrue(manager.isRegistered(.copyForChat))
        XCTAssertTrue(combinationIsHeld(HotkeyPreset.f13), "the summon hotkey was released")
        XCTAssertTrue(combinationIsHeld(ChatHotkeyPreset.f14), "the copy hotkey was released")
    }

    func test_stopping_one_action_leaves_the_other_registered() throws {
        let manager = HotkeyManager()
        defer { manager.stop() }

        guard manager.start(.summonShelf, preset: HotkeyPreset.f13),
              manager.start(.copyForChat, preset: ChatHotkeyPreset.f14)
        else {
            throw XCTSkip("F13/F14 are already claimed in this environment")
        }

        manager.stop(.copyForChat)

        XCTAssertTrue(manager.isRegistered(.summonShelf))
        XCTAssertFalse(manager.isRegistered(.copyForChat))
        XCTAssertTrue(combinationIsHeld(HotkeyPreset.f13), "stopping copy dropped summon too")
        XCTAssertFalse(combinationIsHeld(ChatHotkeyPreset.f14), "the copy hotkey was not released")
    }

    func test_restarting_one_action_only_replaces_its_own_registration() throws {
        let manager = HotkeyManager()
        defer { manager.stop() }

        guard manager.start(.summonShelf, preset: HotkeyPreset.f13),
              manager.start(.copyForChat, preset: ChatHotkeyPreset.f14)
        else {
            throw XCTSkip("F13/F14 are already claimed in this environment")
        }

        // The Settings picker changing the copy shortcut must not take the
        // summon shortcut down with it — the failure mode of the old
        // single-slot manager, whose start() began with a full stop().
        guard manager.start(.copyForChat, preset: ChatHotkeyPreset.optionShiftV) else {
            throw XCTSkip("⌥⇧V is already claimed in this environment")
        }

        XCTAssertTrue(combinationIsHeld(HotkeyPreset.f13), "summon lost when copy was re-pointed")
        XCTAssertFalse(combinationIsHeld(ChatHotkeyPreset.f14), "the old copy shortcut leaked")
        XCTAssertTrue(combinationIsHeld(ChatHotkeyPreset.optionShiftV))
    }

    func test_stop_releases_every_action() throws {
        let manager = HotkeyManager()
        guard manager.start(.summonShelf, preset: HotkeyPreset.f13),
              manager.start(.copyForChat, preset: ChatHotkeyPreset.f14)
        else {
            throw XCTSkip("F13/F14 are already claimed in this environment")
        }

        manager.stop()

        XCTAssertFalse(manager.isRegistered(.summonShelf))
        XCTAssertFalse(manager.isRegistered(.copyForChat))
        XCTAssertFalse(combinationIsHeld(HotkeyPreset.f13))
        XCTAssertFalse(combinationIsHeld(ChatHotkeyPreset.f14))
    }

    func test_actions_have_distinct_carbon_ids_that_round_trip() {
        // One installed handler serves both hotkeys and tells them apart by
        // this id alone; a collision would fire the wrong action.
        let ids = HotkeyAction.allCases.map(\.carbonID)
        XCTAssertEqual(Set(ids).count, HotkeyAction.allCases.count)
        for action in HotkeyAction.allCases {
            XCTAssertEqual(HotkeyAction(carbonID: action.carbonID), action)
        }
        XCTAssertNil(HotkeyAction(carbonID: 999))
    }

    func test_the_two_preset_lists_cannot_be_set_to_the_same_shortcut() {
        let summon = Set(HotkeyPreset.allCases.map { [$0.keyCode, $0.carbonModifiers] })
        for preset in ChatHotkeyPreset.allCases {
            XCTAssertFalse(
                summon.contains([preset.keyCode, preset.carbonModifiers]),
                "\(preset.rawValue) can be set to the same combination as a summon preset"
            )
        }
    }

    func test_chat_presets_are_distinct_and_do_not_collide_with_menu_shortcuts() {
        let combos = ChatHotkeyPreset.allCases.map { [$0.keyCode, $0.carbonModifiers] }
        XCTAssertEqual(Set(combos).count, ChatHotkeyPreset.allCases.count)

        // ⌥⇧N and ⌥⇧A are owned by the status menu.
        let taken: Set<[UInt32]> = [
            [UInt32(kVK_ANSI_N), UInt32(optionKey | shiftKey)],
            [UInt32(kVK_ANSI_A), UInt32(optionKey | shiftKey)],
        ]
        for preset in ChatHotkeyPreset.allCases {
            XCTAssertFalse(taken.contains([preset.keyCode, preset.carbonModifiers]))
        }
    }

    func test_chat_preset_raw_values_are_pinned() {
        // @AppStorage persists the raw value; a rename silently resets the
        // user's chosen shortcut. This also pins the Settings picker's order.
        XCTAssertEqual(
            ChatHotkeyPreset.allCases.map(\.rawValue),
            ["optionShiftC", "controlOptionCommandC", "optionShiftV", "f14"]
        )
        XCTAssertNil(ChatHotkeyPreset(rawValue: "nonsense"))
    }

    func test_chat_display_names_are_unique_and_non_empty() {
        let names = ChatHotkeyPreset.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }
}
