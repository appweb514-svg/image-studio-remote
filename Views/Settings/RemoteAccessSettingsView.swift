import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings > Remote Access: enable the embedded Web UI server, choose the
/// port, LAN exposure and auth. Shows connection URLs and a QR code for
/// phones. The access token lives in the Keychain.
struct RemoteAccessSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemoteAccessStore.self) private var remoteAccess

    @State private var portDraft: Int = 7860
    @State private var tokenRevealed = false

    var body: some View {
        @Bindable var remoteAccess = remoteAccess

        Form {
            Section {
                Toggle("Enable Remote Web UI", isOn: $remoteAccess.isEnabled)

                if remoteAccess.isRunning {
                    Label(
                        "Serveur en cours — \(remoteAccess.localURL)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.callout)
                } else if let error = remoteAccess.startError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else if settings.remoteAccessEnabled {
                    Text("Démarrage du serveur…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                Text("Serveur")
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $portDraft, format: .number.grouping(.never))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitPort)
                    Button("Appliquer") { commitPort() }
                        .disabled(portDraft == remoteAccess.port)
                }

                Toggle("Autoriser les autres appareils du réseau (LAN / VPN)", isOn: $remoteAccess.allowLAN)
                if remoteAccess.allowLAN {
                    Text(
                        "Le serveur écoute sur toutes les interfaces. Gardez l'authentification active "
                            + "(recommandé) et utilisez NetBird/Tailscale pour un accès extérieur au LAN."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Réseau")
            } footer: {
                Text("Désactivé, le serveur n'écoute que sur 127.0.0.1 (localhost).")
            }

            Section {
                Toggle("Exiger l'authentification", isOn: $remoteAccess.requireAuth)
                    .disabled(remoteAccess.allowLAN == false && !remoteAccess.isRunning)

                HStack {
                    Text(tokenRevealed ? remoteAccess.token : "••••••••••••••••••••••••")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        tokenRevealed.toggle()
                    } label: {
                        Image(systemName: tokenRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.iconButtonCompact)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(remoteAccess.token, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.iconButtonCompact)
                    Button(role: .destructive) {
                        remoteAccess.regenerateToken()
                        remoteAccess.syncServerState()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.iconButtonCompact)
                    .help("Régénérer le token (déconnecte tous les appareils)")
                }
            } header: {
                Text("Authentification")
            } footer: {
                Text("Token stocké dans le trousseau macOS. Le navigateur s'authentifie une fois via le formulaire de connexion ; les clients API utilisent « Authorization: Bearer <token> ».")
            }

            Section("Accès") {
                urlRow("Local", remoteAccess.localURL)
                if remoteAccess.allowLAN {
                    urlRow("Réseau", remoteAccess.networkURL)
                }
                HStack {
                    Spacer()
                    qrCodeView(for: remoteAccess.allowLAN ? remoteAccess.networkURL : remoteAccess.localURL)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .help("Scanner pour ouvrir depuis un téléphone")
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portDraft = remoteAccess.port }
    }

    private func commitPort() {
        let clamped = min(max(portDraft, 1024), 65_535)
        portDraft = clamped
        remoteAccess.port = clamped
        remoteAccess.syncServerState()
    }

    @ViewBuilder
    private func urlRow(_ label: String, _ url: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Text(url)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.iconButtonCompact)
            .help("Copier l'URL")
        }
    }

    private func qrCodeView(for string: String) -> Image {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return Image(systemName: "qrcode")
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        if let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) {
            return Image(decorative: cgImage, scale: 1.0, orientation: .up)
        }
        return Image(systemName: "qrcode")
    }
}
