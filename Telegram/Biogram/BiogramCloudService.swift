import Foundation
import UIKit
import Security

private struct BiogramCloudStartResponse: Decodable {
    let flowId: String
    let state: String
    let authorizationUrl: String
}

private struct BiogramCloudStatusResponse: Decodable {
    let status: String
    let error: String?
    let isNewUser: Bool?
}

private struct BiogramCloudProfileEnvelope: Decodable {
    let profile: BiogramCloudPublicProfile
}

private struct BiogramCloudPendingFlow: Codable {
    let flowId: String
    let state: String
    let authorizationUrl: String
}

private struct BiogramCloudImagePayload: Encodable {
    let imageBase64: String
}

public final class BiogramCloudService {
    public static let shared = BiogramCloudService()

    public static let apiBaseURL = URL(string: "https://fog-wallet-api.collab-docs-b1o.workers.dev")!

    private let keychainService = "org.biogram.cloud-profiles"
    private let lock = NSLock()
    private var publicProfiles: [String: BiogramCloudPublicProfile] = [:]
    private var publicProfileFetchedAt: [String: Date] = [:]
    private var loadingProfiles: Set<String> = []
    private var attemptedBootstrapAccounts: Set<String> = []
    private var pendingSyncWorkItems: [String: DispatchWorkItem] = [:]

    private init() {}

    // MARK: - Secure account state

