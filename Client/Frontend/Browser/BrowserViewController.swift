/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import WebKit
import Shared
import Storage
import SnapKit
import XCGLogger
import Alamofire

private let log = XCGLogger.defaultInstance()

private let OKString = NSLocalizedString("OK", comment: "OK button")
private let CancelString = NSLocalizedString("Cancel", comment: "Cancel button")

private let KVOLoading = "loading"
private let KVOEstimatedProgress = "estimatedProgress"

private struct BrowserViewControllerUX {
    private static let ToolbarBaseAnimationDuration: CGFloat = 0.3
    private static let BackgroundColor = AppConstants.AppBackgroundColor
    private static let ShowHeaderTapAreaHeight: CGFloat = 32
}

class BrowserViewController: UIViewController {

    private var urlBar: URLBarView!
    private var readerModeBar: ReaderModeBarView?
    private var statusBarOverlay: UIView!
    private var toolbar: BrowserToolbar?
    private var homePanelController: HomePanelViewController?
    private var searchController: SearchViewController?
    private var webViewContainer: UIView!
    private let uriFixup = URIFixup()
    private var screenshotHelper: ScreenshotHelper!
    private var homePanelIsInline = false
    private var searchLoader: SearchLoader!
    private let snackBars = UIView()
    private let auralProgress = AuralProgressBar()

    private weak var tabTrayController: TabTrayController!

    private let profile: Profile
    private let tabManager: TabManager

    // These views wrap the urlbar and toolbar to provide background effects on them
    private var header: UIView!
    private var footer: UIView!
    private var footerBackground: UIView!
    private var topTouchArea: UIButton!

    // Scroll management properties
    private var previousScroll: CGPoint?

    private var headerConstraint: Constraint?
    private var headerConstraintOffset: CGFloat = 0

    private var footerConstraint: Constraint?
    private var footerConstraintOffset: CGFloat = 0

    private var readerConstraint: Constraint?
    private var readerConstraintOffset: CGFloat = 0

    let WhiteListedUrls = ["\\/\\/itunes\\.apple\\.com\\/"]

    // Tracking navigation items to record history types.
    // TODO: weak references?
    var ignoredNavigation = Set<WKNavigation>()
    var typedNavigation = [WKNavigation: VisitType]()
    var navigationToolbar: BrowserToolbarProtocol {
        return toolbar ?? urlBar
    }

    init(profile: Profile, tabManager: TabManager) {
        self.profile = profile
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
        didInit()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func supportedInterfaceOrientations() -> Int {
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            return Int(UIInterfaceOrientationMask.AllButUpsideDown.rawValue)
        } else {
            return Int(UIInterfaceOrientationMask.All.rawValue)
        }
    }

