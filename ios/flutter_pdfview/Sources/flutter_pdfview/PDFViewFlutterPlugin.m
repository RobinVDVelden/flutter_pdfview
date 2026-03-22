#import "./include/flutter_pdfview/PDFViewFlutterPlugin.h"
#import "./include/flutter_pdfview/FlutterPDFView.h"

// Import the Swift-generated ObjC interface for FLTPDFTextureFactory.
#if __has_include(<flutter_pdfview/flutter_pdfview-Swift.h>)
#import <flutter_pdfview/flutter_pdfview-Swift.h>
#else
#import "flutter_pdfview-Swift.h"
#endif

@implementation FLTPDFViewFlutterPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    // Keep the legacy platform-view factory registered (used by Android; harmless on iOS).
    FLTPDFViewFactory* pdfViewFactory = [[FLTPDFViewFactory alloc] initWithMessenger:registrar.messenger];
    [registrar registerViewFactory:pdfViewFactory withId:@"plugins.endigo.io/pdfview"];

    // Register the texture-based factory for iOS.  The factory creates a
    // MethodChannel on "plugins.endigo.io/pdfview_factory" and handles
    // "create" / "dispose" calls from the Dart side.
    FLTPDFTextureFactory *textureFactory = [[FLTPDFTextureFactory alloc]
        initWithTextureRegistry:[registrar textures]
                      messenger:registrar.messenger];
    // publish: retains the factory for the lifetime of the plugin.
    [registrar publish:textureFactory];
}
@end
