import SwiftUI

/// One option of a single-choice group in a `Menu`, with its glyph and a checkmark while chosen.
///
/// A `Picker` whose options are `Text` carries no image to draw, and Apple documents no image for its
/// options. A `Toggle` made with `init(_:systemImage:isOn:)` is the documented menu item that draws both its
/// symbol and its checkmark ("Populating SwiftUI menus with adaptive controls"), so each option is one,
/// switched on while it is the selection. Choosing the chosen option again leaves it chosen.
struct MenuChoice<Value: Hashable>: View {
    let title: String
    let systemImage: String
    let value: Value
    @Binding var selection: Value

    var body: some View {
        Toggle(title, systemImage: systemImage, isOn: Binding {
            selection == value
        } set: { chosen in
            if chosen { selection = value }
        })
    }
}
