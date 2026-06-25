import SwiftUI
import UIKit

// MARK: - UITextField that blocks password autofill but allows paste

/// UITextField subclass that prevents iOS from treating the field as a password/credential
/// field (which hides Paste and shows only Autofill). Paste is always allowed via menu or button.
final class PasteFriendlyTextField: UITextField {
    var onTextChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        applyAntiAutofillConfiguration()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyAntiAutofillConfiguration()
    }

    private func applyAntiAutofillConfiguration() {
        isSecureTextEntry = false
        passwordRules = nil
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        // Empty raw value — prevents Passwords / Cards autofill bar (not .password, not .oneTimeCode).
        textContentType = UITextContentType(rawValue: "")
        if #available(iOS 17.0, *) {
            // Remove QuickType accessory suggestions (Contact / Passwords / Scan).
            let assistant = inputAssistantItem
            assistant.leadingBarButtonGroups = []
            assistant.trailingBarButtonGroups = []
        }
    }

    func applyFieldKind(_ kind: PasteableFieldKind) {
        applyAntiAutofillConfiguration()
        switch kind {
        case .url:
            keyboardType = .URL
            textContentType = .URL
            font = UIFont.systemFont(ofSize: 17, weight: .regular)
        case .token, .secret:
            keyboardType = .asciiCapable
            textContentType = UITextContentType(rawValue: "")
            font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        }
        adjustsFontSizeToFitWidth = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        if action == #selector(copy(_:)) || action == #selector(cut(_:))
            || action == #selector(select(_:)) || action == #selector(selectAll(_:)) {
            return super.canPerformAction(action, withSender: sender)
        }
        // Suppress Passwords / Contact / Credit Card autofill actions.
        let name = NSStringFromSelector(action).lowercased()
        if name.contains("autofill") || name.contains("password") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func editingChanged() {
        onTextChange?()
    }
}

enum PasteableFieldKind {
    case url
    case token
    case secret
}

// MARK: - UIViewRepresentable

struct PasteableUITextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var textColor: UIColor
    var placeholderColor: UIColor
    var fieldKind: PasteableFieldKind
    var onTextChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PasteFriendlyTextField {
        let field = PasteFriendlyTextField()
        field.delegate = context.coordinator
        field.text = text
        field.returnKeyType = .done
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.textColor = textColor
        field.applyFieldKind(fieldKind)
        field.onTextChange = {
            context.coordinator.syncFromField(field)
        }
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        applyPlaceholder(to: field)
        return field
    }

    func updateUIView(_ uiView: PasteFriendlyTextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.textColor = textColor
        uiView.applyFieldKind(fieldKind)
        applyPlaceholder(to: uiView)
    }

    private func applyPlaceholder(to field: UITextField) {
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor]
        )
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteFriendlyTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        return CGSize(width: width, height: 36)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PasteableUITextField

        init(parent: PasteableUITextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            syncFromField(sender)
        }

        func syncFromField(_ sender: UITextField) {
            parent.text = sender.text ?? ""
            parent.onTextChange?()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

// MARK: - SwiftUI row with always-visible Colar button

/// API key / URL / token field with a guaranteed paste path (button always visible).
struct PasteableSecretInput: View {
    enum Style {
        case darkOnboarding
        case form
    }

    @Binding var text: String
    var placeholder: String
    var style: Style = .form
    var fieldKind: PasteableFieldKind = .secret
    var onTextChange: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var pasteHint: String?

    private var textUIColor: UIColor {
        switch style {
        case .darkOnboarding: .white
        case .form: .label
        }
    }

    private var placeholderUIColor: UIColor {
        switch style {
        case .darkOnboarding: UIColor.white.withAlphaComponent(0.35)
        case .form: .placeholderText
        }
    }

    private var accessoryTint: Color {
        switch style {
        case .darkOnboarding: .white.opacity(0.85)
        case .form: .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PasteableUITextField(
                text: $text,
                placeholder: placeholder,
                textColor: textUIColor,
                placeholderColor: placeholderUIColor,
                fieldKind: fieldKind,
                onTextChange: onTextChange
            )
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .clipped()

            if style == .darkOnboarding {
                onboardingPasteRow
            } else {
                HStack(spacing: 8) {
                    pasteButton(compact: true)
                    if !text.isEmpty {
                        clearButton
                    }
                    Spacer(minLength: 0)
                }
                pasteButton(compact: false)
            }

            if let pasteHint {
                Text(pasteHint)
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { pasteHint = nil }
        }
    }

    private var onboardingPasteRow: some View {
        HStack(spacing: 10) {
            pasteButton(compact: false)

            if !text.isEmpty {
                clearButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var clearButton: some View {
        Button {
            text = ""
            onTextChange?()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(accessoryTint.opacity(0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Limpar")
    }

    @ViewBuilder
    private func pasteButton(compact: Bool) -> some View {
        Button {
            pasteFromClipboard()
        } label: {
            if compact {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accessoryTint)
                    .frame(width: 36, height: 36)
                    .background(accessoryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                    Text(style == .darkOnboarding ? "Colar" : "Colar da área de transferência")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(style == .darkOnboarding ? .black : .white)
                .padding(.horizontal, style == .darkOnboarding ? 20 : 0)
                .frame(maxWidth: style == .darkOnboarding ? nil : .infinity)
                .frame(minWidth: style == .darkOnboarding ? 120 : nil)
                .padding(.vertical, 10)
                .background(
                    style == .darkOnboarding ? Color.white.opacity(0.92) : Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .frame(maxWidth: style == .form ? .infinity : nil)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colar da área de transferência")
    }

    private func pasteFromClipboard() {
        pasteHint = nil
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            pasteHint = "Nada na área de transferência — copie no Safari e volte aqui."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        onTextChange?()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Form row replacement for `TextField("API Key", text:)`.
struct PasteableFormSecretField: View {
    var title: String
    @Binding var text: String
    var fieldKind: PasteableFieldKind = .secret
    var onTextChange: (() -> Void)?

    var body: some View {
        PasteableSecretInput(
            text: $text,
            placeholder: title,
            style: .form,
            fieldKind: fieldKind,
            onTextChange: onTextChange
        )
    }
}

/// URL field with paste support (gateway, webhooks, etc.).
struct PasteableURLInput: View {
    @Binding var text: String
    var placeholder: String
    var style: PasteableSecretInput.Style = .form
    var onTextChange: (() -> Void)?

    var body: some View {
        PasteableSecretInput(
            text: $text,
            placeholder: placeholder,
            style: style,
            fieldKind: .url,
            onTextChange: onTextChange
        )
    }
}