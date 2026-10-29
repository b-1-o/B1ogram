import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import PresentationDataUtils
import Biogram

// MARK: - Helpers

private final class BiogramActionsAlertController: ViewController {
    private let titleText: String
    private let messageText: String?
    private let actions: [(title: String, destructive: Bool, action: () -> Void)]
   
    init(title: String, message: String?, actions: [(title: String, destructive: Bool, action: () -> Void)]) {
        self.titleText = title
        self.messageText = message
        self.actions = actions
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }
   
    required init(coder aDecoder: NSCoder) { fatalError() }
   
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
       
        let alert = UIAlertController(title: titleText, message: messageText, preferredStyle: .actionSheet)
        for item in actions {
            alert.addAction(UIAlertAction(title: item.title, style: item.destructive ? .destructive : .default, handler: { [weak self] _ in
                item.action()
                self?.close()
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in
            self?.close()
        }))
       
        Queue.mainQueue().after(0.05) { [weak self] in
            guard let self = self else { return }
            guard let root = self.view.window?.rootViewController else { return }
            var top: UIViewController = root
            while let presented = top.presentedViewController { top = presented }
            if let pop = alert.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(alert, animated: true)
        }
    }
   
    private func close() { self.dismiss(animated: false) }
}

private final class BiogramTextInputController: ViewController {
    private let titleText: String
    private let messageText: String
    private let initialValue: String
    private let placeholder: String
    private let actionTitle: String
    private let cancelTitle: String
    private let keyboardType: UIKeyboardType
    private let onAction: (String) -> Bool
    private var textField: UITextField?
   
    init(title: String, text: String, value: String, placeholder: String, actionTitle: String, cancelTitle: String, keyboardType: UIKeyboardType = .default, action: @escaping (String) -> Bool) {
        self.titleText = title
        self.messageText = text
        self.initialValue = value
        self.placeholder = placeholder
        self.actionTitle = actionTitle
        self.cancelTitle = cancelTitle
        self.keyboardType = keyboardType
        self.onAction = action
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }
   
    required init(coder aDecoder: NSCoder) { fatalError() }
   
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
       
        let alert = UIAlertController(title: titleText, message: messageText, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            guard let self = self else { return }
            tf.text = self.initialValue
            tf.placeholder = self.placeholder
            tf.keyboardType = self.keyboardType
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            self.textField = tf
        }
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel, handler: { [weak self] _ in self?.close() }))
        alert.addAction(UIAlertAction(title: actionTitle, style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            if self.onAction(self.textField?.text ?? "") { self.close() }
        }))
       
        Queue.mainQueue().after(0.05) { [weak self] in
            guard let self = self else { return }
            guard let root = self.view.window?.rootViewController else { return }
            var top: UIViewController = root
            while let presented = top.presentedViewController { top = presented }
            top.present(alert, animated: true)
        }
    }
   
    private func close() { self.dismiss(animated: false) }
}

private func biogramPrompt(
    title: String, text: String, value: String, placeholder: String,
    actionTitle: String, cancelTitle: String, keyboardType: UIKeyboardType = .default,
    action: @escaping (String) -> Bool
) -> ViewController {
    return BiogramTextInputController(
        title: title, text: text, value: value, placeholder: placeholder,
        actionTitle: actionTitle, cancelTitle: cancelTitle, keyboardType: keyboardType, action: action
    )
}

// MARK: - Gallery picker

private final class BannerPickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    static let shared = BannerPickerDelegate()
    var onPicked: ((UIImage?) -> Void)?
   
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
        onPicked?(image)
        picker.dismiss(animated: true)
    }
   
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

private final class PickerWrapper: ViewController {
    private let picker: UIImagePickerController
   
    init(picker: UIImagePickerController) {
        self.picker = picker
        super.init(navigationBarPresentationData: nil)
        statusBar.statusBarStyle = .Ignore
    }
   
    required init(coder: NSCoder) { fatalError() }
   
    override func loadDisplayNode() {
        displayNode = ASDisplayNode()
        displayNode.backgroundColor = .clear
        Queue.mainQueue().after(0.05) { [weak self] in
            guard let self, let root = self.view.window?.rootViewController else { return }
            var top = root
            while let p = top.presentedViewController { top = p }
            top.present(self.picker, animated: true)
        }
    }
}

// MARK: - Sections / State / Entries

private enum BiogramSection: Int32 {
    case premium = 0
    case numbers = 1
    case aliases = 2
    case color = 3
    case collectibles = 4
    case banner = 5
    case fogWallet = 6
    case info = 7
}

private final class BiogramControllerState: Equatable {
    let premiumEnabled: Bool
    let numbers: [BiogramVirtualNumber]
    let aliases: [String]
    let collectibles: [BiogramCollectible]
    let profileColorEnabled: Bool
    let profileColor: BiogramProfileColor?
    let hasBanner: Bool
    let fogWalletConnected: Bool
   
    init(
        premiumEnabled: Bool,
        numbers: [BiogramVirtualNumber],
        aliases: [String],
        collectibles: [BiogramCollectible],
        profileColorEnabled: Bool,
        profileColor: BiogramProfileColor?,
        hasBanner: Bool,
        fogWalletConnected: Bool
    ) {
        self.premiumEnabled = premiumEnabled
        self.numbers = numbers
        self.aliases = aliases
        self.collectibles = collectibles
        self.profileColorEnabled = profileColorEnabled
        self.profileColor = profileColor
        self.hasBanner = hasBanner
        self.fogWalletConnected = fogWalletConnected
    }
   
    static func == (lhs: BiogramControllerState, rhs: BiogramControllerState) -> Bool {
        return lhs.premiumEnabled == rhs.premiumEnabled
            && lhs.numbers == rhs.numbers
            && lhs.aliases == rhs.aliases
            && lhs.collectibles == rhs.collectibles
            && lhs.profileColorEnabled == rhs.profileColorEnabled
            && lhs.profileColor == rhs.profileColor
            && lhs.hasBanner == rhs.hasBanner
            && lhs.fogWalletConnected == rhs.fogWalletConnected
    }
   
    static func current(accountId: String) -> BiogramControllerState {
        return BiogramControllerState(
            premiumEnabled: BiogramManager.shared.localPremiumEnabled,
            numbers: BiogramManager.shared.virtualNumbers(),
            aliases: BiogramManager.shared.aliases(),
            collectibles: BiogramManager.shared.collectibles(),
            profileColorEnabled: BiogramManager.shared.profileColorEnabled,
            profileColor: BiogramManager.shared.profileColor,
            hasBanner: BiogramManager.shared.banner() != nil,
            fogWalletConnected: FogWalletConnectionManager.shared.isConnected(accountId: accountId)
        )
    }
}

