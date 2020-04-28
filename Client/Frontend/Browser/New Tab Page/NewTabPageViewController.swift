// Copyright 2020 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import UIKit
import BraveUI
import CoreData
import Data
import Shared
import BraveShared
import SnapKit

enum NTPLandscapeBehavior {
    case halfWidth
    case fullWidth
}

/// A section that will be shown in the NTP. Sections are responsible for the
/// layout and interaction of their own items
protocol NTPSectionProvider: NSObject, UICollectionViewDelegateFlowLayout & UICollectionViewDataSource {
    func registerCells(to collectionView: UICollectionView)
    var landscapeBehavior: NTPLandscapeBehavior { get }
}
extension NTPSectionProvider {
    var landscapeBehavior: NTPLandscapeBehavior {
        .halfWidth
    }
    
    /// The bounding size for auto-sizing cells, bound to the maximum available
    /// width in the collection view, taking into account safe area insets and
    /// insets for that given section
    func fittingSizeForCollectionView(_ collectionView: UICollectionView, section: Int) -> CGSize {
        let sectionInset: UIEdgeInsets
        if let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            if let flowLayoutDelegate = collectionView.delegate as? UICollectionViewDelegateFlowLayout {
                sectionInset = flowLayoutDelegate.collectionView?(collectionView, layout: collectionView.collectionViewLayout, insetForSectionAt: section) ?? flowLayout.sectionInset
            } else {
                sectionInset = flowLayout.sectionInset
            }
        } else {
            sectionInset = .zero
        }
        return CGSize(
            width: collectionView.bounds.width -
                collectionView.safeAreaInsets.left -
                collectionView.safeAreaInsets.right -
                sectionInset.left -
                sectionInset.right,
            height: 1000
        )
    }
}

protocol NTPObservableSectionProvider: NTPSectionProvider {
    var sectionDidChange: (() -> Void)? { get set }
}

private class NewTabCollectionView: UICollectionView {
    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        
        backgroundColor = .clear
        delaysContentTouches = false
        contentInsetAdjustmentBehavior = .always
    }
    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }
    override func touchesShouldCancel(in view: UIView) -> Bool {
        return true
    }
}

protocol NewTabPageDelegate: AnyObject {
    func focusURLBar()
    func navigateToInput(_ input: String, inNewTab: Bool, switchingToPrivateMode: Bool)
    func tappedDuckDuckGoCallout()
    func sponseredImageCalloutActioned(_ state: BrandedImageCalloutState)
}

/// The new tab page. Shows users a variety of information, including stats and
/// favourites
class NewTabPageViewController: UIViewController, Themeable {
    weak var delegate: NewTabPageDelegate?
    
    /// The modules to show on the new tab page
    private var sections: [NTPSectionProvider] = []
    
    private let layout = NewTabPageFlowLayout()
    private let collectionView: NewTabCollectionView
    private let tab: Tab
    
    private var background: NewTabBackground
    private let backgroundView = NewTabBackgroundView()
    private lazy var imageCreditSection = BackgroundImageCreditSectionProvider(background: background.currentBackground, action: { [weak self] control in
        self?.presentImageCredit(control)
    })
    
