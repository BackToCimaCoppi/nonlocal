#if canImport(UIKit)
import Litext
import UIKit

private func makeRetryFailedMessageButton(target: Any, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    button.setImage(UIImage(systemName: "arrow.counterclockwise", withConfiguration: symbolConfig), for: .normal)
    button.tintColor = .white
    button.backgroundColor = .systemOrange
    button.layer.cornerRadius = UserTextRowView.retryButtonSize / 2
    button.layer.cornerCurve = .continuous
    button.clipsToBounds = true
    button.isHidden = true
    button.accessibilityLabel = String(localized: "action.retry_send", defaultValue: "Retry sending")
    button.addTarget(target, action: action, for: .touchUpInside)
    return button
}

final class UserTextRowView: BaseRowView {
    static let retryButtonSize: CGFloat = 28
    static let retryButtonSpacing: CGFloat = 8

    static func maxBubbleWidth(for rowWidth: CGFloat, showsRetryButton: Bool) -> CGFloat {
        let reservedLeading: CGFloat = showsRetryButton
            ? max(50, retryButtonSize + retryButtonSpacing + 14)
            : 50
        return max(0, rowWidth - reservedLeading)
    }

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            cachedMeasuredWidth = -1
            cachedMeasuredSize = .zero
            applyAttributedText()
            setNeedsLayout()
        }
    }

    private let bubble = UIView()
    // Render with CoreText-backed LTXLabel instead of UILabel to avoid TextKit's
    // multi-second layout/draw hang on large (e.g. 50KB+) user prompts.
    private let textView = LTXLabel()
    private lazy var retryButton = makeRetryFailedMessageButton(target: self, action: #selector(handleRetryTap))
    private var messageId: UUID?
    private var showsRetryButton: Bool = false
    private var onRetry: ((UUID) -> Void)?
    private var cachedMeasuredWidth: CGFloat = -1
    private var cachedMeasuredSize: CGSize = .zero
    private var lastUserInterfaceStyle: UIUserInterfaceStyle = .unspecified

    private static var textFont: UIFont {
        .preferredFont(forTextStyle: .callout)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        bubble.layer.cornerRadius = 12
        bubble.layer.cornerCurve = .continuous
        rowContainer.addSubview(bubble)
        rowContainer.addSubview(retryButton)

        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        bubble.addSubview(textView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (self: UserTextRowView, _) in
            self.cachedMeasuredWidth = -1
            self.cachedMeasuredSize = .zero
            self.applyAttributedText()
            self.setNeedsLayout()
        }
    }

    func configure(
        text: String,
        messageId: UUID,
        showsRetryButton: Bool,
        onRetry: ((UUID) -> Void)?
    ) {
        self.text = text
        self.messageId = messageId
        self.onRetry = onRetry
        let retryChanged = self.showsRetryButton != showsRetryButton
        self.showsRetryButton = showsRetryButton
        retryButton.isHidden = !showsRetryButton
        retryButton.accessibilityIdentifier = showsRetryButton
            ? "retry-failed-message-\(messageId.uuidString)"
            : nil
        if retryChanged {
            cachedMeasuredWidth = -1
            cachedMeasuredSize = .zero
            setNeedsLayout()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageId = nil
        showsRetryButton = false
        onRetry = nil
        retryButton.isHidden = true
        retryButton.accessibilityIdentifier = nil
    }

    @objc private func handleRetryTap() {
        guard let messageId else { return }
        onRetry?(messageId)
    }

    private func applyAttributedText() {
        guard !text.isEmpty else {
            textView.attributedText = NSAttributedString()
            return
        }
        let resolvedColor = UIColor.label.resolvedColor(with: traitCollection)
        lastUserInterfaceStyle = traitCollection.userInterfaceStyle
        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: Self.textFont,
                .foregroundColor: resolvedColor,
            ]
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if traitCollection.userInterfaceStyle != lastUserInterfaceStyle && !text.isEmpty {
            applyAttributedText()
        }
        let maxWidth = Self.maxBubbleWidth(for: rowContainer.bounds.width, showsRetryButton: showsRetryButton)
        let textMaxWidth = max(0, maxWidth - 20)
        let textSize: CGSize
        if abs(cachedMeasuredWidth - textMaxWidth) <= 0.5 {
            textSize = cachedMeasuredSize
        } else {
            textSize = ChatTextMetrics.measureSize(for: text, font: Self.textFont, maxWidth: textMaxWidth)
            cachedMeasuredWidth = textMaxWidth
            cachedMeasuredSize = textSize
        }
        let bubbleWidth = min(maxWidth, ceil(textSize.width) + 20)
        let bubbleHeight = ceil(textSize.height) + 14
        let rowHeight = showsRetryButton ? max(bubbleHeight, Self.retryButtonSize) : bubbleHeight
        let bubbleY = floor((rowHeight - bubbleHeight) / 2)
        bubble.frame = CGRect(
            x: rowContainer.bounds.width - bubbleWidth,
            y: bubbleY,
            width: bubbleWidth,
            height: bubbleHeight
        )
        let contentFrame = bubble.bounds.insetBy(dx: 10, dy: 7)
        textView.preferredMaxLayoutWidth = contentFrame.width
        textView.frame = contentFrame

        if showsRetryButton {
            retryButton.frame = CGRect(
                x: max(0, bubble.frame.minX - Self.retryButtonSpacing - Self.retryButtonSize),
                y: floor((rowHeight - Self.retryButtonSize) / 2),
                width: Self.retryButtonSize,
                height: Self.retryButtonSize
            )
        } else {
            retryButton.frame = .zero
        }
    }
}

