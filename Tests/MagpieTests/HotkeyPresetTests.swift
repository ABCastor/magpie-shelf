import XCTest
import Carbon.HIToolbox
@testable import Magpie

final class HotkeyPresetTests: XCTestCase {
    func test_key_codes() {
        XCTAssertEqual(HotkeyPreset.optionShiftS.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(HotkeyPreset.controlOptionCommandS.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(HotkeyPreset.optionShiftD.keyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(HotkeyPreset.f13.keyCode, UInt32(kVK_F13))
    }

    func test_modifiers_use_carbon_masks_not_nsevent_flags() {
        XCTAssertEqual(HotkeyPreset.optionShiftS.carbonModifiers, UInt32(optionKey | shiftKey))
        XCTAssertEqual(HotkeyPreset.optionShiftD.carbonModifiers, UInt32(optionKey | shiftKey))
        XCTAssertEqual(
            HotkeyPreset.controlOptionCommandS.carbonModifiers,
            UInt32(controlKey | optionKey | cmdKey)
        )
    }

    func test_f13_takes_no_modifiers() {
        XCTAssertEqual(HotkeyPreset.f13.carbonModifiers, 0)
    }

    func test_every_preset_is_a_distinct_combination() {
        let combos = HotkeyPreset.allCases.map { [$0.keyCode, $0.carbonModifiers] }
        XCTAssertEqual(Set(combos).count, HotkeyPreset.allCases.count)
    }

    func test_no_preset_collides_with_the_status_menu_shortcuts() {
        // ⌥⇧N (New Shelf) and ⌥⇧A (New Shelf From Clipboard) are already
        // owned by the status menu — a preset matching either would shadow it.
        let taken: Set<[UInt32]> = [
            [UInt32(kVK_ANSI_N), UInt32(optionKey | shiftKey)],
            [UInt32(kVK_ANSI_A), UInt32(optionKey | shiftKey)],
        ]
        for preset in HotkeyPreset.allCases {
            XCTAssertFalse(
                taken.contains([preset.keyCode, preset.carbonModifiers]),
                "\(preset.rawValue) collides with an existing menu key equivalent"
            )
        }
    }

    func test_raw_values_are_pinned() {
        // @AppStorage persists the raw value, so a rename silently resets the
        // user's chosen shortcut to the default. Pinning the literals is the
        // only form of this test that can actually fail — round-tripping
        // `HotkeyPreset(rawValue: $0.rawValue)` is compiler-guaranteed for a
        // String-backed enum and would survive exactly the rename it claims
        // to guard against. This also pins allCases order, which is the order
        // the Settings picker renders.
        XCTAssertEqual(
            HotkeyPreset.allCases.map(\.rawValue),
            ["optionShiftS", "controlOptionCommandS", "optionShiftD", "f13"]
        )
        XCTAssertNil(HotkeyPreset(rawValue: "nonsense"))
    }

    func test_display_names_are_unique_and_non_empty() {
        let names = HotkeyPreset.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }
}