    private func didInit() {
        screenshotHelper = BrowserScreenshotHelper(controller: self)
        tabManager.addDelegate(self)
        tabManager.addNavigationDelegate(self)
    }

    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        if header == nil {
            return UIStatusBarStyle.LightContent
        }
        if header.transform.ty == 0 {
            return UIStatusBarStyle.LightContent
        }
        return UIStatusBarStyle.Default
    }

    func shouldShowToolbarForTraitCollection(previousTraitCollection: UITraitCollection) -> Bool {
        return previousTraitCollection.verticalSizeClass != .Compact &&
               previousTraitCollection.horizontalSizeClass != .Regular
    }

    private func updateToolbarStateForTraitCollection(newCollection: UITraitCollection) {
        let showToolbar = shouldShowToolbarForTraitCollection(newCollection)

        urlBar.setShowToolbar(!showToolbar)
        toolbar?.removeFromSuperview()
        toolbar?.browserToolbarDelegate = nil
        footerBackground?.removeFromSuperview()
        footerBackground = nil
        toolbar = nil

        if showToolbar {
            toolbar = BrowserToolbar()
            toolbar?.browserToolbarDelegate = self
            footerBackground = wrapInEffect(toolbar!, parent: footer)
        }

        view.setNeedsUpdateConstraints()
        if let home = homePanelController {
            home.view.setNeedsUpdateConstraints()
        }

        if let tab = tabManager.selectedTab {
            navigationToolbar.updateBackStatus(tab.canGoBack)
            navigationToolbar.updateForwardStatus(tab.canGoForward)
            let isPage = (tab.displayURL != nil) ? isWebPage(tab.displayURL!) : false
            navigationToolbar.updatePageStatus(isWebPage: isPage)
            navigationToolbar.updateReloadStatus(tab.loading ?? false)

            if let url = tab.displayURL?.absoluteString {
                profile.bookmarks.isBookmarked(url, success: { bookmarked in
                    self.navigationToolbar.updateBookmarkStatus(bookmarked)
                }, failure: { err in
                    log.error("Error getting bookmark status: \(err).")
                })
            }
        }
    }

    override func willTransitionToTraitCollection(newCollection: UITraitCollection, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransitionToTraitCollection(newCollection, withTransitionCoordinator: coordinator)
        updateToolbarStateForTraitCollection(newCollection)

        // WKWebView looks like it has a bug where it doesn't invalidate it's visible area when the user
        // performs a device rotation. Since scrolling calls
        // _updateVisibleContentRects (https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/API/Cocoa/WKWebView.mm#L1430)
        // this method nudges the web view's scroll view by a single pixel to force it to invalidate.
        if let scrollView = self.tabManager.selectedTab?.webView?.scrollView {
            let contentOffset = scrollView.contentOffset
            coordinator.animateAlongsideTransition({ context in
                self.updateHeaderFooterConstraintsAndAlpha(
                    headerOffset: 0,
                    footerOffset: 0,
                    readerOffset: 0,
                    alpha: 1)
                self.view.layoutIfNeeded()

                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + 1), animated: true)
            }, completion: { context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y), animated: false)
            })
        }
    }

    func SELstatusBarFrameWillChange(notification: NSNotification) {
        if let statusBarFrame = notification.userInfo![UIApplicationStatusBarFrameUserInfoKey] as? NSValue {
            showToolbars(animated: false)
            self.view.setNeedsUpdateConstraints()
        }
    }

    func SELtappedTopArea() {
        showToolbars(animated: true, completion: nil)
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillChangeStatusBarFrameNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: BookmarkStatusChangedNotification, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "SELstatusBarFrameWillChange:", name: UIApplicationWillChangeStatusBarFrameNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "SELBookmarkStatusDidChange:", name: BookmarkStatusChangedNotification, object: nil)

        webViewContainer = UIView()
        view.addSubview(webViewContainer)

        // Temporary work around for covering the non-clipped web view content
        statusBarOverlay = UIView()
        statusBarOverlay.backgroundColor = BrowserViewControllerUX.BackgroundColor
        view.addSubview(statusBarOverlay)

        topTouchArea = UIButton()
        topTouchArea.addTarget(self, action: "SELtappedTopArea", forControlEvents: UIControlEvents.TouchUpInside)
        view.addSubview(topTouchArea)

        // Setup the URL bar, wrapped in a view to get transparency effect
        urlBar = URLBarView()
        urlBar.setTranslatesAutoresizingMaskIntoConstraints(false)
        urlBar.delegate = self
        urlBar.browserToolbarDelegate = self
        header = wrapInEffect(urlBar, parent: view, backgroundColor: nil)

        searchLoader = SearchLoader(history: profile.history, urlBar: urlBar)

        footer = UIView()
        self.view.addSubview(footer)
        footer.addSubview(snackBars)
        snackBars.backgroundColor = UIColor.clearColor()
        self.updateToolbarStateForTraitCollection(self.traitCollection)
    }

    func startTrackingAccessibilityStatus() {
        NSNotificationCenter.defaultCenter().addObserverForName(UIAccessibilityVoiceOverStatusChanged, object: nil, queue: nil) { (notification) -> Void in
            self.auralProgress.hidden = !UIAccessibilityIsVoiceOverRunning()
        }
        auralProgress.hidden = !UIAccessibilityIsVoiceOverRunning()
    }

    func stopTrackingAccessibilityStatus() {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIAccessibilityVoiceOverStatusChanged, object: nil)
        auralProgress.hidden = true
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)

        // On iPhone, if we are about to show the On-Boarding, blank out the browser so that it does
        // not flash before we present. This change of alpha also participates in the animation when
        // the intro view is dismissed.
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            self.view.alpha = (profile.prefs.intForKey(IntroViewControllerSeenProfileKey) != nil) ? 1.0 : 0.0
        }

        if (tabManager.count == 0) {
            let tab = tabManager.addTab()
            tabManager.selectTab(tab)
        }
    }

    override func viewDidAppear(animated: Bool) {
        startTrackingAccessibilityStatus()
        presentIntroViewController()
        super.viewDidAppear(animated)
    }

    override func viewDidDisappear(animated: Bool) {
        stopTrackingAccessibilityStatus()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()

        statusBarOverlay.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)
            make.height.equalTo(UIApplication.sharedApplication().statusBarFrame.height)
            make.bottom.equalTo(header.snp_top)
        }

        topTouchArea.snp_remakeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(BrowserViewControllerUX.ShowHeaderTapAreaHeight)
        }

        urlBar.snp_remakeConstraints { make in
            make.edges.equalTo(self.header)
        }

        header.snp_remakeConstraints { make in
            let topLayoutGuide = self.topLayoutGuide as! UIView
            self.headerConstraint = make.top.equalTo(topLayoutGuide.snp_bottom).constraint
            make.height.equalTo(AppConstants.ToolbarHeight)
            make.left.right.equalTo(self.view)
        }
        header.setNeedsUpdateConstraints()

        readerModeBar?.snp_remakeConstraints { make in
            self.readerConstraint = make.top.equalTo(self.header.snp_bottom).constraint
            make.height.equalTo(AppConstants.ToolbarHeight)
            make.leading.trailing.equalTo(self.view)
        }

        webViewContainer.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)

            if let readerModeBarBottom = readerModeBar?.snp_bottom {
                make.top.equalTo(readerModeBarBottom)
            } else {
                make.top.equalTo(self.header.snp_bottom)
            }

            if let toolbar = self.toolbar {
                make.bottom.equalTo(toolbar.snp_top)
            } else {
                make.bottom.equalTo(self.view)
            }
        }

        // Setup the bottom toolbar
        toolbar?.snp_remakeConstraints { make in
            make.edges.equalTo(self.footerBackground!)
            make.height.equalTo(AppConstants.ToolbarHeight)
        }

        footer.snp_remakeConstraints { [unowned self] make in
            let bars = self.footer.subviews
            self.footerConstraint = make.bottom.equalTo(self.view.snp_bottom).constraint
            make.top.equalTo(self.snackBars.snp_top)
            make.leading.trailing.equalTo(self.view)
        }

        adjustFooterSize(top: nil)
        footerBackground?.snp_remakeConstraints { make in
            make.bottom.left.right.equalTo(self.footer)
            make.height.equalTo(AppConstants.ToolbarHeight)
        }
        urlBar.setNeedsUpdateConstraints()

        // Remake constraints even if we're already showing the home controller.
        // The home controller may change sizes if we tap the URL bar while on about:home.
        homePanelController?.view.snp_remakeConstraints { make in
            make.top.equalTo(self.urlBar.snp_bottom)
            make.left.right.equalTo(self.view)
            if self.homePanelIsInline {
                make.bottom.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            } else {
                make.bottom.equalTo(self.view.snp_bottom)
            }
        }
    }

    private func wrapInEffect(view: UIView, parent: UIView) -> UIView {
        return self.wrapInEffect(view, parent: parent, backgroundColor: UIColor.clearColor())
    }

    private func wrapInEffect(view: UIView, parent: UIView, backgroundColor: UIColor?) -> UIView {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: UIBlurEffectStyle.ExtraLight))
        effect.setTranslatesAutoresizingMaskIntoConstraints(false)
        if let background = backgroundColor {
            view.backgroundColor = backgroundColor
        }
        effect.addSubview(view)

        parent.addSubview(effect)
        return effect
    }

    private func showHomePanelController(#inline: Bool) {
        homePanelIsInline = inline

        if homePanelController == nil {
            homePanelController = HomePanelViewController()
            homePanelController!.profile = profile
            homePanelController!.delegate = self
            homePanelController!.url = tabManager.selectedTab?.displayURL
            homePanelController!.view.alpha = 0
            view.addSubview(homePanelController!.view)

            addChildViewController(homePanelController!)
        }

        var panelNumber = tabManager.selectedTab?.url?.fragment
        var numberArray = panelNumber?.componentsSeparatedByString("=")
        homePanelController?.selectedButtonIndex = numberArray?.last?.toInt() ?? 0

        // We have to run this animation, even if the view is already showing because there may be a hide animation running
        // and we want to be sure to override its results.
        UIView.animateWithDuration(0.2, animations: { () -> Void in
            self.homePanelController!.view.alpha = 1
        }, completion: { finished in
            if finished {
                self.webViewContainer.accessibilityElementsHidden = true
                self.stopTrackingAccessibilityStatus()
                UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            }
        })
        toolbar?.hidden = !inline
        view.setNeedsUpdateConstraints()
    }

    private func hideHomePanelController() {
        if let controller = homePanelController {
            UIView.animateWithDuration(0.2, delay: 0, options: .BeginFromCurrentState, animations: { () -> Void in
                controller.view.alpha = 0
            }, completion: { finished in
                if finished {
                    controller.view.removeFromSuperview()
                    controller.removeFromParentViewController()
                    self.homePanelController = nil
                    self.webViewContainer.accessibilityElementsHidden = false
                    self.toolbar?.hidden = false
                    self.startTrackingAccessibilityStatus()
                    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)

                    // Refresh the reading view toolbar since the article record may have changed
                    if let readerMode = self.tabManager.selectedTab?.getHelper(name: ReaderMode.name()) as? ReaderMode where readerMode.state == .Active {
                        self.showReaderModeBar(animated: false)
                    }
                }
            })
        }
    }

    private func updateInContentHomePanel(url: NSURL?) {
        if !urlBar.isEditing {
            if AboutUtils.isAboutHomeURL(url){
                showHomePanelController(inline: (tabManager.selectedTab?.canGoForward ?? false || tabManager.selectedTab?.canGoBack ?? false))
            } else {
                hideHomePanelController()
            }
        }
    }

    private func showSearchController() {
        if searchController != nil {
            return
        }

        searchController = SearchViewController()
        searchController!.searchEngines = profile.searchEngines
        searchController!.searchDelegate = self
        searchController!.profile = self.profile

        searchLoader.addListener(searchController!)

        view.addSubview(searchController!.view)
        searchController!.view.snp_makeConstraints { make in
            make.top.equalTo(self.urlBar.snp_bottom)
            make.left.right.bottom.equalTo(self.view)
            return
        }

        homePanelController?.view?.hidden = true

        addChildViewController(searchController!)
    }

    private func hideSearchController() {
        if let searchController = searchController {
            searchController.view.removeFromSuperview()
            searchController.removeFromParentViewController()
            self.searchController = nil
            homePanelController?.view?.hidden = false
        }
    }

    private func finishEditingAndSubmit(var url: NSURL, visitType: VisitType) {
        urlBar.currentURL = url
        urlBar.finishEditing()

        if let tab = tabManager.selectedTab,
           let nav = tab.loadRequest(NSURLRequest(URL: url)) {
            self.recordNavigationInTab(tab, navigation: nav, visitType: visitType)
        }
    }

    func addBookmark(url: String, title: String?) {
        let shareItem = ShareItem(url: url, title: title, favicon: nil)
        profile.bookmarks.shareItem(shareItem)

        // Dispatch to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue()) { _ in
            self.toolbar?.updateBookmarkStatus(true)
            self.urlBar.updateBookmarkStatus(true)
        }
    }

    private func removeBookmark(url: String) {
        profile.bookmarks.removeByURL(url, success: { success in
            self.toolbar?.updateBookmarkStatus(!success)
            self.urlBar.updateBookmarkStatus(!success)
        }, failure: { err in
            log.error("Error removing bookmark: \(err).")
        })
    }

    func SELBookmarkStatusDidChange(notification: NSNotification) {
        if let bookmark = notification.object as? BookmarkItem {
            if bookmark.url == urlBar.currentURL?.absoluteString {
                if let userInfo = notification.userInfo as? Dictionary<String, Bool>{
                    if let added = userInfo["added"]{
                        self.toolbar?.updateBookmarkStatus(added)
                        self.urlBar.updateBookmarkStatus(added)
                    }
                }
            }
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if urlBar.isEditing {
            urlBar.SELdidClickCancel()
            return true
        } else if let selectedTab = tabManager.selectedTab where selectedTab.canGoBack {
            selectedTab.goBack()
            return true
        }
        return false
    }

    override func observeValueForKeyPath(keyPath: String, ofObject object: AnyObject, change: [NSObject: AnyObject], context: UnsafeMutablePointer<Void>) {
        if object as? WKWebView !== tabManager.selectedTab?.webView {
            return
        }

        switch keyPath {
        case KVOEstimatedProgress:
            let progress = change[NSKeyValueChangeNewKey] as! Float
            urlBar.updateProgressBar(progress)
            // when loading is stopped, KVOLoading is fired first, and only then KVOEstimatedProgress with progress 1.0 which would leave the progress bar running
            if progress != 1.0 || tabManager.selectedTab?.loading ?? false {
                auralProgress.progress = Double(progress)
            }
        case KVOLoading:
            let loading = change[NSKeyValueChangeNewKey] as! Bool
            toolbar?.updateReloadStatus(loading)
            urlBar.updateReloadStatus(loading)
            auralProgress.progress = loading ? 0 : nil
        default:
            assertionFailure("Unhandled KVO key: \(keyPath)")
        }
    }

    private func isWhitelistedUrl(url: NSURL) -> Bool {
        for entry in WhiteListedUrls {
            if let match = url.absoluteString!.rangeOfString(entry, options: .RegularExpressionSearch) {
                return UIApplication.sharedApplication().canOpenURL(url)
            }
        }
        return false
    }

    private func updateNavigationToolbarStates(tab: Browser, webView: WKWebView) {
        urlBar.currentURL = tab.displayURL
        navigationToolbar.updateBackStatus(webView.canGoBack)
        navigationToolbar.updateForwardStatus(webView.canGoForward)

        if let url = tab.displayURL?.absoluteString {
            profile.bookmarks.isBookmarked(url, success: { bookmarked in
                self.navigationToolbar.updateBookmarkStatus(bookmarked)
            }, failure: { err in
                log.error("Error getting bookmark status: \(err).")
            })
        }
    }

    func openURLInNewTab(url: NSURL) {
        log.info("Opening URL \(url) in new tab")

        let tab = tabManager.addTab()
        if let nav = tab.loadRequest(NSURLRequest(URL: url)) {
            self.recordNavigationInTab(tab, navigation: nav, visitType: VisitType.Typed)
            tabManager.selectTab(tab)
        }
        else {
            tabManager.removeTab(tab)
        }
    }
}

