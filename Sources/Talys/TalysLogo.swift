import CoreGraphics

/// The Talys cracked-egg mark, as SVG path data in a 100×120 design space (y-down).
/// Shared by the bar's brand pill and `scripts/make-icon` (which renders the app icon and
/// `Resources/logo.svg`), so keep it free of AppKit/SwiftUI. Paste new artwork's `d` strings here.
public enum TalysLogo {
    public static let designSize = CGSize(width: 100, height: 120)

    /// Stroke widths the artwork was drawn with, in design units.
    public static let shellStroke: CGFloat = 2.8
    public static let spotStroke: CGFloat = 2.4

    /// Top shell (wobbly dome, teeth down) and bottom shell (wonky bowl, teeth up).
    public static var shells: CGPath {
        path([
            "M18.5 52.5 C17.5 40 22 27 31 18.5 C39.5 11 47.5 8.5 50.5 9 C56 9.8 64 13.5 71.5 21 C79.5 30 83.5 41 82 52 L76 50.5 L72.5 58 L67 48 L61.5 57.5 L55 46.5 L49.5 56 L43 47.5 L37.5 58.5 L31 48 L25.5 56.5 L20.5 50.5 Z",
            "M18 71.5 L23 73 L28.5 64 L34 74.5 L40.5 63.5 L46 75 L52.5 64 L58 74 L64.5 63 L70 73.5 L76.5 65 L82.5 72 C84 86 78 100 66.5 108 C58 113.5 43 114.5 33 109 C22.5 102.5 16.5 88 18 71.5 Z",
        ])
    }

    /// The eyes peeking out through the crack.
    public static var eyes: CGPath {
        path([
            "M29 55 Q34.5 51.5 40 55.5 Q44.5 58.5 46 62 Q40.5 65.5 34 62.5 Q28.5 59.5 29 55 Z",
            "M71.5 54.5 Q66 51 60.5 55 Q55.5 58.5 54 62.5 Q59.5 66 66 62 Q72 58.5 71.5 54.5 Z",
        ])
    }

    /// Doodle triangles on both shells.
    public static var spots: CGPath {
        path([
            "M33 23 L39 33.5 L27.5 31.5 Z",
            "M48.5 16.5 L54 27 L43.5 25.5 Z",
            "M65 25 L72 35 L58 34.5 Z",
            "M40 36.5 L47.5 38 L42 46 Z",
            "M56 37 L62.5 36 L61 46.5 Z",
            "M30 83.5 L37.5 85 L32.5 94 Z",
            "M46 86 L54 84.5 L52 97 Z",
            "M64 82 L71.5 84.5 L66 93 Z",
            "M35.5 97.5 L43 96 L41 107.5 Z",
            "M55.5 96.5 L63.5 99 L57.5 108 Z",
        ])
    }

    /// Scale + offset that fits the design space centered inside `rect` (y-down).
    public static func transform(fitting rect: CGRect) -> CGAffineTransform {
        let k = min(rect.width / designSize.width, rect.height / designSize.height)
        let dx = rect.minX + (rect.width - designSize.width * k) / 2
        let dy = rect.minY + (rect.height - designSize.height * k) / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: k, y: k)
    }

    /// Parses absolute SVG path data using M, L, Q, C and Z — all the artwork needs.
    static func path(_ data: [String]) -> CGPath {
        let p = CGMutablePath()
        for d in data {
            var tokens = d.split(whereSeparator: { $0 == " " || $0 == "," })[...]
            var command: Character = "M"
            func point() -> CGPoint {
                let x = Double(tokens.popFirst() ?? "") ?? 0
                let y = Double(tokens.popFirst() ?? "") ?? 0
                return CGPoint(x: x, y: y)
            }
            while let token = tokens.first {
                if let c = token.first, c.isLetter {
                    command = c
                    tokens = tokens.dropFirst()
                    // Commands may be glued to their first number ("M18.5").
                    if token.count > 1 { tokens.insert(Substring(token.dropFirst()), at: tokens.startIndex) }
                    if c == "Z" || c == "z" { p.closeSubpath(); continue }
                }
                switch command {
                case "M": p.move(to: point()); command = "L"
                case "L": p.addLine(to: point())
                case "Q": let c1 = point(); p.addQuadCurve(to: point(), control: c1)
                case "C": let c1 = point(), c2 = point(); p.addCurve(to: point(), control1: c1, control2: c2)
                default: tokens = tokens.dropFirst()
                }
            }
        }
        return p
    }
}