final class UserImagesRowView: BaseRowView {
    static let retryButtonSize: CGFloat = 28
    static let retryButtonSpacing: CGFloat = 8

    var images: [ChatImageData] = [] {
        didSet {
            rebuildImageViews()
        }
    }

    private var imageViews: [UIImageView] = []
    private lazy var retryButton = makeRetryFailedMessageButton(target: self, action: #selector(handleRetryTap))
    private var messageId: UUID?
    private var showsRetryButton: Bool = false
    private var onRetry: ((UUID) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowContainer.addSubview(retryButton)
    }

    func configure(
        images: [ChatImageData],
        messageId: UUID,
        showsRetryButton: Bool,
        onRetry: ((UUID) -> Void)?
    ) {
        self.images = images
        self.messageId = messageId
        self.onRetry = onRetry
        self.showsRetryButton = showsRetryButton
        retryButton.isHidden = !showsRetryButton
        retryButton.accessibilityIdentifier = showsRetryButton
            ? "retry-failed-message-\(messageId.uuidString)"
            : nil
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageId = nil
        showsRetryButton = false
        onRetry = nil
        retryButton.isHidden = true
        retryButton.accessibilityIdentifier = nil
    }

    @objc private func handleRetryTap() {
        guard let messageId else { return }
        onRetry?(messageId)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = imageViews.count
        guard count > 0 else {
            retryButton.frame = .zero
            return
        }

        let spacing: CGFloat = 6
        let baseSize: CGFloat = 80
        let reservedLeading: CGFloat = showsRetryButton ? (Self.retryButtonSize + Self.retryButtonSpacing) : 0
        let maxGroupWidth = max(0, rowContainer.bounds.width - reservedLeading)
        let totalSpacing = CGFloat(max(0, count - 1)) * spacing
        let naturalGroupWidth = CGFloat(count) * baseSize + totalSpacing
        let itemSize: CGFloat
        if naturalGroupWidth <= maxGroupWidth || maxGroupWidth <= 0 {
            itemSize = baseSize
        } else {
            itemSize = max(24, floor((maxGroupWidth - totalSpacing) / CGFloat(count)))
        }
        let itemY = floor((baseSize - itemSize) / 2)

        var x = rowContainer.bounds.width
        var leftmostMinX = rowContainer.bounds.width
        for imageView in imageViews.reversed() {
            x -= itemSize
            imageView.frame = CGRect(x: x, y: itemY, width: itemSize, height: itemSize)
            leftmostMinX = x
            x -= spacing
        }

        if showsRetryButton {
            retryButton.frame = CGRect(
                x: max(0, leftmostMinX - Self.retryButtonSpacing - Self.retryButtonSize),
                y: floor((baseSize - Self.retryButtonSize) / 2),
                width: Self.retryButtonSize,
                height: Self.retryButtonSize
            )
        } else {
            retryButton.frame = .zero
        }
    }

    private func rebuildImageViews() {
        for view in imageViews {
            view.removeFromSuperview()
        }
        imageViews.removeAll(keepingCapacity: true)

        for image in images {
            let imageView = UIImageView(image: image.thumbnail)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.layer.cornerCurve = .continuous
            imageView.layer.borderWidth = 1
            imageView.layer.borderColor = UIColor.tintColor.withAlphaComponent(0.3).cgColor
            rowContainer.addSubview(imageView)
            imageViews.append(imageView)
        }

        setNeedsLayout()
    }
}
#endif