private enum BiogramEntryId: Hashable {
    case premiumHeader, premiumToggle
    case numbersHeader, number(String), addNumber
    case aliasesHeader, alias(String), addAlias
    case colorHeader, colorToggle, colorPreset(String), colorBrightness
    case colorPattern(String), colorPatternOpacity
    case collectiblesHeader, collectible(String), addGiftFromLink
    case bannerHeader, bannerPreview, chooseBanner, removeBanner
    case fogWalletHeader, fogWalletStatus, openFogWallet, connectFogWallet, disconnectFogWallet, fogWalletInfo
    case info
}

private enum BiogramEntry: ItemListNodeEntry {
    case premiumHeader
    case premiumToggle(Bool)
    case numbersHeader
    case number(Int, BiogramVirtualNumber)
    case addNumber
    case aliasesHeader
    case alias(Int, String)
    case addAlias
    case colorHeader
    case colorToggle(Bool)
    case colorPreset(String, BiogramProfileColor, Bool)
    case colorBrightness(Double)
    case colorPattern(String, String, Bool) // title, key, selected
    case colorPatternOpacity(Double)
    case collectiblesHeader
    case collectible(Int, BiogramCollectible)
    case addGiftFromLink
    case bannerHeader
    case bannerPreview(Bool)
    case chooseBanner
    case removeBanner
    case fogWalletHeader
    case fogWalletStatus(Bool)
    case openFogWallet
    case connectFogWallet
    case disconnectFogWallet
    case fogWalletInfo
    case info
   
    var section: ItemListSectionId {
        switch self {
        case .premiumHeader, .premiumToggle: return BiogramSection.premium.rawValue
        case .numbersHeader, .number, .addNumber: return BiogramSection.numbers.rawValue
        case .aliasesHeader, .alias, .addAlias: return BiogramSection.aliases.rawValue
        case .colorHeader, .colorToggle, .colorPreset, .colorBrightness, .colorPattern, .colorPatternOpacity:
            return BiogramSection.color.rawValue
        case .collectiblesHeader, .collectible, .addGiftFromLink: return BiogramSection.collectibles.rawValue
        case .bannerHeader, .bannerPreview, .chooseBanner, .removeBanner: return BiogramSection.banner.rawValue
        case .fogWalletHeader, .fogWalletStatus, .openFogWallet, .connectFogWallet, .disconnectFogWallet, .fogWalletInfo: return BiogramSection.fogWallet.rawValue
        case .info: return BiogramSection.info.rawValue
        }
    }
   
    var stableId: BiogramEntryId {
        switch self {
        case .premiumHeader: return .premiumHeader
        case .premiumToggle: return .premiumToggle
        case .numbersHeader: return .numbersHeader
        case let .number(_, n): return .number(n.id)
        case .addNumber: return .addNumber
        case .aliasesHeader: return .aliasesHeader
        case let .alias(_, a): return .alias(a)
        case .addAlias: return .addAlias
        case .colorHeader: return .colorHeader
        case .colorToggle: return .colorToggle
        case let .colorPreset(name, _, _): return .colorPreset(name)
        case .colorBrightness: return .colorBrightness
        case let .colorPattern(_, key, _): return .colorPattern(key)
        case .colorPatternOpacity: return .colorPatternOpacity
        case .collectiblesHeader: return .collectiblesHeader
        case let .collectible(_, c): return .collectible(c.id)
        case .addGiftFromLink: return .addGiftFromLink
        case .bannerHeader: return .bannerHeader
        case .bannerPreview: return .bannerPreview
        case .chooseBanner: return .chooseBanner
        case .removeBanner: return .removeBanner
        case .fogWalletHeader: return .fogWalletHeader
        case .fogWalletStatus: return .fogWalletStatus
        case .openFogWallet: return .openFogWallet
        case .connectFogWallet: return .connectFogWallet
        case .disconnectFogWallet: return .disconnectFogWallet
        case .fogWalletInfo: return .fogWalletInfo
        case .info: return .info
        }
    }
   
    static func < (lhs: BiogramEntry, rhs: BiogramEntry) -> Bool {
        if lhs.section != rhs.section { return lhs.section < rhs.section }
        return false
    }
   
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! BiogramArguments
        switch self {
        case .premiumHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "LOCAL PREMIUM", sectionId: self.section)
        case let .premiumToggle(value):
            return ItemListSwitchItem(presentationData: presentationData, title: "Local Premium", value: value, sectionId: self.section, style: .blocks, updated: { arguments.togglePremium($0) })
        case .numbersHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "VIRTUAL / ANONYMOUS NUMBERS", sectionId: self.section)
        case let .number(_, number):
            let title = number.label ?? number.number
            let label = number.label != nil ? number.number : "Tap to edit / remove"
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: label, sectionId: self.section, style: .blocks, action: { arguments.editOrRemoveNumber(number) })
        case .addNumber:
            return ItemListActionItem(presentationData: presentationData, title: "Add Number", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.addNumber() })
        case .aliasesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ALIASES / USERNAMES", sectionId: self.section)
        case let .alias(_, alias):
            return ItemListDisclosureItem(presentationData: presentationData, title: "@\(alias)", label: "Tap to edit / remove", sectionId: self.section, style: .blocks, action: { arguments.editOrRemoveAlias(alias) })
        case .addAlias:
            return ItemListActionItem(presentationData: presentationData, title: "Add Alias", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.addAlias() })
        case .colorHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "PROFILE COLOR", sectionId: self.section)
        case let .colorToggle(value):
            return ItemListSwitchItem(presentationData: presentationData, title: "Custom profile color", value: value, sectionId: self.section, style: .blocks, updated: { arguments.toggleColor($0) })
        case let .colorPreset(name, color, selected):
            return ItemListDisclosureItem(presentationData: presentationData, title: name, label: selected ? "✓" : "", sectionId: self.section, style: .blocks, action: { arguments.selectPreset(color) })
        case let .colorBrightness(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Brightness", label: "\(Int((value * 100).rounded()))%", sectionId: self.section, style: .blocks, action: { arguments.pickBrightness() })
        case let .colorPattern(title, key, selected):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: selected ? "✓" : "", sectionId: self.section, style: .blocks, action: { arguments.selectPattern(key) })
        case let .colorPatternOpacity(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Pattern opacity", label: "\(Int((value * 100).rounded()))%", sectionId: self.section, style: .blocks, action: { arguments.pickPatternOpacity() })
        case .collectiblesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "COLLECTIBLES / GIFTS", sectionId: self.section)
        case let .collectible(_, item):
            let title = item.title ?? item.giftSlug ?? item.id
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "Tap to remove", sectionId: self.section, style: .blocks, action: { arguments.removeCollectible(item.id) })
        case .addGiftFromLink:
            return ItemListActionItem(presentationData: presentationData, title: "Add Gift by Link", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.addGiftFromLink() })
        case .bannerHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "PROFILE BANNER", sectionId: self.section)
        case let .bannerPreview(hasImage):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Current banner", label: hasImage ? "Set" : "Not set", sectionId: self.section, style: .blocks, action: nil)
        case .chooseBanner:
            return ItemListActionItem(presentationData: presentationData, title: "Choose from Gallery", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.chooseBanner() })
        case .removeBanner:
            return ItemListActionItem(presentationData: presentationData, title: "Remove Banner", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.removeBanner() })
        case .fogWalletHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "FOG WALLET", sectionId: self.section)
        case let .fogWalletStatus(connected):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Cloud connection", label: connected ? "Connected" : "Not connected", sectionId: self.section, style: .blocks, action: nil)
        case .openFogWallet:
            return ItemListActionItem(presentationData: presentationData, title: "Open card collection", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.openFogWallet() })
        case .connectFogWallet:
            return ItemListActionItem(presentationData: presentationData, title: "Connect Fog Wallet", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.connectFogWallet() })
        case .disconnectFogWallet:
            return ItemListActionItem(presentationData: presentationData, title: "Disconnect Fog Wallet", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.disconnectFogWallet() })
        case .fogWalletInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Cards are stored in Fog Wallet and shown here when you open the collection. Linking does not grant access to chats, contacts, or your phone number. You can disconnect at any time."), sectionId: self.section)
        case .info:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Local-only. Visible only in this client. Not sent to Telegram servers. Banner uses original image aspect ratio."), sectionId: self.section)
        }
    }
}

