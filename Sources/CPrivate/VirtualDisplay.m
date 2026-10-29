#import "CPrivate.h"

// Private CoreGraphics classes (macOS 11+). Declared here because there are
// no public headers. Chromium's ui/display/mac/test/virtual_display_util_mac.mm
// is the best public reference for this API.
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation BCUVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned)width
                               height:(unsigned)height
                                  ppi:(double)ppi
                               serial:(unsigned)serial {
    if (!(self = [super init])) return nil;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !displayClass) return nil;

    CGVirtualDisplayDescriptor *descriptor = [descriptorClass new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    // Retina: `width` x `height` points backed by twice the pixels, so the
    // live preview stays sharp on the user's Retina screen.
    descriptor.maxPixelsWide = width * 2;
    descriptor.maxPixelsHigh = height * 2;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / ppi, height * 25.4 / ppi);
    // macOS 14+ needs a non-zero vendor and a serial unique per display.
    descriptor.serialNum = serial;
    descriptor.productID = 0xBC01;
    descriptor.vendorID = 0xBC0F;
    descriptor.terminationHandler = ^(id a, id b) {
        NSLog(@"[bcu] virtual display terminated");
    };

    _display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!_display) return nil;

    CGVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI = 1;  // Screenshots for the agent are scaled back to 1 pixel per point.
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60]];
    if (![_display applySettings:settings]) {
        _display = nil;
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? _display.displayID : kCGNullDirectDisplay;
}

- (void)invalidate {
    _display = nil;
}

@end
