import Foundation

/// 9 built-in pixel buddies. Per PRD §1 decision A — user manually picks one
/// in Settings; we don't try to mirror Claude Code's internal buddy hashing.
public enum BuddySpecies: String, CaseIterable, Sendable {
    case cat
    case duck
    case octopus
    case fox
    case ghost
    case axolotl
    case rabbit
    case capybara
    case dragon

    public var emoji: String {
        switch self {
        case .cat:      return "🐱"
        case .duck:     return "🦆"
        case .octopus:  return "🐙"
        case .fox:      return "🦊"
        case .ghost:    return "👻"
        case .axolotl:  return "🦎"
        case .rabbit:   return "🐰"
        case .capybara: return "🦫"
        case .dragon:   return "🐉"
        }
    }

    public var displayName: String {
        switch self {
        case .cat:      return "Cat"
        case .duck:     return "Duck"
        case .octopus:  return "Octopus"
        case .fox:      return "Fox"
        case .ghost:    return "Ghost"
        case .axolotl:  return "Axolotl"
        case .rabbit:   return "Rabbit"
        case .capybara: return "Capybara"
        case .dragon:   return "Dragon"
        }
    }
}
