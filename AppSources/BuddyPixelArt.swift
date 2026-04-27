import SwiftUI

/// Pixel art definition for one buddy. 16×16 char grid + palette.
/// Rendered at runtime via SwiftUI `Canvas` — no PNG assets, scales crisply
/// at any size, and any future "buddy variants" (idle/working tints) can be
/// done by swapping the palette without re-exporting bitmaps.
struct PixelArt {
    static let gridSize = 16

    /// Each row is exactly `gridSize` chars; `.` means transparent.
    let rows: [String]
    let palette: [Character: Color]
}

extension PixelArt {
    /// Self-check: every sprite must be exactly `gridSize × gridSize`. Easy to
    /// break by miscounting dots while editing.
    var isValid: Bool {
        rows.count == Self.gridSize && rows.allSatisfy { $0.count == Self.gridSize }
    }
}

/// Run at app startup (DEBUG builds) so a typo in one sprite trips an obvious
/// crash instead of a silently misaligned buddy.
@inline(__always)
func validateAllBuddyArt() {
    for species in BuddySpecies.allCases {
        let art = species.pixelArt
        precondition(
            art.isValid,
            "Pixel art for \(species) is malformed: rows=\(art.rows.count), widths=\(art.rows.map(\.count))"
        )
    }
}

extension BuddySpecies {
    /// 16×16 sprite for this species. Designed to be recognizable as a silhouette
    /// from across the room, not as fine art — they're placeholders that an
    /// artist (or another iteration with screenshots) can refine later.
    var pixelArt: PixelArt {
        switch self {
        case .cat:      return .cat
        case .duck:     return .duck
        case .octopus:  return .octopus
        case .fox:      return .fox
        case .ghost:    return .ghost
        case .axolotl:  return .axolotl
        case .rabbit:   return .rabbit
        case .capybara: return .capybara
        case .dragon:   return .dragon
        }
    }
}

// MARK: - Sprite catalog

private extension PixelArt {
    static let cat = PixelArt(
        rows: [
            "................",
            "..O.........O...",
            "..OO.......OO...",
            "..OOO.....OOO...",
            "..OOOOOOOOOOO...",
            ".OOOOOOOOOOOOO..",
            ".OOBBOOOOOOBBO..",
            ".OOBBOOOOOOBBO..",
            ".OOOOOOOOOOOOO..",
            ".OOOOOOPPOOOOO..",
            ".OOOOO.PP.OOOO..",
            ".OOO..OOO..OO...",
            ".OOOOOOOOOOOOO..",
            "..OOOOOOOOOOO...",
            "...OOOOOOOOO....",
            "................",
        ],
        palette: [
            "O": Color(red: 1.00, green: 0.62, blue: 0.20),  // orange tabby
            "B": .black,
            "P": Color(red: 1.00, green: 0.50, blue: 0.55),  // nose
        ]
    )

    static let duck = PixelArt(
        rows: [
            "................",
            "................",
            "......YYYY......",
            ".....YYYYYY.....",
            "....YYYYYYYY....",
            "....YYBYYYYYNN..",  // eye + beak
            "....YYYYYYYYNN..",
            "...YYYYYYYYY....",
            "..YYYYYYYYYYY...",
            "..YYYYYYYYYYY...",
            "..YYYYYYYYYYY...",
            "..YYYYYYYYYYY...",
            "..YYYYYYYYYYY...",
            "...YYYYYYYYY....",
            "................",
            "................",
        ],
        palette: [
            "Y": Color(red: 1.00, green: 0.84, blue: 0.30),
            "B": .black,
            "N": Color(red: 1.00, green: 0.45, blue: 0.10),
        ]
    )

    static let octopus = PixelArt(
        rows: [
            "................",
            "....PPPPPPPP....",
            "...PPPPPPPPPP...",
            "..PPPPPPPPPPPP..",
            ".PPPBBPPPPBBPPP.",
            ".PPPBBPPPPBBPPP.",
            ".PPPPPPPPPPPPPP.",
            ".PPPPPPPPPPPPPP.",
            ".PPPPPP..PPPPPP.",
            ".PP.PP.PP.PP.PP.",
            ".P.P.P.PP.P.P.P.",
            "P.P.P.P..P.P.P.P",
            ".P..P.P..P.P..P.",
            "....P..P..P.....",
            "................",
            "................",
        ],
        palette: [
            "P": Color(red: 0.61, green: 0.35, blue: 0.71),
            "B": .black,
        ]
    )

    static let fox = PixelArt(
        rows: [
            "................",
            ".O.O........O.O.",
            ".OO..........OO.",
            ".OOO........OOO.",
            ".OOOOOOOOOOOOOO.",
            ".OOBBOOOOOOBBOO.",
            ".OOBBOOOOOOBBOO.",
            ".OOOOOWWWWOOOOO.",
            ".OOOOWWWWWWOOOO.",
            "..OOOWWNNWWOOO..",
            "..OOOOWWWWOOOO..",
            "...OOOOOOOOOO...",
            "....OOOOOOOO....",
            ".....OOOOOO.....",
            "................",
            "................",
        ],
        palette: [
            "O": Color(red: 0.90, green: 0.49, blue: 0.13),
            "B": .black,
            "W": Color.white,
            "N": Color(red: 0.20, green: 0.13, blue: 0.10),
        ]
    )

