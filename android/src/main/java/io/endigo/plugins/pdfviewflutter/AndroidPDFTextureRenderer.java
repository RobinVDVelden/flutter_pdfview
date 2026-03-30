package io.endigo.plugins.pdfviewflutter;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.pdf.PdfRenderer;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.view.Surface;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

/**
 * Renders a single PDF document into a Flutter texture via Android's built-in
 * {@link PdfRenderer} API.  Communicates with Flutter over a per-instance
 * {@link MethodChannel} whose name is "plugins.endigo.io/pdfview_<textureId>".
 *
 * <p>Mirrors the iOS {@code FLTPDFTextureRenderer} class.  Because it relies
 * only on {@link TextureRegistry} (and not on platform-view infrastructure),
 * it works correctly on secondary Flutter engines that are attached to a
 * {@code Presentation} rather than a full {@code FlutterActivity}.
 */
class AndroidPDFTextureRenderer {

    // ── exposed to factory ────────────────────────────────────────────────────
    final long textureId;
    final String channelName;
    /** Physical pixel width of the rendered texture (page-fitted, no margins). */
    int renderWidth;
    /** Physical pixel height of the rendered texture (page-fitted, no margins). */
    int renderHeight;
    /** Total number of pages in the document; set synchronously during construction. */
    int pageCount = 0;

    // ── internals ─────────────────────────────────────────────────────────────
    private final TextureRegistry.SurfaceTextureEntry textureEntry;
    private final MethodChannel channel;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService renderExecutor = Executors.newSingleThreadExecutor();

    private volatile boolean isDisposed = false;

    private PdfRenderer pdfRenderer;
    private ParcelFileDescriptor pfd;
    private File tempFile;

    private int currentPageIndex = 0;
    private final int availableWidth;
    private final int availableHeight;
    private final boolean nightMode;
    private final int backgroundColor;
    private final int renderMode;

    // ── constructor ───────────────────────────────────────────────────────────

    AndroidPDFTextureRenderer(
            Map<String, Object> args,
            TextureRegistry textureRegistry,
            BinaryMessenger messenger) {

        availableWidth   = getInt(args, "width",  800);
        availableHeight  = getInt(args, "height", 1200);
        nightMode        = getBool(args, "nightMode");
        backgroundColor  = getInt(args, "backgroundColor", Color.BLACK);
        // useBestQuality (default true) maps to RENDER_MODE_FOR_PRINT which
        // produces fully anti-aliased text and sharper vector edges at the cost
        // of ~2-3× render time vs RENDER_MODE_FOR_DISPLAY.
        renderMode = getBool(args, "useBestQuality", true)
                ? PdfRenderer.Page.RENDER_MODE_FOR_PRINT
                : PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY;
        renderWidth      = availableWidth;
        renderHeight     = availableHeight;

        textureEntry = textureRegistry.createSurfaceTexture();
        textureId    = textureEntry.id();
        channelName  = "plugins.endigo.io/pdfview_" + textureId;

        channel = new MethodChannel(messenger, channelName);
        channel.setMethodCallHandler(this::onMethodCall);

        loadDocument(args);
    }

    // ── document loading ──────────────────────────────────────────────────────

    private void loadDocument(Map<String, Object> args) {
        String filePath  = getString(args, "filePath");
        byte[] pdfData   = args.get("pdfData") instanceof byte[]
                           ? (byte[]) args.get("pdfData") : null;
        int    defaultPage = getInt(args, "defaultPage", 0);

        try {
            if (filePath != null && !filePath.isEmpty()) {
                pfd = ParcelFileDescriptor.open(
                        new File(filePath), ParcelFileDescriptor.MODE_READ_ONLY);
            } else if (pdfData != null) {
                // PdfRenderer requires a file descriptor; write bytes to a
                // temporary file that is cleaned up on dispose().
                tempFile = File.createTempFile("pdfview_", ".pdf");
                tempFile.deleteOnExit();
                try (FileOutputStream fos = new FileOutputStream(tempFile)) {
                    fos.write(pdfData);
                }
                pfd = ParcelFileDescriptor.open(
                        tempFile, ParcelFileDescriptor.MODE_READ_ONLY);
            } else {
                sendError("No filePath or pdfData provided");
                return;
            }

            pdfRenderer = new PdfRenderer(pfd);
            pageCount = pdfRenderer.getPageCount();
            if (pageCount == 0) {
                sendError("PDF has no pages");
                return;
            }

            currentPageIndex = Math.min(defaultPage, pageCount - 1);
            // Compute the texture dimensions synchronously before the
            // first render task, so renderWidth/renderHeight are ready
            // by the time the factory returns from create().
            adjustRenderSize(currentPageIndex);

            final int finalPage  = currentPageIndex;
            final int finalCount = pageCount;
            renderExecutor.execute(() -> {
                renderPage(finalPage);
                mainHandler.post(() -> {
                    if (!isDisposed) {
                        channel.invokeMethod("onRender",
                                mapOf("pages", finalCount));
                        channel.invokeMethod("onPageChanged",
                                mapOf("page", finalPage, "total", finalCount));
                    }
                });
            });

        } catch (IOException e) {
            sendError("Cannot open PDF: " + e.getMessage());
        }
    }

