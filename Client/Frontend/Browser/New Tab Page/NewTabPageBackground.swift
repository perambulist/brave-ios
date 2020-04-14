// Copyright 2020 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveShared
import SnapKit
import BraveUI

class NewTabBackground: NSObject, PreferencesObserver {
    private let dataSource: NTPBackgroundDataSource
    
    private(set) var currentBackground: NTPBackground? {
        didSet {
            changed?()
        }
    }
    
    var backgroundImage: UIImage? {
        currentBackground?.wallpaper.image
    }
    
    var sponsorImage: UIImage? {
        currentBackground?.sponsor?.logo.image
    }
    
    var changed: (() -> Void)?
    
    init(dataSource: NTPBackgroundDataSource) {
        self.dataSource = dataSource
        self.currentBackground = dataSource.newBackground()
        
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(privateModeChanged), name: .privacyModeChanged, object: nil)
        
        Preferences.NewTabPage.backgroundImages.observe(from: self)
        Preferences.NewTabPage.backgroundSponsoredImages.observe(from: self)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func privateModeChanged() {
        self.currentBackground = dataSource.newBackground()
    }
    
    private var timer: Timer?
    
    func preferencesDidChange(for key: String) {
        // Debounce multiple changes to preferences
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            self.currentBackground = self.dataSource.newBackground()
        })
    }
}

class NewTabBackgroundView: UIView, Themeable {
    let imageView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
    }
    var imageConstraints: (portraitCenter: Constraint, landscapeCenter: Constraint)?
    let gradient = GradientView(
        colors: [
            UIColor(white: 0.0, alpha: 0.5),
            UIColor(white: 0.0, alpha: 0.0),
            UIColor(white: 0.0, alpha: 0.3)
        ],
        positions: [0, 0.5, 0.8],
        startPoint: .zero,
        endPoint: CGPoint(x: 0, y: 1)
    )
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        clipsToBounds = true
        
        addSubview(imageView)
        addSubview(gradient)
        
        imageView.snp.makeConstraints {
            $0.edges.equalToSuperview()
        }
        gradient.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.height.greaterThanOrEqualTo(700)
            $0.bottom.equalToSuperview().priority(.low)
        }
    }
    
    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }
    
    func applyTheme(_ theme: Theme) {
        if theme.isDark {
            backgroundColor = theme.colors.home
        } else {
            backgroundColor = UIColor(red: 59.0/255.0, green: 62.0/255.0, blue: 79.0/255.0, alpha: 1.0)
        }
    }
}
