import AppKit

var checks = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
let visible = CGRect(x: 0, y: 30, width: 1440, height: 845)
let leftDisplay = CGRect(x: -1280, y: -200, width: 1280, height: 1000)
let size = CGSize(width: 340, height: 82)

func placed(_ caret: CGRect, screens: [CGRect] = [visible], size: CGSize = size) -> CGRect {
    CaretPlacement.frame(size: size, caret: caret, screens: screens, fallbackPoint: .zero)
}
func clear(_ frame: CGRect, _ caret: CGRect) -> Bool {
    !frame.intersects(caret.insetBy(dx: -0.5, dy: 0))
}

let middle = CGRect(x: 600, y: 450, width: 1, height: 20)
let below = placed(middle)
check(below.maxY == middle.minY - 8, "Prefer an eight-point gap below the caret")
check(below.minX == middle.minX, "Align to the caret horizontally")
check(clear(below, middle), "Below placement must not overlap the caret")

let bottom = CGRect(x: 600, y: 35, width: 0, height: 20)
let above = placed(bottom)
check(above.minY == bottom.maxY + 8, "Flip above near the bottom edge")
check(visible.contains(above) && clear(above, bottom), "Above placement must stay visible and clear")
let top = CGRect(x: 1430, y: 850, width: 1, height: 20)
let clamped = placed(top)
check(clamped.maxX == visible.maxX, "Clamp at right edge")
check(clamped.maxY == top.minY - 8 && visible.contains(clamped), "Place below near top edge")

let negative = CGRect(x: -1220, y: -150, width: 0, height: 18)
let secondary = placed(negative, screens: [visible, leftDisplay])
check(leftDisplay.contains(secondary), "Use the caret's negative-coordinate monitor")
check(secondary.minY == negative.maxY + 8, "Flip above at secondary monitor bottom")
check(clear(secondary, negative), "Secondary placement must not overlap")

let shallow = CGRect(x: -500, y: -100, width: 900, height: 100)
let shallowCaret = CGRect(x: -200, y: -60, width: 0, height: 20)
let side = placed(shallowCaret, screens: [shallow])
check(side.minX == shallowCaret.maxX + 8, "Use a side when neither above nor below fits")
check(shallow.contains(side) && clear(side, shallowCaret), "Side placement must stay visible and clear")
let leftOnlyCaret = CGRect(x: 300, y: -60, width: 0, height: 20)
let left = placed(leftOnlyCaret, screens: [shallow])
check(left.maxX == leftOnlyCaret.minX - 8, "Use left side when right side cannot fit")

// Gap cannot fit, but a fixed corner can avoid the insertion point itself.
let narrow = CGRect(x: 0, y: 0, width: 350, height: 100)
let edgeCaret = CGRect(x: 345, y: 45, width: 0, height: 20)
let edge = placed(edgeCaret, screens: [narrow])
check(narrow.contains(edge) && clear(edge, edgeCaret), "Fixed-edge fallback avoids actual caret when possible")

let fallback = CaretPlacement.frame(size: size, caret: nil, screens: [visible, leftDisplay],
                               fallbackPoint: CGPoint(x: -500, y: 100))
check(leftDisplay.contains(fallback), "Missing AX geometry falls back to pointer's monitor")
check(fallback.minY == leftDisplay.minY + 28, "Fallback uses a fixed bottom-screen position")
let dockFallback = CaretPlacement.frame(size: size, caret: nil, screens: [visible, leftDisplay],
                                   fallbackPoint: CGPoint(x: 700, y: 0))
check(visible.contains(dockFallback), "Pointer outside visible frame still selects nearest screen")
let empty = CaretPlacement.frame(size: size, caret: nil, screens: [], fallbackPoint: CGPoint(x: 5, y: 7))
check(empty.origin == CGPoint(x: 5, y: 7), "Empty screen list is deterministic")

let axLeft = CGRect(x: -1000, y: 1020, width: 0, height: 20)
let converted = CaretPosition.appKitRect(fromAX: axLeft, primaryFrame: primary)
check(converted == CGRect(x: -1000, y: -140, width: 0, height: 20), "AX conversion uses primary top, preserving negative coordinates")
let axAbove = CGRect(x: 300, y: -400, width: 1, height: 18)
check(CaretPosition.appKitRect(fromAX: axAbove, primaryFrame: primary).minY == 1282,
      "AX conversion supports displays above the primary display")

// Cover edge and corner combinations, including zero-width insertion points.
for screen in [visible, leftDisplay] {
    for x in stride(from: screen.minX, through: screen.maxX, by: 40) {
        for y in stride(from: screen.minY, through: screen.maxY - 20, by: 25) {
            let caret = CGRect(x: x, y: y, width: 0, height: 20)
            let result = placed(caret, screens: [screen])
            check(screen.contains(result), "Grid placement must stay inside the visible frame")
            check(clear(result, caret), "Grid placement must not cover the caret")
        }
    }
}
print("Passed \(checks) caret geometry and placement checks")
