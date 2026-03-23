import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Gap (in logical pixels) added between pages in PageView mode.
/// Appears as a coloured band in the scroll direction; the band colour is the
/// widget's [PDFView.backgroundColor].
const double _kPageSpacing = 4.0;

typedef PDFViewCreatedCallback = void Function(PDFViewController controller);
typedef RenderCallback = void Function(int? pages);
typedef PageChangedCallback = void Function(int? page, int? total);
typedef ErrorCallback = void Function(dynamic error);
typedef PageErrorCallback = void Function(int? page, dynamic error);
typedef LinkHandlerCallback = void Function(String? uri);

enum FitPolicy { WIDTH, HEIGHT, BOTH }

class PDFView extends StatefulWidget {
  const PDFView({
    Key? key,
    this.filePath,
    this.pdfData,
    this.onViewCreated,
    this.onRender,
    this.onPageChanged,
    this.onError,
    this.onPageError,
    this.onLinkHandler,
    this.gestureRecognizers,
    this.enableSwipe = true,
    this.swipeHorizontal = false,
    this.password,
    this.nightMode = false,
    this.autoSpacing = true,
    this.pageFling = true,
    this.pageSnap = true,
    this.enableAntialiasing = true,
    this.useBestQuality = true,
    this.enableRenderDuringScale = true,
    this.thumbnailRatio = 0.8,
    this.fitEachPage = true,
    this.defaultPage = 0,
    this.fitPolicy = FitPolicy.WIDTH,
    this.preventLinkNavigation = false,
    this.backgroundColor,
  })  : assert(filePath != null || pdfData != null),
        super(key: key);

  @override
  _PDFViewState createState() => _PDFViewState();

  /// If not null invoked once the PDFView is created.
  final PDFViewCreatedCallback? onViewCreated;

  /// Return PDF page count as a parameter
  final RenderCallback? onRender;

  /// Return current page and page count as a parameter
  final PageChangedCallback? onPageChanged;

  /// Invokes on error that handled on native code
  final ErrorCallback? onError;

  /// Invokes on page cannot be rendered or something happens
  final PageErrorCallback? onPageError;

  /// Used with preventLinkNavigation=true. It's helpful to customize link navigation
  final LinkHandlerCallback? onLinkHandler;

  /// Which gestures should be consumed by the pdf view.
  ///
  /// It is possible for other gesture recognizers to be competing with the pdf view on pointer
  /// events, e.g if the pdf view is inside a [ListView] the [ListView] will want to handle
  /// vertical drags. The pdf view will claim gestures that are recognized by any of the
  /// recognizers on this list.
  ///
  /// When this set is empty or null, the pdf view will only handle pointer events for gestures that
  /// were not claimed by any other gesture recognizer.
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  /// The initial URL to load.
  final String? filePath;

  /// The binary data of a PDF document
  final Uint8List? pdfData;

  /// Indicates whether or not the user can swipe to change pages in the PDF document. If set to true, swiping is enabled.
  final bool enableSwipe;

  /// Indicates whether or not the user can swipe horizontally to change pages in the PDF document. If set to true, horizontal swiping is enabled.
  final bool swipeHorizontal;

  /// Represents the password for a password-protected PDF document. It can be nullable
  final String? password;

  /// Indicates whether or not the PDF viewer is in night mode. If set to true, the viewer is in night mode
  final bool nightMode;

  /// Indicates whether or not the PDF viewer automatically adds spacing between pages. If set to true, spacing is added.
  final bool autoSpacing;

  /// Indicates whether or not the user can "fling" pages in the PDF document. If set to true, page flinging is enabled.
  final bool pageFling;

  /// Indicates whether or not the viewer snaps to a page after the user has scrolled to it. If set to true, snapping is enabled.
  final bool pageSnap;

  /// Controls whether the PDF renderer uses anti-aliasing (Android only).
  final bool enableAntialiasing;

  /// Improves render quality at the cost of performance (Android only).
  final bool useBestQuality;

  /// Renders during scale gestures for smoother zooming (Android only).
  final bool enableRenderDuringScale;

