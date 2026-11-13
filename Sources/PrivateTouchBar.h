//
//  PrivateTouchBar.h
//  TouchBarPal
//
//  Private AppKit entry points used by Pock / MTMR / BetterTouchTool to show a
//  Touch Bar that stays visible while other apps are frontmost.
//
//  These methods are not in the public SDK. They are guarded with
//  -respondsToSelector: and only used by the locally built, ad-hoc signed app.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSTouchBar (TouchBarPalPrivate)

+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
          systemTrayItemIdentifier:(nullable NSTouchBarItemIdentifier)identifier;

+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;

@end

@interface NSTouchBarItem (TouchBarPalPrivate)

+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;

@end

NS_ASSUME_NONNULL_END
