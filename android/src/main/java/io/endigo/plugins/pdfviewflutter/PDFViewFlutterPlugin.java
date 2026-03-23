package io.endigo.plugins.pdfviewflutter;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public class PDFViewFlutterPlugin implements FlutterPlugin {

    private AndroidPDFTextureFactory textureFactory;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        // Keep the legacy platform-view factory registered for any code paths
        // that still use the old channel (Android only, requires an Activity).
        binding.getPlatformViewRegistry()
                .registerViewFactory(
                        "plugins.endigo.io/pdfview",
                        new PDFViewFactory(binding.getBinaryMessenger()));

        // Register the texture-based factory.  Unlike platform views, this
        // requires only a TextureRegistry and a BinaryMessenger, so it works
        // on both the main engine and secondary engines attached to a
        // Presentation (external display) via application context.
        textureFactory = new AndroidPDFTextureFactory(
                binding.getTextureRegistry(),
                binding.getBinaryMessenger());
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (textureFactory != null) {
            textureFactory.dispose();
            textureFactory = null;
        }
    }
}