    let sponsorButton = SpringButton()
    let sponsorImageView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
    }
    
    init(tab: Tab, profile: Profile, backgroundDataSource: NTPBackgroundDataSource) {
        self.tab = tab
        background = NewTabBackground(dataSource: backgroundDataSource)
        collectionView = NewTabCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        
        sections = [
            StatsSectionProvider(),
            FavoritesSectionProvider(action: { [weak self] bookmark, action in
                self?.handleBookmarkAction(bookmark: bookmark, action: action)
            }),
            FavoritesOverflowSectionProvider(action: { [weak self] in
                self?.delegate?.focusURLBar()
            }),
            DuckDuckGoCalloutSectionProvider(profile: profile, action: { [weak self] in
                self?.delegate?.tappedDuckDuckGoCallout()
            }),
            SpacerSectionProvider(),
            imageCreditSection
        ]
        layout.imageCreditSection = sections.firstIndex(where: { $0 is BackgroundImageCreditSectionProvider })
        sections.enumerated().forEach { (index, provider) in
            provider.registerCells(to: collectionView)
            if let observableProvider = provider as? NTPObservableSectionProvider {
                observableProvider.sectionDidChange = {
                    DispatchQueue.main.async {
                        UIView.performWithoutAnimation {
                            self.collectionView.reloadSections(IndexSet(integer: index))
                        }
                    }
                }
            }
        }
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.dataSource = self
        applyTheme(Theme.of(tab))
        
        background.changed = { [weak self] in
            self?.setupBackgroundImage()
        }
    }
    
    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sponsorButton.addTarget(self, action: #selector(tappedSponsorButton), for: .touchUpInside)
        
        view.addSubview(backgroundView)
        view.addSubview(collectionView)
        
        setupBackgroundImage()
        backgroundView.snp.makeConstraints {
            $0.edges.equalToSuperview()
        }
        collectionView.snp.makeConstraints {
            $0.edges.equalToSuperview()
        }
        
        collectionView.insertSubview(sponsorButton, at: 0)
        
        sponsorButton.addSubview(sponsorImageView)
        
        sponsorImageView.snp.makeConstraints {
            $0.edges.equalToSuperview()
        }
        
        updateSponsorImageConstraints()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        collectionView.reloadData()
        
        if let image = backgroundView.imageView.image {
            // Need to calculate the sizing difference between `image` and `imageView` to determine the pixel difference ratio
            let sizeRatio = backgroundView.imageView.frame.size.width / image.size.width
            let focal = background.currentBackground?.wallpaper.focalPoint
            // Center as fallback
            let x = focal?.x ?? image.size.width / 2
            let y = focal?.y ?? image.size.height / 2
            let portrait = view.frame.height > view.frame.width
            
            // Center point of image is not center point of view.
            // Take `0` for example, if specying `0`, setting centerX to 0, it is not attempting to place the left
            //  side of the image to the middle (e.g. left justifying), it is instead trying to move the image view's
            //  center to `0`, shifting the image _to_ the left, and making more of the image's right side visible.
            // Therefore specifying `0` should take the imageView's left and pinning it to view's center.
            
            // So basically the movement needs to be "inverted" (hence negation)
            // In landscape, left / right are pegged to superview
            let imageViewOffset = portrait ? sizeRatio * -x : 0
            backgroundView.imageConstraints?.portraitCenter.update(offset: imageViewOffset)
            
            // If potrait, top / bottom are just pegged to superview
            let inset = portrait ? 0 : sizeRatio * -y
            backgroundView.imageConstraints?.landscapeCenter.update(offset: inset)
        }
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        updateSponsorImageConstraints()
        if #available(iOS 13.0, *) {
            if UITraitCollection.current.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
                // Reload UI
                applyTheme(Theme.of(tab))
            }
        }
    }
    
    func updateSponsorImageConstraints() {
        let isIphone = UIDevice.isPhone
        let isLandscape = view.frame.width > view.frame.height
        
        sponsorButton.snp.remakeConstraints {
            $0.size.equalTo(170)
            $0.bottom.equalTo(view.safeArea.bottom).inset(10)
            
            if isLandscape && isIphone {
                $0.left.equalTo(view.safeArea.left).offset(20)
            } else {
                $0.centerX.equalToSuperview()
            }
        }
    }
    
    var themeableChildren: [Themeable?]? {
        [backgroundView]
    }
    
    func applyTheme(_ theme: Theme) {
        styleChildren(theme: theme)
        collectionView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        collectionView.reloadData()
    }
    
    // MARK: - Background
    
    func setupBackgroundImage() {
        collectionView.reloadData()
        
        imageCreditSection.background = background.currentBackground
        backgroundView.gradient.isHidden = background.backgroundImage == nil
        backgroundView.imageView.image = background.backgroundImage
        sponsorImageView.image = background.sponsorImage
        sponsorButton.isEnabled = background.currentBackground?.sponsor != nil
        
        guard let image = backgroundView.imageView.image else {
            return
        }
        
        let imageAspectRatio = image.size.width / image.size.height
        let imageView = backgroundView.imageView
        
        // Make sure it goes to the back
        imageView.snp.remakeConstraints {
            // Determines the height of the content
            // `999` priority is required for landscape, since top/bottom constraints no longer the most important
            //    using `1000` / `required` would cause constraint conflicts (with `centerY` in landscape), and
            //    using `high` is not enough either.
            $0.bottom.equalToSuperview().priority(ConstraintPriority(999))
            $0.top.equalToSuperview().priority(ConstraintPriority(999))
            
            // In portrait `top`/`bottom` is enough, however, when switching to landscape, those constraints
            //  don't force centering, so this is used as a stronger constraint to center in landscape/portrait
            let landscapeCenterConstraint = $0.top.equalTo(view.snp.centerY).priority(ConstraintPriority.high).constraint
            
            // Width of the image view is determined by the forced height constraint and the literal image ratio
            $0.width.equalTo(imageView.snp.height).multipliedBy(imageAspectRatio)
            
            // These are required constraints to avoid a bad center pushing the image out of view.
            // if a center of `-100` or `100000` is specified, these override to keep entire background covered by image.
            // The left side cannot exceed `0` (or superview's left side), otherwise whitespace will be shown on left.
            $0.left.lessThanOrEqualToSuperview()
            
            // the right side cannot drop under `width` (or superview's right side), otherwise whitespace will be shown on right.
            $0.right.greaterThanOrEqualToSuperview()
            
            // Same as left / right above but necessary for landscape y centering (to prevent overflow)
            $0.top.lessThanOrEqualToSuperview()
            $0.bottom.greaterThanOrEqualToSuperview()
            
            // If for some reason the image cannot fill full width (e.g. not a landscape image), then these constraints
            //  will fail. A constraint will be broken, since cannot keep both left and right side's pinned
            //  (due to the width multiplier being < 1
            
            // Using `high` priority so that it will not be applied / broken  if out-of-bounds.
            // Offset updated / calculated during view layout as views are not setup yet.
            let portraitCenterConstraint = $0.left.equalTo(view.snp.centerX).priority(ConstraintPriority.high).constraint
            self.backgroundView.imageConstraints = (portraitCenterConstraint, landscapeCenterConstraint)
        }
    }
    
    // MARK: - Actions
    
    func updateDuckDuckGoVisibility() {
        collectionView.reloadData()
    }
    
    @objc private func tappedSponsorButton() {
        guard let url = background.currentBackground?.sponsor?.logo.destinationUrl else { return }
        UIImpactFeedbackGenerator(style: .medium).bzzt()
        delegate?.navigateToInput(url, inNewTab: false, switchingToPrivateMode: false)
    }
    
    private func handleBookmarkAction(bookmark: Bookmark, action: BookmarksAction) {
        guard let url = bookmark.url else { return }
        switch action {
        case .opened(let inNewTab, let switchingToPrivateMode):
            delegate?.navigateToInput(
                url,
                inNewTab: inNewTab,
                switchingToPrivateMode: switchingToPrivateMode
            )
        case .edited:
            guard let title = bookmark.displayTitle, let urlString = bookmark.url else { return }
            let editPopup = UIAlertController.userTextInputAlert(title: Strings.editBookmark, message: urlString,
                                                                 startingText: title, startingText2: bookmark.url,
                                                                 placeholder2: urlString,
                                                                 keyboardType2: .URL) { callbackTitle, callbackUrl in
                                                                    if let cTitle = callbackTitle, !cTitle.isEmpty, let cUrl = callbackUrl, !cUrl.isEmpty {
                                                                        if URL(string: cUrl) != nil {
                                                                            bookmark.update(customTitle: cTitle, url: cUrl)
                                                                        }
                                                                    }
            }
            self.present(editPopup, animated: true)
        }
    }
    
    @objc private func presentImageCredit(_ button: UIControl) {
        guard let credit = background.currentBackground?.wallpaper.credit else { return }
        
        let alert = UIAlertController(title: credit.name, message: nil, preferredStyle: .actionSheet)
        
        if let creditWebsite = credit.url, let creditURL = URL(string: creditWebsite) {
            let websiteTitle = String(format: Strings.viewOn, creditURL.hostSLD.capitalizeFirstLetter)
            alert.addAction(UIAlertAction(title: websiteTitle, style: .default) { [weak self] _ in
                self?.delegate?.navigateToInput(creditWebsite, inNewTab: false, switchingToPrivateMode: false)
            })
        }
        
        alert.popoverPresentationController?.sourceView = button
        alert.popoverPresentationController?.permittedArrowDirections = [.down, .up]
        alert.addAction(UIAlertAction(title: Strings.close, style: .cancel, handler: nil))
        
        UIImpactFeedbackGenerator(style: .medium).bzzt()
        present(alert, animated: true, completion: nil)
    }
}

