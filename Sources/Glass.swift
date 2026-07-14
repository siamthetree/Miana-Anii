import SwiftUI

extension View {

    @ViewBuilder
    func glassPanel<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func glassControl<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                self.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            self.background(tint ?? .black.opacity(0.45), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        }
    }

  
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
