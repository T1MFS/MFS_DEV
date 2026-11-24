import CryptoKit
import HealthKit
import SwiftUI
import UniformTypeIdentifiers

/// Secrets and client identities live in the Keychain, never in UserDefaults.
enum ServiceKeychain {
    private static let service = "MFS.ServiceSecrets"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    static func hasSecret(for id: UUID) -> Bool {
        var q = query(id)
        q[kSecReturnData as String] = false
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func secret(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ value: String, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func deleteSecret(for id: UUID) { SecItemDelete(query(id) as CFDictionary) }

    /// Value to send in the header: the secret, or its SHA-1 hex digest for Nightscout-style API secrets.
    static func headerValue(for connection: ServiceConnection) -> String? {
        guard let secret = secret(for: connection.id) else { return nil }
        guard connection.hashSecretSHA1 else { return secret }
        return Insecure.SHA1.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func importIdentity(p12: Data, password: String, label: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw ServiceKeychainError.importFailed(status)
        }
        deleteIdentity(label: label)
        let add = SecItemAdd([kSecValueRef as String: identity, kSecAttrLabel as String: label] as CFDictionary, nil)
        guard add == errSecSuccess else { throw ServiceKeychainError.importFailed(add) }
    }

    static func deleteIdentity(label: String) {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label] as CFDictionary)
    }
}

enum ServiceKeychainError: LocalizedError {
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .importFailed(let status): return "Could not import the certificate. Check the file and password (code \(status))."
        }
    }
}

struct ServiceConnectionsView: View {
    @EnvironmentObject private var store: ServiceConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ServiceConnection?
    @State private var healthMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Services") {
                    ForEach(store.connections) { connection in
                        Button { editing = connection } label: {
                            VStack(alignment: .leading) {
                                Text(connection.name).foregroundStyle(.primary)
                                Text("\(connection.baseURL) · \(connection.auth.label)").font(.footnote).foregroundStyle(.secondary)
                                SecurityBadgeView(badge: SecurityBadge.make(for: connection))
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let connection = store.connections[index]
                            ServiceKeychain.deleteSecret(for: connection.id)
                            if let label = connection.identityLabel { ServiceKeychain.deleteIdentity(label: label) }
                            if let label = connection.caLabel { MutualTLSKeychain.deleteCA(label: label) }
                            store.delete(connection.id)
                        }
                    }
                    Menu {
                        Button("Nightscout (shared secret)") { editing = .nightscout() }
                        Button("Client certificate (mTLS)") { editing = .mutualTLSService() }
                        Button("Other") { editing = ServiceConnection(name: "", baseURL: "https://") }
                    } label: {
                        Label("Add service", systemImage: "plus")
                    }
                }

                Section {
                    ForEach(HealthDataKind.allCases) { kind in
                        Toggle(kind.label, isOn: Binding(
                            get: { store.healthKinds.contains(kind) },
                            set: { on in if on { store.healthKinds.insert(kind) } else { store.healthKinds.remove(kind) } }))
                    }
                    Button(store.healthRequested ? "Review Apple Health access" : "Connect Apple Health", systemImage: "heart.text.square") {
                        Task { await requestHealth() }
                    }
                    .disabled(store.healthKinds.isEmpty)
                    if let healthMessage { Text(healthMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Read only. iOS does not tell apps whether read access was granted; change it in Settings > Health > Data Access.")
                }
            }
            .navigationTitle("Service connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { connection in
                ServiceConnectionForm(connection: connection)
            }
        }
    }

    private func requestHealth() async {
        guard HKHealthStore.isHealthDataAvailable() else { healthMessage = "Apple Health is not available on this device."; return }
        var types = Set<HKObjectType>()
        for kind in store.healthKinds {
            switch kind {
            case .heartRate: types.insert(HKQuantityType(.heartRate))
            case .sleep: types.insert(HKCategoryType(.sleepAnalysis))
            case .heartRateVariability: types.insert(HKQuantityType(.heartRateVariabilitySDNN))
            }
        }
        do {
            try await HKHealthStore().requestAuthorization(toShare: [], read: types)
            store.markHealthRequested()
            healthMessage = "Permission sheet completed."
        } catch {
            healthMessage = "Apple Health request failed: \(error.localizedDescription)"
        }
    }
}