// MARK: - UICollectionViewDelegateFlowLayout
extension NewTabPageViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        sections[indexPath.section].collectionView?(collectionView, didSelectItemAt: indexPath)
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        sections[indexPath.section].collectionView?(collectionView, layout: collectionViewLayout, sizeForItemAt: indexPath) ?? .zero
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let sectionProvider = sections[section]
        var inset = sectionProvider.collectionView?(collectionView, layout: collectionViewLayout, insetForSectionAt: section) ?? .zero
        if sectionProvider.landscapeBehavior == .halfWidth {
            let isIphone = UIDevice.isPhone
            let isLandscape = view.frame.width > view.frame.height
            if isLandscape {
                let availableWidth = collectionView.bounds.width - collectionView.safeAreaInsets.left - collectionView.safeAreaInsets.right
                if isIphone {
                    inset.left = availableWidth / 2.0
                } else {
                    inset.right = availableWidth / 2.0
                }
            }
        }
        return inset
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        sections[section].collectionView?(collectionView, layout: collectionViewLayout, minimumLineSpacingForSectionAt: section) ?? 0
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        sections[section].collectionView?(collectionView, layout: collectionViewLayout, minimumInteritemSpacingForSectionAt: section) ?? 0
    }
}

// MARK: - UICollectionViewDataSource
extension NewTabPageViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].collectionView(collectionView, numberOfItemsInSection: section)
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = sections[indexPath.section].collectionView(collectionView, cellForItemAt: indexPath)
        if let themableCell = cell as? Themeable {
            themableCell.applyTheme(Theme.of(tab))
        }
        return cell
    }
    @available(iOS 13.0, *)
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        sections[indexPath.section].collectionView?(collectionView, contextMenuConfigurationForItemAt: indexPath, point: point)
    }
    @available(iOS 13.0, *)
    func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath else {
            return nil
        }
        return sections[indexPath.section].collectionView?(collectionView, previewForHighlightingContextMenuWithConfiguration: configuration)
    }
    @available(iOS 13.0, *)
    func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath else {
            return nil
        }
        return sections[indexPath.section].collectionView?(collectionView, previewForHighlightingContextMenuWithConfiguration: configuration)
    }
    @available(iOS 13.0, *)
    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let indexPath = configuration.identifier as? IndexPath else {
            return
        }
        sections[indexPath.section].collectionView?(collectionView, willPerformPreviewActionForMenuWith: configuration, animator: animator)
    }
}
