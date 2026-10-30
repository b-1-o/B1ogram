import Foundation
import UIKit

/// Notifications posted on the main queue when Biogram state changes.
public extension Notification.Name {
    static let biogramStateDidChange = Notification.Name("BiogramStateDidChange")
    static let biogramAccountDidLoad = Notification.Name("BiogramAccountDidLoad")
}

/// Singleton manager for Biogram state. Private/local data stays per Telegram account,
/// while public profile customizations are synchronized by BiogramCloudService.
public final class BiogramManager {
    public static let shared = BiogramManager()

    private let storage: BiogramStorage
    private let bannerIOQueue = DispatchQueue(
        label: "org.biogram.banner.io",
        qos: .utility
    )

    // All cache mutations are delivered on the main queue.
    private var currentAccountId: String = "default"
    private var switchGeneration: UInt64 = 0
    private var loadedAccountId: String?

    private var cachedCustomizations: BiogramCustomizations
    private var cachedAliases: [String]
    private var cachedVirtualNumbers: [BiogramVirtualNumber]
    private var cachedCollectibles: [BiogramCollectible]
    private var cachedBanner: BiogramBanner?
    private var cachedBannerImage: UIImage?
    private var cachedProfileCardImage: UIImage?

    /// True after the user changes/removes the banner and until
    /// the application is launched again.
    ///
    /// The new banner is written to disk immediately, but the currently
    /// displayed banner remains unchanged until restart. This avoids
    /// forcing PeerInfo layout to rebuild while the user is still inside
    /// the settings screen.
    private var _bannerRestartRequired: Bool = false

    private init(storageBase: URL? = nil) {
        self.storage = BiogramStorage(baseDirectory: storageBase)
        self.cachedCustomizations = BiogramCustomizations()
        self.cachedAliases = []
        self.cachedVirtualNumbers = []
        self.cachedCollectibles = []
        self.cachedBanner = nil
        self.cachedBannerImage = nil
        self.cachedProfileCardImage = nil
        self._bannerRestartRequired = false
    }

    // MARK: - Account

    /// True when the given account (or current) has finished loading from disk.
    public var isLoaded: Bool {
        return self.loadedAccountId != nil &&
            self.loadedAccountId == self.currentAccountId
    }

    public var activeAccountId: String {
        return self.currentAccountId
    }

    /// True after a banner was changed or removed and until the next
    /// application launch/account reload.
    public var bannerRestartRequired: Bool {
        return self._bannerRestartRequired
    }

    /// Switch the local Biogram state to a Telegram account.
    /// The completion is called on the main queue only after JSON and
    /// banner image are loaded.
    public func switchToAccount(
        accountId: String,
        completion: (() -> Void)? = nil
    ) {
        assert(Thread.isMainThread)

        if accountId == self.loadedAccountId {
            completion?()
            return
        }

        // A new account load starts a new runtime state.
        self._bannerRestartRequired = false

        self.currentAccountId = accountId
        self.switchGeneration &+= 1
        let generation = self.switchGeneration

        self.storage.setCurrentAccountId(accountId)

        self.storage.load(for: accountId) { [weak self] payload in
            guard let self else {
                return
            }

            // Decode the image off the main thread.
            var bannerImage: UIImage?

            if let banner = payload.banner {
                let url = Self.bannersDirectory()
                    .appendingPathComponent(banner.localFilename)

                if let data = try? Data(contentsOf: url),
                   let image = UIImage(data: data) {
                    bannerImage = image
                }
            }
            var profileCardImage: UIImage?
            if let filename = payload.customizations.profileCardStyle?.imageFilename {
                let url = Self.profileCardsDirectory().appendingPathComponent(filename)
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    profileCardImage = image
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                guard generation == self.switchGeneration,
                      accountId == self.currentAccountId else {
                    return
                }

                self.cachedCustomizations = payload.customizations
                self.cachedAliases = payload.aliases
                self.cachedVirtualNumbers = payload.virtualNumbers
                self.cachedCollectibles = payload.collectibles
                self.cachedBanner = payload.banner
                self.cachedBannerImage = bannerImage
                self.cachedProfileCardImage = profileCardImage

                // The new banner is now the active banner because it has
                // been loaded from disk during application/account startup.
                self._bannerRestartRequired = false

                self.loadedAccountId = accountId

                NotificationCenter.default.post(
                    name: .biogramAccountDidLoad,
                    object: self
                )

                NotificationCenter.default.post(
                    name: .biogramStateDidChange,
                    object: self
                )

                completion?()
            }
        }
    }