private final class BiogramArguments {
    let togglePremium: (Bool) -> Void
    let addNumber: () -> Void
    let editOrRemoveNumber: (BiogramVirtualNumber) -> Void
    let addAlias: () -> Void
    let editOrRemoveAlias: (String) -> Void
    let toggleColor: (Bool) -> Void
    let selectPreset: (BiogramProfileColor) -> Void
    let setBrightness: (Double) -> Void
    let pickBrightness: () -> Void
    let selectPattern: (String) -> Void
    let pickPatternOpacity: () -> Void
    let removeCollectible: (String) -> Void
    let addGiftFromLink: () -> Void
    let chooseBanner: () -> Void
    let removeBanner: () -> Void
    let openFogWallet: () -> Void
    let connectFogWallet: () -> Void
    let disconnectFogWallet: () -> Void
   
    init(
        togglePremium: @escaping (Bool) -> Void,
        addNumber: @escaping () -> Void,
        editOrRemoveNumber: @escaping (BiogramVirtualNumber) -> Void,
        addAlias: @escaping () -> Void,
        editOrRemoveAlias: @escaping (String) -> Void,
        toggleColor: @escaping (Bool) -> Void,
        selectPreset: @escaping (BiogramProfileColor) -> Void,
        setBrightness: @escaping (Double) -> Void,
        pickBrightness: @escaping () -> Void,
        selectPattern: @escaping (String) -> Void,
        pickPatternOpacity: @escaping () -> Void,
        removeCollectible: @escaping (String) -> Void,
        addGiftFromLink: @escaping () -> Void,
        chooseBanner: @escaping () -> Void,
        removeBanner: @escaping () -> Void,
        openFogWallet: @escaping () -> Void,
        connectFogWallet: @escaping () -> Void,
        disconnectFogWallet: @escaping () -> Void
    ) {
        self.togglePremium = togglePremium
        self.addNumber = addNumber
        self.editOrRemoveNumber = editOrRemoveNumber
        self.addAlias = addAlias
        self.editOrRemoveAlias = editOrRemoveAlias
        self.toggleColor = toggleColor
        self.selectPreset = selectPreset
        self.setBrightness = setBrightness
        self.pickBrightness = pickBrightness
        self.selectPattern = selectPattern
        self.pickPatternOpacity = pickPatternOpacity
        self.removeCollectible = removeCollectible
        self.addGiftFromLink = addGiftFromLink
        self.chooseBanner = chooseBanner
        self.removeBanner = removeBanner
        self.openFogWallet = openFogWallet
        self.connectFogWallet = connectFogWallet
        self.disconnectFogWallet = disconnectFogWallet
    }
}

private func biogramControllerEntries(state: BiogramControllerState) -> [BiogramEntry] {
    var entries: [BiogramEntry] = []
   
    entries.append(.premiumHeader)
    entries.append(.premiumToggle(state.premiumEnabled))
   
    entries.append(.numbersHeader)
    for (i, n) in state.numbers.enumerated() { entries.append(.number(i, n)) }
    entries.append(.addNumber)
   
    entries.append(.aliasesHeader)
    for (i, a) in state.aliases.enumerated() { entries.append(.alias(i, a)) }
    entries.append(.addAlias)
   
    entries.append(.colorHeader)
    entries.append(.colorToggle(state.profileColorEnabled))
    if state.profileColorEnabled {
        let current = state.profileColor
        for (name, preset) in BiogramProfileColor.presets {
            let selected = current != nil
                && abs(current!.r - preset.r) < 0.01
                && abs(current!.g - preset.g) < 0.01
                && abs(current!.b - preset.b) < 0.01
            entries.append(.colorPreset(name, preset, selected))
        }
        entries.append(.colorBrightness(current?.brightness ?? 1.0))
       
        let currentPattern = current?.pattern ?? "none"
        for (title, key) in BiogramProfileColor.patterns {
            entries.append(.colorPattern(title, key, currentPattern == key))
        }
        if currentPattern != "none" {
            entries.append(.colorPatternOpacity(current?.patternOpacity ?? 0.25))
        }
    }
   
    entries.append(.collectiblesHeader)
    for (i, c) in state.collectibles.enumerated() { entries.append(.collectible(i, c)) }
    entries.append(.addGiftFromLink)
   
    // Banner — без ручной высоты, aspect ratio берётся из картинки (free)
    entries.append(.bannerHeader)
    entries.append(.bannerPreview(state.hasBanner))
    entries.append(.chooseBanner)
    if state.hasBanner {
        entries.append(.removeBanner)
    }

    entries.append(.fogWalletHeader)
    entries.append(.fogWalletStatus(state.fogWalletConnected))
    if state.fogWalletConnected {
        entries.append(.openFogWallet)
        entries.append(.disconnectFogWallet)
    } else {
        entries.append(.connectFogWallet)
    }
    entries.append(.fogWalletInfo)

    entries.append(.info)
    return entries
}

