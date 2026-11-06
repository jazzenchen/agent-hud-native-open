import SwiftUI
import AgentHUDCore

struct QuotaForecastDetails: View {
    let agent: AgentDescriptor
    let hint: String
    /// The look of the HUD the row is in, which the popover hands on to its own window (`IslandHoverPopover`). The
    /// details stand on a surface of that look in their window, glass included, with its hairline, which Liquid Glass
    /// leaves out for the rim it lights of its own (`HUDLook.outline(_:standIn:)`).
    @Environment(\.hudLook) private var look
    @Environment(\.drawsGlassStandIn) private var glassStandIn

    private var theme: Theme { look.theme }

    var body: some View {
        Text(hint)
            .lineSpacing(3)
            .frame(maxWidth: hint.contains("\n") ? 340 : nil, alignment: .leading)
            .font(.ui(12, .medium))
            .monospacedDigit()
            .foregroundStyle(theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(HUDSurface(RoundedRectangle(cornerRadius: 8), look: look, fill: theme.raisedSurface, contact: nil)
                .environment(\.drawsRaisedBox, true))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(look.outline(theme.cardBorder, standIn: glassStandIn)))
            .fixedSize()
            .accessibilityLabel("\(agent.displayName), \(hint)")
    }
}
