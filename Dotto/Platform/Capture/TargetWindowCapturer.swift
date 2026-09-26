import AppKit
import CoreImage
import ScreenCaptureKit

enum TargetWindowCaptureError: Error, LocalizedError {
    case windowNotFound
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .windowNotFound: return "The window Dotto is working in is no longer available to capture."
        case .imageEncodingFailed: return "The window image could not be encoded."
        }
    }
}

/// The task window's image as captured, with the frames of the app's own windows drawn over it.
struct CapturedWindowImage {
    var image: CGImage
    var taskWindowFrame: CGRect
    /// Sheets, popovers and menus of the target composited over the task window; they cover what is under them.
    var childWindowFrames: [CGRect]
}

/// Captures only the task window, also when other windows cover it, and streams it for the live view.
@MainActor final class TargetWindowCapturer: NSObject, TargetWindowFrameStreaming {
    nonisolated private static let maximumLongEdgePixels = 1280
    /// Claude downsamples images above ~1.15 megapixels server-side; staying under it keeps the pixel coordinates
    /// the model answers with identical to the image we mapped them from.
    nonisolated private static let maximumTotalPixelCount = 1_150_000
    nonisolated private static let jpegCompressionFactor = 0.8
    /// Captured larger than the grid so each cell averages many real pixels.
    nonisolated private static let thumbnailCapturePixelSide = WindowImageThumbnail.sideLengthInCells * 8
    private static let streamMaximumPixelWidth: CGFloat = 720
    private static let streamFramesPerSecondRange = 5...10

    var onFrame: ((CGImage) -> Void)?

    private var activeStream: SCStream?
    private var streamedWindowIdentifier: UInt32?
    private let streamOutputQueue = DispatchQueue(label: "com.sryo.dotto.target-window-stream")
    // CIContext is thread-safe; frames are rendered on the stream queue before SCK recycles their buffers.
    nonisolated private let frameImageContext = CIContext()

    // MARK: - One-shot capture

    /// The task window with its own sheets, popovers and menus composited in, before encoding, so marks can be drawn on
    /// it. `taskWindowFrame` is the frame at capture time, which click_point maps from.
    nonisolated func captureComposedWindowImage(_ targetWindow: TargetWindowReference) async throws -> CapturedWindowImage {
        let (taskWindow, childWindows) = try await Self.shareableWindows(for: targetWindow)
        let pixelSize = ScreenCoordinateConversion.screenshotPixelSize(
            fittingWindowSizeInPoints: taskWindow.frame.size, maximumLongEdgePixels: Self.maximumLongEdgePixels,
            maximumTotalPixelCount: Self.maximumTotalPixelCount)
        let taskWindowImage = try await Self.captureImage(of: taskWindow, pixelSize: pixelSize)
        let composedImage = try await Self.compositing(childWindows, over: taskWindowImage, taskWindowFrame: taskWindow.frame)
        return CapturedWindowImage(image: composedImage, taskWindowFrame: taskWindow.frame,
                                   childWindowFrames: childWindows.map(\.frame))
    }

    nonisolated static func encodeJPEG(_ image: CGImage) throws -> Data {
        guard let jpegData = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else {
            throw TargetWindowCaptureError.imageEncodingFailed
        }
        return jpegData
    }

    /// A tiny grayscale capture for the change fingerprint, used only when every AX signal shows no change.
    nonisolated func captureThumbnail(of targetWindow: TargetWindowReference) async -> WindowImageThumbnail? {
        guard let (taskWindow, _) = try? await Self.shareableWindows(for: targetWindow),
              let windowImage = try? await Self.captureImage(
                of: taskWindow, pixelSize: CGSize(width: Self.thumbnailCapturePixelSide, height: Self.thumbnailCapturePixelSide))
        else { return nil }
        return Self.grayscaleThumbnail(of: windowImage)
    }

    nonisolated static func grayscaleThumbnail(of windowImage: CGImage) -> WindowImageThumbnail? {
        let sideLengthInCells = WindowImageThumbnail.sideLengthInCells
        var grayscaleCells = [UInt8](repeating: 0, count: sideLengthInCells * sideLengthInCells)
        let didDraw = grayscaleCells.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let grayscaleContext = CGContext(
                data: pixelBuffer.baseAddress, width: sideLengthInCells, height: sideLengthInCells,
                bitsPerComponent: 8, bytesPerRow: sideLengthInCells, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            grayscaleContext.interpolationQuality = .medium
            grayscaleContext.draw(windowImage, in: CGRect(x: 0, y: 0, width: sideLengthInCells, height: sideLengthInCells))
            return true
        }
        guard didDraw else { return nil }
        return WindowImageThumbnail(grayscaleCells: grayscaleCells)
    }

    /// The task window's sheets, popovers and open menus belong in the picture the model sees
    /// (`ScreenshotWindowComposition`). Shareable content lists windows in no particular order, so the window list
    /// says which ones are in front of the task window.
    nonisolated private static func shareableWindows(for targetWindow: TargetWindowReference) async throws
        -> (taskWindow: SCWindow, childWindows: [SCWindow]) {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let taskWindow = shareableContent.windows.first(where: { $0.windowID == targetWindow.windowIdentifier }) else {
            throw TargetWindowCaptureError.windowNotFound
        }
        let windowIdentifiersInFrontOfTaskWindow = Set(WindowListEntryClassification.onScreenWindowList(above: taskWindow.windowID)
            .compactMap(WindowListEntryClassification.windowIdentifier(of:)))
        let shareableWindowsByIdentifier = Dictionary(shareableContent.windows.map { ($0.windowID, $0) }) { firstWindow, _ in firstWindow }
        let childWindows = ScreenshotWindowComposition.windowsToDrawOverTaskWindow(
            shareableContent.windows.map(candidateWindow(from:)), taskWindow: candidateWindow(from: taskWindow),
            windowIdentifiersInFrontOfTaskWindow: windowIdentifiersInFrontOfTaskWindow)
            .compactMap { shareableWindowsByIdentifier[$0.windowIdentifier] }
        return (taskWindow, childWindows)
    }