public func biogramSettingsController(context: AccountContext) -> ViewController {
    // Preserve the existing Biogram account key for its local preferences.
    let accountId = String(context.account.peerId.toInt64())
    // Use Telegram's raw user ID only for Fog Wallet's explicit account-link check.
    let fogWalletAccountId = String(context.account.peerId.id._internalGetInt64Value())
    let initialState = BiogramControllerState.current(accountId: fogWalletAccountId)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: (() -> Void) = {
        let newState = BiogramControllerState.current(accountId: fogWalletAccountId)
        _ = stateValue.swap(newState)
        statePromise.set(newState)
    }
    // === Biogram: загружаем настройки именно текущего Telegram-аккаунта ===
    BiogramManager.shared.switchToAccount(accountId: accountId) {
        updateState()
    }
    // =====================================================================
    var presentControllerImpl: ((ViewController, Any?) -> Void)?

    let startFogWalletConnection: () -> Void = {
        let telegramUserId = String(context.account.peerId.id._internalGetInt64Value())
        FogWalletConnectionManager.shared.connect(
            telegramUserId: telegramUserId,
            accountId: fogWalletAccountId,
            presentBrowser: { browser in
                presentControllerImpl?(browser, nil)
            },
            completion: { result in
                Queue.mainQueue().async {
                    updateState()
                    switch result {
                    case .success:
                        let alert = BiogramActionsAlertController(
                            title: "Fog Wallet connected",
                            message: "Your Telegram account is linked. Open the Fog Wallet collection from Biogram settings to view and claim cards.",
                            actions: []
                        )
                        presentControllerImpl?(alert, nil)
                    case let .failure(error):
                        let alert = BiogramActionsAlertController(
                            title: "Could not connect",
                            message: error.localizedDescription,
                            actions: []
                        )
                        presentControllerImpl?(alert, nil)
                    }
                }
            }
        )
    }

    let arguments = BiogramArguments(
        togglePremium: { enabled in
            BiogramManager.shared.setLocalPremiumEnabled(enabled) {
                Queue.mainQueue().async { updateState() }
            }
        },
        addNumber: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = biogramPrompt(
                title: "Enter number", text: "Virtual / anonymous number", value: "+888 ",
                placeholder: "+888 00001212", actionTitle: presentationData.strings.Common_Done,
                cancelTitle: presentationData.strings.Common_Cancel, keyboardType: .default
            ) { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                BiogramManager.shared.addVirtualNumber(BiogramVirtualNumber(number: trimmed)) {
                    Queue.mainQueue().async { updateState() }
                }
                return true
            }
            presentControllerImpl?(controller, nil)
        },
        editOrRemoveNumber: { number in
            let alert = BiogramActionsAlertController(title: number.number, message: "Edit or remove this number", actions: [
                (title: "Edit", destructive: false, action: {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let editCtrl = biogramPrompt(
                        title: "Number", text: "Edit number", value: number.number, placeholder: "+888 ...",
                        actionTitle: presentationData.strings.Common_Done, cancelTitle: presentationData.strings.Common_Cancel
                    ) { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return false }
                        BiogramManager.shared.updateVirtualNumber(id: number.id, number: trimmed, label: number.label) {
                            Queue.mainQueue().async { updateState() }
                        }
                        return true
                    }
                    presentControllerImpl?(editCtrl, nil)
                }),
                (title: "Delete", destructive: true, action: {
                    BiogramManager.shared.removeVirtualNumber(id: number.id) {
                        Queue.mainQueue().async { updateState() }
                    }
                })
            ])
            presentControllerImpl?(alert, nil)
        },
        addAlias: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = biogramPrompt(
                title: "Enter username", text: "Alias / username (without @)", value: "",
                placeholder: "username", actionTitle: presentationData.strings.Common_Done,
                cancelTitle: presentationData.strings.Common_Cancel
            ) { value in
                var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("@") { trimmed = String(trimmed.dropFirst()) }
                guard !trimmed.isEmpty else { return false }
                BiogramManager.shared.addAlias(trimmed) {
                    Queue.mainQueue().async { updateState() }
                }
                return true
            }
            presentControllerImpl?(controller, nil)
        },
        editOrRemoveAlias: { alias in
            let alert = BiogramActionsAlertController(title: "@\(alias)", message: "Edit or remove this username", actions: [
                (title: "Edit", destructive: false, action: {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let editCtrl = biogramPrompt(
                        title: "Username", text: "Edit username", value: alias, placeholder: "username",
                        actionTitle: presentationData.strings.Common_Done, cancelTitle: presentationData.strings.Common_Cancel
                    ) { value in
                        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("@") { trimmed = String(trimmed.dropFirst()) }
                        guard !trimmed.isEmpty else { return false }
                        BiogramManager.shared.replaceAlias(old: alias, new: trimmed) {
                            Queue.mainQueue().async { updateState() }
                        }
                        return true
                    }
                    presentControllerImpl?(editCtrl, nil)
                }),
                (title: "Delete", destructive: true, action: {
                    BiogramManager.shared.removeAlias(alias) {
                        Queue.mainQueue().async { updateState() }
                    }
                })
            ])
            presentControllerImpl?(alert, nil)
        },
        toggleColor: { enabled in
            let current = BiogramManager.shared.profileColor ?? BiogramProfileColor.presets[0].1
            BiogramManager.shared.setProfileColor(current, enabled: enabled) {
                Queue.mainQueue().async { updateState() }
            }
        },
        selectPreset: { color in
            let existing = BiogramManager.shared.profileColor
            let newColor = BiogramProfileColor(
                r: color.r,
                g: color.g,
                b: color.b,
                brightness: existing?.brightness ?? 1.0,
                pattern: existing?.pattern ?? "none",
                patternOpacity: existing?.patternOpacity ?? 0.25
            )
            BiogramManager.shared.setProfileColor(newColor, enabled: true) {
                Queue.mainQueue().async { updateState() }
            }
        },
        setBrightness: { value in
            guard var color = BiogramManager.shared.profileColor else { return }
            color.brightness = value
            BiogramManager.shared.setProfileColor(color, enabled: true) {
                Queue.mainQueue().async { updateState() }
            }
        },
        pickBrightness: {
            let alert = BiogramActionsAlertController(title: "Brightness", message: "Choose shade intensity", actions: [0.3, 0.5, 0.7, 0.85, 1.0, 1.15, 1.2].map { value in
                (title: "\(Int(value * 100))%", destructive: false, action: {
                    guard var color = BiogramManager.shared.profileColor else { return }
                    color.brightness = value
                    BiogramManager.shared.setProfileColor(color, enabled: true) {
                        Queue.mainQueue().async { updateState() }
                    }
                })
            })
            presentControllerImpl?(alert, nil)
        },
        selectPattern: { key in
            guard var color = BiogramManager.shared.profileColor else {
                var c = BiogramProfileColor.presets[0].1
                c.pattern = key
                BiogramManager.shared.setProfileColor(c, enabled: true) {
                    Queue.mainQueue().async { updateState() }
                }
                return
            }
            color.pattern = key
            BiogramManager.shared.setProfileColor(color, enabled: true) {
                Queue.mainQueue().async { updateState() }
            }
        },
        pickPatternOpacity: {
            let alert = BiogramActionsAlertController(title: "Pattern opacity", message: "How visible the pattern is", actions: [0.1, 0.15, 0.25, 0.35, 0.5, 0.7].map { value in
                (title: "\(Int(value * 100))%", destructive: false, action: {
                    guard var color = BiogramManager.shared.profileColor else { return }
                    color.patternOpacity = value
                    BiogramManager.shared.setProfileColor(color, enabled: true) {
                        Queue.mainQueue().async { updateState() }
                    }
                })
            })
            presentControllerImpl?(alert, nil)
        },
        removeCollectible: { id in
            BiogramManager.shared.removeCollectible(id: id) {
                Queue.mainQueue().async { updateState() }
            }
        },
        addGiftFromLink: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = biogramPrompt(
                title: "Gift link", text: "Paste https://t.me/nft/... or slug", value: "",
                placeholder: "https://t.me/nft/VoodooDoll-319", actionTitle: presentationData.strings.Common_Done,
                cancelTitle: presentationData.strings.Common_Cancel, keyboardType: .URL
            ) { value in
                _ = BiogramManager.shared.addCollectibleFromGiftLink(value) {
                    Queue.mainQueue().async { updateState() }
                }
                return true
            }
            presentControllerImpl?(controller, nil)
        },
        chooseBanner: {
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.allowsEditing = false  // false = не режет квадратом, сохраняет исходный aspect
            picker.delegate = BannerPickerDelegate.shared
           
            BannerPickerDelegate.shared.onPicked = { image in
                guard let image = image else { return }
                BiogramManager.shared.setBannerImage(image, aspectRatio: "free") {
                    Queue.mainQueue().async { updateState() }
                }
            }
            presentControllerImpl?(PickerWrapper(picker: picker), nil)
        },
        removeBanner: {
            BiogramManager.shared.setBannerImage(nil) {
                Queue.mainQueue().async { updateState() }
            }
        },
        openFogWallet: {
            presentControllerImpl?(FogWalletCardsViewController(accountId: fogWalletAccountId), nil)
        },
        connectFogWallet: {
            let confirmation = BiogramActionsAlertController(
                title: "Connect Fog Wallet?",
                message: "Telegram will confirm that the account already open in Biogram is yours. Fog Wallet stores a minimal account link and a revocable session. It does not request your phone number, chats, contacts, or permission for a bot to message you. Continue?",
                actions: [
                    (title: "Continue to Telegram", destructive: false, action: {
                        startFogWalletConnection()
                    })
                ]
            )
            presentControllerImpl?(confirmation, nil)
        },
        disconnectFogWallet: {
            let confirmation = BiogramActionsAlertController(
                title: "Disconnect Fog Wallet?",
                message: "This revokes Fog Wallet sessions on the server and stops this app from using the connection. Issued-card records and transfer history, if any, are not deleted.",
                actions: [
                    (title: "Disconnect", destructive: true, action: {
                        FogWalletConnectionManager.shared.disconnect(accountId: fogWalletAccountId) { result in
                            Queue.mainQueue().async {
                                updateState()
                                switch result {
                                case .success:
                                    let alert = BiogramActionsAlertController(
                                        title: "Fog Wallet disconnected",
                                        message: "This Biogram app can no longer use the saved Fog Wallet session.",
                                        actions: []
                                    )
                                    presentControllerImpl?(alert, nil)
                                case let .failure(error):
                                    let alert = BiogramActionsAlertController(
                                        title: "Could not disconnect",
                                        message: error.localizedDescription,
                                        actions: []
                                    )
                                    presentControllerImpl?(alert, nil)
                                }
                            }
                        }
                    })
                ]
            )
            presentControllerImpl?(confirmation, nil)
        }
    )
   
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = biogramControllerEntries(state: state)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Biogram"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: true
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
   
    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }

    let promptKey = "fogWalletConnectPromptShown.\(fogWalletAccountId)"
    if !initialState.fogWalletConnected && !UserDefaults.standard.bool(forKey: promptKey) {
        UserDefaults.standard.set(true, forKey: promptKey)
        Queue.mainQueue().after(0.6) { [weak controller] in
            guard controller != nil else { return }
            let invitation = BiogramActionsAlertController(
                title: "Connect Fog Wallet?",
                message: "Connect Fog Wallet to view your card collection and claim cards in Biogram. Telegram confirms the account. Fog Wallet does not request your phone number, chats, or contacts. Connecting is optional, and you can disconnect any time in Biogram settings.",
                actions: [
                    (title: "Connect", destructive: false, action: {
                        startFogWalletConnection()
                    })
                ]
            )
            presentControllerImpl?(invitation, nil)
        }
    }
    return controller
}
// MARK: - Fog Wallet cards

