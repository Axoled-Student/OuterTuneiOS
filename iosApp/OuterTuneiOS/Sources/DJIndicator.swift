import SwiftUI

/// Three bars that rise and fall, the way a level meter does.
///
/// Used while the DJ is choosing what comes next and again while it is
/// talking. Planning a set takes the server several seconds, and a static
/// icon during those seconds is indistinguishable from a button that did
/// nothing - which is exactly what it looked like.
///
/// The phases are offset rather than random so the three bars never line up
/// into one block, and the whole thing collapses to a still shape when
/// `isAnimating` is false so it can sit next to a finished line without
/// drawing the eye.
struct DJIndicator: View {
    var isAnimating: Bool = true
    var color: Color = AppTheme.accent
    var barWidth: CGFloat = 2.5
    var height: CGFloat = 14

    /// Each bar's own rhythm. Different durations mean the pattern does not
    /// repeat on a beat you can follow, which is what makes it read as a
    /// level rather than a spinner.
    private let bars: [(low: CGFloat, duration: Double, delay: Double)] = [
        (0.35, 0.62, 0.0),
        (0.20, 0.48, 0.18),
        (0.45, 0.74, 0.09),
    ]

    @State private var isUp = false

    var body: some View {
        HStack(alignment: .center, spacing: barWidth) {
            ForEach(bars.indices, id: \.self) { index in
                let bar = bars[index]
                Capsule()
                    .fill(color)
                    .frame(width: barWidth,
                           height: height * (isUp && isAnimating ? 1.0 : bar.low))
                    .animation(isAnimating
                               ? .easeInOut(duration: bar.duration)
                                   .repeatForever(autoreverses: true)
                                   .delay(bar.delay)
                               : .easeOut(duration: 0.2),
                               value: isUp)
            }
        }
        .frame(height: height, alignment: .center)
        .onAppear { isUp = true }
        // Restarting the cycle on the way in stops the bars from resuming
        // mid-stride with all three at the same height.
        .onChange(of: isAnimating) { running in
            isUp = false
            guard running else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isUp = true
            }
        }
    }
}