/**
 * History visit management.
 * TODO: this should be expanded to track various visit types; see Bug 1166084.
 */
extension BrowserViewController {
    func ignoreNavigationInTab(tab: Browser, navigation: WKNavigation) {
        self.ignoredNavigation.insert(navigation)
    }

    func recordNavigationInTab(tab: Browser, navigation: WKNavigation, visitType: VisitType) {
        self.typedNavigation[navigation] = visitType
    }

    /**
     * Untrack and do the right thing.
     */
    func getVisitTypeForTab(tab: Browser, navigation: WKNavigation?) -> VisitType? {
        if let navigation = navigation {
            if let ignored = self.ignoredNavigation.remove(navigation) {
                return nil
            }
            return self.typedNavigation.removeValueForKey(navigation) ?? VisitType.Link
        } else {
            // See https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/Cocoa/NavigationState.mm#L390
            return VisitType.Link
        }
    }
}

extension BrowserViewController: URLBarDelegate {
    func urlBarDidPressReload(urlBar: URLBarView) {
        tabManager.selectedTab?.reload()
    }

    func urlBarDidPressStop(urlBar: URLBarView) {
        tabManager.selectedTab?.stop()
    }

    func urlBarDidPressTabs(urlBar: URLBarView) {
        let tabTrayController = TabTrayController()
        tabTrayController.profile = profile
        tabTrayController.tabManager = tabManager
        tabTrayController.transitioningDelegate = self
        tabTrayController.modalPresentationStyle = .Custom

        if let tab = tabManager.selectedTab {
            tab.screenshot = screenshotHelper.takeScreenshot(tab, aspectRatio: 0, quality: 1)
        }

        presentViewController(tabTrayController, animated: true, completion: nil)
        self.tabTrayController = tabTrayController
    }

    func dismissTabTrayController(#animated: Bool, completion: () -> Void) {
        if let tabTrayController = tabTrayController {
            tabTrayController.dismissViewControllerAnimated(animated) {
                completion()
                self.tabTrayController = nil
            }
        }
    }

    func urlBarDidPressReaderMode(urlBar: URLBarView) {
        if let tab = tabManager.selectedTab {
            if let readerMode = tab.getHelper(name: "ReaderMode") as? ReaderMode {
                switch readerMode.state {
                case .Available:
                    enableReaderMode()
                case .Active:
                    disableReaderMode()
                case .Unavailable:
                    break
                }
            }
        }
    }

    func urlBarDidLongPressReaderMode(urlBar: URLBarView) {
        if let tab = tabManager.selectedTab {
            if var url = tab.displayURL {
                if let absoluteString = url.absoluteString {
                    let result = profile.readingList?.createRecordWithURL(absoluteString, title: tab.title ?? "", addedBy: UIDevice.currentDevice().name) // TODO Check result, can this fail?
                    // TODO Followup bug, provide some form of 'this has been added' feedback?
                }
            }
        }
    }

    func urlBarDidLongPressLocation(urlBar: URLBarView) {
        let longPressAlertController = UIAlertController(title: nil, message: nil, preferredStyle: .ActionSheet)

        let pasteboardContents = UIPasteboard.generalPasteboard().string

        // Check if anything is on the pasteboard
        if pasteboardContents != nil {
            let pasteAndGoAction = UIAlertAction(title: NSLocalizedString("Paste & Go", comment: "Paste the URL into the location bar and visit"), style: .Default, handler: { (alert: UIAlertAction!) -> Void in
                self.urlBar(urlBar, didSubmitText: pasteboardContents!)
            })
            longPressAlertController.addAction(pasteAndGoAction)

            let pasteAction = UIAlertAction(title: NSLocalizedString("Paste", comment: "Paste the URL into the location bar"), style: .Default, handler: { (alert: UIAlertAction!) -> Void in
                urlBar.updateURLBarText(pasteboardContents!)
            })
            longPressAlertController.addAction(pasteAction)
        }

        let copyAddressAction = UIAlertAction(title: NSLocalizedString("Copy Address", comment: "Copy the URL from the location bar"), style: .Default, handler: { (alert: UIAlertAction!) -> Void in
            UIPasteboard.generalPasteboard().string = urlBar.currentURL?.absoluteString
        })
        longPressAlertController.addAction(copyAddressAction)

        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel alert view"), style: .Cancel, handler: nil)
        longPressAlertController.addAction(cancelAction)

        if let popoverPresentationController = longPressAlertController.popoverPresentationController {
            popoverPresentationController.sourceView = urlBar
            popoverPresentationController.sourceRect = urlBar.frame
            popoverPresentationController.permittedArrowDirections = .Any
        }
        self.presentViewController(longPressAlertController, animated: true, completion: nil)
    }

    func urlBarDidPressScrollToTop(urlBar: URLBarView) {
        if let selectedTab = tabManager.selectedTab {
            // Only scroll to top if we are not showing the home view controller
            if homePanelController == nil {
                selectedTab.webView?.scrollView.setContentOffset(CGPointZero, animated: true)
            }
        }
    }

    func urlBar(urlBar: URLBarView, didEnterText text: String) {
        searchLoader.query = text

        if text.isEmpty {
            hideSearchController()
        } else {
            showSearchController()
            searchController!.searchQuery = text
        }
    }

    func urlBar(urlBar: URLBarView, didSubmitText text: String) {
        var url = uriFixup.getURL(text)

        // If we can't make a valid URL, do a search query.
        if url == nil {
            url = profile.searchEngines.defaultEngine.searchURLForQuery(text)
        }

        // If we still don't have a valid URL, something is broken. Give up.
        if url == nil {
            log.error("Error handling URL entry: \"\(text)\".")
            return
        }

        finishEditingAndSubmit(url!, visitType: VisitType.Typed)
    }

    func urlBarDidBeginEditing(urlBar: URLBarView) {
        // Pass the edit message along if we are already showing the home panel
        if let homePanelController = self.homePanelController where homePanelController.view.alpha == 1 {
            homePanelController.endEditing(nil)
        } else {
            showHomePanelController(inline: false)
        }
    }

    func urlBarDidEndEditing(urlBar: URLBarView) {
        hideSearchController()
        updateInContentHomePanel(tabManager.selectedTab?.url)
    }
}

extension BrowserViewController: BrowserToolbarDelegate {
    func browserToolbarDidPressBack(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.goBack()
    }

    func browserToolbarDidLongPressBack(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
// See 1159373 - Disable long press back/forward for backforward list
//        let controller = BackForwardListViewController()
//        controller.listData = tabManager.selectedTab?.backList
//        controller.tabManager = tabManager
//        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressReload(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.reload()
    }

    func browserToolbarDidPressStop(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.stop()
    }

    func browserToolbarDidPressForward(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.goForward()
    }

    func browserToolbarDidLongPressForward(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
// See 1159373 - Disable long press back/forward for backforward list
//        let controller = BackForwardListViewController()
//        controller.listData = tabManager.selectedTab?.forwardList
//        controller.tabManager = tabManager
//        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressBookmark(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        if let tab = tabManager.selectedTab,
           let url = tab.displayURL?.absoluteString {
            profile.bookmarks.isBookmarked(url,
                success: { isBookmarked in
                    if isBookmarked {
                        self.removeBookmark(url)
                    } else {
                        self.addBookmark(url, title: tab.title)
                    }
                },
                failure: { err in
                    log.error("Bookmark error: \(err).")
                }
            )
        } else {
            log.error("Bookmark error: No tab is selected, or no URL in tab.")
        }
    }

