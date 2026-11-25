#if canImport(UIKit)
import UIKit

final class SystemRowView: BaseRowView {
    var text: String = "" {
        didSet {
            label.text = text
            setNeedsLayout()
        }
    }

    private let isError: Bool
    private let card = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()

    init(isError: Bool) {
        self.isError = isError
        super.init(frame: .zero)

        card.layer.cornerCurve = .continuous
        card.backgroundColor = isError ? UIColor.systemRed.withAlphaComponent(0.10) : UIColor.systemGray5

        iconView.image = UIImage(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
        iconView.tintColor = isError ? .systemRed : .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = isError ? .systemRed : .secondaryLabel

        rowContainer.addSubview(card)
        card.addSubview(iconView)
        card.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func estimatedHeight(for text: String, width: CGFloat) -> CGFloat {
        let maxWidth = max(0, width - 16)
        let iconSize: CGFloat = 14
        let labelMaxWidth = max(1, maxWidth - 12 - iconSize - 6 - 12)
        let textHeight = ChatTextMetrics.measureSize(
            for: text,
            font: .preferredFont(forTextStyle: .footnote),
            maxWidth: labelMaxWidth
        ).height
        return max(26, ceil(textHeight) + 12)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = max(0, rowContainer.bounds.width - 16)
        let iconSize: CGFloat = 14
        let labelMaxWidth = max(1, maxWidth - 12 - iconSize - 6 - 12)
        let labelSize = label.sizeThatFits(CGSize(width: labelMaxWidth, height: .greatestFiniteMagnitude))
        let cardWidth = min(maxWidth, ceil(labelSize.width) + 12 + 6 + iconSize + 12)
        let cardHeight = max(26, ceil(labelSize.height) + 12)
        card.frame = CGRect(
            x: (rowContainer.bounds.width - cardWidth) / 2,
            y: max(0, (rowContainer.bounds.height - cardHeight) / 2),
            width: cardWidth,
            height: cardHeight
        )
        card.layer.cornerRadius = min(cardHeight / 2, 16)

        iconView.frame = CGRect(x: 12, y: (cardHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let labelX = iconView.frame.maxX + 6
        label.frame = CGRect(x: labelX, y: (cardHeight - ceil(labelSize.height)) / 2, width: cardWidth - labelX - 12, height: ceil(labelSize.height))
    }
}

final class StreamingIndicatorRowView: BaseRowView {
    var text: String = String(localized: "Thinking…") {
        didSet {
            label.text = text
            setNeedsLayout()
        }
    }

    private let card = UIView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor.systemGray6

        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail

        spinner.startAnimating()

        rowContainer.addSubview(card)
        card.addSubview(spinner)
        card.addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxLabelWidth = max(0, rowContainer.bounds.width - 44)
        let cardHeight: CGFloat = 32
        let labelSize = label.sizeThatFits(CGSize(width: maxLabelWidth, height: cardHeight))
        let clampedLabelWidth = min(maxLabelWidth, ceil(labelSize.width))
        let cardWidth = min(rowContainer.bounds.width, 10 + 16 + 6 + clampedLabelWidth + 10)
        card.frame = CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        spinner.frame = CGRect(x: 10, y: (card.bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(
            x: spinner.frame.maxX + 6,
            y: (card.bounds.height - ceil(labelSize.height)) / 2,
            width: max(0, card.bounds.width - spinner.frame.maxX - 16),
            height: ceil(labelSize.height)
        )
    }
}
#endif
