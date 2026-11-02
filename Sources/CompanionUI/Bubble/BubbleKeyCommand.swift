import AppKit

enum BubbleKeyCommand: Equatable {
    case submit, insertNewline, close, cycleModel, toggleHint, newChat

    static func from(keyCode: UInt16, charactersIgnoringModifiers: String?, modifiers: NSEvent.ModifierFlags) -> BubbleKeyCommand? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        switch keyCode {
        case 36, 76:
            if mods.isEmpty { return .submit }
            return mods == [.shift] ? .insertNewline : nil
        case 48: return mods.isEmpty ? .cycleModel : nil
        case 53: return .close
        default: break
        }
        // Characters, not key codes, so non-QWERTY layouts work.
        guard mods == [.command] else { return nil }
        switch charactersIgnoringModifiers?.lowercased() {
        case "h": return .toggleHint
        case "n": return .newChat
        default: return nil
        }
    }
}
