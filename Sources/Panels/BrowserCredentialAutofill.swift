import Foundation
import Security
import WebKit
import AppKit
#if canImport(Bonsplit)
import Bonsplit
#endif

// MARK: - Keychain Credential Model

/// A username/password pair retrieved from the macOS Keychain.
struct KeychainCredential: Identifiable, Hashable {
    let id = UUID()
    let username: String
    let password: String
    let server: String
    /// When non-nil, the Keychain label (e.g. "github.com (user@example.com)").
    let label: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(username)
        hasher.combine(server)
    }

    static func == (lhs: KeychainCredential, rhs: KeychainCredential) -> Bool {
        lhs.username == rhs.username && lhs.server == rhs.server
    }
}

// MARK: - Keychain Queries

enum KeychainCredentialStore {
    /// Search the default Keychain (including iCloud Keychain) for internet passwords matching `server`.
    /// The query matches both the server attribute and the protocol (HTTPS preferred).
    static func credentials(for server: String) -> [KeychainCredential] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: server,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[CFString: Any]] else {
            return []
        }

        return items.compactMap { item -> KeychainCredential? in
            guard let passwordData = item[kSecValueData] as? Data,
                  let password = String(data: passwordData, encoding: .utf8),
                  !password.isEmpty else {
                return nil
            }
            let username = item[kSecAttrAccount] as? String ?? ""
            let label = item[kSecAttrLabel] as? String
            return KeychainCredential(
                username: username,
                password: password,
                server: server,
                label: label
            )
        }
    }

    /// Save a credential to the default Keychain.
    static func save(username: String, password: String, server: String) -> Bool {
        // Check if an entry already exists for this account + server.
        let searchQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: server,
            kSecAttrAccount: username,
        ]

        var existing: CFTypeRef?
        let searchStatus = SecItemCopyMatching(searchQuery as CFDictionary, &existing)

        if searchStatus == errSecSuccess {
            // Update existing entry.
            let updateAttrs: [CFString: Any] = [
                kSecValueData: Data(password.utf8),
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
            return updateStatus == errSecSuccess
        }

        // Add new entry.
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: server,
            kSecAttrAccount: username,
            kSecAttrProtocol: kSecAttrProtocolHTTPS,
            kSecAttrLabel: "\(server) (\(username))",
            kSecValueData: Data(password.utf8),
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}

// MARK: - Login Form Detection (injected JS)

private let credentialDetectorMessageName = "cmuxCredentialDetector"