  /// Thumbnail ratio used by AndroidPdfViewer (Android only).
  final double? thumbnailRatio;

  /// Represents the default page to display when the PDF document is loaded.
  final int defaultPage;

  /// FitPolicy that determines how the PDF pages are fit to the screen. The FitPolicy enum can take on the following values:
  /// - FitPolicy.WIDTH: The PDF pages are scaled to fit the width of the screen.
  /// - FitPolicy.HEIGHT: The PDF pages are scaled to fit the height of the screen.
  /// - FitPolicy.BOTH: The PDF pages are scaled to fit both the width and height of the screen.
  final FitPolicy fitPolicy;

  /// fitEachPage
  @Deprecated("will be removed next version")
  final bool fitEachPage;

  /// Indicates whether or not clicking on links in the PDF document will open the link in a new page. If set to true, link navigation is prevented.
  final bool preventLinkNavigation;

  /// Use to change the background color. ex : "#FF0000" => red
  final Color? backgroundColor;
}

// ---------------------------------------------------------------------------
// Main state
// ---------------------------------------------------------------------------

class _PDFViewState extends State<PDFView> {
  final Completer<PDFViewController> _controller =
      Completer<PDFViewController>();

  // ── Texture state (iOS + Android) ────────────────────────────────────────

  static const MethodChannel _factoryChannel =
      MethodChannel('plugins.endigo.io/pdfview_factory');

  bool _isDisposed = false;

  // Single-texture mode (single page, or swipe disabled)
  int? _textureId;
  String? _textureChannelName;
  // Logical pixel size of the single-texture (= PDF page fitted to viewport).
  // Null while the texture is still being created.
  double? _singleTextureLogicalWidth;
  double? _singleTextureLogicalHeight;

  // Multi-page PageView mode
  bool _usePageView = false;
  int _pageCount = 0;
  int _currentPageIndex = 0;
  PageController? _pageController;
  Map<String, dynamic>? _pageBaseParams; // params reused by each _NativePageTexture

  // ── lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      _setupTextureView();
    }
  }

  /// Probes native side for pageCount, then decides single-texture vs PageView.
  Future<void> _setupTextureView() async {
    // Wait one frame so MediaQuery is available.
    final frameCompleter = Completer<void>();
    SchedulerBinding.instance
        .addPostFrameCallback((_) => frameCompleter.complete());
    await frameCompleter.future;

    if (!mounted || _isDisposed) return;

    final mediaQuery = MediaQuery.of(context);
    final pixelRatio = mediaQuery.devicePixelRatio;

    // Use the widget's own rendered size, not the screen size.  When PDFView
    // is placed inside a container that is smaller than the screen (e.g. a
    // Card, a Column child, a split-view pane) MediaQuery.size would return
    // the full screen dimensions, causing the texture to be oversized and
    // appear stretched inside the smaller widget.
    final renderBox = context.findRenderObject() as RenderBox?;
    final size = renderBox?.size ?? mediaQuery.size;

    final params = _CreationParams.fromWidget(widget).toMap();
    params['width'] = (size.width * pixelRatio).toInt();
    params['height'] = (size.height * pixelRatio).toInt();
    // pixelRatio lets each renderer convert physical → logical pixel dimensions.
    params['pixelRatio'] = pixelRatio;

    try {
      // Create a probe renderer (renders defaultPage) to discover pageCount.
      final result = await _factoryChannel
          .invokeMapMethod<String, dynamic>('create', params);

      if (_isDisposed) {
        _disposeNativeChannel(result?['channelName'] as String?);
        return;
      }
      if (!mounted || result == null) return;

      final textureId = result['textureId'] as int;
      final channelName = result['channelName'] as String;
      final probeChannel = MethodChannel(channelName);

      // pageCount is available synchronously after create() because the
      // native renderer loads the PDFDocument before returning.
      final pageCount =
          await probeChannel.invokeMethod<int>('pageCount') ?? 1;

      if (_isDisposed || !mounted) {
        _disposeNativeChannel(channelName);
        return;
      }

      final usePageView = widget.enableSwipe && pageCount > 1;

      PDFViewController controller;

      if (usePageView) {
        // Dispose the probe renderer — _NativePageTexture will create per-page ones.
        _disposeNativeChannel(channelName);

        final pageController =
            PageController(initialPage: widget.defaultPage);

        controller = PDFViewController._fromPageController(
          pageController,
          () => _pageCount,
          () => _currentPageIndex,
          widget,
        );

        setState(() {
          _usePageView = true;
          _pageCount = pageCount;
          _currentPageIndex = widget.defaultPage;
          _pageController = pageController;
          _pageBaseParams = Map<String, dynamic>.from(params);
        });
      } else {
        // Keep the probe renderer as the single texture.
        controller = PDFViewController._fromChannel(probeChannel, widget);

        // Convert the physical render dimensions back to logical pixels so
        // the Texture widget can be sized to exactly the PDF page bounds.
        final renderWidth = result['renderWidth'] as int? ?? params['width'] as int;
        final renderHeight = result['renderHeight'] as int? ?? params['height'] as int;

        setState(() {
          _textureId = textureId;
          _textureChannelName = channelName;
          _singleTextureLogicalWidth = renderWidth / pixelRatio;
          _singleTextureLogicalHeight = renderHeight / pixelRatio;
        });
      }

      if (!_controller.isCompleted) {
        _controller.complete(controller);
      }
      widget.onViewCreated?.call(controller);
    } catch (e) {
      if (mounted) widget.onError?.call(e.toString());
    }
  }

  void _disposeNativeChannel(String? channelName) {
    if (channelName != null) {
      _factoryChannel.invokeMethod<void>('dispose', {'channelName': channelName});
    }
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      final bg = widget.backgroundColor ?? const Color(0x00000000);

      // ── multi-page swipe mode ──────────────────────────────────────────
      if (_usePageView) {
        // Directional padding creates a visible gap between pages while the
        // user swipes.  The ColoredBox makes the background colour visible
        // through those gaps.
        final EdgeInsets itemPadding = widget.swipeHorizontal
            ? const EdgeInsets.symmetric(horizontal: _kPageSpacing)
            : const EdgeInsets.symmetric(vertical: _kPageSpacing);

        return ColoredBox(
          color: bg,
          child: PageView.builder(
            controller: _pageController,
            scrollDirection:
                widget.swipeHorizontal ? Axis.horizontal : Axis.vertical,
            physics: widget.pageSnap
                ? const PageScrollPhysics()
                : const ClampingScrollPhysics(),
            onPageChanged: (index) {
              _currentPageIndex = index;
              widget.onPageChanged?.call(index, _pageCount);
            },
            itemCount: _pageCount,
            itemBuilder: (ctx, index) => Padding(
              padding: itemPadding,
              child: _NativePageTexture(
                pageIndex: index,
                baseParams: _pageBaseParams!,
                backgroundColor: bg,
                // Forward onRender only from the initially-visible page so
                // the caller gets exactly one onRender({pages: N}) event.
                onRenderCallback: index == widget.defaultPage
                    ? (pages) => widget.onRender?.call(pages)
                    : null,
                onErrorCallback: (error) => widget.onError?.call(error),
              ),
            ),
          ),
        );
      }

      // ── single-texture mode ────────────────────────────────────────────
      // The Texture widget is sized to exactly the PDF page bounds (logical
      // pixels) and centred inside the ColoredBox, so the background colour
      // is naturally visible in the surrounding area.
      return ColoredBox(
        color: bg,
        child: Center(
          child: _textureId == null ||
                  _singleTextureLogicalWidth == null ||
                  _singleTextureLogicalHeight == null
              ? const SizedBox.shrink()
              : SizedBox(
                  width: _singleTextureLogicalWidth,
                  height: _singleTextureLogicalHeight,
                  child: Texture(textureId: _textureId!),
                ),
        ),
      );
    }

    return Text(
        '$defaultTargetPlatform is not yet supported by the pdfview_flutter plugin');
  }

  // ── widget update / dispose ──────────────────────────────────────────────

  @override
  void didUpdateWidget(PDFView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.future
        .then((PDFViewController c) => c._updateWidget(widget));
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller.future.then((PDFViewController c) => c.dispose());
    _disposeNativeChannel(_textureChannelName);
    _pageController?.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Per-page texture widget (iOS PageView mode)
// ---------------------------------------------------------------------------

/// Creates and owns a single native texture renderer for one PDF page.
///
/// Flutter's [PageView] automatically calls [dispose] when the page scrolls
/// beyond the cache extent, which unregisters the underlying texture.
class _NativePageTexture extends StatefulWidget {
  const _NativePageTexture({
    required this.pageIndex,
    required this.baseParams,
    required this.backgroundColor,
    this.onRenderCallback,
    this.onErrorCallback,
  });

  final int pageIndex;

  /// Creation params shared across all pages (file path / data, render size,
  /// etc.).  `defaultPage` is overridden with [pageIndex] before calling
  /// `create`.
  final Map<String, dynamic> baseParams;

  /// Shown as a solid fill while the texture is still being rendered by the
  /// native side, preventing a white flash.
  final Color backgroundColor;

  final void Function(int pages)? onRenderCallback;
  final void Function(dynamic error)? onErrorCallback;

  @override
  State<_NativePageTexture> createState() => _NativePageTextureState();
}

class _NativePageTextureState extends State<_NativePageTexture>
    with AutomaticKeepAliveClientMixin {
  static const _factoryChannel =
      MethodChannel('plugins.endigo.io/pdfview_factory');

  int? _textureId;
  String? _channelName;
  // Logical pixel size of this page's texture (= page fitted to viewport).
  double? _logicalWidth;
  double? _logicalHeight;
  bool _isDisposed = false;

  // Keep this page alive in the PageView once its texture has been rendered,
  // so that setPage() / jumpToPage() is instant without any re-render.
  bool _wantKeepAlive = false;

  @override
  bool get wantKeepAlive => _wantKeepAlive;

  @override
  void initState() {
    super.initState();
    _createTexture();
  }

  Future<void> _createTexture() async {
    final params = Map<String, dynamic>.from(widget.baseParams);
    params['defaultPage'] = widget.pageIndex;

    try {
      final result = await _factoryChannel
          .invokeMapMethod<String, dynamic>('create', params);

      if (_isDisposed) {
        // Widget was disposed while we were waiting — clean up native side.
        final channelName = result?['channelName'] as String?;
        if (channelName != null) {
          _factoryChannel
              .invokeMethod<void>('dispose', {'channelName': channelName});
        }
        return;
      }
      if (!mounted || result == null) return;

      final textureId = result['textureId'] as int;
      final channelName = result['channelName'] as String;

      // Convert physical render dimensions to logical pixels.
      final pixelRatio =
          (widget.baseParams['pixelRatio'] as num?)?.toDouble() ?? 1.0;
      final renderWidth =
          (result['renderWidth'] as num?)?.toInt() ??
          (widget.baseParams['width'] as num?)?.toInt() ??
          1;
      final renderHeight =
          (result['renderHeight'] as num?)?.toInt() ??
          (widget.baseParams['height'] as num?)?.toInt() ??
          1;

      // Forward native events to the caller.
      MethodChannel(channelName).setMethodCallHandler((call) async {
        if (call.method == 'onRender') {
          widget.onRenderCallback?.call(call.arguments['pages'] as int);
        } else if (call.method == 'onError') {
          widget.onErrorCallback?.call(call.arguments['error']);
        }
        return null;
      });

      setState(() {
        _textureId = textureId;
        _channelName = channelName;
        _logicalWidth = renderWidth / pixelRatio;
        _logicalHeight = renderHeight / pixelRatio;
        // Activate keep-alive so the PageView doesn't dispose this widget
        // once it scrolls out of the cache — makes setPage() instant.
        if (!_wantKeepAlive) _wantKeepAlive = true;
      });
      updateKeepAlive();
    } catch (e) {
      if (mounted) widget.onErrorCallback?.call(e.toString());
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    final channelName = _channelName;
    if (channelName != null) {
      _factoryChannel
          .invokeMethod<void>('dispose', {'channelName': channelName});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin

    // While the texture is initialising, show the background colour to avoid
    // a white flash in the PageView.
    if (_textureId == null || _logicalWidth == null || _logicalHeight == null) {
      return ColoredBox(color: widget.backgroundColor);
    }

    // The Texture is sized to exactly the PDF page bounds and centred so that
    // the surrounding ColoredBox (background colour) is visible around it.
    return Center(
      child: SizedBox(
        width: _logicalWidth,
        height: _logicalHeight,
        child: Texture(textureId: _textureId!),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Creation params helpers (unchanged)
// ---------------------------------------------------------------------------

class _CreationParams {
  _CreationParams({
    this.filePath,
    this.pdfData,
    this.settings,
  });

  static _CreationParams fromWidget(PDFView widget) {
    return _CreationParams(
      filePath: widget.filePath,
      pdfData: widget.pdfData,
      settings: _PDFViewSettings.fromWidget(widget),
    );
  }

  final String? filePath;
  final Uint8List? pdfData;

  final _PDFViewSettings? settings;

  Map<String, dynamic> toMap() {
    Map<String, dynamic> params = {
      'filePath': filePath,
      'pdfData': pdfData,
    };
    params.addAll(settings!.toMap());
    return params;
  }
}

class _PDFViewSettings {
  _PDFViewSettings({
    this.enableSwipe,
    this.swipeHorizontal,
    this.password,
    this.nightMode,
    this.autoSpacing,
    this.pageFling,
    this.pageSnap,
    this.enableAntialiasing,
    this.useBestQuality,
    this.enableRenderDuringScale,
    this.thumbnailRatio,
    this.defaultPage,
    this.fitPolicy,
    this.preventLinkNavigation,
    this.backgroundColor,
  });

  static _PDFViewSettings fromWidget(PDFView widget) {
    return _PDFViewSettings(
      enableSwipe: widget.enableSwipe,
      swipeHorizontal: widget.swipeHorizontal,
      password: widget.password,
      nightMode: widget.nightMode,
      autoSpacing: widget.autoSpacing,
      pageFling: widget.pageFling,
      pageSnap: widget.pageSnap,
      enableAntialiasing: widget.enableAntialiasing,
      useBestQuality: widget.useBestQuality,
      enableRenderDuringScale: widget.enableRenderDuringScale,
      thumbnailRatio: widget.thumbnailRatio,
      defaultPage: widget.defaultPage,
      fitPolicy: widget.fitPolicy,
      preventLinkNavigation: widget.preventLinkNavigation,
      backgroundColor: widget.backgroundColor,
    );
  }

  final bool? enableSwipe;
  final bool? swipeHorizontal;
  final String? password;
  final bool? nightMode;
  final bool? autoSpacing;
  final bool? pageFling;
  final bool? pageSnap;
  final bool? enableAntialiasing;
  final bool? useBestQuality;
  final bool? enableRenderDuringScale;
  final double? thumbnailRatio;
  final int? defaultPage;
  final FitPolicy? fitPolicy;
  final bool? preventLinkNavigation;

  final Color? backgroundColor;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'enableSwipe': enableSwipe,
      'swipeHorizontal': swipeHorizontal,
      'password': password,
      'nightMode': nightMode,
      'autoSpacing': autoSpacing,
      'pageFling': pageFling,
      'pageSnap': pageSnap,
      'enableAntialiasing': enableAntialiasing,
      'useBestQuality': useBestQuality,
      'enableRenderDuringScale': enableRenderDuringScale,
      'thumbnailRatio': thumbnailRatio,
      'defaultPage': defaultPage,
      'fitPolicy': fitPolicy.toString(),
      'preventLinkNavigation': preventLinkNavigation,
      'backgroundColor': backgroundColor?.value,
    };
  }

  Map<String, dynamic> updatesMap(_PDFViewSettings newSettings) {
    final Map<String, dynamic> updates = <String, dynamic>{};
    if (enableSwipe != newSettings.enableSwipe) {
      updates['enableSwipe'] = newSettings.enableSwipe;
    }
    if (pageFling != newSettings.pageFling) {
      updates['pageFling'] = newSettings.pageFling;
    }
    if (pageSnap != newSettings.pageSnap) {
      updates['pageSnap'] = newSettings.pageSnap;
    }
    if (preventLinkNavigation != newSettings.preventLinkNavigation) {
      updates['preventLinkNavigation'] = newSettings.preventLinkNavigation;
    }
    return updates;
  }
}

// ---------------------------------------------------------------------------
// PDFViewController
// ---------------------------------------------------------------------------

class PDFViewController {
  /// Single-texture path (iOS + Android): uses a pre-created channel returned
  /// by the native texture factory.
  PDFViewController._fromChannel(MethodChannel channel, PDFView widget)
      : _channel = channel,
        _pageController = null,
        _pageCountGetter = null,
        _currentPageGetter = null,
        _widget = widget {
    _settings = _PDFViewSettings.fromWidget(widget);
    _channel!.setMethodCallHandler(_onMethodCall);
  }

  /// Multi-page PageView path (iOS + Android): no native channel; drives a
  /// Flutter [PageController].
  PDFViewController._fromPageController(
    PageController pageController,
    int Function() pageCountGetter,
    int Function() currentPageGetter,
    PDFView widget,
  )   : _channel = null,
        _pageController = pageController,
        _pageCountGetter = pageCountGetter,
        _currentPageGetter = currentPageGetter,
        _widget = widget {
    _settings = _PDFViewSettings.fromWidget(widget);
  }

  // ── internals ────────────────────────────────────────────────────────────

  final MethodChannel? _channel;
  final PageController? _pageController;
  final int Function()? _pageCountGetter;
  final int Function()? _currentPageGetter;

  late _PDFViewSettings _settings;
  PDFView? _widget;

  // ── public API ───────────────────────────────────────────────────────────

  void dispose() {
    _channel?.setMethodCallHandler(null);
    _widget = null;
  }

  Future<int?> getPageCount() async {
    if (_pageController != null) return _pageCountGetter!();
    return _channel?.invokeMethod<int>('pageCount');
  }

  Future<int?> getCurrentPage() async {
    if (_pageController != null) return _currentPageGetter!();
    return _channel?.invokeMethod<int>('currentPage');
  }

  Future<bool?> setPage(int page) async {
    if (_pageController != null) {
      if (_pageController!.hasClients) {
        _pageController!.jumpToPage(page);
      }
      return true;
    }
    return _channel?.invokeMethod<bool>('setPage', <String, dynamic>{
      'page': page,
    });
  }

  // ── internal ─────────────────────────────────────────────────────────────

  Future<bool?> _onMethodCall(MethodCall call) async {
    final widget = _widget;
    if (widget == null) return null;

    switch (call.method) {
      case 'onRender':
        widget.onRender?.call(call.arguments['pages']);
        return null;
      case 'onPageChanged':
        widget.onPageChanged?.call(
          call.arguments['page'],
          call.arguments['total'],
        );
        return null;
      case 'onError':
        widget.onError?.call(call.arguments['error']);
        return null;
      case 'onPageError':
        widget.onPageError
            ?.call(call.arguments['page'], call.arguments['error']);
        return null;
      case 'onLinkHandler':
        widget.onLinkHandler?.call(call.arguments);
        return null;
    }
    throw MissingPluginException(
        '${call.method} was invoked but has no handler');
  }

  Future<void> _updateWidget(PDFView widget) async {
    _widget = widget;
    if (_channel != null) {
      await _updateSettings(_PDFViewSettings.fromWidget(widget));
    }
  }

  Future<void> _updateSettings(_PDFViewSettings setting) async {
    final Map<String, dynamic> updateMap = _settings.updatesMap(setting);
    if (updateMap.isEmpty) return;
    _settings = setting;
    return _channel?.invokeMethod<void>('updateSettings', updateMap);
  }
}