    /// Call this as early as possible when AccountContext is ready
    /// (app launch / account switch).
    /// Safe to call repeatedly.
    public func ensureAccountLoaded(
        accountId: String,
        completion: (() -> Void)? = nil
    ) {
        if Thread.isMainThread {
            self.switchToAccount(
                accountId: accountId,
                completion: completion
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.switchToAccount(
                    accountId: accountId,
                    completion: completion
                )
            }
        }
    }

    private func notifyStateChanged() {
        assert(Thread.isMainThread)

        NotificationCenter.default.post(
            name: .biogramStateDidChange,
            object: self
        )

        if !self.isApplyingCloudProfile, self.isLoaded {
            BiogramCloudService.shared.scheduleLocalProfileSync(accountId: self.currentAccountId)
        }
    }

    // MARK: - Read accessors

    public var localPremiumEnabled: Bool {
        return self.cachedCustomizations.localPremiumEnabled
    }

    public func aliases() -> [String] {
        return self.cachedAliases
    }

    public func virtualNumbers() -> [BiogramVirtualNumber] {
        return self.cachedVirtualNumbers
    }

    public func collectibles() -> [BiogramCollectible] {
        return self.cachedCollectibles
    }

    public func banner() -> BiogramBanner? {
        return self.cachedBanner
    }

    public func bannerImage() -> UIImage? {
        return self.cachedBannerImage
    }

    /// Calculates the banner height from the original image aspect ratio.
    ///
    /// There is intentionally NO 80...300 pt clamp here.
    /// Width is fixed by the PeerInfo layout and height follows the
    /// original image aspect ratio.
    public func bannerHeight(forWidth width: CGFloat) -> CGFloat {
        guard let image = self.cachedBannerImage,
              image.size.width > 0.0,
              image.size.height > 0.0 else {
            return 140.0
        }

        let ratio = image.size.height / image.size.width

        return max(
            1.0,
            width * ratio
        )
    }

    public var profileColorEnabled: Bool {
        return self.cachedCustomizations.profileColorEnabled
    }

    public var profileColor: BiogramProfileColor? {
        return self.cachedCustomizations.profileColor
    }

    public var profileCardStyle: BiogramProfileCardStyle {
        return self.cachedCustomizations.profileCardStyle ?? BiogramProfileCardStyle()
    }

    public func profileCardImage() -> UIImage? {
        return self.cachedProfileCardImage
    }


    public func cloudProfilePayload() -> BiogramCloudProfilePayload {
        let publicNumbers = self.cachedVirtualNumbers.compactMap { item -> BiogramCloudPublicNumber? in
            guard item.isPublic == true else { return nil }
            return BiogramCloudPublicNumber(
                id: item.id,
                label: item.label,
                number: item.number,
                isPublic: true
            )
        }
        return BiogramCloudProfilePayload(
            profileColorEnabled: self.cachedCustomizations.profileColorEnabled,
            profileColor: self.cachedCustomizations.profileColor,
            cardStyle: self.profileCardStyle,
            aliases: self.cachedAliases,
            publicNumbers: publicNumbers,
            publicEnabled: true
        )
    }

    public func setVirtualNumberPublic(
        id: String,
        isPublic: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard let index = self.cachedVirtualNumbers.firstIndex(where: { $0.id == id }) else {
            completion?()
            return
        }
        self.cachedVirtualNumbers[index].isPublic = isPublic
        self.notifyStateChanged()
        self.storage.replaceVirtualNumbers(self.cachedVirtualNumbers, completion: completion)
    }

    public func applyCloudProfile(
        _ profile: BiogramCloudPublicProfile,
        accountId: String,
        completion: (() -> Void)? = nil
    ) {
        guard self.currentAccountId == accountId, self.isLoaded else {
            completion?()
            return
        }

        self.isApplyingCloudProfile = true

        var customizations = self.cachedCustomizations
        customizations.profileColorEnabled = profile.profileColorEnabled
        customizations.profileColor = profile.profileColor
        customizations.profileCardStyle = BiogramProfileCardStyle(
            paletteName: profile.cardStyle.paletteName,
            material: profile.cardStyle.material,
            imageFilename: self.cachedCustomizations.profileCardStyle?.imageFilename
        )
        self.cachedCustomizations = customizations
        self.cachedAliases = profile.aliases

        let existingPrivateNumbers = self.cachedVirtualNumbers.filter { $0.isPublic != true }
        let serverPublicNumbers = profile.publicNumbers.map {
            BiogramVirtualNumber(
                id: $0.id,
                label: $0.label,
                number: $0.number,
                isPublic: true
            )
        }
        self.cachedVirtualNumbers = existingPrivateNumbers + serverPublicNumbers

        self.storage.setCustomizations(customizations)
        self.storage.replaceAliases(profile.aliases)
        self.storage.replaceVirtualNumbers(self.cachedVirtualNumbers)

        NotificationCenter.default.post(name: .biogramStateDidChange, object: self)

        guard let image = profile.cardImage else {
            self.isApplyingCloudProfile = false
            completion?()
            return
        }

        self.setProfileCardImage(image) { [weak self] in
            guard let self else { completion?(); return }
            self.isApplyingCloudProfile = false
            completion?()
        }
    }

