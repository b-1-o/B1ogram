import Foundation
import Security
import UIKit
import SafariServices
import AsyncDisplayKit
import Display
import SwiftSignalKit

private let fogWalletBaseURL = URL(string: "https://fog-wallet-api.collab-docs-b1o.workers.dev")!

private enum FogWalletConnectionError: LocalizedError {
    case invalidResponse
    case serverUnavailable
    case authorizationExpired
    case authorizationCancelled
    case keychainFailure
    case serverRejected
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Fog Wallet returned an unexpected response. Please try again."
        case .serverUnavailable:
            return "Fog Wallet is temporarily unavailable. Please try again later."
        case .authorizationExpired:
            return "The Telegram connection request expired. Please start again."
        case .authorizationCancelled:
            return "Connection was cancelled. Your Biogram account was not changed."
        case .keychainFailure:
            return "iOS could not securely save the Fog Wallet session. Please try again."
        case .serverRejected:
            return "Telegram could not confirm the currently signed-in Biogram account. No connection was created."
        case let .requestFailed(code):
            switch code {
            case "telegram_identity_refresh_required":
                return "Fog Wallet needs a fresh Telegram identity check. Disconnect and reconnect Fog Wallet in Biogram settings."
            case "card_signing_key_not_configured":
                return "Card issuing is not ready on the Fog Wallet server yet."
            case "activation_code_required":
                return "This is a limited card. Enter its activation code to claim it."
            case "activation_code_invalid_or_used":
                return "That activation code is invalid, expired, or has already been used."
            case "too_many_attempts":
                return "Too many attempts. Please wait a few minutes before trying another code."
            case "design_not_found":
                return "This card design is no longer available."
            case "card_not_found":
                return "This card is no longer in your collection."
            case "unauthorized", "admin_unauthorized":
                return "Your Fog Wallet session expired. Reconnect Fog Wallet in Biogram settings."
            default:
                return "Fog Wallet could not complete the request (\(code)). Please try again later."
            }
        }
    }
}

private final class FogWalletAuthBrowserController: ViewController, SFSafariViewControllerDelegate {
    private let safariController: SFSafariViewController
    private(set) var isFlowActive = true
    private(set) var userDismissedAt: Date?

    init(url: URL) {
        self.safariController = SFSafariViewController(url: url)
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
        self.safariController.delegate = self
    }

    required init(coder: NSCoder) {
        fatalError()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .clear

        Queue.mainQueue().after(0.05) { [weak self] in
            guard let self, let root = self.view.window?.rootViewController else { return }
            var top: UIViewController = root
            while let presented = top.presentedViewController {
                top = presented
            }
            top.present(self.safariController, animated: true)
        }
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard self.isFlowActive else { return }
        self.userDismissedAt = Date()
        self.dismiss(animated: false)
    }

    func closeAfterCompletion() {
        guard self.isFlowActive else { return }
        self.isFlowActive = false
        self.safariController.dismiss(animated: true) { [weak self] in
            self?.dismiss(animated: false)
        }
    }
}

public final class FogWalletConnectionManager {
    public static let shared = FogWalletConnectionManager()

    private let keychainService = "com.b1o.biogram.fog-wallet"
    private let flowLifetime: TimeInterval = 10 * 60
    private let session = URLSession(configuration: .ephemeral)

    private init() {}

    public func isConnected(accountId: String) -> Bool {
        return loadAccessToken(accountId: accountId) != nil
    }

