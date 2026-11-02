import Foundation

/// Submitted means a clipboard data request was observed, not verified document insertion.
enum PasteOutcome: String, Sendable {
    case submitted, cancelled, clipboardChanged, unconfirmed, blocked, targetChanged, writeFailed

    var isSilent: Bool { self == .unconfirmed || self == .blocked }

    var diagnosticReason: String {
        switch self {
        case .submitted: "read_observed"
        case .cancelled: "cancelled"
        case .clipboardChanged: "clipboard_changed"
        case .unconfirmed: "paste_unconfirmed"
        case .blocked: "paste_pending"
        case .targetChanged: "target_changed"
        case .writeFailed: "clipboard_write_failed"
        }
    }

    var message: String {
        switch self {
        case .submitted: ""
        case .cancelled: L10n.tr("Input cancelled; result saved")
        case .clipboardChanged: L10n.tr("Clipboard changed; result saved")
        case .unconfirmed: L10n.tr("Paste could not be confirmed. Text remains on the clipboard; check the destination before pasting manually.")
        case .blocked: L10n.tr("The previous paste is still unresolved. This result is saved in History; the clipboard was not replaced.")
        case .targetChanged: L10n.tr("Target app changed; result saved")
        case .writeFailed: L10n.tr("Could not write to the clipboard; result saved")
        }
    }
}