    func browserToolbarDidLongPressBookmark(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
    }

    func browserToolbarDidPressShare(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        if let selected = tabManager.selectedTab {
            if let url = selected.displayURL {
                var activityViewController = UIActivityViewController(activityItems: [selected.title ?? url.absoluteString!, url], applicationActivities: nil)
                // Hide 'Add to Reading List' which currently uses Safari
                activityViewController.excludedActivityTypes = [UIActivityTypeAddToReadingList]
                if let popoverPresentationController = activityViewController.popoverPresentationController {
                    // Using the button for the sourceView here results in this not showing on iPads.
                    popoverPresentationController.sourceView = toolbar ?? urlBar
                    popoverPresentationController.sourceRect = button.frame ?? button.frame
                    popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirection.Up
                }
                presentViewController(activityViewController, animated: true, completion: nil)
            }
        }
    }
}

extension BrowserViewController: BrowserDelegate {

    func browser(browser: Browser, didCreateWebView webView: WKWebView) {
        webView.scrollView.delegate = self
        webViewContainer.insertSubview(webView, atIndex: 0)
        webView.snp_makeConstraints { make in
            make.edges.equalTo(self.webViewContainer)
        }

        // Observers that live as long as the tab. Make sure these are all cleared
        // in willDeleteWebView below!
        webView.addObserver(self, forKeyPath: KVOEstimatedProgress, options: .New, context: nil)
        webView.addObserver(self, forKeyPath: KVOLoading, options: .New, context: nil)
        webView.UIDelegate = self

        let readerMode = ReaderMode(browser: browser)
        readerMode.delegate = self
        browser.addHelper(readerMode, name: ReaderMode.name())

        let favicons = FaviconManager(browser: browser, profile: profile)
        browser.addHelper(favicons, name: FaviconManager.name())

        // Temporarily disable password support until the new code lands
        // let logins = LoginsHelper(browser: browser, profile: profile)
        //  browser.addHelper(logins, name: LoginsHelper.name())

        let contextMenuHelper = ContextMenuHelper(browser: browser)
        contextMenuHelper.delegate = self
        browser.addHelper(contextMenuHelper, name: ContextMenuHelper.name())

        let hashchangeHelper = HashchangeHelper(browser: browser)
        hashchangeHelper.delegate = self
        browser.addHelper(hashchangeHelper, name: HashchangeHelper.name())

        let errorHelper = ErrorPageHelper()
        browser.addHelper(errorHelper, name: ErrorPageHelper.name())
    }

    func browser(browser: Browser, willDeleteWebView webView: WKWebView) {
        webView.removeObserver(self, forKeyPath: KVOEstimatedProgress)
        webView.removeObserver(self, forKeyPath: KVOLoading)
        webView.UIDelegate = nil
        webView.scrollView.delegate = nil
        webView.removeFromSuperview()
    }

    private func findSnackbar(barToFind: SnackBar) -> Int? {
        let bars = snackBars.subviews
        for (index, bar) in enumerate(bars) {
            if bar === barToFind {
                return index
            }
        }
        return nil
    }

    private func adjustFooterSize(top: UIView? = nil) {
        snackBars.snp_remakeConstraints({ make in
            make.bottom.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            if traitCollection.horizontalSizeClass != .Regular {
                make.leading.trailing.equalTo(self.footer)
                self.snackBars.layer.borderWidth = 0
            } else {
                make.centerX.equalTo(self.footer)
                make.width.equalTo(SnackBarUX.MaxWidth)
                self.snackBars.layer.borderColor = AppConstants.BorderColor.CGColor
                self.snackBars.layer.borderWidth = 1
            }

            let bars = self.snackBars.subviews
            if bars.count > 0 {
                let view = bars[bars.count-1] as! UIView
                make.top.equalTo(view.snp_top)
            } else {
                make.top.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            }
        })
    }

    // This removes the bar from its superview and updates constraints appropriately
    private func finishRemovingBar(bar: SnackBar) {
        // If there was a bar above this one, we need to remake its constraints.
        if let index = findSnackbar(bar) {
            // If the bar being removed isn't on the top of the list
            let bars = snackBars.subviews
            if index < bars.count-1 {
                // Move the bar above this one
                var nextbar = bars[index+1] as! SnackBar
                nextbar.snp_updateConstraints { make in
                    // If this wasn't the bottom bar, attach to the bar below it
                    if index > 0 {
                        let bar = bars[index-1] as! SnackBar
                        nextbar.bottom = make.bottom.equalTo(bar.snp_top).constraint
                    } else {
                        // Otherwise, we attach it to the bottom of the snackbars
                        nextbar.bottom = make.bottom.equalTo(self.snackBars.snp_bottom).constraint
                    }
                }
            }
        }

        // Really remove the bar
        bar.removeFromSuperview()
    }

    private func finishAddingBar(bar: SnackBar) {
        snackBars.addSubview(bar)
        bar.snp_remakeConstraints({ make in
            // If there are already bars showing, add this on top of them
            let bars = self.snackBars.subviews

            // Add the bar on top of the stack
            // We're the new top bar in the stack, so make sure we ignore ourself
            if bars.count > 1 {
                let view = bars[bars.count - 2] as! UIView
                bar.bottom = make.bottom.equalTo(view.snp_top).offset(0).constraint
            } else {
                bar.bottom = make.bottom.equalTo(self.snackBars.snp_bottom).offset(0).constraint
            }
            make.leading.trailing.equalTo(self.snackBars)
        })
    }

    func showBar(bar: SnackBar, animated: Bool) {
        finishAddingBar(bar)
        adjustFooterSize(top: bar)

        bar.hide()
        view.layoutIfNeeded()
        UIView.animateWithDuration(animated ? 0.25 : 0, animations: { () -> Void in
            bar.show()
            self.view.layoutIfNeeded()
        })
    }

    func removeBar(bar: SnackBar, animated: Bool) {
        let index = findSnackbar(bar)!
        UIView.animateWithDuration(animated ? 0.25 : 0, animations: { () -> Void in
            bar.hide()
            self.view.layoutIfNeeded()
        }) { success in
            // Really remove the bar
            self.finishRemovingBar(bar)

            // Adjust the footer size to only contain the bars
            self.adjustFooterSize()
        }
    }

    func removeAllBars() {
        let bars = snackBars.subviews
        for bar in bars {
            if let bar = bar as? SnackBar {
                bar.removeFromSuperview()
            }
        }
        self.adjustFooterSize()
    }

    func browser(browser: Browser, didAddSnackbar bar: SnackBar) {
        showBar(bar, animated: true)
    }

    func browser(browser: Browser, didRemoveSnackbar bar: SnackBar) {
        removeBar(bar, animated: true)
    }
}

extension BrowserViewController: HomePanelViewControllerDelegate {
    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectURL url: NSURL, visitType: VisitType) {
        finishEditingAndSubmit(url, visitType: visitType)
    }

    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectPanel panel: Int) {
        if AboutUtils.isAboutHomeURL(tabManager.selectedTab?.url) {
            tabManager.selectedTab?.webView?.evaluateJavaScript("history.replaceState({}, '', '#panel=\(panel)')", completionHandler: nil)
        }
    }

    func homePanelViewControllerDidRequestToCreateAccount(homePanelViewController: HomePanelViewController) {
        presentSignInViewController() // TODO UX Right now the flow for sign in and create account is the same
    }

    func homePanelViewControllerDidRequestToSignIn(homePanelViewController: HomePanelViewController) {
        presentSignInViewController() // TODO UX Right now the flow for sign in and create account is the same
    }
}

extension BrowserViewController: SearchViewControllerDelegate {
    func searchViewController(searchViewController: SearchViewController, didSelectURL url: NSURL) {
        finishEditingAndSubmit(url, visitType: VisitType.Typed)
    }
}

extension BrowserViewController : UIScrollViewDelegate {
    func scrollViewWillBeginDragging(scrollView: UIScrollView) {
        previousScroll = scrollView.contentOffset
    }

