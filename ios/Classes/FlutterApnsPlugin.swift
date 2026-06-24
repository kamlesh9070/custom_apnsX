import Flutter
import UserNotifications

private func flutterError(_ error: Error) -> FlutterError {
    let e = error as NSError
    return FlutterError(code: "apns_error_\(e.code)", message: e.localizedDescription, details: e.domain)
}

@objc public class FlutterApnsPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate, FlutterSceneLifeCycleDelegate {

    private let channel: FlutterMethodChannel
    private var launchNotification: [String: Any]?
    private var resumingFromBackground = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_apns", binaryMessenger: registrar.messenger())
        let instance = FlutterApnsPlugin(channel: channel)
        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)  
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - Channel helpers

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
                    message: "UNUserNotificationCenter.current().delegate is nil. Assign it in AppDelegate before calling configure(). See https://pub.dev/packages/flutter_apns",
                    details: nil
                ))
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            if let launch = launchNotification {
                launchNotification = nil
                invoke("onLaunch", launch)
            }
            result(nil)

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
            // registerForRemoteNotifications must run on the main thread.
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            result(granted)
        }
    }

    // Cold start: launchOptions is nil under UIScene, so the notification that
    // launched the app arrives here instead of in didFinishLaunching.
    public func scene(_ scene: UIScene,
                  willConnectTo session: UISceneSession,
                  options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    if let userInfo = connectionOptions?.notificationResponse?.notification.request.content.userInfo,
       userInfo["aps"] != nil {
        launchNotification = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
    }
    return false   //  observer only — let the chain continue to other plugins
}


    // MARK: - UISceneDelegate (replaces the application* equivalents post-migration)

    public func sceneDidEnterBackground(_ scene: UIScene) {
        resumingFromBackground = true               // mirrors applicationDidEnterBackground
    }

    public func sceneDidBecomeActive(_ scene: UIScene) {
        resumingFromBackground = false
        clearBadge()                                // mirrors applicationDidBecomeActive
    }

    // MARK: - UIApplicationDelegate

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]) -> Bool {
        if let remote = launchOptions[.remoteNotification] as? [String: Any] {
            launchNotification = FlutterApnsSerialization.remoteMessageUserInfo(toDict: remote)
        }
        return true
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        resumingFromBackground = true
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        resumingFromBackground = false
        clearBadge()
    }

    private func clearBadge() {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

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
        invoke(resumingFromBackground ? "onResume" : "onMessage", dict)
        completionHandler(.noData)
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    private static var foregroundPresentationOptions: UNNotificationPresentationOptions {
        if #available(iOS 14.0, *) {
            return [.banner, .list, .badge, .sound]
        } else {
            return [.alert, .badge, .sound]
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        guard userInfo["aps"] != nil else {
            completionHandler([])   // always call the handler
            return
        }
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
        invoke("willPresent", dict) { [weak self] response in
            let shouldShow = (response as? Bool) ?? false
            if shouldShow {
                completionHandler(Self.foregroundPresentationOptions)
            } else {
                completionHandler([])
                self?.invoke("onMessage", dict)
            }
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        var userInfo = response.notification.request.content.userInfo
        guard userInfo["aps"] != nil else {
            completionHandler()     // always call the handler
            return
        }
        userInfo["actionIdentifier"] = response.actionIdentifier
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)

        // Cold start via notification tap: defer to configure() -> onLaunch.
        if launchNotification != nil {
            launchNotification = dict
            completionHandler()
            return
        }
        invoke("onResume", dict)
        completionHandler()
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