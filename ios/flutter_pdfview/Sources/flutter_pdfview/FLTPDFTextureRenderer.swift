import Flutter
import PDFKit
import UIKit

// MARK: - Factory

/// Manages all FLTPDFTextureRenderer instances, created via the
/// "plugins.endigo.io/pdfview_factory" method channel.
@objc(FLTPDFTextureFactory)
public class FLTPDFTextureFactory: NSObject {
    private let textureRegistry: FlutterTextureRegistry
    private let messenger: FlutterBinaryMessenger
    private let factoryChannel: FlutterMethodChannel
    private var renderers: [String: FLTPDFTextureRenderer] = [:]

    @objc public init(textureRegistry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
        self.textureRegistry = textureRegistry
        self.messenger = messenger
        self.factoryChannel = FlutterMethodChannel(
            name: "plugins.endigo.io/pdfview_factory",
            binaryMessenger: messenger
        )
        super.init()

        weak var weakSelf = self
        factoryChannel.setMethodCallHandler { call, result in
            weakSelf?.onMethodCall(call, result: result)
        }
    }

    private func onMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "create":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected dictionary arguments", details: nil))
                return
            }
            let renderer = FLTPDFTextureRenderer(
                args: args,
                textureRegistry: textureRegistry,
                messenger: messenger
            )
            renderers[renderer.channelName] = renderer
            result([
                "textureId": renderer.textureId,
                "channelName": renderer.channelName,
                // Physical pixel dimensions of the texture, sized to fit the PDF
                // page within the available space (no centering margins).
                "renderWidth": Int(renderer.renderSize.width),
                "renderHeight": Int(renderer.renderSize.height),
            ])

        case "dispose":
            guard let args = call.arguments as? [String: Any],
                  let channelName = args["channelName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected channelName", details: nil))
                return
            }
            renderers[channelName]?.dispose()
            renderers.removeValue(forKey: channelName)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - Renderer

/// Renders a single PDF document into a CVPixelBuffer registered as a FlutterTexture.
/// Communicates with Flutter via a per-instance method channel.
class FLTPDFTextureRenderer: NSObject, FlutterTexture {
    private(set) var textureId: Int64
    private(set) var channelName: String

    private let textureRegistry: FlutterTextureRegistry
    private var channel: FlutterMethodChannel!

    private var document: PDFDocument?
    private var currentPageIndex: Int = 0
    // Settable only within this class; the factory reads it after init to
    // forward the actual texture dimensions back to Flutter.
    private(set) var renderSize: CGSize

    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private let renderQueue = DispatchQueue(label: "io.endigo.pdfview.render", qos: .userInitiated)

    init(args: [String: Any], textureRegistry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
        self.textureRegistry = textureRegistry

        // The codec may deliver width/height as Int or Double; NSNumber handles both.
        let width = (args["width"] as? NSNumber)?.doubleValue ?? 800.0
        let height = (args["height"] as? NSNumber)?.doubleValue ?? 1200.0
        self.renderSize = CGSize(width: max(1, width), height: max(1, height))

        self.textureId = -1
        self.channelName = ""

        super.init()

        self.textureId = textureRegistry.register(self)
        self.channelName = "plugins.endigo.io/pdfview_\(textureId)"

        self.channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.onMethodCall(call, result: result)
        }

        loadDocument(args: args)

