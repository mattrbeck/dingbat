import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google sign-in for Drive, the web's broker flow (index.js driveCodeGrant):
/// the consent page opens in the system's browser sheet with PKCE and
/// offline access, Google redirects to the web's oauth-callback.html (the
/// redirect the web client allows), which hands an "app."-tagged code on to
/// dingbat://oauth. The signaling server's broker, holding the client secret,
/// swaps the code for tokens and later renews them. Same client, same
/// appDataFolder: the app and dingbat.gg are one library.
enum DriveAuth {
    static let clientID = "44914400148-bkh9oiu6ian098gbg5jecns4js5d849f.apps.googleusercontent.com"
    static let scope = "https://www.googleapis.com/auth/drive.appdata email"
    static let redirectURI = "https://dingbat.gg/oauth-callback.html"
    static let brokerBase = "https://signal.dingbat.gg"
    static var tokenInfoURL = "https://oauth2.googleapis.com/tokeninfo"

    struct Grant {
        var accessToken: String
        var expiresIn: Double
        var refreshToken: String?
    }

    enum AuthError: LocalizedError {
        case canceled, failed(String), brokerDown, grantGone
        var errorDescription: String? {
            switch self {
            case .canceled: return "Sign-in was canceled"
            case .failed(let m): return m
            case .brokerDown: return "Couldn't reach dingbat's sign-in service — try again"
            case .grantGone: return "Signed out of Google Drive — sign in again to keep syncing"
            }
        }
    }

    private static func base64Url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomToken() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return base64Url(Data(b))
    }

    /// The consent sheet, then the broker's exchange. `hint` skips the
    /// account chooser for a re-grant.
    @MainActor
    static func codeGrant(hint: String?) async throws -> Grant {
        let state = "app." + randomToken()
        let verifier = randomToken()
        let challenge = base64Url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var q = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: hint != nil ? "consent" : "select_account consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let hint { items.append(URLQueryItem(name: "login_hint", value: hint)) }
        q.queryItems = items
        let callback = try await present(url: q.url!)
        let back = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { back.first { $0.name == n }?.value }
        guard item("state") == state else { throw AuthError.failed("Google sign-in failed") }
        if let err = item("error"), !err.isEmpty {
            throw err == "access_denied" ? AuthError.canceled : AuthError.failed("Google sign-in failed: " + err)
        }
        guard let code = item("code"), !code.isEmpty else { throw AuthError.failed("Google sign-in failed") }
        let (status, j) = try await brokerPost("/oauth/exchange",
            ["code": code, "code_verifier": verifier, "redirect_uri": redirectURI])
        guard status == 200, let tok = j?["access_token"] as? String else {
            throw AuthError.failed("Google sign-in failed" + ((j?["error"] as? String).map { ": " + $0 } ?? ""))
        }
        return Grant(accessToken: tok, expiresIn: (j?["expires_in"] as? NSNumber)?.doubleValue ?? 3600,
                     refreshToken: j?["refresh_token"] as? String)
    }

    /// A new access token from the refresh token. `grantGone` when Google
    /// says the grant ended (signed out everywhere, or expired unused).
    static func refresh(_ token: String) async throws -> Grant {
        let (status, j) = try await brokerPost("/oauth/refresh", ["refresh_token": token])
        if status == 200, let tok = j?["access_token"] as? String {
            return Grant(accessToken: tok, expiresIn: (j?["expires_in"] as? NSNumber)?.doubleValue ?? 3600,
                         refreshToken: nil)
        }
        if status == 400, (j?["error"] as? String) == "invalid_grant" { throw AuthError.grantGone }
        throw AuthError.brokerDown
    }

    /// The account a token was granted for: (sub, email), or nil.
    static func tokenInfo(_ token: String) async -> (sub: String, email: String?)? {
        var c = URLComponents(string: tokenInfoURL)!
        c.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let (data, res) = try? await URLSession.shared.data(from: c.url!),
              (res as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = o["sub"] as? String else { return nil }
        return (sub, o["email"] as? String)
    }

    /// Ends dingbat's Drive access for the whole account (every device finds
    /// out at its next renewal). True when Google said yes.
    static func revoke(_ token: String) async -> Bool {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        req.httpBody = Data("token=\(enc)".utf8)
        guard let (_, res) = try? await URLSession.shared.data(for: req) else { return false }
        return (res as? HTTPURLResponse)?.statusCode == 200
    }

    private static func brokerPost(_ path: String, _ body: [String: String]) async throws -> (Int, [String: Any]?) {
        var req = URLRequest(url: URL(string: brokerBase + path)!, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, res: URLResponse
        do { (data, res) = try await URLSession.shared.data(for: req) } catch { throw AuthError.brokerDown }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((res as? HTTPURLResponse)?.statusCode ?? 0, j)
    }

    // MARK: the browser sheet

    private static var session: ASWebAuthenticationSession?
    private static let anchor = Anchor()

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    @MainActor
    private static func present(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "dingbat") { cb, err in
                session = nil
                if let cb { cont.resume(returning: cb); return }
                if let e = err as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: AuthError.canceled)
                } else {
                    cont.resume(throwing: AuthError.failed("Google sign-in failed"))
                }
            }
            s.presentationContextProvider = anchor
            // Google's own sign-in cookies help (already signed in on Safari).
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() {
                session = nil
                cont.resume(throwing: AuthError.failed("Couldn't open Google sign-in"))
            }
        }
    }
}
