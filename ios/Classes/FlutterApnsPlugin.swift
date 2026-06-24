import Flutter
import UserNotifications

private func flutterError(_ error: Error) -> FlutterError {
    let e = error as NSError
    return FlutterError(code: "apns_error_\(e.code)", message: e.localizedDescription, details: e.domain)
}

@objc public class FlutterApnsPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate, FlutterSceneLifeCycleDelegate {

    private let channel: FlutterMethodChannel

    // ─── Shared state. ACCESSED ON MAIN THREAD ONLY (see `onMain`). ───────────
    private var launchNotification: [String: Any]?   // payload that cold-launched the app
    private var resumingFromBackground = false        // foreground vs background remote push
    private var isConfigured = false                  // Dart has called configure() → engine ready

    // willPresent: hard ceiling before we decide for Dart, so the handler is never dropped.
    private static let willPresentTimeout: TimeInterval = 24

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_apns", binaryMessenger: registrar.messenger())
        let instance = FlutterApnsPlugin(channel: channel)
        registrar.addApplicationDelegate(instance)   // legacy / un-migrated hosts
        registrar.addSceneDelegate(instance)          // UIScene hosts (Flutter ≥3.38)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // Engine teardown (multi-engine / add-to-app). We never own the UN delegate, so don't touch it.
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        onMain {
            self.launchNotification = nil
            self.isConfigured = false
            self.resumingFromBackground = false
        }
    }

    // MARK: - Threading

    // All mutable-state access funnels through here so we never need a lock.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func invoke(_ method: String, _ arguments: Any?, result: FlutterResult? = nil) {
        if Thread.isMainThread {
            channel.invokeMethod(method, arguments: arguments, result: result)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.channel.invokeMethod(method, arguments: arguments, result: result)
            }
        }
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestNotificationPermissions":
            requestNotificationPermissions(call, result: result)

        case "configure":
            guard UNUserNotificationCenter.current().delegate != nil else {
                result(FlutterError(
                    code: "delegate_not_set",
                    message: "UNUserNotificationCenter.current().delegate is nil. Assign it in AppDelegate before calling configure().",
                    details: nil
                ))
                return
            }
            onMain {
                self.isConfigured = true                          // CRITICAL: gates cold-start detection
                UIApplication.shared.registerForRemoteNotifications()
                if let launch = self.launchNotification {
                    self.launchNotification = nil                 // emit onLaunch exactly once
                    self.invoke("onLaunch", launch)
                }
                result(nil)
            }

        case "getAuthorizationStatus":
            getAuthorizationStatus(result)

        case "unregister":
            UIApplication.shared.unregisterForRemoteNotifications()
            result(nil)

        case "setNotificationCategories":
            do {
                try setNotificationCategories(call.arguments)
                result(nil)
            } catch {
                result(FlutterError(code: "invalid_categories", message: "\(error)", details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Categories (safe decoding, no force casts)

    private enum DecodeError: Error { case malformed(String) }

    private func setNotificationCategories(_ arguments: Any?) throws {
        guard let raw = arguments as? [[String: Any]] else {
            throw DecodeError.malformed("expected [[String: Any]], got \(String(describing: arguments))")
        }
        let categories = try raw.map(decodeCategory)
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    private func decodeCategory(_ map: [String: Any]) throws -> UNNotificationCategory {
        guard let id = map["identifier"] as? String,
              let actionMaps = map["actions"] as? [[String: Any]],
              let intents = map["intentIdentifiers"] as? [String],
              let optionStrings = map["options"] as? [String]
        else { throw DecodeError.malformed("category: \(map)") }

        return UNNotificationCategory(
            identifier: id,
            actions: try actionMaps.map(decodeAction),
            intentIdentifiers: intents,
            options: UNNotificationCategoryOptions(
                optionStrings.compactMap { UNNotificationCategoryOptions.stringToValue[$0] }
            )
        )
    }

    private func decodeAction(_ map: [String: Any]) throws -> UNNotificationAction {
        guard let id = map["identifier"] as? String,
              let title = map["title"] as? String,
              let optionStrings = map["options"] as? [String]
        else { throw DecodeError.malformed("action: \(map)") }

        return UNNotificationAction(
            identifier: id,
            title: title,
            options: UNNotificationActionOptions(
                optionStrings.compactMap { UNNotificationActionOptions.stringToValue[$0] }
            )
        )
    }

    // MARK: - Authorization

    private func getAuthorizationStatus(_ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:    result("authorized")
            case .denied:        result("denied")
            case .notDetermined: result("notDetermined")
            default:             result("unsupported")
            }
        }
    }

    private func requestNotificationPermissions(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()
        let args = call.arguments as? [String: Any] ?? [:]
        func flag(_ key: String) -> Bool { args[key] as? Bool ?? false }

        var options: UNAuthorizationOptions = []
        if flag("sound") { options.insert(.sound) }
        if flag("badge") { options.insert(.badge) }
        if flag("alert") { options.insert(.alert) }
        let provisionalRequested = flag("provisional")
        if provisionalRequested { options.insert(.provisional) }

        center.requestAuthorization(options: options) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                result(flutterError(error))
                return
            }
            center.getNotificationSettings { settings in
                let map: [String: Bool] = [
                    "sound": settings.soundSetting == .enabled,
                    "badge": settings.badgeSetting == .enabled,
                    "alert": settings.alertSetting == .enabled,
                    "provisional": granted && provisionalRequested,
                ]
                self.invoke("onIosSettingsRegistered", map)
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()   // must be main thread
            }
            result(granted)
        }
    }

    // MARK: - UISceneDelegate (the live path on migrated apps)

    // Cold start under UIScene: launchOptions is nil in didFinishLaunching, so the
    // launching notification arrives here. Observer only → return false to let the chain continue.
    public func scene(_ scene: UIScene,
                      willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
        guard let userInfo = connectionOptions?.notificationResponse?.notification.request.content.userInfo,
              userInfo["aps"] != nil else { return false }
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
        onMain {
            // Only seed if didReceive hasn't already stored the richer payload (incl. actionIdentifier).
            if self.launchNotification == nil { self.launchNotification = dict }
        }
        return false
    }

    public func sceneDidEnterBackground(_ scene: UIScene) { handleEnteredBackground() }
    public func sceneDidBecomeActive(_ scene: UIScene)    { handleBecameActive() }

    // MARK: - UIApplicationDelegate (kept for un-migrated / add-to-app hosts only)
    // On a migrated app UIKit never calls these, and the engine suppresses its app-event
    // fallback for scene-conforming plugins — so they cannot double-fire with the scene path.

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]) -> Bool {
        // launchOptions[.remoteNotification] is nil on UIScene apps; non-nil only on legacy hosts.
        if let remote = launchOptions[.remoteNotification] as? [String: Any] {
            let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: remote)
            onMain { if self.launchNotification == nil { self.launchNotification = dict } }
        }
        return true
    }

    public func applicationDidEnterBackground(_ application: UIApplication) { handleEnteredBackground() }
    public func applicationDidBecomeActive(_ application: UIApplication)    { handleBecameActive() }

    // MARK: - Single-sourced lifecycle (idempotent; safe even if both paths somehow fire)

    private func handleEnteredBackground() {
        onMain { self.resumingFromBackground = true }
    }

    private func handleBecameActive() {
        onMain {
            self.resumingFromBackground = false
            self.clearBadge()
        }
    }

    private func clearBadge() {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)            // setter is not scene-specific
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0           // deprecated iOS 17, legacy path only
        }
    }

    // MARK: - Remote notification (app-delegate only; no scene equivalent, never duplicated)

    public func application(_ application: UIApplication,
                            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        invoke("onToken", deviceToken.hexString)
    }

    public func application(_ application: UIApplication,
                            didFailToRegisterForRemoteNotificationsWithError error: Error) {
        invoke("onTokenError", error.localizedDescription)
    }

    public func application(_ application: UIApplication,
                            didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
        onMain {
            self.invoke(self.resumingFromBackground ? "onResume" : "onMessage", dict)
            completionHandler(.noData)   // guaranteed call
        }
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    private static var foregroundPresentationOptions: UNNotificationPresentationOptions {
        if #available(iOS 14.0, *) { return [.banner, .list, .badge, .sound] }
        else { return [.alert, .badge, .sound] }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        guard userInfo["aps"] != nil else { completionHandler([]); return }
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)

        onMain {
            // One-shot guard + timeout: the handler fires exactly once even if Dart never replies.
            var done = false
            let complete: (UNNotificationPresentationOptions) -> Void = { opts in
                guard !done else { return }
                done = true
                completionHandler(opts)
            }
            let fallback = DispatchWorkItem { complete([]) }   // CRITICAL: no dropped handler
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.willPresentTimeout, execute: fallback)

            self.invoke("willPresent", dict) { [weak self] response in
                fallback.cancel()
                if (response as? Bool) ?? false {
                    complete(Self.foregroundPresentationOptions)
                } else {
                    complete([])
                    self?.invoke("onMessage", dict)
                }
            }
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        var userInfo = response.notification.request.content.userInfo
        guard userInfo["aps"] != nil else { completionHandler(); return }
        userInfo["actionIdentifier"] = response.actionIdentifier
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)

        onMain {
            // Cold-start detection is order-independent: if Dart hasn't called configure() yet,
            // the engine isn't ready, so this tap MUST be the launch tap → defer to onLaunch.
            if !self.isConfigured {
                self.launchNotification = dict      // richer than scene/app seed (has actionIdentifier)
                completionHandler()
                return
            }
            self.invoke("onResume", dict)           // app already live → resume
            completionHandler()
        }
    }
}

// MARK: - Option string maps

extension UNNotificationCategoryOptions {
    static let stringToValue: [String: UNNotificationCategoryOptions] = {
        var r: [String: UNNotificationCategoryOptions] = [
            "UNNotificationCategoryOptions.customDismissAction": .customDismissAction,
            "UNNotificationCategoryOptions.allowInCarPlay": .allowInCarPlay,
            "UNNotificationCategoryOptions.hiddenPreviewsShowTitle": .hiddenPreviewsShowTitle,
            "UNNotificationCategoryOptions.hiddenPreviewsShowSubtitle": .hiddenPreviewsShowSubtitle,
        ]
        if #available(iOS 13.0, *) {
            r["UNNotificationCategoryOptions.allowAnnouncement"] = .allowAnnouncement
        }
        return r
    }()
}

extension UNNotificationActionOptions {
    static let stringToValue: [String: UNNotificationActionOptions] = [
        "UNNotificationActionOptions.authenticationRequired": .authenticationRequired,
        "UNNotificationActionOptions.destructive": .destructive,
        "UNNotificationActionOptions.foreground": .foreground,
    ]
}

extension Data {
    var hexString: String {
        map { String(format: "%02.2hhx", $0) }.joined()
    }
}