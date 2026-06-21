import Foundation

/// Maps a spoken phrase to a teleprompter control action. Like `HUDVoiceCommand`, the
/// match is deliberately **strict** — only a tight whole-phrase match fires, so a control
/// word that merely appears *inside* a sentence the reader is speaking ("…we move faster
/// than before…") never triggers. A leading filler ("ok", "hey", …) is tolerated.
///
/// Pure and side-effect-free, so it's fully unit-tested without audio or hardware.
enum TeleprompterCommand: Equatable {
    case next       // advance one line
    case back       // go back one line
    case pause      // hold the auto-pacing
    case resume     // resume after a pause
    case restart    // jump back to the top
    case stop       // end the teleprompter session
    case faster     // nudge the pace up
    case slower     // nudge the pace down

    static func parse(_ text: String) -> TeleprompterCommand? {
        // Lowercase, strip punctuation, collapse whitespace, drop leading filler.
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        let core = words.drop(while: { filler.contains($0) }).joined(separator: " ")

        switch core {
        case "next", "next line", "forward", "skip", "skip line", "next one":
            return .next
        case "back", "go back", "previous", "previous line", "step back", "last line":
            return .back
        case "pause", "hold", "hold on", "wait", "pause teleprompter":
            return .pause
        case "resume", "go on", "keep going", "play", "continue", "carry on":
            return .resume
        case "restart", "start over", "from the top", "back to the top", "beginning", "from the start":
            return .restart
        case "stop", "stop teleprompter", "close teleprompter", "end teleprompter", "exit teleprompter", "close", "exit":
            return .stop
        case "faster", "go faster", "speed up", "quicker", "speed it up":
            return .faster
        case "slower", "go slower", "slow down", "slow it down", "too fast":
            return .slower
        default:
            return nil
        }
    }
}
