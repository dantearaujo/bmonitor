import SwiftUI

private enum ApplicationLanguage: String, CaseIterable, Identifiable {
    case automatic
    case english = "en"
    case portuguese = "pt-BR"
    case turkish = "tr"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automático (idioma do Mac)"
        case .english: "English"
        case .portuguese: "Português (Brasil)"
        case .turkish: "Türkçe"
        }
    }

    private static let preference = "AppleLanguages"

    static func savedChoice() -> Self {
        guard let domain = Bundle.main.bundleIdentifier,
            let preferred = UserDefaults.standard.persistentDomain(forName: domain)?[preference] as? [String],
            let first = preferred.first
        else { return .automatic }

        switch Locale(identifier: first).language.languageCode?.identifier {
        case "en": return .english
        case "pt": return .portuguese
        case "tr": return .turkish
        default: return .automatic
        }
    }

    func save() {
        // O bundle resolve o idioma antes de o SwiftUI construir as janelas e os menus.
        // Sem preferência do app, o macOS usa sua lista de idiomas e o idioma base do bundle.
        if self == .automatic {
            UserDefaults.standard.removeObject(forKey: Self.preference)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.preference)
        }
    }
}

struct LanguageSettings: View {
    @State private var language = ApplicationLanguage.savedChoice()

    var body: some View {
        Form {
            Picker("Idioma do aplicativo", selection: $language) {
                ForEach(ApplicationLanguage.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .onChange(of: language) { _, choice in choice.save() }

            Text("Feche e reabra o bmonitor para aplicar o idioma.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
