import UIKit

/// 锚点定位的短暂提示层，不改变消息高度、选中文字或点击区域。
@MainActor
enum NanoMuseAnchorPulse {
    private static let overlayTag = 0x4E4D4150

    /// 单元格复用或重新配置时立即移除提示，避免高亮跑到其他消息。
    static func clear(_ cell: UICollectionViewCell) {
        cell.contentView.viewWithTag(overlayTag)?.removeFromSuperview()
    }

    /// 对已完成定位的可见消息显示柔和高亮，减少动态效果时保持静态后消失。
    static func show(_ cell: UICollectionViewCell) {
        clear(cell)
        let overlay = UIView(frame: cell.contentView.bounds.insetBy(dx: 4, dy: 0))
        overlay.tag = overlayTag
        overlay.isUserInteractionEnabled = false
        overlay.isAccessibilityElement = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.12)
        overlay.layer.cornerRadius = 12
        overlay.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.25).cgColor
        overlay.layer.borderWidth = 1
        cell.contentView.addSubview(overlay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak overlay] in
            guard let overlay else { return }
            if UIAccessibility.isReduceMotionEnabled { overlay.removeFromSuperview() }
            else {
                UIView.animate(withDuration: 0.25, animations: { overlay.alpha = 0 }) { _ in
                    overlay.removeFromSuperview()
                }
            }
        }
    }
}
