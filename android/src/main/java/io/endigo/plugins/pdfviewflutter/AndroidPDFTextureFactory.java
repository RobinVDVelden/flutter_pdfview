package io.endigo.plugins.pdfviewflutter;

import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

/**
 * Listens on the {@code "plugins.endigo.io/pdfview_factory"} method channel and
 * creates / disposes {@link AndroidPDFTextureRenderer} instances on demand.
 *
 * <p>Mirrors the iOS {@code FLTPDFTextureFactory} class.  Because it registers
 * only a plain {@link MethodChannel} (and not a platform-view factory), it works
 * correctly on secondary Flutter engines that run inside a {@code Presentation}
 * dialog with an application context — the exact scenario that breaks the
 * platform-view approach.
 */
class AndroidPDFTextureFactory {

    private final TextureRegistry textureRegistry;
    private final BinaryMessenger messenger;
    private final MethodChannel factoryChannel;
    private final Map<String, AndroidPDFTextureRenderer> renderers = new HashMap<>();

    AndroidPDFTextureFactory(
            TextureRegistry textureRegistry,
            BinaryMessenger messenger) {
        this.textureRegistry = textureRegistry;
        this.messenger       = messenger;
        this.factoryChannel  = new MethodChannel(
                messenger, "plugins.endigo.io/pdfview_factory");
        factoryChannel.setMethodCallHandler(this::onMethodCall);
    }

    private void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "create": {
                @SuppressWarnings("unchecked")
                Map<String, Object> args = (Map<String, Object>) call.arguments;
                if (args == null) {
                    result.error("INVALID_ARGS", "Expected map arguments", null);
                    return;
                }
                AndroidPDFTextureRenderer renderer =
                        new AndroidPDFTextureRenderer(args, textureRegistry, messenger);
                renderers.put(renderer.channelName, renderer);

                Map<String, Object> response = new HashMap<>();
                response.put("textureId",    renderer.textureId);
                response.put("channelName",  renderer.channelName);
                response.put("renderWidth",  renderer.renderWidth);
                response.put("renderHeight", renderer.renderHeight);
                result.success(response);
                break;
            }

            case "dispose": {
                @SuppressWarnings("unchecked")
                Map<String, Object> args = (Map<String, Object>) call.arguments;
                if (args == null) {
                    result.error("INVALID_ARGS", "Expected map arguments", null);
                    return;
                }
                String channelName = (String) args.get("channelName");
                AndroidPDFTextureRenderer renderer = renderers.remove(channelName);
                if (renderer != null) renderer.dispose();
                result.success(null);
                break;
            }

            default:
                result.notImplemented();
        }
    }

    /** Disposes all live renderers and removes the factory channel handler. */
    void dispose() {
        factoryChannel.setMethodCallHandler(null);
        for (AndroidPDFTextureRenderer r : renderers.values()) r.dispose();
        renderers.clear();
    }
}
