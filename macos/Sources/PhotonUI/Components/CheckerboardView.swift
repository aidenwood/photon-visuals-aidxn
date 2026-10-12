import SwiftUI

/// Static alpha reference; no timers or per-frame UI drawing.
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.09)))
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(Color(white: 0.16)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
