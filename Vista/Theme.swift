//
//  Theme.swift
//  Vista
//
//  VISTA 3D design system (Design Board v1 — approved 2026-06-10).
//  One idea, everywhere: THE APP LOOKS LIKE THE SCAN.
//    - Ink ground, glowing Vista Teal primary (action/success),
//      Seam Orange accent ("something is waiting": bake pending, retry).
//    - One glowing primary button per screen. Numbers/filenames mono.
//  All tokens live here; views must never hardcode colors.
//

import SwiftUI

extension Color {
    init(vistaHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum VistaTheme {
    static let ink     = Color(vistaHex: 0x0B1014)   // app background
    static let surface = Color(vistaHex: 0x131B21)   // cards
    static let raised  = Color(vistaHex: 0x1A242C)   // chips, fields
    static let line    = Color(vistaHex: 0x243038)   // hairlines
    static let teal    = Color(vistaHex: 0x0DF2CC)   // primary / success
    static let tealDim = Color(vistaHex: 0x0A8F7A)
    static let orange  = Color(vistaHex: 0xFF8019)   // accent / waiting
    static let text    = Color(vistaHex: 0xE8F1F2)
    static let text2   = Color(vistaHex: 0x8FA3AD)
    static let onTeal  = Color(vistaHex: 0x062420)   // text on teal fills
}

/// The Vista mark: a triangulated V — the LiDAR mesh forming a valley —
/// split by the orange seam (the room-corner crease the scanner paints).
struct VistaMark: View {
    var lineWidth: CGFloat = 2.2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let p: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: x / 100 * w, y: y / 100 * h)
            }
            let l1 = p(17, 24), l2 = p(35, 24)
            let r1 = p(83, 24), r2 = p(65, 24)
            let m = p(50, 50), b = p(50, 84)

            ZStack {
                // hologram fill
                Path { path in
                    for tri in [[l1, l2, m], [l1, m, b], [r2, r1, m], [r1, m, b]] {
                        path.move(to: tri[0])
                        path.addLine(to: tri[1])
                        path.addLine(to: tri[2])
                        path.closeSubpath()
                    }
                }
                .fill(VistaTheme.teal.opacity(0.14))

                // teal wire edges
                Path { path in
                    let edges = [(l1, l2), (l2, m), (l1, m), (l1, b),
                                 (r1, r2), (r2, m), (r1, m), (r1, b)]
                    for e in edges {
                        path.move(to: e.0)
                        path.addLine(to: e.1)
                    }
                }
                .stroke(VistaTheme.teal,
                        style: StrokeStyle(lineWidth: lineWidth,
                                           lineCap: .round, lineJoin: .round))

                // orange seam
                Path { path in
                    path.move(to: m)
                    path.addLine(to: b)
                }
                .stroke(VistaTheme.orange,
                        style: StrokeStyle(lineWidth: lineWidth * 1.15,
                                           lineCap: .round))
            }
            .shadow(color: VistaTheme.teal.opacity(0.55), radius: lineWidth * 2)
        }
    }
}

/// Header lockup: mark + "VISTA 3D" wordmark. Use at the top of tabs.
struct VistaHeader: View {
    var body: some View {
        HStack(spacing: 9) {
            VistaMark(lineWidth: 1.8)
                .frame(width: 24, height: 24)
            (Text("VISTA").tracking(4)
                .font(.system(size: 17, weight: .heavy))
             + Text(" 3D")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(VistaTheme.orange))
            .foregroundColor(VistaTheme.text)
        }
    }
}

/// Primary action: glowing teal capsule. ONE per screen.
struct VistaPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(VistaTheme.onTeal)
            .padding(.vertical, 14)
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity)
            .background(VistaTheme.teal, in: Capsule())
            .shadow(color: VistaTheme.teal.opacity(configuration.isPressed ? 0.2 : 0.4),
                    radius: 14, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Accent action: orange outline — "something is waiting" (bake, retry).
struct VistaGhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(VistaTheme.orange)
            .padding(.vertical, 12)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(VistaTheme.orange.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(VistaTheme.orange, lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet tertiary action: hairline border, secondary text.
struct VistaQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(VistaTheme.text2)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .overlay(Capsule().strokeBorder(VistaTheme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension View {
    /// Standard Vista card chrome: surface, continuous corners, hairline.
    func vistaCard() -> some View {
        self.padding(16)
            .background(VistaTheme.surface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(VistaTheme.line, lineWidth: 1))
    }
}

#Preview {
    VStack(spacing: 20) {
        VistaHeader()
        VistaMark().frame(width: 96, height: 96)
        Button("Start Room Scan") {}.buttonStyle(VistaPrimaryButton())
        Button("Bake last scan") {}.buttonStyle(VistaGhostButton())
        Button("Quiet action") {}.buttonStyle(VistaQuietButton())
        Text("card").vistaCard()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(VistaTheme.ink)
}