/// JavaScript injected at document-end to detect login forms.
/// Main frame only to avoid CAPTCHA interference.
///
/// Detection strategy:
/// 1. Find visible `<input type="password">` elements.
/// 2. Walk siblings/ancestors to find the closest username/email field.
/// 3. Report the domain and field identifiers to native.
/// 4. Use MutationObserver + pushState interception for SPA-loaded forms.
///
/// The script also provides `window.__cmuxFillCredential(user, pass)` for
/// the native side to invoke after the user picks a credential.
let credentialDetectorScript: String = """
(function() {
  'use strict';
  if (window.__cmuxCredentialDetectorInstalled) return;
  window.__cmuxCredentialDetectorInstalled = true;

  var MSG = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(credentialDetectorMessageName);
  if (!MSG) return;

  // ---- Utility ----

  function isVisible(el) {
    if (!el || !el.offsetParent && el.style.position !== 'fixed') return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function isUsernameField(el) {
    if (!el || el.tagName !== 'INPUT') return false;
    var t = (el.type || '').toLowerCase();
    if (t !== 'text' && t !== 'email' && t !== 'tel') return false;
    var name = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.autocomplete || '')).toLowerCase();
    return /user|email|login|account|phone|identifier/.test(name);
  }

  function findUsernameField(passwordField) {
    // Walk backwards through the form or DOM siblings.
    var form = passwordField.closest('form');
    var container = form || passwordField.parentElement;
    if (!container) return null;
    var inputs = container.querySelectorAll('input');
    var candidate = null;
    for (var i = 0; i < inputs.length; i++) {
      if (inputs[i] === passwordField) break;
      if (isUsernameField(inputs[i]) && isVisible(inputs[i])) {
        candidate = inputs[i];
      }
    }
    return candidate;
  }

  // ---- Fill ----

  function dispatchInputEvents(el) {
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function setNativeValue(el, value) {
    // React overrides the value setter; use the native HTMLInputElement descriptor.
    var nativeSetter = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype, 'value'
    );
    if (nativeSetter && nativeSetter.set) {
      nativeSetter.set.call(el, value);
    } else {
      el.value = value;
    }
    dispatchInputEvents(el);
  }

  window.__cmuxFillCredential = function(username, password) {
    var pwFields = document.querySelectorAll('input[type="password"]');
    var filled = false;
    for (var i = 0; i < pwFields.length; i++) {
      if (!isVisible(pwFields[i])) continue;
      var userField = findUsernameField(pwFields[i]);
      if (userField && username) {
        setNativeValue(userField, username);
      }
      setNativeValue(pwFields[i], password);
      filled = true;
      break;
    }
    return filled;
  };

  // ---- Capture on submit ----

  window.__cmuxCaptureCredentialOnSubmit = function() {
    var pwFields = document.querySelectorAll('input[type="password"]');
    for (var i = 0; i < pwFields.length; i++) {
      if (!isVisible(pwFields[i]) || !pwFields[i].value) continue;
      var userField = findUsernameField(pwFields[i]);
      return {
        username: userField ? userField.value : '',
        password: pwFields[i].value,
        domain: location.hostname
      };
    }
    return null;
  };

  // ---- Detection ----

  function scan() {
    var pwFields = document.querySelectorAll('input[type="password"]');
    var found = false;
    for (var i = 0; i < pwFields.length; i++) {
      if (isVisible(pwFields[i])) { found = true; break; }
    }
    MSG.postMessage({
      type: found ? 'loginFormDetected' : 'noLoginForm',
      domain: location.hostname,
      url: location.href
    });
  }

  // ---- Submit capture ----

  document.addEventListener('submit', function(e) {
    var creds = window.__cmuxCaptureCredentialOnSubmit && window.__cmuxCaptureCredentialOnSubmit();
    if (creds) {
      MSG.postMessage({
        type: 'credentialCaptured',
        username: creds.username,
        password: creds.password,
        domain: creds.domain
      });
    }
  }, true);

  // Also capture on Enter key in password fields (some SPAs don't use form submit).
  document.addEventListener('keydown', function(e) {
    if (e.key !== 'Enter') return;
    var el = e.target;
    if (!el || el.tagName !== 'INPUT' || el.type !== 'password') return;
    var creds = window.__cmuxCaptureCredentialOnSubmit && window.__cmuxCaptureCredentialOnSubmit();
    if (creds) {
      MSG.postMessage({
        type: 'credentialCaptured',
        username: creds.username,
        password: creds.password,
        domain: creds.domain
      });
    }
  }, true);

  // Initial scan after a short delay (DOM may still be rendering).
  setTimeout(scan, 300);

  // Re-scan on DOM mutations (SPA lazy-load).
  var observer = new MutationObserver(function() { setTimeout(scan, 200); });
  observer.observe(document.body || document.documentElement, {
    childList: true, subtree: true
  });

  // Re-scan on SPA navigation.
  window.addEventListener('popstate', function() { setTimeout(scan, 300); });
})();
""";

// MARK: - WKScriptMessageHandler

enum CredentialDetectorMessage {
    case loginFormDetected(domain: String, url: String)
    case noLoginForm(domain: String)
    case credentialCaptured(username: String, password: String, domain: String)

