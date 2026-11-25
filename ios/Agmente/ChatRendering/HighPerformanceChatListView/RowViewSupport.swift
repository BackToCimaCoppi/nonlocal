#if canImport(UIKit)
import CoreText
import UIKit
import ListViewKit

enum ChatTextMetrics {
    /// Measures multi-line plain text via CoreText (`CTFramesetter`) instead of
    /// `UILabel.sizeThatFits` / `NSString.boundingRect`, avoiding TextKit's O(N²)
    /// multi-second layout hang on very large user/system messages (e.g. 50KB+).
    static func measureSize(
        for text: String,
        font: UIFont,
        maxWidth: CGFloat,
        lineLimit: Int = 0
    ) -> CGSize {
        guard !text.isEmpty, maxWidth > 0 else { return .zero }

        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        if lineLimit <= 0 {
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: 0),
                nil,
                CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                nil
            )
            return CGSize(
                width: min(maxWidth, ceil(suggested.width)),
                height: ceil(suggested.height)
            )
        }

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as NSArray
        let limitedCount = min(lineLimit, lines.count)
        guard limitedCount > 0 else { return .zero }

        var maxLineWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for i in 0..<limitedCount {
            let line = lines[i] as! CTLine
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            maxLineWidth = max(maxLineWidth, lineWidth)
            totalHeight += ascent + descent + max(0, leading)
        }
        return CGSize(width: min(maxWidth, ceil(maxLineWidth)), height: ceil(totalHeight))
    }
}

class BaseRowView: ListRowView {
    let rowContainer = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(rowContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rowContainer.frame = CGRect(
            x: HighPerformanceChatListView.rowInsets.left,
            y: 0,
            width: bounds.width - HighPerformanceChatListView.rowInsets.left - HighPerformanceChatListView.rowInsets.right,
            height: bounds.height - HighPerformanceChatListView.rowInsets.bottom
        )
    }
}

final class ActionButton: UIButton {
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        action?()
    }
}

extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