    func scrollViewDidScroll(scrollView: UIScrollView) {
        if let tab = tabManager.selectedTab,
           let prev = self.previousScroll {

            var totalToolbarHeight = header.frame.size.height
            let offset = scrollView.contentOffset
            let dy = prev.y - offset.y

            let scrollingSize = scrollView.contentSize.height - scrollView.frame.size.height
            totalToolbarHeight += readerModeBar?.frame.size.height ?? 0
            totalToolbarHeight += self.toolbar?.frame.size.height ?? 0

            // Only scroll away our toolbars if,
            if !tab.loading &&

                // There is enough web content to fill the screen if the scroll bars are fulling animated out
                scrollView.contentSize.height > (scrollView.frame.size.height + totalToolbarHeight) &&

                // The user is scrolling through the content and not because of the bounces that
                // happens when you pull up past the content
                scrollView.contentOffset.y > 0 &&

                // Only scroll away the toolbars if we are NOT pinching to zoom, only when we are dragging
                !scrollView.zooming {

                scrollFooter(dy)
                scrollHeader(dy)
                scrollReader(dy)
            } else {
                // Force toolbars to be in open state
                showToolbars(animated: false)
            }

            self.previousScroll = offset
        }
    }

    func scrollViewDidEndDragging(scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if previousScroll != nil {
            endDragging()
        }
    }

    private func endDragging() {
        self.previousScroll = nil

        let headerHeight = header.frame.size.height
        let totalOffset = headerHeight

        if headerConstraintOffset > -totalOffset {
            // Whenever we try running an animation from the scrollViewWillEndDragging delegate method,
            // it calls layoutSubviews so many times that it ends up clobbering any animations we want to
            // run from here. This dispatch_async places the animation onto the main queue for processing after
            // the scrollView has placed it's work on it already
            dispatch_async(dispatch_get_main_queue()) {
                self.showToolbars(animated: true)
            }
        }
    }
}

// Functions for scrolling the urlbar and footers.
extension BrowserViewController {
    func scrollViewShouldScrollToTop(scrollView: UIScrollView) -> Bool {
        showToolbars(animated: true)
        return true
    }

    private func scrollHeader(dy: CGFloat) {
        let totalOffset = self.header.frame.size.height
        let newOffset = self.clamp(self.headerConstraintOffset + dy, min: -totalOffset, max: 0)
        self.headerConstraint?.updateOffset(newOffset)
        self.headerConstraintOffset = newOffset
        let alpha = 1 - (abs(newOffset) / totalOffset)
        self.urlBar.updateAlphaForSubviews(alpha)
    }

    private func scrollFooter(dy: CGFloat) {
        let newOffset = self.clamp(self.footerConstraintOffset - dy, min: 0, max: footer.frame.size.height)
        self.footerConstraint?.updateOffset(newOffset)
        self.footerConstraintOffset = newOffset
    }

    private func scrollReader(dy: CGFloat) {
        let totalOffset = AppConstants.ToolbarHeight
        let newOffset = self.clamp(self.readerConstraintOffset + dy,
            min: -totalOffset, max: 0)
        self.readerConstraint?.updateOffset(newOffset)
        self.readerConstraintOffset = newOffset
    }

    private func clamp(y: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        if y >= max {
            return max
        } else if y <= min {
            return min
        }
        return y
    }

    private func showToolbars(#animated: Bool, completion: ((finished: Bool) -> Void)? = nil) {
        let animationDistance = self.headerConstraintOffset
        let totalOffset = self.header.frame.size.height
        let durationRatio = abs(animationDistance / totalOffset)
        let actualDuration = NSTimeInterval(BrowserViewControllerUX.ToolbarBaseAnimationDuration * durationRatio)

        self.animateToolbarsWithOffsets(
            animated: animated,
            duration: actualDuration,
            headerOffset: 0,
            footerOffset: 0,
            readerOffset: 0,
            alpha: 1,
            completion: completion)
    }

    private func hideToolbars(#animated: Bool, completion: ((finished: Bool) -> Void)? = nil) {
        let totalOffset = self.header.frame.size.height
        let animationDistance = totalOffset - abs(self.headerConstraintOffset)
        let durationRatio = abs(animationDistance / totalOffset)
        let actualDuration = NSTimeInterval(BrowserViewControllerUX.ToolbarBaseAnimationDuration * durationRatio)

        self.animateToolbarsWithOffsets(
            animated: animated,
            duration: actualDuration,
            headerOffset: -self.header.frame.size.height,
            footerOffset: self.footer.frame.height,
            readerOffset: -(readerModeBar?.frame.size.height ?? 0),
            alpha: 0,
            completion: completion)
    }

    private func animateToolbarsWithOffsets(#animated: Bool, duration: NSTimeInterval, headerOffset: CGFloat,
        footerOffset: CGFloat, readerOffset: CGFloat, alpha: CGFloat, completion: ((finished: Bool) -> Void)?) {

        let animation: () -> Void = {
            self.updateHeaderFooterConstraintsAndAlpha(headerOffset: headerOffset, footerOffset: footerOffset,
                readerOffset: readerOffset, alpha: alpha)
            self.view.layoutIfNeeded()
        }

        if animated {
            UIView.animateWithDuration(duration, animations: animation, completion: completion)
        } else {
            animation()
            completion?(finished: true)
        }
    }

    private func updateHeaderFooterConstraintsAndAlpha(#headerOffset: CGFloat,
        footerOffset: CGFloat, readerOffset: CGFloat, alpha: CGFloat) {
            self.headerConstraint?.updateOffset(headerOffset)
            self.footerConstraint?.updateOffset(footerOffset)
            self.readerConstraint?.updateOffset(readerOffset)
            self.headerConstraintOffset = headerOffset
            self.footerConstraintOffset = footerOffset
            self.readerConstraintOffset = readerOffset
            self.urlBar.updateAlphaForSubviews(alpha)
    }
}

extension BrowserViewController: TabManagerDelegate {
    func tabManager(tabManager: TabManager, didSelectedTabChange selected: Browser?, previous: Browser?) {
        // Remove the old accessibilityLabel. Since this webview shouldn't be visible, it doesn't need it
        // and having multiple views with the same label confuses tests.
        if let wv = previous?.webView {
            wv.accessibilityLabel = nil
            wv.accessibilityElementsHidden = true
            wv.accessibilityIdentifier = nil
            // due to screwy handling within iOS, the scrollToTop handling does not work if there are
            // more than one scroll view in the view hierarchy
            // we therefore have to hide all the scrollViews that we are no actually interesting in interacting with
            // to ensure that scrollsToTop actually works
            wv.scrollView.hidden = true
        }

        if let webView = selected?.webView {
            // if we have previously hidden this scrollview in order to make scrollsToTop work then
            // we should ensure that it is not hidden now that it is our foreground scrollView
            if webView.scrollView.hidden {
                webView.scrollView.hidden = false
            }
            webViewContainer.addSubview(webView)
            webView.accessibilityLabel = NSLocalizedString("Web content", comment: "Accessibility label for the main web content view")
            webView.accessibilityIdentifier = "contentView"
            webView.accessibilityElementsHidden = false

            if let url = webView.URL?.absoluteString {
                profile.bookmarks.isBookmarked(url, success: { bookmarked in
                    self.toolbar?.updateBookmarkStatus(bookmarked)
                    self.urlBar.updateBookmarkStatus(bookmarked)
                }, failure: { err in
                    log.error("Error getting bookmark status: \(err).")
                })
            } else {
                // The web view can go gray if it was zombified due to memory pressure.
                // When this happens, the URL is nil, so try restoring the page upon selection.
                webView.reload()
            }
        }

        removeAllBars()
        urlBar.currentURL = selected?.displayURL
        if let bars = selected?.bars {
            for bar in bars {
                showBar(bar, animated: true)
            }
        }

        toolbar?.updateBackStatus(selected?.canGoBack ?? false)
        toolbar?.updateForwardStatus(selected?.canGoForward ?? false)
        toolbar?.updateReloadStatus(selected?.loading ?? false)

        let isPage = (selected?.displayURL != nil) ? isWebPage(selected!.displayURL!) : false
        toolbar?.updatePageStatus(isWebPage: isPage)

        self.urlBar.updateBackStatus(selected?.canGoBack ?? false)
        self.urlBar.updateForwardStatus(selected?.canGoForward ?? false)
        self.urlBar.updateProgressBar(Float(selected?.estimatedProgress ?? 0))

        if let readerMode = selected?.getHelper(name: ReaderMode.name()) as? ReaderMode {
            urlBar.updateReaderModeState(readerMode.state)
            if readerMode.state == .Active {
                showReaderModeBar(animated: false)
            } else {
                hideReaderModeBar(animated: false)
            }
        } else {
            urlBar.updateReaderModeState(ReaderModeState.Unavailable)
        }

        updateInContentHomePanel(selected?.url)
    }

    func tabManager(tabManager: TabManager, didCreateTab tab: Browser) {
    }

    func tabManager(tabManager: TabManager, didAddTab tab: Browser, atIndex: Int) {
        urlBar.updateTabCount(tabManager.count)
        tab.browserDelegate = self
    }

