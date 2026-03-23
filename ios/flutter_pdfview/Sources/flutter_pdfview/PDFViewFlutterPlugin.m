#import "./include/flutter_pdfview/PDFViewFlutterPlugin.h"

// Import the Swift-generated ObjC interface for FLTPDFTextureFactory.
#if __has_include(<flutter_pdfview/flutter_pdfview-Swift.h>)
#import <flutter_pdfview/flutter_pdfview-Swift.h>
#else
#import "flutter_pdfview-Swift.h"
#endif

@implementation FLTPDFViewFlutterPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FLTPDFTextureFactory *textureFactory = [[FLTPDFTextureFactory alloc]
        initWithTextureRegistry:[registrar textures]
                      messenger:registrar.messenger];
    [registrar publish:textureFactory];
}
@end
