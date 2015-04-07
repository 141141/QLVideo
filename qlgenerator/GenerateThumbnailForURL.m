#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>

#include "snapshotter.h"

// Undocumented properties
const CFStringRef kQLThumbnailPropertyIconFlavorKey = CFSTR("IconFlavor");

typedef NS_ENUM(NSInteger, QLThumbnailIconFlavor)
{
    kQLThumbnailIconPlainFlavor		= 0,
    kQLThumbnailIconShadowFlavor	= 1,
    kQLThumbnailIconBookFlavor		= 2,
    kQLThumbnailIconMovieFlavor		= 3,
    kQLThumbnailIconAddressFlavor	= 4,
    kQLThumbnailIconImageFlavor		= 5,
    kQLThumbnailIconGlossFlavor		= 6,
    kQLThumbnailIconSlideFlavor		= 7,
    kQLThumbnailIconSquareFlavor	= 8,
    kQLThumbnailIconBorderFlavor	= 9,
    // = 10,
    kQLThumbnailIconCalendarFlavor	= 11,
    kQLThumbnailIconPatternFlavor	= 12,
};


OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);

/* -----------------------------------------------------------------------------
    Generate a thumbnail for file

   This function's job is to create thumbnail for designated file as fast as possible
   ----------------------------------------------------------------------------- */

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    // https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool {
#ifdef DEBUG
        NSLog(@"QLVideo options=%@ size=%dx%d %@", options, (int) maxSize.width, (int) maxSize.height, url);
#endif
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter) return kQLReturnNoError;

        // Use cover art if present
        CGImageRef snapshot = [snapshotter CreateCoverArtWithMode:CoverArtThumbnail];
        if (snapshot)
        {
            NSDictionary *properties = @{(__bridge NSString *) kQLThumbnailPropertyIconFlavorKey: @(kQLThumbnailIconGlossFlavor) }; // suppress letterbox mattes
            QLThumbnailRequestSetImage(thumbnail, snapshot, (__bridge CFDictionaryRef) properties);
            CGImageRelease(snapshot);
            return kQLReturnNoError;
        }

        // determine thumbnail size (scale up if video is tiny)
        NSNumber *scaleFactor = ((__bridge NSDictionary *) options)[(__bridge NSString *) kQLThumbnailOptionScaleFactorKey];	// can be >1 on Retina displays
        CGSize desired = scaleFactor.boolValue ? CGSizeMake(maxSize.width * scaleFactor.floatValue, maxSize.height * scaleFactor.floatValue) : CGSizeMake(maxSize.width, maxSize.height);
        CGSize size = [snapshotter displaySize];
        CGSize scaled;
        if (size.width/desired.width > size.height/desired.height)
            scaled = CGSizeMake(desired.width, round(size.height * desired.width / size.width));
        else
            scaled = CGSizeMake(round(size.width * desired.height / size.height), desired.height);

        if (QLThumbnailRequestIsCancelled(thumbnail)) return kQLReturnNoError;
        snapshot = [snapshotter CreateSnapshotWithSize:scaled];
        if (!snapshot) return kQLReturnNoError;
        
        QLThumbnailRequestSetImage(thumbnail, snapshot, NULL);
        CGImageRelease(snapshot);
        return kQLReturnNoError;
    }
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{
    // Implement only if supported
}