    init?(body: [String: Any]) {
        guard let type = body["type"] as? String else { return nil }
        switch type {
        case "loginFormDetected":
            guard let domain = body["domain"] as? String,
                  let url = body["url"] as? String else { return nil }
            self = .loginFormDetected(domain: domain, url: url)
        case "noLoginForm":
            guard let domain = body["domain"] as? String else { return nil }
            self = .noLoginForm(domain: domain)
        case "credentialCaptured":
            guard let username = body["username"] as? String,
                  let password = body["password"] as? String,
                  let domain = body["domain"] as? String else { return nil }
            self = .credentialCaptured(username: username, password: password, domain: domain)
        default:
            return nil
        }
    }
}

final class CredentialDetectorMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (CredentialDetectorMessage) -> Void

    init(onMessage: @escaping @MainActor (CredentialDetectorMessage) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let bridgeMessage = CredentialDetectorMessage(body: body) else { return }
        Task { @MainActor in
            onMessage(bridgeMessage)
        }
    }
}

// MARK: - Credential Popover View (AppKit)

final class CredentialPickerViewController: NSViewController {
    private let credentials: [KeychainCredential]
    private let onSelect: (KeychainCredential) -> Void
    private let onDismiss: () -> Void

    init(
        credentials: [KeychainCredential],
        onSelect: @escaping (KeychainCredential) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.credentials = credentials
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let headerField = NSTextField(labelWithString: String(
            localized: "browser.credential.title",
            defaultValue: "Passwords for this site"
        ))
        headerField.font = .systemFont(ofSize: 11, weight: .semibold)
        headerField.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(headerField)

        for credential in credentials {
            let button = NSButton()
            button.bezelStyle = .recessed
            button.isBordered = false
            let displayName = credential.username.isEmpty
                ? String(localized: "browser.credential.noUsername", defaultValue: "(no username)")
                : credential.username
            button.title = displayName
            button.font = .systemFont(ofSize: 13)
            button.target = self
            button.action = #selector(credentialSelected(_:))
            button.tag = credentials.firstIndex(of: credential) ?? 0
            button.translatesAutoresizingMaskIntoConstraints = false

            let rowContainer = NSView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.wantsLayer = true
            rowContainer.layer?.cornerRadius = 4

            let icon = NSImageView(image: NSImage(
                systemSymbolName: "person.circle",
                accessibilityDescription: nil
            )!)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .secondaryLabelColor

            rowContainer.addSubview(icon)
            rowContainer.addSubview(button)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),

                button.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                button.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor, constant: -6),
                button.topAnchor.constraint(equalTo: rowContainer.topAnchor, constant: 4),
                button.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor, constant: -4),

                rowContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            ])

            // Hover effect
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: rowContainer,
                userInfo: nil
            )
            rowContainer.addTrackingArea(trackingArea)

            stackView.addArrangedSubview(rowContainer)
        }

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        scrollView.documentView = documentView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let itemHeight: CGFloat = 28
        let headerHeight: CGFloat = 20
        let padding: CGFloat = 16
        let maxVisibleItems = 5
        let visibleItems = min(credentials.count, maxVisibleItems)
        let height = CGFloat(visibleItems) * itemHeight + headerHeight + padding
        container.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        self.view = container
    }

    @objc private func credentialSelected(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < credentials.count else { return }
        onSelect(credentials[sender.tag])
    }
}

// MARK: - BrowserPanel Credential Extension

extension BrowserPanel {
    /// Wire up the credential detector message handler on the given web view.
    func setupCredentialDetectorMessageHandler(for webView: WKWebView) {
        let handler = CredentialDetectorMessageHandler { [weak self] message in
            self?.handleCredentialDetectorMessage(message)
        }
        credentialDetectorHandler = handler
        webView.configuration.userContentController.add(handler, name: credentialDetectorMessageName)
    }

