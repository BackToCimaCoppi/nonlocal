#if canImport(UIKit)
import UIKit
import ListViewKit

/// Native static-image Mermaid card for `HighPerformanceChatListView` (T10 / SD-6.3 / AC-603).
/// Strictly embeds ZERO `WKWebView` instances; renders cached snapshots from `MermaidRenderer.shared`,
/// responds to dark mode via `UITraitUserInterfaceStyle`, hides zoom affordance when `onOpenFullscreen == nil`
/// (preserving Codex isolation), and falls back to full source + red error banner + copy button on failure.
final class MermaidRowView: BaseRowView {
    static let placeholderHeight: CGFloat = 160
    static let minDiagramHeight: CGFloat = 120
    static let maxDiagramHeight: CGFloat = 320
    static let maxFailureHeight: CGFloat = 420

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let placeholderStack = UIStackView()
    private let placeholderSpinner = UIActivityIndicatorView(style: .medium)
    private let placeholderLabel = UILabel()
    private let zoomBadge = UILabel()

    private let errorBanner = UIView()
    private let errorLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let sourceTextView = UITextView()

    private var currentSource: String = ""
    private var currentRenderToken: String?
    private var onOpenFullscreen: ((String) -> Void)?
    private var renderTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)

        cardView.layer.cornerRadius = 12
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.5
        cardView.layer.borderColor = UIColor.separator.cgColor
        cardView.backgroundColor = .secondarySystemBackground
        cardView.clipsToBounds = true
        rowContainer.addSubview(cardView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        cardView.addSubview(imageView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCardTap))
        cardView.addGestureRecognizer(tap)

        placeholderLabel.text = String(localized: "Rendering Mermaid diagram…")
        placeholderLabel.font = .preferredFont(forTextStyle: .footnote)
        placeholderLabel.textColor = .secondaryLabel
        placeholderStack.axis = .horizontal
        placeholderStack.spacing = 8
        placeholderStack.alignment = .center
        placeholderStack.addArrangedSubview(placeholderSpinner)
        placeholderStack.addArrangedSubview(placeholderLabel)
        cardView.addSubview(placeholderStack)

        zoomBadge.text = String(localized: "Tap for fullscreen")
        zoomBadge.font = .systemFont(ofSize: 11, weight: .medium)
        zoomBadge.textColor = .secondaryLabel
        zoomBadge.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        zoomBadge.layer.cornerRadius = 8
        zoomBadge.layer.masksToBounds = true
        zoomBadge.textAlignment = .center
        cardView.addSubview(zoomBadge)

        errorBanner.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        errorBanner.isHidden = true
        cardView.addSubview(errorBanner)

        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorBanner.addSubview(errorLabel)

        copyButton.setTitle(String(localized: "Copy source"), for: .normal)
        copyButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        copyButton.addTarget(self, action: #selector(handleCopySource), for: .touchUpInside)
        errorBanner.addSubview(copyButton)

        sourceTextView.isEditable = false
        sourceTextView.isSelectable = true
        sourceTextView.isScrollEnabled = true
        sourceTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sourceTextView.textColor = .label
        sourceTextView.backgroundColor = .clear
        sourceTextView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        sourceTextView.isHidden = true
        cardView.addSubview(sourceTextView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: MermaidRowView, _) in
            self.refreshForCurrentAppearance()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isZoomHintVisible: Bool {
        !zoomBadge.isHidden
    }

    var currentFullscreenHandlerForTesting: ((String) -> Void)? {
        onOpenFullscreen
    }

    var hasActiveRenderTaskForTesting: Bool {
        renderTask != nil
    }

    func configure(
        source: String,
        renderToken: String,
        onOpenFullscreen: ((String) -> Void)?
    ) {
        self.onOpenFullscreen = onOpenFullscreen
        self.currentSource = source
        zoomBadge.isHidden = (onOpenFullscreen == nil)
        accessibilityIdentifier = "acp-mermaid-row"

        let isDark = (traitCollection.userInterfaceStyle == .dark)
        if let outcome = MermaidRenderer.shared.cachedOutcome(source: source, isDark: isDark) {
            renderTask?.cancel()
            renderTask = nil
            currentRenderToken = renderToken
            applyOutcome(outcome, source: source)
            return
        }

        showPlaceholder()
        guard currentRenderToken != renderToken || renderTask == nil else { return }
        currentRenderToken = renderToken
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            let result = await MermaidRenderer.shared.render(source: source, isDark: isDark)
            guard let self, !Task.isCancelled, self.currentSource == source else { return }
            self.renderTask = nil
            switch result {
            case .success(let diagram):
                self.applyOutcome(.ready(diagram), source: source)
            case .failure(let err):
                self.applyOutcome(.failure(err), source: source)
            }
        }
    }

    private func refreshForCurrentAppearance() {
        guard !currentSource.isEmpty else { return }
        let src = currentSource
        let isDark = (traitCollection.userInterfaceStyle == .dark)
        if let outcome = MermaidRenderer.shared.cachedOutcome(source: src, isDark: isDark) {
            applyOutcome(outcome, source: src)
            return
        }
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            let result = await MermaidRenderer.shared.render(source: src, isDark: isDark)
            guard let self, !Task.isCancelled, self.currentSource == src else { return }
            self.renderTask = nil
            switch result {
            case .success(let diagram):
                self.applyOutcome(.ready(diagram), source: src)
            case .failure(let err):
                self.applyOutcome(.failure(err), source: src)
            }
        }
    }

    private func showPlaceholder() {
        imageView.isHidden = true
        imageView.image = nil
        errorBanner.isHidden = true
        sourceTextView.isHidden = true
        placeholderStack.isHidden = false
        placeholderSpinner.startAnimating()
        zoomBadge.isHidden = true
        setNeedsLayout()
    }

    private func applyOutcome(_ outcome: MermaidRenderer.CachedOutcome, source: String) {
        placeholderSpinner.stopAnimating()
        placeholderStack.isHidden = true
        switch outcome {
        case .ready(let diagram):
            errorBanner.isHidden = true
            sourceTextView.isHidden = true
            imageView.isHidden = false
            imageView.image = diagram.image
            zoomBadge.isHidden = (onOpenFullscreen == nil)
        case .failure(let err):
            imageView.isHidden = true
            imageView.image = nil
            zoomBadge.isHidden = true
            errorBanner.isHidden = false
            copyButton.setTitle(String(localized: "Copy source"), for: .normal)
            errorLabel.text = String(localized: "Mermaid render failed: \(err.localizedDescription)")
            sourceTextView.isHidden = false
            sourceTextView.text = source
        }
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderTask?.cancel()
        renderTask = nil
        onOpenFullscreen = nil
        currentSource = ""
        currentRenderToken = nil
        imageView.image = nil
        sourceTextView.text = ""
        copyButton.setTitle(String(localized: "Copy source"), for: .normal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cardView.frame = rowContainer.bounds
        let bounds = cardView.bounds

        if !placeholderStack.isHidden {
            let size = placeholderStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            placeholderStack.frame = CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        if !imageView.isHidden {
            imageView.frame = bounds.insetBy(dx: 8, dy: 8)
            if !zoomBadge.isHidden {
                let maxBadgeWidth = max(44, bounds.width - 16)
                let badgeSize = zoomBadge.sizeThatFits(CGSize(width: maxBadgeWidth, height: 24))
                let badgeWidth = min(maxBadgeWidth, max(44, ceil(badgeSize.width) + 14))
                let badgeHeight = max(22, ceil(badgeSize.height) + 6)
                zoomBadge.frame = CGRect(
                    x: bounds.width - badgeWidth - 8,
                    y: 8,
                    width: badgeWidth,
                    height: badgeHeight
                )
            }
        }

        if !errorBanner.isHidden {
            let maxCopyWidth = max(56, bounds.width * 0.45)
            let copySize = copyButton.sizeThatFits(CGSize(width: maxCopyWidth, height: 28))
            let copyWidth = min(maxCopyWidth, max(56, ceil(copySize.width) + 12))
            let errorLabelWidth = max(40, bounds.width - copyWidth - 26)
            let errorLabelSize = errorLabel.sizeThatFits(CGSize(width: errorLabelWidth, height: .greatestFiniteMagnitude))
            let errorLabelHeight = max(24, ceil(errorLabelSize.height))
            let bannerHeight = max(36, errorLabelHeight + 12)
            errorBanner.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
            copyButton.frame = CGRect(
                x: bounds.width - copyWidth - 8,
                y: floor((bannerHeight - 28) / 2),
                width: copyWidth,
                height: 28
            )
            errorLabel.frame = CGRect(
                x: 10,
                y: floor((bannerHeight - errorLabelHeight) / 2),
                width: errorLabelWidth,
                height: errorLabelHeight
            )
            sourceTextView.frame = CGRect(
                x: 0,
                y: bannerHeight,
                width: bounds.width,
                height: max(40, bounds.height - bannerHeight)
            )
        }
    }

    @objc private func handleCardTap() {
        guard !currentSource.isEmpty, errorBanner.isHidden else { return }
        onOpenFullscreen?(currentSource)
    }

    @objc private func handleCopySource() {
        UIPasteboard.general.string = currentSource
        copyButton.setTitle(String(localized: "Copied"), for: .normal)
        setNeedsLayout()
    }

    static func measureHeight(
        source: String,
        outcome: MermaidRenderer.CachedOutcome?,
        contentWidth: CGFloat
    ) -> CGFloat {
        guard let outcome else {
            return placeholderHeight
        }
        switch outcome {
        case .ready(let diagram):
            let innerWidth = max(120, contentWidth - 16)
            let rawHeight = innerWidth / max(0.3, diagram.aspectRatio) + 16
            return min(maxDiagramHeight, max(minDiagramHeight, ceil(rawHeight)))
        case .failure:
            let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let textWidth = max(100, contentWidth - 24)
            let measured = ChatTextMetrics.measureSize(for: source, font: font, maxWidth: textWidth)
            let total = ceil(measured.height) + 36 + 24
            return min(maxFailureHeight, max(120, total))
        }
    }
}
#endif