private struct ServiceConnectionForm: View {
    @EnvironmentObject private var store: ServiceConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State var connection: ServiceConnection
    @State private var secret = ""
    @State private var certificatePassword = ""
    @State private var showImporter = false
    @State private var importingCA = false
    @State private var importMessage: String?
    @State private var report: SecurityReport?
    @State private var checking = false
    @State private var pendingEvents: [String] = []
    @State private var pendingChange: (change: SecurityChange, snapshot: SecuritySnapshot)?
    @State private var confirmLower: SecurityLevel?

    private var hasSavedSecret: Bool { ServiceKeychain.hasSecret(for: connection.id) }
    private var needsSecret: Bool { connection.auth == .sharedSecretHeader || connection.auth == .bearerToken }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    TextField("Name", text: $connection.name)
                    TextField("https://", text: $connection.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Enabled", isOn: $connection.enabled)
                }
                Section("Authentication") {
                    Picker("Method", selection: $connection.auth) {
                        ForEach(ServiceAuthMethod.allCases) { Text($0.label).tag($0) }
                    }
                    if connection.auth == .sharedSecretHeader {
                        TextField("Header name", text: $connection.headerName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Send SHA-1 of the secret", isOn: $connection.hashSecretSHA1)
                    }
                    if needsSecret {
                        SecureField(hasSavedSecret ? "Secret saved; type to replace" : "Secret", text: $secret)
                    }
                    if connection.auth == .mutualTLS {
                        if let label = connection.identityLabel {
                            Label("Certificate imported", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                            Text(label).font(.footnote).foregroundStyle(.secondary)
                        }
                        SecureField("Certificate file password", text: $certificatePassword)
                        Button(connection.identityLabel == nil ? "Import .p12 certificate" : "Replace certificate", systemImage: "doc.badge.plus") {
                            importingCA = false
                            showImporter = true
                        }
                        if connection.caLabel != nil {
                            Label("Server CA imported", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                        }
                        Button(connection.caLabel == nil ? "Import server CA (.der/.cer)" : "Replace server CA", systemImage: "building.columns") {
                            importingCA = true
                            showImporter = true
                        }
                        if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.red) }
                    }
                }
                securitySection
                if !connection.issues.isEmpty {
                    Section { ForEach(connection.issues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) } }
                }
            }
            .navigationTitle(connection.name.isEmpty ? "New service" : connection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!connection.issues.isEmpty || (needsSecret && secret.isEmpty && !hasSavedSecret))
                }
            }
            .confirmationDialog("Lower the required security?", isPresented: Binding(get: { confirmLower != nil }, set: { if !$0 { confirmLower = nil } }), titleVisibility: .visible) {
                if let level = confirmLower {
                    Button("Allow \(level.shortLabel) for this service", role: .destructive) { lowerRequirement(to: level) }
                }
                Button("Keep current requirement", role: .cancel) {}
            } message: {
                Text("Uploads to this service will be allowed over a weaker connection. This is recorded in the security history and shown on the service.")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importingCA ? [.x509Certificate] : [.pkcs12]) { result in
                if importingCA { importCA(result) } else { importCertificate(result) }
            }
        }
    }

    private func importCertificate(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let label = connection.identityLabel ?? "MFS.mtls.\(connection.id.uuidString)"
            try ServiceKeychain.importIdentity(p12: try Data(contentsOf: url), password: certificatePassword, label: label)
            connection.identityLabel = label
            certificatePassword = ""
            importMessage = nil
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private var requiredBinding: Binding<SecurityLevel> {
        Binding(get: { connection.requiredSecurity }, set: { level in
            if level < connection.requiredSecurity {
                confirmLower = level
            } else if level > connection.requiredSecurity {
                connection.minimumSecurity = level
                pendingEvents.append("You raised the required security to \(level.shortLabel).")
            }
        })
    }

    @ViewBuilder private var securitySection: some View {
        Section {
            SecurityBadgeView(badge: SecurityBadge.make(for: connection))
            Picker("Require at least", selection: requiredBinding) {
                ForEach(SecurityLevel.allCases) { Text($0.shortLabel).tag($0) }
            }
            Text(connection.requiredSecurity.detail).font(.footnote).foregroundStyle(.secondary)
            Button(checking ? "Checking..." : "Test security", systemImage: "checkmark.shield") {
                Task { await runSecurityCheck() }
            }
            .disabled(checking || !connection.issues.isEmpty)
            if let report { securityReportRows(report) }
        } header: {
            Text("Security")
        } footer: {
            Text("MFS never lowers security by itself. If the connection gets weaker or the server's certificate changes, uploads stop until you review and accept it here.")
        }
        let history = store.securityEvents.filter { $0.connectionID == connection.id }.suffix(10).reversed()
        if !history.isEmpty || !pendingEvents.isEmpty {
            Section("Security history") {
                ForEach(pendingEvents, id: \.self) { Text("\($0) (not saved yet)").font(.footnote) }
                ForEach(Array(history)) { event in
                    VStack(alignment: .leading) {
                        Text(event.message).font(.footnote)
                        Text(event.date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func securityReportRows(_ report: SecurityReport) -> some View {
        ForEach(report.steps) { step in
            Label {
                VStack(alignment: .leading) {
                    Text(step.title).font(.subheadline)
                    Text(step.detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: step.symbol)
            }
        }
        if let failure = report.failure {
            VStack(alignment: .leading, spacing: 4) {
                Text("What you can do").font(.subheadline)
                ForEach(failure.suggestions, id: \.self) { Text("• \($0)").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        if let snapshot = report.snapshot {
            Text("Result: \(snapshot.level.shortLabel). \(snapshot.level.detail)").font(.footnote)
            if snapshot.level < connection.requiredSecurity {
                Text("Below the required \(connection.requiredSecurity.shortLabel). Fix the setup, or deliberately allow the lower level for this service.")
                    .font(.footnote).foregroundStyle(.red)
                Button("Allow \(snapshot.level.shortLabel) for this service...", systemImage: "exclamationmark.shield") {
                    confirmLower = snapshot.level
                }
            }
        }
        if let pendingChange {
            VStack(alignment: .leading, spacing: 4) {
                Label(pendingChange.change.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Uploads are blocked until you accept this.").font(.footnote).foregroundStyle(.secondary)
                Button("Accept this change") { acceptPendingChange() }
            }
        }
    }

    private func runSecurityCheck() async {
        checking = true
        defer { checking = false }
        let result = await ConnectionSecurityChecker(connection: connection).check()
        report = result
        pendingChange = nil
        guard let snapshot = result.snapshot else {
            if let failure = result.failure { pendingEvents.append("Security check failed: \(failure.explanation)") }
            return
        }
        let change = SecurityChange.compare(previous: connection.lastSnapshot, current: snapshot)
        if change.needsAcknowledgement {
            pendingChange = (change, snapshot)
            pendingEvents.append("\(change.summary) Waiting for your decision.")
        } else {
            connection.lastSnapshot = snapshot
            if change != .unchanged { pendingEvents.append("\(change.summary) Now: \(snapshot.level.shortLabel).") }
        }
    }

    private func acceptPendingChange() {
        guard let pendingChange else { return }
        connection.lastSnapshot = pendingChange.snapshot
        pendingEvents.append("You accepted: \(pendingChange.change.summary) Now: \(pendingChange.snapshot.level.shortLabel).")
        self.pendingChange = nil
    }

    private func lowerRequirement(to level: SecurityLevel) {
        connection.minimumSecurity = level
        pendingEvents.append("You lowered the required security to \(level.shortLabel).")
        confirmLower = nil
    }

    private func importCA(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let label = connection.caLabel ?? "MFS.mtls.ca.\(connection.id.uuidString)"
            try MutualTLSKeychain.importCA(der: try Data(contentsOf: url), label: label)
            connection.caLabel = label
            importMessage = nil
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func save() {
        connection.name = connection.name.trimmingCharacters(in: .whitespaces)
        connection.baseURL = connection.baseURL.trimmingCharacters(in: .whitespaces)
        if needsSecret {
            if !secret.isEmpty { ServiceKeychain.setSecret(secret, for: connection.id) }
        } else {
            ServiceKeychain.deleteSecret(for: connection.id)
        }
        store.logSecurity(pendingEvents, for: connection.id)
        store.save(connection)
        dismiss()
    }
}

struct SecurityBadgeView: View {
    let badge: SecurityBadge

    private var color: Color {
        switch badge.tone {
        case .good: return .green
        case .caution: return .orange
        case .bad: return .red
        case .unknown: return .secondary
        }
    }

    var body: some View {
        Label(badge.text, systemImage: badge.symbol).font(.footnote).foregroundStyle(color)
    }
}
