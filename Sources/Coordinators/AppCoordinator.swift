/*****************************************************************************
 * AppCoordinator.swift
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2018 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Carola Nitz <nitz.carola # gmail.com>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

@objc(VLCService)
class Services: NSObject {
    @objc let medialibraryService = MediaLibraryService()
    @objc let rendererDiscovererManager = VLCRendererDiscovererManager(presentingViewController: nil)
}

@objc class AppCoordinator: NSObject {
    private var services = Services()
    private var childCoordinators: [NSObject] = []
    private var playerController: VLCPlayerDisplayController
    private var tabBarController: UITabBarController
    private var tabBarCoordinator: VLCTabBarCoordinator
    private var migrationViewController = VLCMigrationViewController(nibName: String(describing: VLCMigrationViewController.self),
                                                                     bundle: nil)

    @objc init(tabBarController: UITabBarController) {
        self.playerController = VLCPlayerDisplayController(services: services)
        self.tabBarController = tabBarController
        tabBarCoordinator = VLCTabBarCoordinator(tabBarController: tabBarController, services: services)
        super.init()
        setupChildViewControllers()

        // Init the HTTP Server and clean its cache
        // FIXME: VLCHTTPUploaderController should perhaps be a service?
        VLCHTTPUploaderController.sharedInstance().cleanCache()
        VLCHTTPUploaderController.sharedInstance().medialibrary = services.medialibraryService
        services.medialibraryService.migrationDelegate = self
    }

    private func setupChildViewControllers() {
        tabBarController.addChild(playerController)
        tabBarController.view.addSubview(playerController.view)
        playerController.view.layoutMargins = UIEdgeInsets(top: 0,
                                                           left: 0,
                                                           bottom: tabBarController.tabBar.frame.size.height,
                                                           right: 0)
        playerController.realBottomAnchor = tabBarController.tabBar.topAnchor
        playerController.didMove(toParent: tabBarController)
    }

    @objc func start() {
        childCoordinators.append(tabBarCoordinator)
    }

    @objc func handleShortcutItem(_ item: UIApplicationShortcutItem) {
        tabBarCoordinator.handleShortcutItem(item)
    }

    @objc func mediaForUserActivity(_ activity: NSUserActivity) -> VLCMLMedia? {
        let userActivityType = activity.activityType
        guard let dict = activity.userInfo else { return nil }
        var identifier: Int64? = nil

        if userActivityType == CSSearchableItemActionType, let searchIdentifier = dict[CSSearchableItemActivityIdentifier] as? NSString {
            identifier = Int64(searchIdentifier.integerValue)
        } else if let mediaIdentifier = dict["playingmedia"] as? Int64 {
            identifier = mediaIdentifier
        }
        guard let mediaIdentifier = identifier else { return nil }

        return services.medialibraryService.media(for: mediaIdentifier)
    }

}

extension AppCoordinator: MediaLibraryMigrationDelegate {
    func medialibraryDidStartMigration(_ medialibrary: MediaLibraryService) {
        DispatchQueue.main.async {
            [tabBarController, migrationViewController] in
            tabBarController.present(migrationViewController, animated: true, completion: nil)
        }
    }

    func medialibraryDidFinishMigration(_ medialibrary: MediaLibraryService) {
        DispatchQueue.main.async {
            [migrationViewController] in
            migrationViewController.dismiss(animated: true, completion: nil)
        }
    }

    func medialibraryDidStopMigration(_ medialibrary: MediaLibraryService) {
        if tabBarController.presentedViewController === migrationViewController {
            DispatchQueue.main.async {
                [tabBarController] in
                tabBarController.dismiss(animated: true, completion: nil)
            }
        }
    }
}
