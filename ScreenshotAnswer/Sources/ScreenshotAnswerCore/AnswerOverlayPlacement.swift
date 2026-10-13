import Foundation

public enum AnswerOverlayPlacement {
    public static func frame(
        in visibleScreenFrame: CGRect,
        popupSize: CGSize,
        margin: CGFloat = 20
    ) -> CGRect {
        CGRect(
            x: visibleScreenFrame.minX + margin,
            y: visibleScreenFrame.minY + margin,
            width: min(popupSize.width, max(0, visibleScreenFrame.width - margin * 2)),
            height: min(popupSize.height, max(0, visibleScreenFrame.height - margin * 2))
        )
    }
}

public enum RecordingOverlayPlacement {
    public static func frame(
        in visibleScreenFrame: CGRect,
        popupSize: CGSize,
        margin: CGFloat = 20
    ) -> CGRect {
        let width = min(popupSize.width, max(0, visibleScreenFrame.width - margin * 2))
        let height = min(popupSize.height, max(0, visibleScreenFrame.height - margin * 2))
        return CGRect(
            x: visibleScreenFrame.maxX - width - margin,
            y: visibleScreenFrame.maxY - height - margin,
            width: width,
            height: height
        )
    }
}