        // Shrink renderSize to match the PDF page's aspect ratio so that the
        // Texture widget on the Flutter side can be sized to exactly the page
        // bounds — leaving the surrounding area free for the background colour.
        adjustRenderSize(for: args)
    }

    /// Recalculates renderSize so the texture is exactly as large as the PDF
    /// page scaled to fit within the originally requested available size.
    ///
    /// Uses the crop box (the "visible" page area, matching PDFView's default)
    /// rather than the media box, so that any printer bleed / trim marks
    /// outside the crop region are not included in the texture dimensions.
    private func adjustRenderSize(for args: [String: Any]) {
        let defaultPageIndex = (args["defaultPage"] as? NSNumber)?.intValue ?? 0
        guard let doc = document, doc.pageCount > 0 else { return }

        let pageIndex = min(defaultPageIndex, doc.pageCount - 1)
        guard let page = doc.page(at: pageIndex) else { return }

        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return }

        let available = renderSize
        let scale = min(available.width / pageRect.width,
                        available.height / pageRect.height)

        // Integer pixel dimensions — no partial pixels in the texture.
        renderSize = CGSize(
            width:  CGFloat(Int(pageRect.width  * scale)),
            height: CGFloat(Int(pageRect.height * scale))
        )
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let buffer = latestPixelBuffer else { return nil }
        return .passRetained(buffer)
    }

    // MARK: - Lifecycle

    func dispose() {
        channel.setMethodCallHandler(nil)
        textureRegistry.unregisterTexture(textureId)
        bufferLock.lock()
        latestPixelBuffer = nil
        bufferLock.unlock()
    }

    // MARK: - Document loading

    private func loadDocument(args: [String: Any]) {
        var doc: PDFDocument?

        if let filePath = args["filePath"] as? String {
            let url = URL(fileURLWithPath: filePath)
            doc = PDFDocument(url: url)
        } else if let pdfData = args["pdfData"] as? FlutterStandardTypedData {
            doc = PDFDocument(data: pdfData.data)
        }

        guard let document = doc else {
            DispatchQueue.main.async { [weak self] in
                self?.channel.invokeMethod("onError", arguments: [
                    "error": "cannot create document: File not in PDF format or corrupted."
                ])
            }
            return
        }

        if let password = args["password"] as? String, document.isEncrypted {
            document.unlock(withPassword: password)
        }

        self.document = document

        let pageCount = document.pageCount
        let defaultPage = min((args["defaultPage"] as? NSNumber)?.intValue ?? 0, max(0, pageCount - 1))
        self.currentPageIndex = defaultPage

        renderQueue.async { [weak self] in
            guard let self = self else { return }
            self.renderPage(self.currentPageIndex)
            DispatchQueue.main.async {
                self.textureRegistry.textureFrameAvailable(self.textureId)
                self.channel.invokeMethod("onRender", arguments: ["pages": pageCount])
                self.channel.invokeMethod("onPageChanged", arguments: [
                    "page": defaultPage,
                    "total": pageCount
                ])
            }
        }
    }

    // MARK: - Rendering

    private func renderPage(_ pageIndex: Int) {
        guard let document = document,
              let page = document.page(at: pageIndex) else { return }

        let size = renderSize
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return }

        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]

        var newBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &newBuffer
        )

        guard status == kCVReturnSuccess, let buffer = newBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return
        }

        // Fill with white — the natural background colour of a PDF page.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Use the crop box (the visible area shown by PDFView) rather than the
        // media box so that printer bleed / trim marks are excluded.
        let pageRect = page.bounds(for: .cropBox)
        let scaleX = CGFloat(width) / pageRect.width
        let scaleY = CGFloat(height) / pageRect.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = pageRect.width * scale
        let scaledHeight = pageRect.height * scale
        let offsetX = (CGFloat(width) - scaledWidth) / 2.0
        let offsetY = (CGFloat(height) - scaledHeight) / 2.0

        // CGBitmapContext memory layout already matches the display convention used by
        // Flutter's Metal texture renderer: no y-flip is needed.  PDFPage.draw places
        // the page origin at the context origin and draws upward, which produces a
        // correctly oriented image in the pixel buffer without any additional transform.
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: scale, y: scale)
        // Normalise the crop box to (0, 0) so pages whose crop box does not
        // start at the PDF origin are still drawn flush against the texture edge.
        context.translateBy(x: -pageRect.minX, y: -pageRect.minY)

        page.draw(with: .cropBox, to: context)

        CVPixelBufferUnlockBaseAddress(buffer, [])

        bufferLock.lock()
        latestPixelBuffer = buffer
        bufferLock.unlock()
    }

    // MARK: - Method channel handler

    private func onMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pageCount":
            result(document?.pageCount ?? 0)

        case "currentPage":
            result(currentPageIndex)

        case "setPage":
            guard let args = call.arguments as? [String: Any],
                  let page = (args["page"] as? NSNumber)?.intValue else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected 'page' Int argument", details: nil))
                return
            }
            guard let doc = document, page >= 0, page < doc.pageCount else {
                result(false)
                return
            }
            let previousPage = currentPageIndex
            currentPageIndex = page
            let pageCount = doc.pageCount

            renderQueue.async { [weak self] in
                guard let self = self else { return }
                self.renderPage(page)
                DispatchQueue.main.async {
                    self.textureRegistry.textureFrameAvailable(self.textureId)
                    if previousPage != page {
                        self.channel.invokeMethod("onPageChanged", arguments: [
                            "page": page,
                            "total": pageCount
                        ])
                    }
                    result(true)
                }
            }

        case "updateSettings":
            // Settings like enableSwipe, pageFling etc. don't apply to the
            // texture-based renderer; silently ignore.
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