private func fogWalletColor(_ hex: String) -> UIColor {
    var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    if value.count != 6 { value = "171719" }
    var rgb: UInt64 = 0
    Scanner(string: value).scanHexInt64(&rgb)
    return UIColor(
        red: CGFloat((rgb >> 16) & 0xff) / 255.0,
        green: CGFloat((rgb >> 8) & 0xff) / 255.0,
        blue: CGFloat(rgb & 0xff) / 255.0,
        alpha: 1.0
    )
}

private final class FogWalletActionButton: UIButton {
    var handler: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addTarget(self, action: #selector(runHandler), for: .touchUpInside)
        self.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        self.layer.cornerRadius = 13
        self.layer.masksToBounds = true
        self.contentEdgeInsets = UIEdgeInsets(top: 11, left: 15, bottom: 11, right: 15)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func runHandler() { self.handler?() }
}

private final class FogPremiumCardView: UIControl {
    private let gradient = CAGradientLayer()
    private let artworkView = UIImageView()
    private let overlayView = UIView()
    private let overlayGradient = CAGradientLayer()
    private let faceView = UIView()
    private var card: [String: Any] = [:]
    private var design: [String: Any] = [:]
    private var showingBack = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 25
        self.layer.borderWidth = 1
        self.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.38
        self.layer.shadowRadius = 18
        self.layer.shadowOffset = CGSize(width: 0, height: 11)
        self.layer.masksToBounds = false
        self.layer.insertSublayer(self.gradient, at: 0)
        self.artworkView.contentMode = .scaleAspectFill
        self.artworkView.clipsToBounds = true
        self.artworkView.layer.cornerRadius = 24
        self.artworkView.isUserInteractionEnabled = false
        self.addSubview(self.artworkView)
        self.overlayView.isUserInteractionEnabled = false
        self.overlayGradient.colors = [
            UIColor.black.withAlphaComponent(0.10).cgColor,
            UIColor.black.withAlphaComponent(0.26).cgColor,
            UIColor.black.withAlphaComponent(0.82).cgColor
        ]
        self.overlayGradient.locations = [0.0, 0.48, 1.0]
        self.overlayView.layer.addSublayer(self.overlayGradient)
        self.addSubview(self.overlayView)
        self.faceView.backgroundColor = .clear
        self.faceView.isUserInteractionEnabled = false
        self.addSubview(self.faceView)
        self.addTarget(self, action: #selector(toggleFace), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.gradient.frame = self.bounds
        self.artworkView.frame = self.bounds
        self.overlayView.frame = self.bounds
        self.overlayGradient.frame = self.overlayView.bounds
        self.faceView.frame = self.bounds
        self.layer.shadowPath = UIBezierPath(roundedRect: self.bounds, cornerRadius: 25).cgPath
    }