    /// Handle messages from the injected credential detector JS.
    func handleCredentialDetectorMessage(_ message: CredentialDetectorMessage) {
        switch message {
        case .loginFormDetected(let domain, _):
            #if DEBUG
            dlog("credential.loginFormDetected domain=\(domain)")
            #endif
            credentialDetectedDomain = domain
            let creds = KeychainCredentialStore.credentials(for: domain)
            hasKeychainCredentials = !creds.isEmpty
            if creds.count == 1, credentialAutoFillOnce {
                credentialAutoFillOnce = false
                fillCredential(creds[0])
            }

        case .noLoginForm:
            credentialDetectedDomain = nil
            hasKeychainCredentials = false

        case .credentialCaptured(let username, let password, let domain):
            #if DEBUG
            dlog("credential.captured domain=\(domain) user=\(String(username.prefix(3)))***")
            #endif
            pendingSaveCredential = (username: username, password: password, domain: domain)
        }
    }

    /// Show a popover with matching credentials for the current domain.
    func showCredentialPicker(relativeTo positioningView: NSView? = nil) {
        let domain = credentialDetectedDomain ?? webView.url?.host ?? ""
        guard !domain.isEmpty else { return }
        let credentials = KeychainCredentialStore.credentials(for: domain)
        guard !credentials.isEmpty else {
            #if DEBUG
            dlog("credential.picker.empty domain=\(domain)")
            #endif
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 200)
        popover.contentViewController = CredentialPickerViewController(
            credentials: credentials,
            onSelect: { [weak self, weak popover] credential in
                popover?.close()
                self?.fillCredential(credential)
            },
            onDismiss: { [weak popover] in
                popover?.close()
            }
        )

        let anchor: NSView = positioningView ?? webView
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Fill the selected credential into the web page.
    func fillCredential(_ credential: KeychainCredential) {
        let escapedUser = credential.username
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let escapedPass = credential.password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let js = "window.__cmuxFillCredential && window.__cmuxFillCredential('\(escapedUser)', '\(escapedPass)');"
        webView.evaluateJavaScript(js) { result, error in
            #if DEBUG
            if let error {
                dlog("credential.fill.error \(error.localizedDescription)")
            } else {
                dlog("credential.fill.result \(String(describing: result))")
            }
            #endif
        }
    }

    /// Attempt to save a pending credential after a successful navigation away from the login page.
    func offerCredentialSaveIfNeeded() {
        guard let pending = pendingSaveCredential,
              !pending.username.isEmpty,
              !pending.password.isEmpty else { return }

        // Don't re-prompt for domains the user has opted out of.
        if credentialSaveExcludedDomains.contains(pending.domain) {
            pendingSaveCredential = nil
            return
        }

        // Check if we already have this exact credential saved.
        let existing = KeychainCredentialStore.credentials(for: pending.domain)
        if existing.contains(where: { $0.username == pending.username && $0.password == pending.password }) {
            pendingSaveCredential = nil
            return
        }

        // Show native save prompt.
        let alert = NSAlert()
        alert.messageText = String(
            localized: "browser.credential.save.title",
            defaultValue: "Save Password?"
        )
        let saveMessage = "Would you like to save the password for \(pending.username) on \(pending.domain)?"
        alert.informativeText = saveMessage
        alert.addButton(withTitle: String(
            localized: "browser.credential.save.save",
            defaultValue: "Save Password"
        ))
        alert.addButton(withTitle: String(
            localized: "browser.credential.save.never",
            defaultValue: "Never for This Site"
        ))
        alert.addButton(withTitle: String(
            localized: "browser.credential.save.notNow",
            defaultValue: "Not Now"
        ))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let saved = KeychainCredentialStore.save(
                username: pending.username,
                password: pending.password,
                server: pending.domain
            )
            #if DEBUG
            dlog("credential.save domain=\(pending.domain) success=\(saved)")
            #endif
        case .alertSecondButtonReturn:
            credentialSaveExcludedDomains.insert(pending.domain)
        default:
            break
        }
        pendingSaveCredential = nil
    }
}