    // MARK: - Mutations
    public func setProfileCardStyle(
        _ style: BiogramProfileCardStyle,
        completion: (() -> Void)? = nil
    ) {
        var custom = self.cachedCustomizations
        var normalized = BiogramProfileCardStyle(
            paletteName: style.paletteName,
            material: style.material,
            imageFilename: custom.profileCardStyle?.imageFilename
        )
        normalized.imageFilename = custom.profileCardStyle?.imageFilename
        custom.profileCardStyle = normalized
        self.cachedCustomizations = custom
        self.notifyStateChanged()
        self.storage.setCustomizations(custom, completion: completion)
    }

    /// Stores card artwork locally. No activation code, serial or server-issued card is involved.
    public func setProfileCardImage(
        _ image: UIImage?,
        completion: (() -> Void)? = nil
    ) {
        let oldFilename = self.cachedCustomizations.profileCardStyle?.imageFilename
        let accountId = self.currentAccountId

        guard let image, image.size.width > 0, image.size.height > 0 else {
            var custom = self.cachedCustomizations
            var style = custom.profileCardStyle ?? BiogramProfileCardStyle()
            style.imageFilename = nil
            custom.profileCardStyle = style
            self.cachedCustomizations = custom
            self.cachedProfileCardImage = nil
            self.notifyStateChanged()
            self.storage.setCustomizations(custom) { [weak self] in
                guard let self else { completion?(); return }
                if let oldFilename {
                    self.bannerIOQueue.async {
                        try? FileManager.default.removeItem(at: Self.profileCardsDirectory().appendingPathComponent(oldFilename))
                    }
                }
                DispatchQueue.main.async { completion?() }
            }
            return
        }

        let filename = "card_\(UUID().uuidString).jpg"
        let directory = Self.profileCardsDirectory()
        let targetURL = directory.appendingPathComponent(filename)
        let optimized = Self.optimizedBannerImage(image, maxDimension: 1600)
        self.bannerIOQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion?() }; return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                guard let data = optimized.jpegData(compressionQuality: 0.84) else {
                    DispatchQueue.main.async { completion?() }
                    return
                }
                try data.write(to: targetURL, options: [.atomic])
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion?(); return }
                    guard self.currentAccountId == accountId else {
                        try? FileManager.default.removeItem(at: targetURL)
                        completion?()
                        return
                    }
                    var custom = self.cachedCustomizations
                    var style = custom.profileCardStyle ?? BiogramProfileCardStyle()
                    style.imageFilename = filename
                    custom.profileCardStyle = style
                    self.cachedCustomizations = custom
                    self.cachedProfileCardImage = optimized
                    self.notifyStateChanged()
                    self.storage.setCustomizations(custom) { [weak self] in
                        guard let self else { DispatchQueue.main.async { completion?() }; return }
                        if let oldFilename, oldFilename != filename {
                            self.bannerIOQueue.async {
                                try? FileManager.default.removeItem(at: Self.profileCardsDirectory().appendingPathComponent(oldFilename))
                            }
                        }
                        DispatchQueue.main.async { completion?() }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion?() }
            }
        }
    }


    public func setLocalPremiumEnabled(
        _ enabled: Bool,
        completion: (() -> Void)? = nil
    ) {
        var custom = self.cachedCustomizations
        custom.localPremiumEnabled = enabled
        self.cachedCustomizations = custom

        self.notifyStateChanged()

        self.storage.setCustomizations(
            custom,
            completion: completion
        )
    }

    public func addAlias(
        _ alias: String,
        completion: (() -> Void)? = nil
    ) {
        if !self.cachedAliases.contains(alias) {
            self.cachedAliases.append(alias)
            self.notifyStateChanged()

            self.storage.addAlias(
                alias,
                completion: completion
            )
        } else {
            completion?()
        }
    }

    public func removeAlias(
        _ alias: String,
        completion: (() -> Void)? = nil
    ) {
        self.cachedAliases.removeAll(where: { $0 == alias })
        self.notifyStateChanged()

        self.storage.removeAlias(
            alias,
            completion: completion
        )
    }

    public func addVirtualNumber(
        _ number: BiogramVirtualNumber,
        completion: (() -> Void)? = nil
    ) {
        self.cachedVirtualNumbers.append(number)
        self.notifyStateChanged()

        self.storage.addVirtualNumber(
            number,
            completion: completion
        )
    }

    public func removeVirtualNumber(
        id: String,
        completion: (() -> Void)? = nil
    ) {
        self.cachedVirtualNumbers.removeAll(where: { $0.id == id })
        self.notifyStateChanged()

        self.storage.removeVirtualNumber(
            id: id,
            completion: completion
        )
    }

    public func replaceAlias(
        old: String,
        new: String,
        completion: (() -> Void)? = nil
    ) {
        if let index = self.cachedAliases.firstIndex(of: old) {
            self.cachedAliases[index] = new
            self.notifyStateChanged()

            self.storage.replaceAliases(
                self.cachedAliases,
                completion: completion
            )
        } else {
            completion?()
        }
    }

    public func updateVirtualNumber(
        id: String,
        number: String,
        label: String?,
        completion: (() -> Void)? = nil
    ) {
        if let index = self.cachedVirtualNumbers.firstIndex(
            where: { $0.id == id }
        ) {
            self.cachedVirtualNumbers[index].number = number
            self.cachedVirtualNumbers[index].label = label

            self.notifyStateChanged()

            self.storage.replaceVirtualNumbers(
                self.cachedVirtualNumbers,
                completion: completion
            )
        } else {
            completion?()
        }
    }

    public func setProfileColor(
        _ color: BiogramProfileColor?,
        enabled: Bool,
        completion: (() -> Void)? = nil
    ) {
        var custom = self.cachedCustomizations

        custom.profileColor = color
        custom.profileColorEnabled = enabled

        self.cachedCustomizations = custom

        self.notifyStateChanged()

        self.storage.setCustomizations(
            custom,
            completion: completion
        )
    }

    public func addCollectible(
        _ collectible: BiogramCollectible,
        completion: (() -> Void)? = nil
    ) {
        self.cachedCollectibles.append(collectible)
        self.notifyStateChanged()

        self.storage.addCollectible(
            collectible,
            completion: completion
        )
    }

    public func removeCollectible(
        id: String,
        completion: (() -> Void)? = nil
    ) {
        self.cachedCollectibles.removeAll(where: { $0.id == id })
        self.notifyStateChanged()

        self.storage.removeCollectible(
            id: id,
            completion: completion
        )
    }

    @discardableResult
    public func addCollectibleFromGiftLink(
        _ input: String,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard let slug = BiogramGiftLink.slug(from: input) else {
            completion?()
            return false
        }

        guard !self.cachedCollectibles.contains(where: {
            $0.giftSlug == slug
        }) else {
            completion?()
            return false
        }

        let item = BiogramCollectible(
            title: slug,
            assetFilename: slug,
            assetType: "gift",
            giftSlug: slug,
            stickerFileId: nil
        )

        self.addCollectible(
            item,
            completion: completion
        )

        return true
    }

    public func moveCollectible(
        from fromIndex: Int,
        to toIndex: Int,
        completion: (() -> Void)? = nil
    ) {
        guard fromIndex != toIndex,
              fromIndex >= 0,
              fromIndex < self.cachedCollectibles.count,
              toIndex >= 0,
              toIndex < self.cachedCollectibles.count else {
            completion?()
            return
        }

        let item = self.cachedCollectibles.remove(
            at: fromIndex
        )

        self.cachedCollectibles.insert(
            item,
            at: toIndex
        )

        self.notifyStateChanged()

        self.storage.replaceCollectibles(
            self.cachedCollectibles,
            completion: completion
        )
    }

    public func replaceCollectibles(
        _ items: [BiogramCollectible],
        completion: (() -> Void)? = nil
    ) {
        self.cachedCollectibles = items
        self.notifyStateChanged()

        self.storage.replaceCollectibles(
            items,
            completion: completion
        )
    }

    // MARK: - Banner

    public func bannerFileURL() -> URL? {
        guard let name = self.cachedBanner?.localFilename else {
            return nil
        }

        return Self.bannersDirectory()
            .appendingPathComponent(name)
    }

    /// Sets banner metadata.
    ///
    /// The currently displayed banner is intentionally NOT changed.
    /// The new value becomes active after the next application restart.
    public func setBanner(
        _ banner: BiogramBanner?,
        completion: (() -> Void)? = nil
    ) {
        let oldName = self.cachedBanner?.localFilename

        self._bannerRestartRequired = true
        self.notifyStateChanged()

        self.storage.setBanner(banner) { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }

            if let oldName,
               oldName != banner?.localFilename {
                self.bannerIOQueue.async {
                    let oldURL = Self.bannersDirectory()
                        .appendingPathComponent(oldName)

                    try? FileManager.default.removeItem(
                        at: oldURL
                    )
                }
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// Removes the banner.
    ///
    /// The currently displayed banner remains visible until the next
    /// application restart.
    public func clearBanner(
        completion: (() -> Void)? = nil
    ) {
        let oldName = self.cachedBanner?.localFilename

        self._bannerRestartRequired = true
        self.notifyStateChanged()

        self.storage.setBanner(nil) { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }

            if let oldName {
                self.bannerIOQueue.async {
                    let url = Self.bannersDirectory()
                        .appendingPathComponent(oldName)

                    try? FileManager.default.removeItem(
                        at: url
                    )
                }
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// Saves a banner without blocking the UI thread.
    ///
    /// Important:
    /// - The image is written to disk immediately.
    /// - The current cached banner is NOT replaced.
    /// - bannerRestartRequired becomes true.
    /// - After restarting the app, switchToAccount() loads the new image.
    @discardableResult
    public func saveBannerImage(
        _ image: UIImage,
        aspectRatio: String = "free",
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard image.size.width > 0.0,
              image.size.height > 0.0 else {
            DispatchQueue.main.async {
                completion?()
            }
            return false
        }

        let oldName = self.cachedBanner?.localFilename

        let filename = "banner_\(UUID().uuidString).jpg"

        let dir = Self.bannersDirectory()
        let url = dir.appendingPathComponent(filename)

        let banner = BiogramBanner(
            localFilename: filename,
            aspectRatio: aspectRatio
        )

        // Do NOT update cachedBanner/cachedBannerImage here.
        //
        // This is intentional:
        // the currently visible profile remains stable and doesn't
        // trigger an expensive PeerInfo relayout immediately after
        // the user selects a new banner.
        //
        // The new banner is stored on disk and becomes active after
        // the next app restart.
        self._bannerRestartRequired = true

        self.notifyStateChanged()

        self.bannerIOQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }

            autoreleasepool {
                do {
                    try FileManager.default.createDirectory(
                        at: dir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )

                    let optimizedImage =
                        Self.optimizedBannerImage(
                            image,
                            maxDimension: 2048
                        )

                    guard let data = optimizedImage.jpegData(
                        compressionQuality: 0.88
                    ) else {
                        DispatchQueue.main.async {
                            completion?()
                        }
                        return
                    }

                    try data.write(
                        to: url,
                        options: [.atomic]
                    )

                    self.storage.setBanner(banner) {
                        // The currently displayed banner is still the
                        // old cached image, so removing its file after
                        // successful persistence is safe: the image is
                        // already retained in memory by UIImage.
                        if let oldName,
                           oldName != filename {
                            self.bannerIOQueue.async {
                                let oldURL = dir
                                    .appendingPathComponent(oldName)

                                try? FileManager.default.removeItem(
                                    at: oldURL
                                )
                            }
                        }

                        DispatchQueue.main.async {
                            completion?()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion?()
                    }
                }
            }
        }

        return true
    }

    public func setBannerImage(
        _ image: UIImage?,
        aspectRatio: String = "free",
        completion: (() -> Void)? = nil
    ) {
        if let image {
            _ = self.saveBannerImage(
                image,
                aspectRatio: aspectRatio,
                completion: completion
            )
        } else {
            self.clearBanner(
                completion: completion
            )
        }
    }

    // MARK: - Image helpers

    private static func optimizedBannerImage(
        _ image: UIImage,
        maxDimension: CGFloat
    ) -> UIImage {
        let longest = max(
            image.size.width,
            image.size.height
        )

        guard longest > maxDimension else {
            return image
        }

        let scale = maxDimension / longest

        let targetSize = CGSize(
            width: max(
                1.0,
                floor(image.size.width * scale)
            ),
            height: max(
                1.0,
                floor(image.size.height * scale)
            )
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        return UIGraphicsImageRenderer(
            size: targetSize,
            format: format
        ).image { _ in
            image.draw(
                in: CGRect(
                    origin: .zero,
                    size: targetSize
                )
            )
        }
    }

    private static func bannersDirectory() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? URL(
                fileURLWithPath: NSTemporaryDirectory()
            )

        let directory = base.appendingPathComponent(
            "Biogram/banners",
            isDirectory: true
        )

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return directory
    }

    private static func profileCardsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Biogram/profile-cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }
}
