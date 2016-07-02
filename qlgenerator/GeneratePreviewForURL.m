#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import <QTKit/QTKit.h>

#include "generator.h"
#include "snapshotter.h"


// Undocumented options
const CFStringRef kQLPreviewOptionModeKey = CFSTR("QLPreviewMode");

typedef NS_ENUM(NSInteger, QLPreviewMode)
{
    kQLPreviewNoMode		= 0,
    kQLPreviewGetInfoMode	= 1,	// File -> Get Info and Column view in Finder
    kQLPreviewCoverFlowMode	= 2,	// Finder's Cover Flow view
    kQLPreviewUnknownMode	= 3,
    kQLPreviewSpotlightMode	= 4,	// Desktop Spotlight search popup bubble
    kQLPreviewQuicklookMode	= 5,	// File -> Quick Look in Finder (also qlmanage -p)
};


OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

/* -----------------------------------------------------------------------------
   Generate a preview for file

   This function's job is to create preview for designated file
   ----------------------------------------------------------------------------- */

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    // https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool {
        NSNumber *nsPreviewMode = ((__bridge NSDictionary *)options)[(__bridge NSString *) kQLPreviewOptionModeKey];
#ifdef DEBUG
        NSLog(@"QLVideo QLPreviewMode=%@ %@", nsPreviewMode, url);
#endif
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter || QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

        // Replace title string
        CFBundleRef myBundle = QLPreviewRequestGetGeneratorBundle(preview);
        CGSize size = [snapshotter displaySize];
        NSString *title, *channels;
        switch ([snapshotter channels])
        {
            case 0:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("🔇"),     NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 1:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("mono"),   NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 2:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("stereo"), NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 6:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("5.1"),    NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 7:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("6.1"),    NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 8:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("7.1"),    NULL, myBundle, "Audio channel info in Preview window title")); break;
            default:    // Quadraphonic, LCRS or something else
                channels = [NSString stringWithFormat:CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("%d🔉"), NULL, myBundle, "Audio channel info in Preview window title")),
                            [snapshotter channels]];
        }
        if ([snapshotter title])
            title = [NSString stringWithFormat:@"%@ (%d×%d %@)", [snapshotter title],
                     (int) size.width, (int) size.height, channels];
        else
            title = [NSString stringWithFormat:@"%@ (%d×%d %@)", [(__bridge NSURL *)url lastPathComponent],
                     (int) size.width, (int) size.height, channels];
        NSDictionary *properties = @{(NSString *) kQLPreviewPropertyDisplayNameKey: title};

        // The preview
        CGImageRef thePreview = NULL;

        // Prefer any cover art (if present) over a playable preview or static snapshot in Finder and Spotlight views
        QLPreviewMode previewMode = nsPreviewMode.intValue;
        if (previewMode == kQLPreviewGetInfoMode || previewMode == kQLPreviewSpotlightMode)
            thePreview = [snapshotter CreateCoverArtWithMode:CoverArtDefault];

        if (!thePreview)
        {
            if (hackedQLDisplay)
            {
                // If QTKit can play it, then hand it off to
                // /System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/LegacyMovie.qldisplay symlinked as Movie.qldisplay

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

                QTMovie *movie = [QTMovie movieWithAttributes:@{QTMovieURLAttribute:(__bridge NSURL *)url,
                                                                QTMovieOpenForPlaybackAttribute:@true,
                                                                QTMovieOpenAsyncOKAttribute:@false}
                                                        error:nil];
                if (movie)
                {
                    QTTrack *track = [movie tracksOfMediaType:QTMediaTypeVideo].firstObject;
                    if (track)
                    {
                        QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, (__bridge CFDictionaryRef) properties);
                        return kQLReturnNoError;    // early exit
                    }
                }
#pragma clang diagnostic pop
            }
            else
            {
                // If AVFoundation can play it, then hand it off to
                // /System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/Movie.qldisplay
                AVAsset *asset = [AVAsset assetWithURL:(__bridge NSURL *)url];
                if (asset)	// note: asset.playable==true doesn't imply there's a playable video track
                {
                    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
                    if (track && track.playable)
                    {
                        QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, (__bridge CFDictionaryRef) properties);
                        return kQLReturnNoError;    // early exit
                    }
                }
            }
            if (QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

            // kQLPreviewCoverFlowMode is broken for "non-native" files on Mavericks - the user gets a blank window
            // if they invoke QuickLook soon after. Presumably QuickLookUI is caching and getting confused?
            // If we return nothing we get called again with no QLPreviewMode option. This somehow forces QuickLookUI to
            // correctly call us with kQLPreviewQuicklookMode when the user later invokes QuickLook. What a crock.
            if (brokenQLCoverFlow && previewMode == kQLPreviewCoverFlowMode)
                return kQLReturnNoError;    // early exit

            // AVFoundation can't play it; prefer landscape cover art (if present) over a static snapshot
            if (previewMode == kQLPreviewQuicklookMode || previewMode == kQLPreviewPrefetchMode || previewMode == kQLPreviewNoMode)
                thePreview = [snapshotter CreateCoverArtWithMode:CoverArtLandscape];
        }

        // Fall back to generating a static snapshot
        if (!thePreview)
            thePreview = [snapshotter CreateSnapshotWithSize:size];
        if (!thePreview)
            return kQLReturnNoError;

        // display
        if (QLPreviewRequestIsCancelled(preview))
        {
            CGImageRelease(thePreview);
            return kQLReturnNoError;
        }
        CGContextRef context = QLPreviewRequestCreateContext(preview, CGSizeMake(CGImageGetWidth(thePreview), CGImageGetHeight(thePreview)), true, (__bridge CFDictionaryRef) properties);
        CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(thePreview), CGImageGetHeight(thePreview)), thePreview);
        QLPreviewRequestFlushContext(preview, context);
        CGContextRelease(context);
        CGImageRelease(thePreview);
    }
    return kQLReturnNoError;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
    // Implement only if supported
}
