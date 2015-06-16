/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import Storage
import AVFoundation

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var browserViewController: BrowserViewController!
    weak var profile: BrowserProfile?

    let appVersion = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") as! String

    func application(application: UIApplication, willFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
        // Set the Firefox UA for browsing.
        setUserAgent()

        // Start the keyboard helper to monitor and cache keyboard state.
        KeyboardHelper.defaultHelper.startObserving()

        let profile = getProfile(application)

        // Set up a web server that serves us static content. Do this early so that it is ready when the UI is presented.
        setUpWebServer(profile)

        // for aural progress bar: play even with silent switch on, and do not stop audio from other apps (like music)
        AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback, withOptions: AVAudioSessionCategoryOptions.MixWithOthers, error: nil)

        self.window = UIWindow(frame: UIScreen.mainScreen().bounds)
        self.window!.backgroundColor = UIColor.whiteColor()

        let defaultRequest = NSURLRequest(URL: AppConstants.AboutHomeURL)
        let tabManager = TabManager(defaultNewTabRequest: defaultRequest, prefs: profile.prefs)

        browserViewController = BrowserViewController(profile: profile, tabManager: tabManager)

        // Add restoration class, the factory that will return the ViewController we 
        // will restore with.
        browserViewController.restorationIdentifier = NSStringFromClass(BrowserViewController.self)
        browserViewController.restorationClass = AppDelegate.self

        self.window!.rootViewController = browserViewController
        self.window!.backgroundColor = AppConstants.AppBackgroundColor

        NSNotificationCenter.defaultCenter().addObserverForName(FSReadingListAddReadingListItemNotification, object: nil, queue: nil) { (notification) -> Void in
            if let userInfo = notification.userInfo, url = userInfo["URL"] as? NSURL, absoluteString = url.absoluteString {
                let title = (userInfo["Title"] as? String) ?? ""
                profile.readingList?.createRecordWithURL(absoluteString, title: title, addedBy: UIDevice.currentDevice().name)
            }
        }

        // Force a database upgrade by requesting a non-existent password
        profile.logins.getLoginsForProtectionSpace(NSURLProtectionSpace(host: "example.com", port: 0, `protocol`: nil, realm: nil, authenticationMethod: nil))

        // check to see if we started cos someone tapped on a notification
        if let localNotification = launchOptions?[UIApplicationLaunchOptionsLocalNotificationKey] as? UILocalNotification {
            if let alertURL = localNotification.alertBody {
                browserViewController.openURLInNewTab(NSURL(string: alertURL)!)
            }
        }

        return true
    }

    /**
     * We maintain a weak reference to the profile so that we can pause timed
     * syncs when we're backgrounded.
     *
     * The long-lasting ref to the profile lives in BrowserViewController,
     * which we set in application:willFinishLaunchingWithOptions:.
     *
     * If that ever disappears, we won't be able to grab the profile to stop
     * syncing... but in that case the profile's deinit will take care of things.
     */
    func getProfile(application: UIApplication) -> Profile {
        if let profile = self.profile {
            return profile
        }
        let p = BrowserProfile(localName: "profile", app: application)
        self.profile = p
        return p
    }

    func application(application: UIApplication, didFinishLaunchingWithOptions launchOptions: [NSObject : AnyObject]?) -> Bool {
        self.window!.makeKeyAndVisible()
        return true
    }

    // We sync in the foreground only, to avoid the possibility of runaway resource usage.
    // Eventually we'll sync in response to notifications.
    func applicationDidBecomeActive(application: UIApplication) {
        self.profile?.syncManager.beginTimedHistorySync()
    }

    func applicationDidEnterBackground(application: UIApplication) {
        self.profile?.syncManager.endTimedHistorySync()
    }

    private func setUpWebServer(profile: Profile) {
        let server = WebServer.sharedInstance
        ReaderModeHandlers.register(server, profile: profile)
        ErrorPageHelper.register(server)
        AboutHomeHandler.register(server)
        server.start()
    }

    private func setUserAgent() {
        let currentiOSVersion = UIDevice.currentDevice().systemVersion
        let lastiOSVersion = NSUserDefaults.standardUserDefaults().stringForKey("LastDeviceSystemVersionNumber")
        var firefoxUA = NSUserDefaults.standardUserDefaults().stringForKey("UserAgent")
        if firefoxUA == nil
            || lastiOSVersion != currentiOSVersion {
            let webView = UIWebView()

            NSUserDefaults.standardUserDefaults().setObject(currentiOSVersion,forKey: "LastDeviceSystemVersionNumber")
            let userAgent = webView.stringByEvaluatingJavaScriptFromString("navigator.userAgent")!

            // Extract the WebKit version and use it as the Safari version.
            let webKitVersionRegex = NSRegularExpression(pattern: "AppleWebKit/([^ ]+) ", options: nil, error: nil)!
            let match = webKitVersionRegex.firstMatchInString(userAgent, options: nil, range: NSRange(location: 0, length: count(userAgent)))
            if match == nil {
                println("Error: Unable to determine WebKit version")
                return
            }
            let webKitVersion = (userAgent as NSString).substringWithRange(match!.rangeAtIndex(1))

            // Insert "FxiOS/<version>" before the Mobile/ section.
            let mobileRange = (userAgent as NSString).rangeOfString("Mobile/")
            if mobileRange.location == NSNotFound {
                println("Error: Unable to find Mobile section")
                return
            }

            let mutableUA = NSMutableString(string: userAgent)
            mutableUA.insertString("FxiOS/\(appVersion) ", atIndex: mobileRange.location)
            firefoxUA = "\(mutableUA) Safari/\(webKitVersion)"
            NSUserDefaults.standardUserDefaults().setObject(firefoxUA, forKey: "UserAgent")
        }
        NSUserDefaults.standardUserDefaults().registerDefaults(["UserAgent": firefoxUA!])

        SDWebImageDownloader.sharedDownloader().setValue(firefoxUA, forHTTPHeaderField: "User-Agent")
    }

    func application(application: UIApplication, handleActionWithIdentifier identifier: String?, forLocalNotification notification: UILocalNotification, completionHandler: () -> Void) {
        if let actionId = identifier {
            if let action = SentTabAction(rawValue: actionId) {
                switch(action) {
                case .View:
                    viewURLInNewTab(notification)
                    break
                case .Bookmark:
                    addBookmark(notification)
                    break
                case .ReadingList:
                    addToReadingList(notification)
                    break
                }
            } else {
                println("ERROR: Unknown notification action received")
            }
        } else {
            println("ERROR: Unknown notification received")
        }
    }

    func application(application: UIApplication, didReceiveLocalNotification notification: UILocalNotification) {
        viewURLInNewTab(notification)
    }

    private func viewURLInNewTab(notification: UILocalNotification) {
        if let alertURL = notification.userInfo?[TabSendURLKey] as? String{
            browserViewController.openURLInNewTab(NSURL(string: alertURL)!)
        }
    }

    private func addBookmark(notification: UILocalNotification) {
        if let alertURL = notification.userInfo?[TabSendURLKey] as? String,
            let title = notification.userInfo?[TabSendTitleKey] as? String {
                browserViewController.addBookmark(alertURL, title: title)
        }
    }

    private func addToReadingList(notification: UILocalNotification) {
        if let alertURL = notification.userInfo?[TabSendURLKey] as? String,
            let title = notification.userInfo?[TabSendTitleKey] as? String {
                NSNotificationCenter.defaultCenter().postNotificationName(FSReadingListAddReadingListItemNotification, object: self, userInfo: ["URL": NSURL(string: alertURL)!, "Title": title])
        }
    }
}

extension AppDelegate: UIApplicationDelegate {
    func application(application: UIApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        return true
    }

    func application(application: UIApplication, shouldRestoreApplicationState code: NSCoder) -> Bool {
        return true
    }
}

extension AppDelegate: UIViewControllerRestoration {
    class func viewControllerWithRestorationIdentifierPath(identifierComponents: [AnyObject], coder: NSCoder) -> UIViewController? {
        // There is only one restorationIdentifier in circulation.
        if let appDelegate = UIApplication.sharedApplication().delegate as? AppDelegate {
            return appDelegate.window!.rootViewController
        }
        return nil
    }
}
