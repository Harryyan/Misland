import Foundation

/// Sanitize tool arguments before showing them in the notch UI (PRD §6 SEC-6).
///
/// Three concerns, in priority order:
/// 1. **ANSI escape sequences** in `Bash` tool args could move the cursor, change
///    colors, or worse if rendered through any control-code-aware view (NSTextView,
///    AttributedString from markdown). Stripped unconditionally.
/// 2. **Other control chars** (< 0x20 except `\n` `\t`, plus DEL 0x7F) can break
///    layout in subtle ways; stripped.
/// 3. **Length**: cap at 4 KB by default. Anything beyond is replaced with a
///    "…(truncated XB)" suffix so the user knows there's more.
///
/// HTML escaping is provided as a separate helper but is **not** part of `sanitize()`
/// — SwiftUI `Text` doesn't parse HTML, and applying it would visually clutter
/// every command shown in the notch. Use `htmlEscape()` only for code paths that
/// render through markdown/HTML.
public enum ArgSanitizer {
    public static let defaultMaxBytes = 4_096
    public static let truncationMarker = "…(truncated)"

    /// Default sanitize: strip ANSI + control chars, then truncate to maxBytes (UTF-8).
    ///
    /// Stripping by itself does NOT count as truncation — if cleaning ANSI noise
    /// shrinks the input below `maxBytes`, the user gets the full meaningful
    /// content with no marker. The `…(truncated)` marker only appears when (a)
    /// input exceeded a hard input cap (maxBytes×4) before regex work, or
    /// (b) the cleaned content still doesn't fit in `maxBytes`.
    public static func sanitize(_ s: String, maxBytes: Int = defaultMaxBytes) -> String {
        let inputUTF8 = s.utf8.count

        // Step 1: cap input if it's pathologically large, so the regex work below
        // is bounded. Use char-prefix (not utf8-prefix) to avoid splitting multi-byte
        // sequences. The 4× factor leaves headroom for stripping to finish under maxBytes.
        let bounded: String
        let preBounded: Bool
        if inputUTF8 > maxBytes * 4 {
            bounded = String(s.prefix(maxBytes * 2))
            preBounded = true
        } else {
            bounded = s
            preBounded = false
        }

        // Step 2: strip dangerous chars.
        let stripped = stripControlChars(stripAnsi(bounded))

        // Step 3: cap by UTF-8 byte count if still too big.
        if stripped.utf8.count <= maxBytes && !preBounded {
            return stripped
        }
        let suffixBudget = truncationMarker.utf8.count + 1   // " …(truncated)"
        let target = max(0, maxBytes - suffixBudget)
        var truncated = stripped
        while truncated.utf8.count > target, !truncated.isEmpty {
            truncated.removeLast()
        }
        return truncated + " " + truncationMarker
    }

    /// Strip CSI / OSC ANSI escape sequences. Coverage:
    /// - CSI: `ESC [ params letter`
    /// - OSC: `ESC ] data BEL` or `ESC ] data ESC \`
    /// - Lone two-char escapes: `ESC <letter>`
    public static func stripAnsi(_ s: String) -> String {
        let pattern =
            "\u{1B}\\[[0-9;?]*[ -/]*[@-~]" +    // CSI
            "|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)" +  // OSC
            "|\u{1B}[@-_]"                       // 2-char ESC seqs
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// Strip C0/C1 control characters except `\n` (0x0A) and `\t` (0x09). DEL (0x7F) is also dropped.
    public static func stripControlChars(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v < 0x20 {
                if v == 0x0A || v == 0x09 { out.append(scalar) }
                continue
            }
            if v == 0x7F { continue }                   // DEL
            if v >= 0x80 && v < 0xA0 { continue }       // C1 controls
            out.append(scalar)
        }
        return String(out)
    }

    /// HTML entity escape for code paths that render through markdown/HTML.
    /// Not applied by `sanitize()` because SwiftUI `Text` renders strings literally.
    public static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(ch)
            }
        }
        return out
    }
}