    static let ghost = PixelArt(
        rows: [
            "................",
            "................",
            "....WWWWWWWW....",
            "...WWWWWWWWWW...",
            "..WWWWWWWWWWWW..",
            ".WWWWWWWWWWWWWW.",
            ".WWBBWWWWWWBBWW.",
            ".WWBBWWWWWWBBWW.",
            ".WWWWWWWWWWWWWW.",
            ".WWWWWMMMMWWWWW.",
            ".WWWWWWWWWWWWWW.",
            ".WWWWWWWWWWWWWW.",
            ".WWW.WWW.WWW.WW.",
            ".WW.WW.WW.WW.WW.",
            "W..WW..WW..WW..W",
            "................",
        ],
        palette: [
            "W": Color.white,
            "B": .black,
            "M": Color(red: 0.35, green: 0.35, blue: 0.45),
        ]
    )

    static let axolotl = PixelArt(
        rows: [
            "................",
            "..G..........G..",
            ".G.G........G.G.",
            ".GGGAAAAAAGGGGG.",
            "..AAAAAAAAAAAA..",
            ".AAAAAAAAAAAAAA.",
            ".AABBAAAAAABBAA.",
            ".AABBAAAAAABBAA.",
            ".AAAAAAAAAAAAAA.",
            ".AAAAAAAAAAAAAA.",
            ".AAAAAAAAAAAAAA.",
            "..AAAAAAAAAAAA..",
            "...AAAAAAAAAA...",
            "....AAAAAAAA....",
            "................",
            "................",
        ],
        palette: [
            "A": Color(red: 1.00, green: 0.72, blue: 0.79),
            "B": .black,
            "G": Color(red: 1.00, green: 0.55, blue: 0.65),
        ]
    )

    static let rabbit = PixelArt(
        rows: [
            "................",
            ".WP..........PW.",
            ".WP..........PW.",
            ".WP..........PW.",
            ".WW..........WW.",
            ".WWWWWWWWWWWWWW.",
            ".WWBBWWWWWWBBWW.",
            ".WWBBWWWWWWBBWW.",
            ".WWWWWWNNWWWWWW.",
            ".WWWWW.NN.WWWWW.",
            ".WWWW..WW..WWWW.",
            ".WWWWWWWWWWWWWW.",
            ".WWWWWWWWWWWWWW.",
            "..WWWWWWWWWWWW..",
            "................",
            "................",
        ],
        palette: [
            "W": Color.white,
            "P": Color(red: 1.00, green: 0.75, blue: 0.80),
            "B": .black,
            "N": Color(red: 1.00, green: 0.50, blue: 0.55),
        ]
    )

    static let capybara = PixelArt(
        rows: [
            "................",
            "................",
            "................",
            ".....BBBBBB.....",
            "....BBBBBBBB....",
            "...BBBBBBBBBB...",
            "...BB.BBBBBBB...",
            "..BBBBBBBBBBBB..",
            ".BBBBBBBBBBBBBB.",
            ".BBBBBBBBBBBBBB.",
            ".BBBBBBBBBBBBBB.",
            ".BBBBBBBBBBBBBB.",
            ".BBBBBBBBBBBBBB.",
            "..BB......BB....",
            "................",
            "................",
        ],
        palette: [
            "B": Color(red: 0.55, green: 0.40, blue: 0.25),
        ]
    )

    static let dragon = PixelArt(
        rows: [
            "................",
            ".G............G.",
            ".GG..........GG.",
            ".GGG........GGG.",
            ".GGGGGGGGGGGGGG.",
            ".GGBBGGGGGGBBGG.",
            ".GGBBGGGGGGBBGG.",
            ".GGGGGGGGGGGGGG.",
            ".GGGGGRRRRGGGGG.",
            ".GGGG.RRRR.GGGG.",
            ".GGGGGGGGGGGGGG.",
            ".GGGSGGGGGGSGGG.",
            ".GGGGGSGGSGGGGG.",
            "..GGGGGGGGGGGG..",
            "...GGGGGGGGGG...",
            "................",
        ],
        palette: [
            "G": Color(red: 0.30, green: 0.69, blue: 0.31),
            "B": .black,
            "R": Color(red: 0.86, green: 0.20, blue: 0.27),
            "S": Color(red: 0.55, green: 0.85, blue: 0.55),
        ]
    )
}

// MARK: - View

struct BuddyView: View {
    let species: BuddySpecies

    var body: some View {
        Canvas { ctx, size in
            let art = species.pixelArt
            let cols = art.rows.first?.count ?? PixelArt.gridSize
            let rowsCount = art.rows.count
            let pixel = floor(min(size.width / CGFloat(cols),
                                  size.height / CGFloat(rowsCount)))
            // Center the grid in the available space.
            let xOffset = (size.width - pixel * CGFloat(cols)) / 2
            let yOffset = (size.height - pixel * CGFloat(rowsCount)) / 2
            for (y, row) in art.rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let color = art.palette[ch] else { continue }
                    let rect = CGRect(
                        x: xOffset + CGFloat(x) * pixel,
                        y: yOffset + CGFloat(y) * pixel,
                        width: pixel,
                        height: pixel
                    )
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
