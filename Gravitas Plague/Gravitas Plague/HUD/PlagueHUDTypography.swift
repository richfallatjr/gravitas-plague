import UIKit

enum PlagueHUDTypography {
    static let textColor = UIColor(
        red: 0.92,
        green: 0.86,
        blue: 0.72,
        alpha: 1.0
    )

    static func instruction(size: CGFloat = 34) -> UIFont {
        UIFont(name: "Baskerville-SemiBold", size: size)
            ?? UIFont(name: "Georgia-Bold", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func title(size: CGFloat = 72) -> UIFont {
        UIFont(name: "Baskerville-Bold", size: size)
            ?? UIFont(name: "Baskerville-SemiBold", size: size)
            ?? UIFont(name: "Georgia-Bold", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .bold)
    }

    static func subtitle(size: CGFloat = 34) -> UIFont {
        UIFont(name: "Baskerville", size: size)
            ?? UIFont(name: "Baskerville-SemiBold", size: size)
            ?? UIFont(name: "Georgia", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .regular)
    }
}
