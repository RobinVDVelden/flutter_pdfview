package io.endigo.plugins.pdfviewflutter;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public class PDFViewFlutterPlugin implements FlutterPlugin {

    private AndroidPDFTextureFactory textureFactory;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
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
