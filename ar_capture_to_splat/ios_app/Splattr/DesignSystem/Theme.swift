//
//  Theme.swift
//  The whole visual identity in one file. Match references:
//    - Astronaut helmet (warm halo on near-black)
//    - Future Tech card (electric blue accent + dark surface)
//    - Balenciaga editorial (oversized type + thin technical labels)
//

import SwiftUI

enum Theme {

    // MARK: Palette
    enum Color {
        // Backgrounds
        static let ink         = SwiftUI.Color(red: 0.030, green: 0.031, blue: 0.039)  // #08080A
        static let inkSurface  = SwiftUI.Color(red: 0.060, green: 0.063, blue: 0.078)  // #0F1014
        static let inkRaised   = SwiftUI.Color(red: 0.090, green: 0.094, blue: 0.110)  // #17181C
        // Hairlines & dividers
        static let hairline    = SwiftUI.Color.white.opacity(0.10)
        static let hairlineHi  = SwiftUI.Color.white.opacity(0.18)
        // Type
        static let textPrimary = SwiftUI.Color(white: 0.96)
        static let textMuted   = SwiftUI.Color(white: 0.62)
        static let textDim     = SwiftUI.Color(white: 0.40)
        // Accents
        static let halo        = SwiftUI.Color(red: 1.00, green: 0.604, blue: 0.180)  // #FF9A2E
        static let haloDeep    = SwiftUI.Color(red: 0.92, green: 0.42,  blue: 0.06)
        static let electric    = SwiftUI.Color(red: 0.227, green: 0.478, blue: 1.00)  // #3A7AFF
        static let danger      = SwiftUI.Color(red: 1.00, green: 0.30,  blue: 0.30)
        static let success     = SwiftUI.Color(red: 0.42, green: 0.96,  blue: 0.66)
    }

    // MARK: Background helpers
    enum Background {
        static let app: LinearGradient = LinearGradient(
            colors: [Color.ink, Color.ink.opacity(0.92)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Typography
    enum Font {
        // Display: oversized headline, like Balenciaga reference.
        static func display(_ size: CGFloat = 56) -> SwiftUI.Font {
            .system(size: size, weight: .heavy, design: .default)
                .width(.condensed)
        }
        static func title(_ size: CGFloat = 28) -> SwiftUI.Font {
            .system(size: size, weight: .bold, design: .default)
        }
        static func body(_ size: CGFloat = 16) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .default)
        }
        // Mono labels for technical readouts (session id, run id, IPs).
        static func mono(_ size: CGFloat = 12) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .monospaced)
        }
        static func caption(_ size: CGFloat = 11) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .default)
        }
    }

    // MARK: Geometry
    enum Layout {
        static let cardCornerRadius: CGFloat = 22
        static let pillCornerRadius: CGFloat = 999
        static let cardPadding: CGFloat = 22
        static let screenPadding: CGFloat = 22
    }
}
