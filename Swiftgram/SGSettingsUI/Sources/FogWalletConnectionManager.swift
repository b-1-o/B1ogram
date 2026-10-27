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
        }
    }
}

private final class FogWalletAuthBrowserController: ViewController, SFSafariViewControllerDelegate {
    private let safariController: SFSafariViewController
    private let onUserDismiss: () -> Void
    private(set) var isFlowActive = true

    init(url: URL, onUserDismiss: @escaping () -> Void) {
        self.safariController = SFSafariViewController(url: url)
        self.onUserDismiss = onUserDismiss
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
        self.isFlowActive = false
        self.onUserDismiss()
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
    private let sessionLifetime: TimeInterval = 30 * 24 * 60 * 60
    private let flowLifetime: TimeInterval = 10 * 60
    private let session = URLSession(configuration: .ephemeral)

    private init() {}

    public func isConnected(accountId: String) -> Bool {
        return loadAccessToken(accountId: accountId) != nil
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
                    var browser: FogWalletAuthBrowserController?
                    let finish: (Result<Void, Error>) -> Void = { result in
                        guard !completed else { return }
                        completed = true
                        completion(result)
                    }

                    let controller = FogWalletAuthBrowserController(url: url) {
                        finish(.failure(FogWalletConnectionError.authorizationCancelled))
                    }
                    browser = controller
                    presentBrowser(controller)

                    self.poll(
                        flowId: flowId,
                        accountId: accountId,
                        browser: controller,
                        startedAt: Date(),
                        attempt: 0,
                        finish: { result in
                            if case .success = result {
                                controller.closeAfterCompletion()
                            }
                            finish(result)
                            _ = browser
                        }
                    )
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
                    completion(.failure(error))
                }
            }
        }
    }

    private func poll(
        flowId: String,
        accountId: String,
        browser: FogWalletAuthBrowserController,
        startedAt: Date,
        attempt: Int,
        finish: @escaping (Result<Void, Error>) -> Void
    ) {
        guard browser.isFlowActive else { return }
        if Date().timeIntervalSince(startedAt) >= self.flowLifetime || attempt >= 120 {
            browser.closeAfterCompletion()
            finish(.failure(FogWalletConnectionError.authorizationExpired))
            return
        }

        let delay: TimeInterval = attempt < 3 ? 2.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak browser] in
            guard let self, let browser, browser.isFlowActive else { return }
            self.post(path: "/v1/connect/telegram/status", body: ["flow_id": flowId], accessToken: nil) { [weak self, weak browser] result in
                guard let self, let browser else { return }
                DispatchQueue.main.async {
                    guard browser.isFlowActive else { return }
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
                                browser.closeAfterCompletion()
                                finish(.failure(FogWalletConnectionError.invalidResponse))
                                return
                            }
                            guard self.saveAccessToken(token, accountId: accountId) else {
                                self.post(path: "/v1/connect/disconnect", body: [:], accessToken: token) { _ in }
                                browser.closeAfterCompletion()
                                finish(.failure(FogWalletConnectionError.keychainFailure))
                                return
                            }
                            browser.closeAfterCompletion()
                            finish(.success(()))
                        case "expired", "consumed":
                            browser.closeAfterCompletion()
                            finish(.failure(FogWalletConnectionError.authorizationExpired))
                        case "failed":
                            browser.closeAfterCompletion()
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
        var request = URLRequest(url: fogWalletBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
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