    nonisolated private static func candidateWindow(from shareableWindow: SCWindow) -> ScreenshotCandidateWindow {
        ScreenshotCandidateWindow(windowIdentifier: shareableWindow.windowID,
                                  ownerProcessIdentifier: shareableWindow.owningApplication?.processID,
                                  windowLayer: shareableWindow.windowLayer, frameInTopLeftGlobalPoints: shareableWindow.frame,
                                  isOnScreen: shareableWindow.isOnScreen)
    }

    nonisolated private static func captureImage(of window: SCWindow, pixelSize: CGSize) async throws -> CGImage {
        let captureConfiguration = SCStreamConfiguration()
        captureConfiguration.width = max(1, Int(pixelSize.width))
        captureConfiguration.height = max(1, Int(pixelSize.height))
        captureConfiguration.showsCursor = false
        captureConfiguration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                          configuration: captureConfiguration)
    }

    nonisolated private static func compositing(_ childWindows: [SCWindow], over taskWindowImage: CGImage,
                                                taskWindowFrame: CGRect) async throws -> CGImage {
        guard !childWindows.isEmpty, taskWindowFrame.width > 0, taskWindowFrame.height > 0,
              let canvasContext = CGContext(data: nil, width: taskWindowImage.width, height: taskWindowImage.height,
                                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return taskWindowImage }
        let pixelsPerPoint = CGFloat(taskWindowImage.width) / taskWindowFrame.width
        let canvasRect = CGRect(x: 0, y: 0, width: taskWindowImage.width, height: taskWindowImage.height)
        canvasContext.draw(taskWindowImage, in: canvasRect)
        canvasContext.clip(to: canvasRect)
        for childWindow in childWindows {
            let childPixelSize = CGSize(width: (childWindow.frame.width * pixelsPerPoint).rounded(.down),
                                        height: (childWindow.frame.height * pixelsPerPoint).rounded(.down))
            guard childPixelSize.width >= 1, childPixelSize.height >= 1,
                  let childImage = try? await captureImage(of: childWindow, pixelSize: childPixelSize) else { continue }
            // Window frames are top-left based; the bitmap context's origin is bottom-left.
            let childOriginX = (childWindow.frame.minX - taskWindowFrame.minX) * pixelsPerPoint
            let childOriginYFromTop = (childWindow.frame.minY - taskWindowFrame.minY) * pixelsPerPoint
            let childRect = CGRect(x: childOriginX, y: canvasRect.height - childOriginYFromTop - childPixelSize.height,
                                   width: childPixelSize.width, height: childPixelSize.height)
            canvasContext.draw(childImage, in: childRect)
        }
        return canvasContext.makeImage() ?? taskWindowImage
    }

    // MARK: - Live view stream

    func startStreaming(_ targetWindow: TargetWindowReference, framesPerSecond: Int) async throws {
        if activeStream != nil, streamedWindowIdentifier == targetWindow.windowIdentifier { return }
        await stopStreaming()
        let (taskWindow, _) = try await Self.shareableWindows(for: targetWindow)
        let clampedFramesPerSecond = min(max(framesPerSecond, Self.streamFramesPerSecondRange.lowerBound),
                                         Self.streamFramesPerSecondRange.upperBound)
        let streamScale = min(1, Self.streamMaximumPixelWidth / max(taskWindow.frame.width, 1))
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = max(1, Int((taskWindow.frame.width * streamScale).rounded(.down)))
        streamConfiguration.height = max(1, Int((taskWindow.frame.height * streamScale).rounded(.down)))
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clampedFramesPerSecond))
        streamConfiguration.queueDepth = 3
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = false
        streamConfiguration.ignoreShadowsSingleWindow = true
        let windowStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: taskWindow),
                                    configuration: streamConfiguration, delegate: nil)
        try windowStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)
        try await windowStream.startCapture()
        activeStream = windowStream
        streamedWindowIdentifier = targetWindow.windowIdentifier
    }

    func stopStreaming() async {
        guard let activeStream else { return }
        self.activeStream = nil
        streamedWindowIdentifier = nil
        try? await activeStream.stopCapture()
    }
}

extension TargetWindowCapturer: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, let framePixelBuffer = sampleBuffer.imageBuffer else { return }
        // Idle frames (the window didn't change) carry no image; only complete frames are shown.
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let frameStatusRawValue = attachmentsArray.first?[.status] as? Int,
           SCFrameStatus(rawValue: frameStatusRawValue) != .complete {
            return
        }
        let frameImage = CIImage(cvPixelBuffer: framePixelBuffer)
        guard let frameCGImage = frameImageContext.createCGImage(frameImage, from: frameImage.extent) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.activeStream === stream else { return }
            self.onFrame?(frameCGImage)
        }
    }
}