    func configure(card: [String: Any]) {
        self.card = card
        self.design = card["design"] as? [String: Any] ?? card
        let palette = (self.design["palette"] as? [String]) ?? ["#151517", "#343238", "#C9B79E"]
        let colors = palette.prefix(4).map { fogWalletColor($0).cgColor }
        self.gradient.colors = colors.count >= 2 ? colors : [fogWalletColor("#171719").cgColor, fogWalletColor("#373137").cgColor]
        self.gradient.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.gradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.artworkView.image = nil
        if let art = self.design["asset_url"] as? String,
           let url = URL(string: art), url.scheme == "https" {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self?.artworkView.image = image }
            }.resume()
        }
        self.showingBack = false
        self.renderFace()
    }

    @objc private func toggleFace() {
        self.showingBack.toggle()
        UIView.transition(
            with: self.faceView,
            duration: 0.52,
            options: [.transitionFlipFromRight, .showHideTransitionViews, .curveEaseInOut],
            animations: { [weak self] in self?.renderFace() }
        )
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = lines
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        return label
    }

    private func renderFace() {
        self.faceView.subviews.forEach { $0.removeFromSuperview() }
        let inset: CGFloat = 21
        if self.showingBack {
            let stamp = self.makeLabel("FOG  /  CERTIFICATE", size: 10, weight: .bold, color: UIColor.white.withAlphaComponent(0.72))
            let title = self.makeLabel("Authenticity proof", size: 20, weight: .semibold, color: .white, lines: 2)
            let proof = self.makeLabel(self.card["proof"] as? String ?? "NOT ISSUED", size: 13, weight: .semibold, color: fogWalletColor("#E6D4B7"))
            proof.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            let serial = self.makeLabel("SERIAL  " + (self.card["serial"] as? String ?? "PREVIEW"), size: 10, weight: .medium, color: UIColor.white.withAlphaComponent(0.82))
            serial.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let valid = (self.card["certificate_verified"] as? Bool) == true
            let state = self.makeLabel(
                valid ? "✓  VERIFIED CERTIFICATE" : (self.card["serial"] == nil ? "PREVIEW — NOT ISSUED" : "CERTIFICATE STATUS UNCONFIRMED"),
                size: 10, weight: .bold,
                color: valid ? fogWalletColor("#D9C29E") : UIColor.white.withAlphaComponent(0.64),
                lines: 2
            )
            let note = self.makeLabel("This masked proof is not the activation code.", size: 10, weight: .regular, color: UIColor.white.withAlphaComponent(0.56), lines: 2)
            [stamp, title, proof, serial, state, note].forEach { self.faceView.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                stamp.topAnchor.constraint(equalTo: self.faceView.topAnchor, constant: 25),
                stamp.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                stamp.trailingAnchor.constraint(lessThanOrEqualTo: self.faceView.trailingAnchor, constant: -inset),
                title.topAnchor.constraint(equalTo: stamp.bottomAnchor, constant: 34),
                title.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                title.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                proof.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 28),
                proof.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                proof.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                serial.topAnchor.constraint(equalTo: proof.bottomAnchor, constant: 23),
                serial.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                serial.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                state.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                state.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                state.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -14),
                note.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                note.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                note.bottomAnchor.constraint(equalTo: self.faceView.bottomAnchor, constant: -22)
            ])
        } else {
            let logo = self.makeLabel("FOG", size: 12, weight: .heavy, color: UIColor.white.withAlphaComponent(0.94))
            let topRight = self.makeLabel("PRIVATE COLLECTION", size: 8, weight: .bold, color: UIColor.white.withAlphaComponent(0.76))
            topRight.textAlignment = .right
            let ornament = self.makeLabel("◌", size: 56, weight: .ultraLight, color: UIColor.white.withAlphaComponent(0.17))
            ornament.textAlignment = .right
            let series = self.makeLabel((self.design["series"] as? String ?? "Fog Originals").uppercased(), size: 9, weight: .semibold, color: UIColor.white.withAlphaComponent(0.65))
            let title = self.makeLabel(self.design["title"] as? String ?? "Fog Card", size: 22, weight: .semibold, color: .white, lines: 3)
            let subtitle = self.makeLabel(self.design["subtitle"] as? String ?? "", size: 11, weight: .regular, color: UIColor.white.withAlphaComponent(0.72), lines: 2)
            let rarity = self.makeLabel((self.design["rarity"] as? String ?? "Standard").uppercased(), size: 9, weight: .bold, color: fogWalletColor("#E7D7C0"))
            let serial = self.makeLabel(self.card["serial"] as? String ?? "CARD PREVIEW", size: 9, weight: .medium, color: UIColor.white.withAlphaComponent(0.76))
            serial.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            [logo, topRight, ornament, series, title, subtitle, rarity, serial].forEach { self.faceView.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                logo.topAnchor.constraint(equalTo: self.faceView.topAnchor, constant: 23),
                logo.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                topRight.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
                topRight.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                topRight.leadingAnchor.constraint(greaterThanOrEqualTo: logo.trailingAnchor, constant: 6),
                ornament.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 2),
                ornament.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                series.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                series.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                series.bottomAnchor.constraint(equalTo: title.topAnchor, constant: -10),
                title.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                title.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                title.bottomAnchor.constraint(equalTo: subtitle.topAnchor, constant: -5),
                subtitle.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                subtitle.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                subtitle.bottomAnchor.constraint(equalTo: rarity.topAnchor, constant: -21),
                rarity.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                rarity.bottomAnchor.constraint(equalTo: serial.topAnchor, constant: -13),
                serial.leadingAnchor.constraint(equalTo: self.faceView.leadingAnchor, constant: inset),
                serial.trailingAnchor.constraint(equalTo: self.faceView.trailingAnchor, constant: -inset),
                serial.bottomAnchor.constraint(equalTo: self.faceView.bottomAnchor, constant: -22)
            ])
        }
    }
}