    private func keychainQuery(accountId: String, key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: "\(accountId):\(key)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private func readSecureValue(accountId: String, key: String) -> Data? {
        var query = self.keychainQuery(accountId: accountId, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    private func writeSecureValue(_ data: Data?, accountId: String, key: String) -> Bool {
        let query = self.keychainQuery(accountId: accountId, key: key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else {
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func bearerToken(accountId: String) -> String? {
        guard let data = self.readSecureValue(accountId: accountId, key: "session"),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func pendingFlow(accountId: String) -> BiogramCloudPendingFlow? {
        guard let data = self.readSecureValue(accountId: accountId, key: "pending-flow") else {
            return nil
        }
        return try? JSONDecoder().decode(BiogramCloudPendingFlow.self, from: data)
    }

    private func setPendingFlow(_ flow: BiogramCloudPendingFlow?, accountId: String) {
        guard let flow, let data = try? JSONEncoder().encode(flow) else {
            _ = self.writeSecureValue(nil, accountId: accountId, key: "pending-flow")
            return
        }
        _ = self.writeSecureValue(data, accountId: accountId, key: "pending-flow")
    }

    // MARK: - HTTP

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil, token: String? = nil) -> URLRequest {
        let url = Self.apiBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(data, response as? HTTPURLResponse, error)
        }.resume()
    }

    // MARK: - Automatic enrollment

    /// Called after the normal Telegram account has become ready.
    /// The first enrollment uses Telegram's own OIDC confirmation, without a separate Biogram settings action.
    public func bootstrap(telegramId: String, accountId: String) {
        guard !telegramId.isEmpty else { return }
        _ = self.writeSecureValue(Data(telegramId.utf8), accountId: accountId, key: "telegram-id")

        if let token = self.bearerToken(accountId: accountId) {
            self.loadMyProfile(accountId: accountId, token: token)
            return
        }

        self.lock.lock()
        let alreadyAttempted = self.attemptedBootstrapAccounts.contains(accountId)
        if !alreadyAttempted {
            self.attemptedBootstrapAccounts.insert(accountId)
        }
        self.lock.unlock()
        guard !alreadyAttempted else { return }

        if let pending = self.pendingFlow(accountId: accountId) {
            self.checkPendingFlow(pending, accountId: accountId, reopenAuthorization: true)
            return
        }

        let body = try? JSONSerialization.data(withJSONObject: ["telegramId": telegramId])
        guard let body else { return }
        let request = self.makeRequest(path: "v1/auth/telegram/start", method: "POST", body: body)
        self.send(request) { [weak self] data, response, error in
            guard let self, error == nil, response?.statusCode == 201,
                  let data,
                  let start = try? JSONDecoder().decode(BiogramCloudStartResponse.self, from: data),
                  let authorizationUrl = URL(string: start.authorizationUrl),
                  authorizationUrl.scheme == "https",
                  authorizationUrl.host == "oauth.telegram.org" else {
                return
            }

            let pending = BiogramCloudPendingFlow(
                flowId: start.flowId,
                state: start.state,
                authorizationUrl: start.authorizationUrl
            )
            self.setPendingFlow(pending, accountId: accountId)
            DispatchQueue.main.async {
                UIApplication.shared.open(authorizationUrl, options: [:], completionHandler: nil)
            }
        }
    }

    private func checkPendingFlow(
        _ flow: BiogramCloudPendingFlow,
        accountId: String,
        reopenAuthorization: Bool
    ) {
        var components = URLComponents(url: Self.apiBaseURL.appendingPathComponent("v1/auth/telegram/status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "state", value: flow.state)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        self.send(request) { [weak self] data, response, error in
            guard let self, error == nil, let data,
                  let status = try? JSONDecoder().decode(BiogramCloudStatusResponse.self, from: data) else {
                return
            }

            switch status.status {
            case "completed":
                _ = self.writeSecureValue(Data(flow.flowId.utf8), accountId: accountId, key: "session")
                self.setPendingFlow(nil, accountId: accountId)
                let preserveLocalProfile = status.isNewUser == true
                    || self.readSecureValue(accountId: accountId, key: "prefer-local-profile") != nil
                if preserveLocalProfile {
                    _ = self.writeSecureValue(nil, accountId: accountId, key: "prefer-local-profile")
                    self.syncLocalProfile(accountId: accountId)
                } else {
                    self.loadMyProfile(accountId: accountId, token: flow.flowId)
                }
            case "failed":
                self.setPendingFlow(nil, accountId: accountId)
                self.lock.lock()
                self.attemptedBootstrapAccounts.remove(accountId)
                self.lock.unlock()
            default:
                if reopenAuthorization,
                   response?.statusCode == 202,
                   let url = URL(string: flow.authorizationUrl) {
                    DispatchQueue.main.async {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
            }
        }
    }

    /// Handles biogram://oauth/callback?state=... after Telegram returns to iOS.
    public func completeAuthorization(state: String, accountId: String) {
        guard let pending = self.pendingFlow(accountId: accountId), pending.state == state else {
            return
        }
        self.checkPendingFlow(pending, accountId: accountId, reopenAuthorization: false)
    }

    // MARK: - Profile synchronization

    public func scheduleLocalProfileSync(accountId: String) {
        self.lock.lock()
        self.pendingSyncWorkItems[accountId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.syncLocalProfile(accountId: accountId)
        }
        self.pendingSyncWorkItems[accountId] = work
        self.lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func syncLocalProfile(accountId: String) {
        guard BiogramManager.shared.activeAccountId == accountId,
              BiogramManager.shared.isLoaded,
              let token = self.bearerToken(accountId: accountId) else { return }
        let payload = BiogramManager.shared.cloudProfilePayload()
        guard let body = try? JSONEncoder().encode(payload) else { return }
        let request = self.makeRequest(path: "v1/profile/me", method: "PUT", body: body, token: token)
        self.send(request) { [weak self] _, response, error in
            guard let self else { return }
            if response?.statusCode == 401 {
                self.restartEnrollment(accountId: accountId, preserveLocalProfile: true)
                return
            }
            guard error == nil, response?.statusCode == 200 else { return }
            self.syncCardArtwork(accountId: accountId, token: token)
        }
    }

    private static func encodedCardImage(_ image: UIImage, maximumBytes: Int) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let longestSide = max(image.size.width, image.size.height)
        var scale = min(1.0, 1280.0 / longestSide)
        let qualities: [CGFloat] = [0.78, 0.70, 0.62, 0.54]

        for _ in 0..<5 {
            let targetSize = CGSize(
                width: max(1, floor(image.size.width * scale)),
                height: max(1, floor(image.size.height * scale))
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }

            for quality in qualities {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                    return data
                }
            }
            scale *= 0.78
        }
        return nil
    }

    private func syncCardArtwork(accountId: String, token: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard BiogramManager.shared.activeAccountId == accountId,
                  BiogramManager.shared.isLoaded else { return }
            let image = BiogramManager.shared.profileCardImage()
            let path = "v1/profile/me/card-image"

            guard let image else {
                let request = self.makeRequest(path: path, method: "DELETE", token: token)
                self.send(request) { _, _, _ in }
                return
            }

            guard let data = Self.encodedCardImage(image, maximumBytes: 327680) else { return }
            let body = try? JSONEncoder().encode(BiogramCloudImagePayload(imageBase64: data.base64EncodedString()))
            guard let body else { return }
            let request = self.makeRequest(path: path, method: "PUT", body: body, token: token)
            self.send(request) { _, _, _ in }
        }
    }

    private func loadMyProfile(accountId: String, token: String) {
        let request = self.makeRequest(path: "v1/profile/me", token: token)
        self.send(request) { [weak self] data, response, error in
            guard let self else { return }
            if response?.statusCode == 401 {
                self.restartEnrollment(accountId: accountId)
                return
            }
            guard error == nil, response?.statusCode == 200,
                  let data,
                  let envelope = try? JSONDecoder().decode(BiogramCloudProfileEnvelope.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                BiogramManager.shared.applyCloudProfile(envelope.profile, accountId: accountId)
                self.cache(profile: envelope.profile)
            }
        }
    }

    /// A revoked or expired 30-day session is re-established using the saved Telegram identity.
    private func restartEnrollment(accountId: String, preserveLocalProfile: Bool = false) {
        guard let identityData = self.readSecureValue(accountId: accountId, key: "telegram-id"),
              let telegramId = String(data: identityData, encoding: .utf8),
              !telegramId.isEmpty else {
            _ = self.writeSecureValue(nil, accountId: accountId, key: "session")
            return
        }
        _ = self.writeSecureValue(nil, accountId: accountId, key: "session")
        if preserveLocalProfile {
            _ = self.writeSecureValue(Data("1".utf8), accountId: accountId, key: "prefer-local-profile")
        }
        self.lock.lock()
        self.attemptedBootstrapAccounts.remove(accountId)
        self.lock.unlock()
        self.bootstrap(telegramId: telegramId, accountId: accountId)
    }

    public func cachedPublicProfile(for telegramId: String) -> BiogramCloudPublicProfile? {
        self.lock.lock()
        let profile = self.publicProfiles[telegramId]
        self.lock.unlock()
        return profile
    }

    private func cache(profile: BiogramCloudPublicProfile) {
        self.lock.lock()
        self.publicProfiles[profile.telegramId] = profile
        self.publicProfileFetchedAt[profile.telegramId] = Date()
        self.lock.unlock()
    }

    public func loadPublicProfile(
        for telegramId: String,
        completion: @escaping (BiogramCloudPublicProfile?) -> Void
    ) {
        self.lock.lock()
        let cached = self.publicProfiles[telegramId]
        let fetchedAt = self.publicProfileFetchedAt[telegramId]
        let cacheIsFresh = fetchedAt.map { Date().timeIntervalSince($0) < 60 } == true
        if cacheIsFresh {
            self.lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        if self.loadingProfiles.contains(telegramId) {
            self.lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        self.loadingProfiles.insert(telegramId)
        self.lock.unlock()

        let path = "v1/profiles/\(telegramId)"
        let request = self.makeRequest(path: path)
        self.send(request) { [weak self] data, response, error in
            guard let self else { completion(nil); return }
            self.lock.lock()
            self.loadingProfiles.remove(telegramId)
            self.lock.unlock()

            guard error == nil, response?.statusCode == 200,
                  let data,
                  let envelope = try? JSONDecoder().decode(BiogramCloudProfileEnvelope.self, from: data) else {
                if response?.statusCode == 404 {
                    self.lock.lock()
                    self.publicProfiles.removeValue(forKey: telegramId)
                    // Cache negative lookups too, preventing profile-layout rebuilds from
                    // repeatedly requesting an account that has no public Biogram profile.
                    self.publicProfileFetchedAt[telegramId] = Date()
                    self.lock.unlock()
                    DispatchQueue.main.async { completion(nil) }
                } else {
                    DispatchQueue.main.async { completion(cached) }
                }
                return
            }
            self.cache(profile: envelope.profile)
            DispatchQueue.main.async { completion(envelope.profile) }
        }
    }

}