    /**
     * Shrinks {@link #renderWidth} / {@link #renderHeight} to match the PDF
     * page's aspect ratio, fitting within the originally requested available
     * area.  Mirrors {@code adjustRenderSize(for:)} on iOS.
     */
    private void adjustRenderSize(int pageIndex) {
        if (pdfRenderer == null || pdfRenderer.getPageCount() == 0) return;

        PdfRenderer.Page page = pdfRenderer.openPage(
                Math.min(pageIndex, pdfRenderer.getPageCount() - 1));
        float pw = page.getWidth();
        float ph = page.getHeight();
        page.close();

        if (pw <= 0 || ph <= 0) return;

        float scale = Math.min(availableWidth / pw, availableHeight / ph);
        renderWidth  = (int) (pw * scale);
        renderHeight = (int) (ph * scale);
    }

    // ── rendering ─────────────────────────────────────────────────────────────

    /**
     * Renders {@code pageIndex} to the Flutter texture.  Must be called on the
     * {@link #renderExecutor} thread — {@code PdfRenderer} only allows one open
     * page at a time and is not thread-safe.
     */
    private void renderPage(int pageIndex) {
        if (isDisposed || pdfRenderer == null
                || renderWidth <= 0 || renderHeight <= 0) return;

        PdfRenderer.Page page = null;
        Bitmap bitmap = null;
        try {
            page = pdfRenderer.openPage(
                    Math.min(pageIndex, pdfRenderer.getPageCount() - 1));

            bitmap = Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888);

            float pw = page.getWidth();
            float ph = page.getHeight();

            if (pw > 0 && ph > 0) {
                // Compute scale-to-fit (preserving aspect ratio) and centre offset.
                float scale   = Math.min(renderWidth / pw, renderHeight / ph);
                float scaledW = pw * scale;
                float scaledH = ph * scale;
                float offsetX = (renderWidth  - scaledW) / 2f;
                float offsetY = (renderHeight - scaledH) / 2f;

                // 1. Fill the whole bitmap with backgroundColor so the margins
                //    (area outside the PDF page) match the widget background.
                bitmap.eraseColor(backgroundColor);

                // 2. Draw a white rect at the page position so PDF content that
                //    relies on an implicit white page background looks correct.
                //    (page.render with a custom transform does not fill the page
                //    area automatically — it only paints the PDF vectors/images.)
                Canvas canvas = new Canvas(bitmap);
                Paint whitePaint = new Paint();
                whitePaint.setColor(Color.WHITE);
                canvas.drawRect(new RectF(offsetX, offsetY,
                        offsetX + scaledW, offsetY + scaledH), whitePaint);

                // 3. Render the PDF page at the correct position and scale.
                Matrix transform = new Matrix();
                transform.postScale(scale, scale);
                transform.postTranslate(offsetX, offsetY);
                page.render(bitmap, null, transform, renderMode);
            } else {
                // Page dimensions unavailable — fall back to stretch-to-fill.
                bitmap.eraseColor(Color.WHITE);
                page.render(bitmap, null, null, renderMode);
            }

        } catch (Exception e) {
            sendError("Render failed for page " + pageIndex + ": " + e.getMessage());
            return;
        } finally {
            // Always close the page — even if render() threw — so the
            // PdfRenderer does not get stuck with a page open.
            if (page != null) {
                try { page.close(); } catch (Exception ignored) {}
            }
        }

        if (bitmap == null) return;

        // Bail out if dispose() was called while the PDF was being rendered.
        if (isDisposed) {
            bitmap.recycle();
            return;
        }