private final class FogWalletCardsViewController: ViewController {
    private enum Tab { case collection, catalog }
    private let accountId: String
    private let cacheCollectionKey: String
    private let cacheCatalogKey: String
    private var cards: [[String: Any]] = []
    private var designs: [[String: Any]] = []
    private var activeTab: Tab = .collection
    private var statusMessage: String?
    private var isRefreshing = false
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    init(accountId: String) {
        self.accountId = accountId
        self.cacheCollectionKey = "fog.cards.collection.\(accountId)"
        self.cacheCatalogKey = "fog.cards.catalog.\(accountId)"
        super.init(navigationBarPresentationData: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = fogWalletColor("#0B0B0D")
        let root = self.displayNode.view
        root.backgroundColor = fogWalletColor("#0B0B0D")
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.keyboardDismissMode = .interactive
        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(self.scrollView)
        self.contentStack.axis = .vertical
        self.contentStack.alignment = .fill
        self.contentStack.spacing = 18
        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.contentStack)
        NSLayoutConstraint.activate([
            self.scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            self.scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            self.contentStack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor, constant: 20),
            self.contentStack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor, constant: 18),
            self.contentStack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor, constant: -18),
            self.contentStack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            self.contentStack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor, constant: -36)
        ])
        self.loadCache()
        self.render()
        self.refreshData()
    }

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: self.cacheCollectionKey),
           let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            self.cards = values
        }
        if let data = UserDefaults.standard.data(forKey: self.cacheCatalogKey),
           let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            self.designs = values
        }
    }

    private func save(_ values: [[String: Any]], key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .white, lines: Int = 0) -> UILabel {
        let view = UILabel()
        view.text = text
        view.font = UIFont.systemFont(ofSize: size, weight: weight)
        view.textColor = color
        view.numberOfLines = lines
        return view
    }

    private func actionButton(_ title: String, primary: Bool = false, handler: @escaping () -> Void) -> UIButton {
        let button = FogWalletActionButton(type: .system)
        button.handler = handler
        button.setTitle(title, for: .normal)
        button.backgroundColor = primary ? fogWalletColor("#D8C2A2") : fogWalletColor("#202024")
        button.setTitleColor(primary ? fogWalletColor("#171619") : UIColor.white, for: .normal)
        button.layer.borderColor = UIColor.white.withAlphaComponent(primary ? 0.0 : 0.12).cgColor
        button.layer.borderWidth = primary ? 0 : 1
        return button
    }

    private func clearStack() {
        while let view = self.contentStack.arrangedSubviews.last {
            self.contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func render() {
        guard self.isViewLoaded else { return }
        self.clearStack()
        let topBar = UIStackView()
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.distribution = .equalSpacing
        topBar.addArrangedSubview(self.actionButton("‹  Biogram") { [weak self] in self?.dismiss(animated: true) })
        topBar.addArrangedSubview(self.actionButton("Refresh") { [weak self] in self?.refreshData() })
        self.contentStack.addArrangedSubview(topBar)
        let title = self.label("FOG WALLET", size: 11, weight: .bold, color: fogWalletColor("#D8C2A2"))
        self.contentStack.addArrangedSubview(title)
        let subtitle = self.label("A private collection. Not a trading game.", size: 25, weight: .semibold, color: .white, lines: 2)
        subtitle.adjustsFontSizeToFitWidth = true
        subtitle.minimumScaleFactor = 0.82
        self.contentStack.addArrangedSubview(subtitle)
        self.contentStack.addArrangedSubview(self.label("Tap any card to turn it over and view its masked authenticity proof. Activation codes are never shown on a card.", size: 13, color: UIColor.white.withAlphaComponent(0.58), lines: 0))
        if let message = self.statusMessage {
            let status = self.label(message, size: 12, color: fogWalletColor("#D9C6A9"), lines: 0)
            status.backgroundColor = fogWalletColor("#1B1918")
            status.layer.cornerRadius = 12
            status.layer.masksToBounds = true
            self.contentStack.addArrangedSubview(status)
        }
        let tabs = UIStackView()
        tabs.axis = .horizontal
        tabs.distribution = .fillEqually
        tabs.spacing = 8
        tabs.addArrangedSubview(self.actionButton(self.cards.isEmpty ? "My cards" : "My cards · \(self.cards.count)", primary: self.activeTab == .collection) { [weak self] in
            self?.activeTab = .collection
            self?.render()
        })
        tabs.addArrangedSubview(self.actionButton("Discover", primary: self.activeTab == .catalog) { [weak self] in
            self?.activeTab = .catalog
            self?.render()
        })
        self.contentStack.addArrangedSubview(tabs)
        self.contentStack.addArrangedSubview(self.actionButton("Activate a code", handler: { [weak self] in self?.promptForActivationCode() }))
        if self.activeTab == .collection {
            if self.cards.isEmpty {
                self.contentStack.addArrangedSubview(self.label("Your collection is empty", size: 19, weight: .semibold, color: .white))
                self.contentStack.addArrangedSubview(self.label("You can collect a standard design without a code, or activate a limited-edition card with a code.", size: 13, color: UIColor.white.withAlphaComponent(0.58), lines: 0))
                self.contentStack.addArrangedSubview(self.actionButton("Explore card designs", primary: true) { [weak self] in
                    self?.activeTab = .catalog
                    self?.render()
                })
            } else {
                for card in self.cards { self.addCollectionCard(card) }
            }
        } else {
            if self.designs.isEmpty {
                self.contentStack.addArrangedSubview(self.label("No card designs are published yet.", size: 16, weight: .semibold, color: .white))
                self.contentStack.addArrangedSubview(self.label("The collection will refresh when designs become available on the Fog Wallet server.", size: 13, color: UIColor.white.withAlphaComponent(0.58), lines: 0))
            } else {
                for design in self.designs { self.addCatalogDesign(design) }
            }
        }
        self.contentStack.addArrangedSubview(self.label("Artwork, collection and proof status refresh from Fog Wallet. Your last successful collection/catalog are cached on this device.", size: 11, color: UIColor.white.withAlphaComponent(0.40), lines: 0))
    }

    private func addCollectionCard(_ card: [String: Any]) {
        let cardView = FogPremiumCardView()
        cardView.configure(card: card)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        let centering = UIView()
        centering.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: centering.centerXAnchor),
            cardView.topAnchor.constraint(equalTo: centering.topAnchor),
            cardView.bottomAnchor.constraint(equalTo: centering.bottomAnchor),
            cardView.widthAnchor.constraint(equalToConstant: 222),
            cardView.heightAnchor.constraint(equalToConstant: 332)
        ])
        let cardIndex = self.cards.firstIndex { ($0["id"] as? String) == (card["id"] as? String) } ?? 0
        centering.alpha = 0
        centering.transform = CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 10)
        self.contentStack.addArrangedSubview(centering)
        UIView.animate(
            withDuration: 0.62,
            delay: Double(min(cardIndex, 6)) * 0.055,
            usingSpringWithDamping: 0.84,
            initialSpringVelocity: 0.35,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                centering.alpha = 1
                centering.transform = .identity
            }
        )
        let issued = (card["issued_at"] as? NSNumber)?.doubleValue ?? 0
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .none
        let dateText = issued > 0 ? date.string(from: Date(timeIntervalSince1970: issued)) : "Date unavailable"
        let design = card["design"] as? [String: Any] ?? [:]
        self.contentStack.addArrangedSubview(self.label("\(design["title"] as? String ?? "Fog Card")  ·  \(dateText)", size: 12, color: UIColor.white.withAlphaComponent(0.62), lines: 2))
    }

    private func addCatalogDesign(_ design: [String: Any]) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        let preview = FogPremiumCardView()
        preview.configure(card: design)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 145),
            preview.heightAnchor.constraint(equalToConstant: 218)
        ])
        row.addArrangedSubview(preview)
        let details = UIStackView()
        details.axis = .vertical
        details.alignment = .fill
        details.spacing = 8
        details.addArrangedSubview(self.label(design["title"] as? String ?? "Fog Card", size: 16, weight: .semibold, color: .white, lines: 3))
        details.addArrangedSubview(self.label("\(design["rarity"] as? String ?? "Standard")  ·  \(design["series"] as? String ?? "Fog Originals")", size: 11, color: fogWalletColor("#D8C2A2"), lines: 2))
        details.addArrangedSubview(self.label(design["subtitle"] as? String ?? "", size: 12, color: UIColor.white.withAlphaComponent(0.56), lines: 3))
        if (design["kind"] as? String ?? "standard") == "standard" {
            details.addArrangedSubview(self.actionButton("Collect", primary: true) { [weak self] in
                self?.claim(designId: design["id"] as? String ?? "")
            })
        } else {
            details.addArrangedSubview(self.actionButton("Activation code") { [weak self] in self?.promptForActivationCode() })
            if let remaining = design["remaining"] as? NSNumber {
                details.addArrangedSubview(self.label("\(remaining.intValue) left in run", size: 10, color: UIColor.white.withAlphaComponent(0.52)))
            }
        }
        row.addArrangedSubview(details)
        let designIndex = self.designs.firstIndex { ($0["id"] as? String) == (design["id"] as? String) } ?? 0
        row.alpha = 0
        row.transform = CGAffineTransform(scaleX: 0.97, y: 0.97).translatedBy(x: 0, y: 7)
        self.contentStack.addArrangedSubview(row)
        UIView.animate(
            withDuration: 0.52,
            delay: Double(min(designIndex, 6)) * 0.04,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.25,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                row.alpha = 1
                row.transform = .identity
            }
        )
        let separator = UIView()
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        self.contentStack.addArrangedSubview(separator)
    }

    private func refreshData() {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        self.statusMessage = "Refreshing Fog Wallet…"
        self.render()
        let group = DispatchGroup()
        var hadFailure = false
        group.enter()
        FogWalletConnectionManager.shared.cardRequest(
            path: "/v1/cards/catalog", method: "GET", body: nil,
            accountId: self.accountId, requiresAuth: false
        ) { [weak self] result in
            guard let self else { group.leave(); return }
            if case let .success(payload) = result, let designs = payload["designs"] as? [[String: Any]] {
                self.designs = designs
                self.save(designs, key: self.cacheCatalogKey)
            } else {
                hadFailure = true
            }
            group.leave()
        }
        group.enter()
        FogWalletConnectionManager.shared.cardRequest(
            path: "/v1/cards/collection", method: "GET", body: nil,
            accountId: self.accountId, requiresAuth: true
        ) { [weak self] result in
            guard let self else { group.leave(); return }
            if case let .success(payload) = result, let cards = payload["cards"] as? [[String: Any]] {
                self.cards = cards
                self.save(cards, key: self.cacheCollectionKey)
            } else {
                hadFailure = true
            }
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isRefreshing = false
            self.statusMessage = hadFailure ? "Some data could not refresh. Showing the last saved data where available." : nil
            self.render()
        }
    }

    private func claim(designId: String) {
        guard !designId.isEmpty else { return }
        FogWalletConnectionManager.shared.cardRequest(
            path: "/v1/cards/claim", method: "POST",
            body: ["design_id": designId], accountId: self.accountId
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.activeTab = .collection
                let alert = UIAlertController(title: "Card added", message: "Fog Wallet has refreshed your collection.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in self?.refreshData() })
                self.present(alert, animated: true)
            case let .failure(error):
                self.showMessage(title: "Could not collect card", message: error.localizedDescription)
            }
        }
    }

    private func promptForActivationCode() {
        let alert = UIAlertController(title: "Activate a card", message: "Enter the activation code. The code will not be displayed on the card.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "FOG-XXXX-XXXX-XXXX"
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Activate", style: .default) { [weak self, weak alert] _ in
            let code = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !code.isEmpty else { return }
            self?.activate(code: code)
        })
        self.present(alert, animated: true)
    }

    private func activate(code: String) {
        FogWalletConnectionManager.shared.cardRequest(
            path: "/v1/cards/activate", method: "POST",
            body: ["code": code], accountId: self.accountId
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.activeTab = .collection
                let alert = UIAlertController(title: "Card activated", message: "The card is now in your Fog Wallet collection.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Show collection", style: .default) { [weak self] _ in self?.refreshData() })
                self.present(alert, animated: true)
            case let .failure(error):
                self.showMessage(title: "Activation failed", message: error.localizedDescription)
            }
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }
}