    /// Sends a small JSON request to Fog Wallet. Access tokens stay in Keychain and
    /// are never copied into the card cache or UserDefaults.
    public func cardRequest(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        accountId: String,
        requiresAuth: Bool = true,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard method == "GET" || method == "POST" else {
            DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.invalidResponse)) }
            return
        }
        let accessToken = requiresAuth ? loadAccessToken(accountId: accountId) : nil
        if requiresAuth && accessToken == nil {
            DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.serverRejected)) }
            return
        }
        guard let requestURL = URL(string: fogWalletBaseURL.absoluteString + path) else {
            DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.invalidResponse)) }
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            } catch {
                DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.invalidResponse)) }
                return
            }
        }
        self.session.dataTask(with: request) { data, response, error in
            if error != nil {
                DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.serverUnavailable)) }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.invalidResponse)) }
                return
            }
            if httpResponse.statusCode == 401 {
                DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.serverRejected)) }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let code = payload["error"] as? String ?? "http_\(httpResponse.statusCode)"
                DispatchQueue.main.async {
                    completion(.failure(FogWalletConnectionError.requestFailed(code)))
                }
                return
            }
            DispatchQueue.main.async { completion(.success(payload)) }
        }.resume()
    }

    public func connect(
        telegramUserId: String,
        accountId: String,
        presentBrowser: @escaping (ViewController) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard telegramUserId.range(of: "^[0-9]{1,24}$", options: .regularExpression) != nil else {
            DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.serverRejected)) }
            return
        }

        post(path: "/v1/connect/telegram/start", body: ["expected_telegram_id": telegramUserId], accessToken: nil) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                DispatchQueue.main.async { completion(.failure(error)) }
            case let .success(payload):
                guard
                    let urlString = payload["authorization_url"] as? String,
                    let url = URL(string: urlString),
                    url.scheme == "https",
                    url.host == "oauth.telegram.org",
                    let flowId = payload["flow_id"] as? String,
                    flowId.range(of: "^[A-Za-z0-9_-]{40,128}$", options: .regularExpression) != nil
                else {
                    DispatchQueue.main.async { completion(.failure(FogWalletConnectionError.invalidResponse)) }
                    return
                }

                DispatchQueue.main.async {
                    var completed = false
                    let finish: (Result<Void, Error>) -> Void = { result in
                        guard !completed else { return }
                        completed = true
                        completion(result)
                    }

                    // Prefer Telegram's native cross-app authorization when Telegram is installed.
                    // If that route is unavailable, retain the regular browser-based OIDC fallback.
                    self.openTelegramCrossApp(authorizationURL: url) { openedTelegram in
                        DispatchQueue.main.async {
                            guard !completed else { return }

                            let controller: FogWalletAuthBrowserController?
                            if openedTelegram {
                                controller = nil
                            } else {
                                let browserController = FogWalletAuthBrowserController(url: url)
                                controller = browserController
                                presentBrowser(browserController)
                            }

                            self.poll(
                                flowId: flowId,
                                accountId: accountId,
                                browser: controller,
                                startedAt: Date(),
                                attempt: 0,
                                finish: { result in
                                    if case .success = result {
                                        controller?.closeAfterCompletion()
                                    }
                                    finish(result)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    public func disconnect(accountId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let token = loadAccessToken(accountId: accountId) else {
            deleteAccessToken(accountId: accountId)
            DispatchQueue.main.async { completion(.success(())) }
            return
        }

        post(path: "/v1/connect/disconnect", body: [:], accessToken: token) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.deleteAccessToken(accountId: accountId)
                    completion(.success(()))
                case let .failure(error):
                    if let connectionError = error as? FogWalletConnectionError,
                       case .serverRejected = connectionError {
                        // The server no longer accepts this session, so clear the stale local credential.
                        self.deleteAccessToken(accountId: accountId)
                        completion(.success(()))
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func openTelegramCrossApp(authorizationURL: URL, completion: @escaping (Bool) -> Void) {
        guard
            let authorizationComponents = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
            let authorizationItems = authorizationComponents.queryItems,
            var crossAppComponents = URLComponents(string: "https://oauth.telegram.org/crossapp")
        else {
            completion(false)
            return
        }

        let forwardedNames: Set<String> = [
            "client_id", "response_type", "redirect_uri", "scope",
            "state", "nonce", "code_challenge", "code_challenge_method"
        ]
        var queryItems = authorizationItems.filter { forwardedNames.contains($0.name) }
        queryItems.append(URLQueryItem(name: "ios_sdk", value: "1"))
        crossAppComponents.queryItems = queryItems

        guard let crossAppURL = crossAppComponents.url else {
            completion(false)
            return
        }

        var request = URLRequest(url: crossAppURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        self.session.dataTask(with: request) { data, response, error in
            guard
                error == nil,
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let data,
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let urlString = payload["url"] as? String,
                let telegramURL = URL(string: urlString),
                let scheme = telegramURL.scheme?.lowercased(),
                scheme == "tg" || (scheme == "https" && ["t.me", "telegram.org"].contains(telegramURL.host?.lowercased() ?? ""))
            else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            DispatchQueue.main.async {
                UIApplication.shared.open(telegramURL, options: [:]) { opened in
                    completion(opened)
                }
            }
        }.resume()
    }

    private func poll(
        flowId: String,
        accountId: String,
        browser: FogWalletAuthBrowserController?,
        startedAt: Date,
        attempt: Int,
        finish: @escaping (Result<Void, Error>) -> Void
    ) {
        if let browser, !browser.isFlowActive { return }
        if let dismissedAt = browser?.userDismissedAt,
           Date().timeIntervalSince(dismissedAt) >= 20 {
            browser?.closeAfterCompletion()
            finish(.failure(FogWalletConnectionError.authorizationCancelled))
            return
        }
        if Date().timeIntervalSince(startedAt) >= self.flowLifetime || attempt >= 120 {
            browser?.closeAfterCompletion()
            finish(.failure(FogWalletConnectionError.authorizationExpired))
            return
        }

        let delay: TimeInterval = attempt < 3 ? 2.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let browser, !browser.isFlowActive { return }
            self.post(path: "/v1/connect/telegram/status", body: ["flow_id": flowId], accessToken: nil) { [weak self] result in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let browser, !browser.isFlowActive { return }
                    switch result {
                    case .failure:
                        self.poll(flowId: flowId, accountId: accountId, browser: browser, startedAt: startedAt, attempt: attempt + 1, finish: finish)
                    case let .success(payload):
                        switch payload["status"] as? String {
                        case "pending":
                            self.poll(flowId: flowId, accountId: accountId, browser: browser, startedAt: startedAt, attempt: attempt + 1, finish: finish)
                        case "connected":
                            guard let token = payload["access_token"] as? String,
                                  token.range(of: "^[A-Za-z0-9_-]{40,128}$", options: .regularExpression) != nil
                            else {
                                browser?.closeAfterCompletion()
                                finish(.failure(FogWalletConnectionError.invalidResponse))
                                return
                            }
                            guard self.saveAccessToken(token, accountId: accountId) else {
                                self.post(path: "/v1/connect/disconnect", body: [:], accessToken: token) { _ in }
                                browser?.closeAfterCompletion()
                                finish(.failure(FogWalletConnectionError.keychainFailure))
                                return
                            }
                            browser?.closeAfterCompletion()
                            finish(.success(()))
                        case "expired", "consumed":
                            browser?.closeAfterCompletion()
                            finish(.failure(FogWalletConnectionError.authorizationExpired))
                        case "failed":
                            browser?.closeAfterCompletion()
                            finish(.failure(FogWalletConnectionError.serverRejected))
                        default:
                            self.poll(flowId: flowId, accountId: accountId, browser: browser, startedAt: startedAt, attempt: attempt + 1, finish: finish)
                        }
                    }
                }
            }
        }
    }

    private func post(
        path: String,
        body: [String: Any],
        accessToken: String?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let requestURL = URL(string: fogWalletBaseURL.absoluteString + path) else {
            completion(.failure(FogWalletConnectionError.invalidResponse))
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            completion(.failure(FogWalletConnectionError.invalidResponse))
            return
        }

        self.session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(FogWalletConnectionError.serverUnavailable))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, let data else {
                completion(.failure(FogWalletConnectionError.invalidResponse))
                return
            }
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(FogWalletConnectionError.invalidResponse))
                return
            }
            if httpResponse.statusCode == 401 {
                completion(.failure(FogWalletConnectionError.serverRejected))
                return
            }
            if httpResponse.statusCode == 410 {
                completion(.success(["status": "expired"]))
                return
            }
            if payload["status"] as? String == "failed" {
                completion(.success(payload))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(FogWalletConnectionError.serverUnavailable))
                return
            }
            completion(.success(payload))
        }.resume()
    }

    private func keychainQuery(accountId: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: accountId,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private func loadAccessToken(accountId: String) -> String? {
        var query = self.keychainQuery(accountId: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func saveAccessToken(_ token: String, accountId: String) -> Bool {
        let data = Data(token.utf8)
        let query = self.keychainQuery(accountId: accountId)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func deleteAccessToken(accountId: String) {
        SecItemDelete(self.keychainQuery(accountId: accountId) as CFDictionary)
    }
}