    func tabManager(tabManager: TabManager, didRemoveTab tab: Browser, atIndex: Int) {
        urlBar.updateTabCount(tabManager.count)
        // browserDelegate is a weak ref (and the tab's webView may not be destroyed yet)
        // so we don't expcitly unset it.
    }

    private func isWebPage(url: NSURL) -> Bool {
        let httpSchemes = ["http", "https"]

        if let scheme = url.scheme,
            index = find(httpSchemes, scheme) {
                return true
        }

        return false
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if tabManager.selectedTab?.webView !== webView {
            return
        }

        // If we are going to navigate to a new page, hide the reader mode button. Unless we
        // are going to a about:reader page. Then we keep it on screen: it will change status
        // (orange color) as soon as the page has loaded.
        if let url = webView.URL {
            if !ReaderModeUtils.isReaderModeURL(url) {
                urlBar.updateReaderModeState(ReaderModeState.Unavailable)
            }
        }
    }

    private func openExternal(url: NSURL, prompt: Bool = true) {
        if prompt {
            // Ask the user if it's okay to open the url with UIApplication.
            let alert = UIAlertController(
                title: String(format: NSLocalizedString("Opening %@", comment:"Opening an external URL"), url),
                message: NSLocalizedString("This will open in another application", comment: "Opening an external app"),
                preferredStyle: UIAlertControllerStyle.Alert
            )

            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Alert Cancel Button"), style: UIAlertActionStyle.Cancel, handler: { (action: UIAlertAction!) in
            }))

            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment:"Alert OK Button"), style: UIAlertActionStyle.Default, handler: { (action: UIAlertAction!) in
                UIApplication.sharedApplication().openURL(url)
            }))

            presentViewController(alert, animated: true, completion: nil)
        } else {
            UIApplication.sharedApplication().openURL(url)
        }
    }

    private func callExternal(url: NSURL) {
        if let phoneNumber = url.resourceSpecifier?.stringByReplacingPercentEscapesUsingEncoding(NSUTF8StringEncoding) {
            let alert = UIAlertController(title: phoneNumber, message: nil, preferredStyle: UIAlertControllerStyle.Alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Alert Cancel Button"), style: UIAlertActionStyle.Cancel, handler: nil))
            alert.addAction(UIAlertAction(title: NSLocalizedString("Call", comment:"Alert Call Button"), style: UIAlertActionStyle.Default, handler: { (action: UIAlertAction!) in
                UIApplication.sharedApplication().openURL(url)
            }))
            presentViewController(alert, animated: true, completion: nil)
        }
    }

    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction, decisionHandler: (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.URL {
            if let scheme = url.scheme {
                switch scheme {
                case "about", "http", "https":
                    if isWhitelistedUrl(url) {
                        // If the url is whitelisted, we open it without prompting.
                        openExternal(url, prompt: false)
                        decisionHandler(WKNavigationActionPolicy.Cancel)
                    } else {
                        decisionHandler(WKNavigationActionPolicy.Allow)
                    }
                case "tel":
                    callExternal(url)
                    decisionHandler(WKNavigationActionPolicy.Cancel)
                default:
                    if UIApplication.sharedApplication().canOpenURL(url) {
                        openExternal(url)
                    }
                    decisionHandler(WKNavigationActionPolicy.Cancel)
                }
            }
        } else {
            decisionHandler(WKNavigationActionPolicy.Cancel)
        }
    }

    func webView(webView: WKWebView, didCommitNavigation navigation: WKNavigation!) {
        if let tab = tabManager.selectedTab {
            if tab.webView == webView {
                updateNavigationToolbarStates(tab, webView: webView)

                let isPage = (tab.displayURL != nil) ? isWebPage(tab.displayURL!) : false
                navigationToolbar.updatePageStatus(isWebPage: isPage)

                showToolbars(animated: false)

                if let url = tab.url {
                    if ReaderModeUtils.isReaderModeURL(url) {
                        showReaderModeBar(animated: false)
                    } else {
                        hideReaderModeBar(animated: false)
                    }
                }
                updateInContentHomePanel(tab.url)
            }
        }
    }

    func webView(webView: WKWebView,
        didReceiveAuthenticationChallenge challenge: NSURLAuthenticationChallenge,
        completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void) {
            if challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodClientCertificate {
                if let tab = tabManager[webView] {
                    let helper = tab.getHelper(name: LoginsHelper.name()) as! LoginsHelper
                    helper.handleAuthRequest(self, challenge: challenge).uponQueue(dispatch_get_main_queue()) { res in
                        if let credentials = res.successValue {
                            completionHandler(.UseCredential, credentials.credentials)
                        } else {
                            completionHandler(NSURLSessionAuthChallengeDisposition.CancelAuthenticationChallenge, nil)
                        }
                    }
                }
            }
    }

    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        let tab: Browser! = tabManager[webView]

        tab.expireSnackbars()

        if let url = webView.URL where !ErrorPageHelper.isErrorPageURL(url) {
            let notificationCenter = NSNotificationCenter.defaultCenter()
            var info = [NSObject: AnyObject]()
            info["url"] = tab.displayURL
            info["title"] = tab.title
            if let visitType = self.getVisitTypeForTab(tab, navigation: navigation)?.rawValue {
                info["visitType"] = visitType
            }
            notificationCenter.postNotificationName("LocationChange", object: self, userInfo: info)

            // The screenshot immediately after didFinishNavigation is actually a screenshot of the
            // previous page, presumably due to some iOS bug. Adding a small delay seems to fix this,
            // and the current page gets captured as expected.
            let time = dispatch_time(DISPATCH_TIME_NOW, Int64(100 * NSEC_PER_MSEC))
            dispatch_after(time, dispatch_get_main_queue()) {
                if webView.URL != url {
                    // The page changed during the delay, so we missed our chance to get a thumbnail.
                    return
                }

                if let screenshot = self.screenshotHelper.takeScreenshot(tab, aspectRatio: CGFloat(ThumbnailCellUX.ImageAspectRatio), quality: 0.5) {
                    let thumbnail = Thumbnail(image: screenshot)
                    self.profile.thumbnails.set(url, thumbnail: thumbnail, complete: nil)
                }
            }

            // Fire the readability check. This is here and not in the pageShow event handler in ReaderMode.js anymore
            // because that event wil not always fire due to unreliable page caching. This will either let us know that
            // the currently loaded page can be turned into reading mode or if the page already is in reading mode. We
            // ignore the result because we are being called back asynchronous when the readermode status changes.
            webView.evaluateJavaScript("_firefox_ReaderMode.checkReadability()", completionHandler: nil)
        }

        if tab === tabManager.selectedTab {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            // must be followed by LayoutChanged, as ScreenChanged will make VoiceOver
            // cursor land on the correct initial element, but if not followed by LayoutChanged,
            // VoiceOver will sometimes be stuck on the element, not allowing user to move
            // forward/backward. Strange, but LayoutChanged fixes that.
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil)
        }
    }
}

extension BrowserViewController: WKUIDelegate {
    func webView(webView: WKWebView, createWebViewWithConfiguration configuration: WKWebViewConfiguration, forNavigationAction navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // If the page uses window.open() or target="_blank", open the page in a new tab.
        // TODO: This doesn't work for window.open() without user action (bug 1124942).
        let tab = tabManager.addTab(request: navigationAction.request, configuration: configuration)
        tabManager.selectTab(tab)
        return tab.webView
    }

    func webView(webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: () -> Void) {
        tabManager.selectTab(tabManager[webView])

        // Show JavaScript alerts.
        let title = frame.request.URL!.host
        let alertController = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler()
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    func webView(webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: (Bool) -> Void) {
        tabManager.selectTab(tabManager[webView])

        // Show JavaScript confirm dialogs.
        let title = frame.request.URL!.host
        let alertController = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler(true)
        }))
        alertController.addAction(UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: { _ in
            completionHandler(false)
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    func webView(webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: (String!) -> Void) {
        tabManager.selectTab(tabManager[webView])

        // Show JavaScript input dialogs.
        let title = frame.request.URL!.host
        let alertController = UIAlertController(title: title, message: prompt, preferredStyle: UIAlertControllerStyle.Alert)
        var input: UITextField!
        alertController.addTextFieldWithConfigurationHandler({ (textField: UITextField!) in
            textField.text = defaultText
            input = textField
        })
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler(input.text)
        }))
        alertController.addAction(UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: { _ in
            completionHandler(nil)
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    /// Invoked when an error occurs during a committed main frame navigation.
    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        if error.code == Int(CFNetworkErrors.CFURLErrorCancelled.rawValue) {
            return
        }

        if let url = error.userInfo?["NSErrorFailingURLKey"] as? NSURL {
            ErrorPageHelper().showPage(error, forUrl: url, inWebView: webView)
        }
    }

    /// Invoked when an error occurs while starting to load data for the main frame.
    func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: NSError) {
        if error.code == Int(CFNetworkErrors.CFURLErrorCancelled.rawValue) {
            return
        }

        if let url = error.userInfo?["NSErrorFailingURLKey"] as? NSURL {
            ErrorPageHelper().showPage(error, forUrl: url, inWebView: webView)
        }
    }

    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse, decisionHandler: (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(WKNavigationResponsePolicy.Allow)
            return
        }

        let error = NSError(domain: ErrorPageHelper.MozDomain, code: Int(ErrorPageHelper.MozErrorDownloadsNotEnabled), userInfo: [NSLocalizedDescriptionKey: "Downloads aren't supported in Firefox yet (but we're working on it)."])
        ErrorPageHelper().showPage(error, forUrl: navigationResponse.response.URL!, inWebView: webView)
        decisionHandler(WKNavigationResponsePolicy.Allow)
    }
}

