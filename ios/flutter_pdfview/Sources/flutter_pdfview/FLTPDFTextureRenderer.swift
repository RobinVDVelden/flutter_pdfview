import Flutter
import UIKit

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

class FLTPDFTextureRenderer: NSObject, FlutterTexture {
    private(set) var textureId: Int64
    private(set) var channelName: String

    private let textureRegistry: FlutterTextureRegistry
    private var channel: FlutterMethodChannel!

    private var document: CGPDFDocument?
    private var currentPageIndex: Int = 0
    private(set) var renderSize: CGSize

    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    private static let sharedRenderQueue = DispatchQueue(
        label: "io.endigo.pdfview.render",
        qos: .background
    )
    private static let renderSemaphore = DispatchSemaphore(value: 2)
    private var renderQueue: DispatchQueue { Self.sharedRenderQueue }

    init(args: [String: Any], textureRegistry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
        self.textureRegistry = textureRegistry

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
    }

    private func adjustRenderSize(for args: [String: Any]) {
        let defaultPageIndex = (args["defaultPage"] as? NSNumber)?.intValue ?? 0
        guard let doc = document, doc.numberOfPages > 0 else { return }

        let pageIndex = min(defaultPageIndex, doc.numberOfPages - 1)
        guard let page = doc.page(at: pageIndex + 1) else { return }

        let pageRect = page.getBoxRect(.cropBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return }

        let rotation = page.rotationAngle % 360
        let effectiveWidth  = (rotation == 90 || rotation == 270) ? pageRect.height : pageRect.width
        let effectiveHeight = (rotation == 90 || rotation == 270) ? pageRect.width  : pageRect.height

        let available = renderSize
        let scale = min(available.width / effectiveWidth,
                        available.height / effectiveHeight)

        renderSize = CGSize(
            width:  CGFloat(Int(effectiveWidth  * scale)),
            height: CGFloat(Int(effectiveHeight * scale))
        )
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let buffer = latestPixelBuffer else { return nil }
        return .passRetained(buffer)
    }

    func dispose() {
        channel.setMethodCallHandler(nil)
        textureRegistry.unregisterTexture(textureId)
        bufferLock.lock()
        latestPixelBuffer = nil
        bufferLock.unlock()
    }

    private func loadDocument(args: [String: Any]) {
        var doc: CGPDFDocument?

        if let filePath = args["filePath"] as? String {
            let url = URL(fileURLWithPath: filePath) as CFURL
            doc = CGPDFDocument(url)
        } else if let pdfData = args["pdfData"] as? FlutterStandardTypedData {
            let cfData = pdfData.data as CFData
            if let provider = CGDataProvider(data: cfData) {
                doc = CGPDFDocument(provider)
            }
        }

        guard let document = doc else {
            DispatchQueue.main.async { [weak self] in
                self?.channel.invokeMethod("onError", arguments: [
                    "error": "cannot create document: File not in PDF format or corrupted."
                ])
            }
            return
        }

        if document.isEncrypted {
            if !document.unlockWithPassword("") {
                if let password = args["password"] as? String {
                    _ = document.unlockWithPassword(password)
                }
            }
        }

        self.document = document

        let pageCount = document.numberOfPages
        let defaultPage = min((args["defaultPage"] as? NSNumber)?.intValue ?? 0, max(0, pageCount - 1))
        self.currentPageIndex = defaultPage

        adjustRenderSize(for: args)

        renderQueue.async { [weak self] in
            guard let self = self else { return }
            Self.renderSemaphore.wait()
            defer { Self.renderSemaphore.signal() }
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

    private func renderPage(_ pageIndex: Int) {
        guard let document = document,
              let page = document.page(at: pageIndex + 1) else { return }

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

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let pageRect = page.getBoxRect(.cropBox)
        let rotation = page.rotationAngle % 360
        let effectiveWidth  = (rotation == 90 || rotation == 270) ? pageRect.height : pageRect.width
        let effectiveHeight = (rotation == 90 || rotation == 270) ? pageRect.width  : pageRect.height

        let scaleX = CGFloat(width)  / effectiveWidth
        let scaleY = CGFloat(height) / effectiveHeight
        let scale  = min(scaleX, scaleY)

        let scaledWidth  = effectiveWidth  * scale
        let scaledHeight = effectiveHeight * scale
        let offsetX = (CGFloat(width)  - scaledWidth)  / 2.0
        let offsetY = (CGFloat(height) - scaledHeight) / 2.0

        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -pageRect.minX, y: -pageRect.minY)

        context.drawPDFPage(page)

        CVPixelBufferUnlockBaseAddress(buffer, [])

        bufferLock.lock()
        latestPixelBuffer = buffer
        bufferLock.unlock()
    }

    private func onMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pageCount":
            result(document?.numberOfPages ?? 0)

        case "currentPage":
            result(currentPageIndex)

        case "setPage":
            guard let args = call.arguments as? [String: Any],
                  let page = (args["page"] as? NSNumber)?.intValue else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected 'page' Int argument", details: nil))
                return
            }
            guard let doc = document, page >= 0, page < doc.numberOfPages else {
                result(false)
                return
            }
            let previousPage = currentPageIndex
            currentPageIndex = page
            let pageCount = doc.numberOfPages

            renderQueue.async { [weak self] in
                guard let self = self else { return }
                Self.renderSemaphore.wait()
                defer { Self.renderSemaphore.signal() }
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
            result(nil)

        case "getPageCount":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected dictionary arguments", details: nil))
                return
            }
            var doc: CGPDFDocument?
            if let filePath = args["filePath"] as? String {
                doc = CGPDFDocument(URL(fileURLWithPath: filePath) as CFURL)
            }
            guard let document = doc else {
                result(0)
                return
            }
            if document.isEncrypted {
                if !document.unlockWithPassword("") {
                    if let password = args["password"] as? String {
                        _ = document.unlockWithPassword(password)
                    }
                }
            }
            result(document.numberOfPages)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