        // Push the rendered bitmap into the Flutter SurfaceTexture.
        // Wrap in a broad try/catch: if dispose() races here and the
        // SurfaceTexture is abandoned between the isDisposed check and
        // lockCanvas(), the unchecked IllegalArgumentException is caught
        // instead of crashing the thread.
        try {
            textureEntry.surfaceTexture().setDefaultBufferSize(renderWidth, renderHeight);
            Surface surface = new Surface(textureEntry.surfaceTexture());
            try {
                if (surface.isValid()) {
                    Canvas canvas = surface.lockCanvas(null);
                    if (canvas != null) {
                        if (nightMode) {
                            // Invert colours to simulate night / dark mode.
                            Paint paint = new Paint();
                            ColorMatrix cm = new ColorMatrix(new float[]{
                                    -1,  0,  0, 0, 255,
                                     0, -1,  0, 0, 255,
                                     0,  0, -1, 0, 255,
                                     0,  0,  0, 1,   0,
                            });
                            paint.setColorFilter(new ColorMatrixColorFilter(cm));
                            canvas.drawBitmap(bitmap, 0, 0, paint);
                        } else {
                            canvas.drawBitmap(bitmap, 0, 0, null);
                        }
                        surface.unlockCanvasAndPost(canvas);
                    }
                }
            } finally {
                surface.release();
            }
        } catch (Exception ignored) {
            // Surface was abandoned concurrently by dispose() — silently
            // discard; the texture is no longer needed anyway.
        } finally {
            bitmap.recycle();
        }
    }

    // ── lifecycle ─────────────────────────────────────────────────────────────

    void dispose() {
        isDisposed = true;
        channel.setMethodCallHandler(null);

        // Capture resources; null the fields immediately so that any
        // renderPage task that already passed the isDisposed guard will
        // still finish, but subsequent ones will bail at the null check.
        final PdfRenderer rendererToClose = pdfRenderer;
        final ParcelFileDescriptor pfdToClose = pfd;
        final File tempFileToDelete = tempFile;
        pdfRenderer = null;
        pfd = null;
        tempFile = null;

        // PdfRenderer / file teardown is queued on the render executor so it
        // runs strictly AFTER any in-progress renderPage task, preventing the
        // PdfDocumentProxy NPE and the abandoned-SurfaceTexture IAE crashes.
        renderExecutor.execute(() -> {
            if (rendererToClose != null) {
                try { rendererToClose.close(); } catch (Exception ignored) {}
            }
            if (pfdToClose != null) {
                try { pfdToClose.close(); } catch (IOException ignored) {}
            }
            if (tempFileToDelete != null) {
                //noinspection ResultOfMethodCallIgnored
                tempFileToDelete.delete();
            }
            // textureEntry.release() calls FlutterJNI.unregisterTexture which
            // is @UiThread — post it to the main thread from here, so it still
            // runs after the render task but on the correct thread.
            mainHandler.post(textureEntry::release);
        });
        renderExecutor.shutdown();
    }

    // ── method channel handler ────────────────────────────────────────────────

    private void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "pageCount":
                result.success(pdfRenderer != null ? pdfRenderer.getPageCount() : 0);
                break;

            case "currentPage":
                result.success(currentPageIndex);
                break;

            case "setPage": {
                Integer newPage = call.argument("page");
                if (newPage == null || pdfRenderer == null
                        || newPage < 0 || newPage >= pdfRenderer.getPageCount()) {
                    result.success(false);
                    return;
                }
                final int prev       = currentPageIndex;
                final int target     = newPage;
                final int totalPages = pdfRenderer.getPageCount();
                currentPageIndex = target;
                renderExecutor.execute(() -> {
                    renderPage(target);
                    mainHandler.post(() -> {
                        // Always complete the Future — never leave Flutter waiting
                        // if dispose() ran while rendering.
                        if (!isDisposed) {
                            if (prev != target) {
                                channel.invokeMethod("onPageChanged",
                                        mapOf("page", target, "total", totalPages));
                            }
                            result.success(true);
                        } else {
                            result.success(false);
                        }
                    });
                });
                break;
            }

            case "updateSettings":
                // Swipe / fling / snap settings are managed by the Flutter
                // PageView widget; silently accept and ignore here.
                result.success(null);
                break;

            default:
                result.notImplemented();
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private void sendError(String msg) {
        mainHandler.post(() -> {
            if (!isDisposed) {
                channel.invokeMethod("onError", mapOf("error", msg));
            }
        });
    }

    private static String getString(Map<String, Object> m, String key) {
        Object v = m.get(key);
        return v instanceof String ? (String) v : null;
    }

    private static int getInt(Map<String, Object> m, String key, int def) {
        Object v = m.get(key);
        return v instanceof Number ? ((Number) v).intValue() : def;
    }

    private static boolean getBool(Map<String, Object> m, String key) {
        return getBool(m, key, false);
    }

    private static boolean getBool(Map<String, Object> m, String key, boolean def) {
        Object v = m.get(key);
        return v instanceof Boolean ? (Boolean) v : def;
    }

    private static Map<String, Object> mapOf(Object... kv) {
        Map<String, Object> m = new HashMap<>();
        for (int i = 0; i + 1 < kv.length; i += 2) {
            m.put((String) kv[i], kv[i + 1]);
        }
        return m;
    }
}