extension BrowserViewController: ReaderModeDelegate, UIPopoverPresentationControllerDelegate {
    func readerMode(readerMode: ReaderMode, didChangeReaderModeState state: ReaderModeState, forBrowser browser: Browser) {
        // If this reader mode availability state change is for the tab that we currently show, then update
        // the button. Otherwise do nothing and the button will be updated when the tab is made active.
        if tabManager.selectedTab === browser {
            log.debug("New readerModeState: \(state.rawValue)")
            urlBar.updateReaderModeState(state)
        }
    }

    func readerMode(readerMode: ReaderMode, didDisplayReaderizedContentForBrowser browser: Browser) {
        self.showReaderModeBar(animated: true)
        browser.showContent(animated: true)
    }

    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.None
    }
}

extension BrowserViewController: ReaderModeStyleViewControllerDelegate {
    func readerModeStyleViewController(readerModeStyleViewController: ReaderModeStyleViewController, didConfigureStyle style: ReaderModeStyle) {
        // Persist the new style to the profile
        let encodedStyle: [String:AnyObject] = style.encode()
        profile.prefs.setObject(encodedStyle, forKey: ReaderModeProfileKeyStyle)
        // Change the reader mode style on all tabs that have reader mode active
        for tabIndex in 0..<tabManager.count {
            if let tab = tabManager[tabIndex] {
                if let readerMode = tab.getHelper(name: "ReaderMode") as? ReaderMode {
                    if readerMode.state == ReaderModeState.Active {
                        readerMode.style = style
                    }
                }
            }
        }
    }
}

extension BrowserViewController : UIViewControllerTransitioningDelegate {
    func animationControllerForDismissedController(dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return TransitionManager(show: false)
    }

    func animationControllerForPresentedController(presented: UIViewController, presentingController presenting: UIViewController, sourceController source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return TransitionManager(show: true)
    }
}

extension BrowserViewController : Transitionable {
    private func headerTransformToCellFrame(frame: CGRect) -> CGAffineTransform {
        let scale = frame.size.width / header.frame.size.width
        // Since the scale will happen in the center of the frame, we move this so the centers of the two frames overlap.
        let tx = frame.origin.x + frame.width/2 - (header.frame.origin.x + header.frame.width/2)
        let ty = frame.origin.y - header.frame.origin.y * scale * 2 // Move this up a little actually keeps it above the web page. I'm not sure what you want
        var transform = CGAffineTransformMakeTranslation(tx, ty)
        return CGAffineTransformScale(transform, scale, scale)
    }

    private func footerTransformToCellFrame(frame: CGRect) -> CGAffineTransform {
        let tx = frame.origin.x + frame.width/2 - (footer.frame.origin.x + footer.frame.width/2)
        var footerTransform = CGAffineTransformMakeTranslation(tx, -footer.frame.origin.y + frame.origin.y + frame.size.height - footer.frame.size.height)
        let footerScale = frame.size.width / footer.frame.size.width
        return CGAffineTransformScale(footerTransform, footerScale, footerScale)
    }

    func transitionablePreHide(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's off screen
        for i in 0..<tabManager.count {
            if let tab = tabManager[i] {
                tab.webView?.hidden = true
            }
        }
        self.homePanelController?.view.hidden = true
    }

    func transitionablePreShow(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's off screen
        for i in 0..<tabManager.count {
            if let tab = tabManager[i] {
                tab.webView?.hidden = true
            }
        }

        // Move over the transforms to reflect where the opening tab is coming from instead of where the previous tab was
        if let frame = options.cellFrame {
            header.transform = CGAffineTransformIdentity
            footer.transform = CGAffineTransformIdentity
            header.transform = headerTransformToCellFrame(frame)
            footer.transform = footerTransformToCellFrame(frame)
        }

        self.homePanelController?.view.hidden = true
    }

    func transitionableWillShow(transitionable: Transitionable, options: TransitionOptions) {
        view.alpha = 1

        header.transform = CGAffineTransformIdentity
        footer.transform = CGAffineTransformIdentity
    }

    func transitionableWillHide(transitionable: Transitionable, options: TransitionOptions) {
        view.alpha = 0

        if let frame = options.cellFrame {
            header.transform = headerTransformToCellFrame(frame)
            footer.transform = footerTransformToCellFrame(frame)
        }
    }

    func transitionableWillComplete(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's back on screen
        for i in 0..<tabManager.count {
            if let tab = tabManager[i] {
                tab.webView?.hidden = false
            }
        }

        self.homePanelController?.view.hidden = false
        if options.toView === self {
            startTrackingAccessibilityStatus()
        } else {
            stopTrackingAccessibilityStatus()
        }
    }
}

extension BrowserViewController {
    func showReaderModeBar(#animated: Bool) {
        if self.readerModeBar == nil {
            let readerModeBar = ReaderModeBarView(frame: CGRectZero)
            readerModeBar.delegate = self
            view.insertSubview(readerModeBar, belowSubview: header)
            self.readerModeBar = readerModeBar
        }

        if let readerModeBar = readerModeBar {
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    readerModeBar.unread = record.unread
                    readerModeBar.added = true
                } else {
                    readerModeBar.unread = true
                    readerModeBar.added = false
                }
            } else {
                readerModeBar.unread = true
                readerModeBar.added = false
            }
        }

        self.updateViewConstraints()
    }

    func hideReaderModeBar(#animated: Bool) {
        if let readerModeBar = self.readerModeBar {
            readerModeBar.removeFromSuperview()
            self.readerModeBar = nil
            self.updateViewConstraints()
        }
    }

    /// There are two ways we can enable reader mode. In the simplest case we open a URL to our internal reader mode
    /// and be done with it. In the more complicated case, reader mode was already open for this page and we simply
    /// navigated away from it. So we look to the left and right in the BackForwardList to see if a readerized version
    /// of the current page is there. And if so, we go there.

    func enableReaderMode() {
        if let tab = tabManager.selectedTab,
            let webView = tab.webView,
            let backList = webView.backForwardList.backList as? [WKBackForwardListItem],
            let forwardList = webView.backForwardList.forwardList as? [WKBackForwardListItem] {

            if let currentURL = webView.backForwardList.currentItem?.URL {
                if let readerModeURL = ReaderModeUtils.encodeURL(currentURL) {
                    if backList.count > 1 && backList.last?.URL == readerModeURL {
                        webView.goToBackForwardListItem(backList.last!)
                    } else if forwardList.count > 0 && forwardList.first?.URL == readerModeURL {
                        webView.goToBackForwardListItem(forwardList.first!)
                    } else {
                        // Store the readability result in the cache and load it. This will later move to the ReadabilityHelper.
                        webView.evaluateJavaScript("\(ReaderModeNamespace).readerize()", completionHandler: { (object, error) -> Void in
                            if let readabilityResult = ReadabilityResult(object: object) {
                                ReaderModeCache.sharedInstance.put(currentURL, readabilityResult, error: nil)
                                if let nav = webView.loadRequest(NSURLRequest(URL: readerModeURL)) {
                                    self.ignoreNavigationInTab(tab, navigation: nav)
                                }
                            }
                        })
                    }
                }
            }
        }
    }

    /// Disabling reader mode can mean two things. In the simplest case we were opened from the reading list, which
    /// means that there is nothing in the BackForwardList except the internal url for the reader mode page. In that
    /// case we simply open a new page with the original url. In the more complicated page, the non-readerized version
    /// of the page is either to the left or right in the BackForwardList. If that is the case, we navigate there.

    func disableReaderMode() {
        if let tab = tabManager.selectedTab,
            let webView = tab.webView {
            let backList = webView.backForwardList.backList as! [WKBackForwardListItem]
            let forwardList = webView.backForwardList.forwardList as! [WKBackForwardListItem]

            if let currentURL = webView.backForwardList.currentItem?.URL {
                if let originalURL = ReaderModeUtils.decodeURL(currentURL) {
                    if backList.count > 1 && backList.last?.URL == originalURL {
                        webView.goToBackForwardListItem(backList.last!)
                    } else if forwardList.count > 0 && forwardList.first?.URL == originalURL {
                        webView.goToBackForwardListItem(forwardList.first!)
                    } else {
                        if let nav = webView.loadRequest(NSURLRequest(URL: originalURL)) {
                            self.ignoreNavigationInTab(tab, navigation: nav)
                        }
                    }
                }
            }
        }
    }
}

extension BrowserViewController: ReaderModeBarViewDelegate {
    func readerModeBar(readerModeBar: ReaderModeBarView, didSelectButton buttonType: ReaderModeBarButtonType) {
        switch buttonType {
        case .Settings:
            if let readerMode = tabManager.selectedTab?.getHelper(name: "ReaderMode") as? ReaderMode where readerMode.state == ReaderModeState.Active {
                var readerModeStyle = DefaultReaderModeStyle
                if let dict = profile.prefs.dictionaryForKey(ReaderModeProfileKeyStyle) {
                    if let style = ReaderModeStyle(dict: dict) {
                        readerModeStyle = style
                    }
                }
                
                let readerModeStyleViewController = ReaderModeStyleViewController()
                readerModeStyleViewController.delegate = self
                readerModeStyleViewController.readerModeStyle = readerModeStyle
                readerModeStyleViewController.modalPresentationStyle = UIModalPresentationStyle.Popover
                
                let popoverPresentationController = readerModeStyleViewController.popoverPresentationController
                popoverPresentationController?.backgroundColor = UIColor.whiteColor()
                popoverPresentationController?.delegate = self
                popoverPresentationController?.sourceView = readerModeBar
                popoverPresentationController?.sourceRect = CGRect(x: readerModeBar.frame.width/2, y: AppConstants.ToolbarHeight, width: 1, height: 1)
                popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection.Up
                
                self.presentViewController(readerModeStyleViewController, animated: true, completion: nil)
            }

        case .MarkAsRead:
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    profile.readingList?.updateRecord(record, unread: false) // TODO Check result, can this fail?
                    readerModeBar.unread = false
                }
            }

        case .MarkAsUnread:
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    profile.readingList?.updateRecord(record, unread: true) // TODO Check result, can this fail?
                    readerModeBar.unread = true
                }
            }

        case .AddToReadingList:
            if let tab = tabManager.selectedTab,
               let url = tab.url where ReaderModeUtils.isReaderModeURL(url) {
                if let url = ReaderModeUtils.decodeURL(url), let absoluteString = url.absoluteString {
                    let result = profile.readingList?.createRecordWithURL(absoluteString, title: tab.title ?? "", addedBy: UIDevice.currentDevice().name) // TODO Check result, can this fail?
                    readerModeBar.added = true
                }
            }

        case .RemoveFromReadingList:
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    profile.readingList?.deleteRecord(record) // TODO Check result, can this fail?
                    readerModeBar.added = false
                }
            }
        }
    }
}

extension BrowserViewController: UIStateRestoring {
    override func encodeRestorableStateWithCoder(coder: NSCoder) {
        super.encodeRestorableStateWithCoder(coder)
        tabManager.encodeRestorableStateWithCoder(coder)
    }

    override func decodeRestorableStateWithCoder(coder: NSCoder) {
        super.decodeRestorableStateWithCoder(coder)
        tabManager.decodeRestorableStateWithCoder(coder)
    }
}

private class BrowserScreenshotHelper: ScreenshotHelper {
    private weak var controller: BrowserViewController?

    init(controller: BrowserViewController) {
        self.controller = controller
    }

    func takeScreenshot(tab: Browser, aspectRatio: CGFloat, quality: CGFloat) -> UIImage? {
        if let url = tab.url {
            if url == AppConstants.AboutHomeURL {
                if let homePanel = controller?.homePanelController {
                    return homePanel.view.screenshot(aspectRatio, quality: quality)
                }
            } else {
                let offset = CGPointMake(0, -(tab.webView?.scrollView.contentInset.top ?? 0))
                return tab.webView?.screenshot(aspectRatio, offset: offset, quality: quality)
            }
        }

        return nil
    }
}

extension BrowserViewController: IntroViewControllerDelegate {
    func presentIntroViewController(force: Bool = false) {
        if force || profile.prefs.intForKey(IntroViewControllerSeenProfileKey) == nil {
            let introViewController = IntroViewController()
            introViewController.delegate = self
            // On iPad we present it modally in a controller
            if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
                introViewController.preferredContentSize = CGSize(width: IntroViewControllerUX.Width, height: IntroViewControllerUX.Height)
                introViewController.modalPresentationStyle = UIModalPresentationStyle.FormSheet
            }
            presentViewController(introViewController, animated: false) {
                self.profile.prefs.setInt(1, forKey: IntroViewControllerSeenProfileKey)
            }
        }
    }

    func introViewControllerDidFinish(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true, completion: nil)
    }

    func presentSignInViewController() {
        // TODO When bug 1161151 has been resolved we can jump directly to the sign in screen
        let settingsNavigationController = SettingsNavigationController()
        settingsNavigationController.profile = self.profile
        settingsNavigationController.tabManager = self.tabManager
        self.presentViewController(settingsNavigationController, animated: true, completion: nil)
    }

    func introViewControllerDidRequestToLogin(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true, completion: { () -> Void in
            self.presentSignInViewController()
        })
    }
}

extension BrowserViewController: ContextMenuHelperDelegate {
    func contextMenuHelper(contextMenuHelper: ContextMenuHelper, didLongPressElements elements: ContextMenuHelper.Elements, gestureRecognizer: UILongPressGestureRecognizer) {
        let actionSheetController = UIAlertController(title: nil, message: nil, preferredStyle: UIAlertControllerStyle.ActionSheet)
        var dialogTitle: String?

        if let url = elements.link {
            dialogTitle = url.absoluteString
            let newTabTitle = NSLocalizedString("Open In New Tab", comment: "Context menu item for opening a link in a new tab")
            let openNewTabAction =  UIAlertAction(title: newTabTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) in
                self.showToolbars(animated: self.headerConstraintOffset != 0, completion: { _ in
                    self.tabManager.addTab(request: NSURLRequest(URL: url))
                })
            }

            actionSheetController.addAction(openNewTabAction)

            let copyTitle = NSLocalizedString("Copy Link", comment: "Context menu item for copying a link URL to the clipboard")
            let copyAction = UIAlertAction(title: copyTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                var pasteBoard = UIPasteboard.generalPasteboard()
                pasteBoard.string = url.absoluteString
            }
            actionSheetController.addAction(copyAction)
        }

        if let url = elements.image {
            if dialogTitle == nil {
                dialogTitle = url.absoluteString
            }

            let saveImageTitle = NSLocalizedString("Save Image", comment: "Context menu item for saving an image")
            let saveImageAction = UIAlertAction(title: saveImageTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                self.getImage(url) { UIImageWriteToSavedPhotosAlbum($0, nil, nil, nil) }
            }
            actionSheetController.addAction(saveImageAction)

            let copyImageTitle = NSLocalizedString("Copy Image", comment: "Context menu item for copying an image to the clipboard")
            let copyAction = UIAlertAction(title: copyImageTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                let pasteBoard = UIPasteboard.generalPasteboard()
                pasteBoard.string = url.absoluteString!
                // TODO: put the actual image on the clipboard
            }
            actionSheetController.addAction(copyAction)
        }

        // If we're showing an arrow popup, set the anchor to the long press location.
        if let popoverPresentationController = actionSheetController.popoverPresentationController {
            popoverPresentationController.sourceView = view
            popoverPresentationController.sourceRect = CGRect(origin: gestureRecognizer.locationInView(view), size: CGSizeMake(0, 16))
            popoverPresentationController.permittedArrowDirections = .Any
        }

        actionSheetController.title = dialogTitle
        var cancelAction = UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: nil)
        actionSheetController.addAction(cancelAction)
        self.presentViewController(actionSheetController, animated: true, completion: nil)
    }

    private func getImage(url: NSURL, success: UIImage -> ()) {
        Alamofire.request(.GET, url)
            .validate(statusCode: 200..<300)
            .response { _, _, data, _ in
                if let data = data as? NSData,
                   let image = UIImage(data: data) {
                    success(image)
                }
            }
    }
}

extension BrowserViewController: HashchangeHelperDelegate {
    func hashchangeHelperDidHashchange(hashchangeHelper: HashchangeHelper) {
        if let tab = tabManager.selectedTab,
           let webView = tab.webView
        {
            updateNavigationToolbarStates(tab, webView: webView)
        }
    }
}
