#import <Foundation/Foundation.h>
#include <lua.h>

#ifdef MACOS_USE_BUNDLE
void set_macos_bundle_resources(lua_State *L)
{ @autoreleasepool
{
    NSString* resource_path = [[NSBundle mainBundle] resourcePath];
    lua_pushstring(L, [resource_path UTF8String]);
    lua_setglobal(L, "MACOS_RESOURCES");
}}
#endif

/* Thanks to mathewmariani, taken from his lite-macos github repository. */
void enable_momentum_scroll() {
  [[NSUserDefaults standardUserDefaults]
    setBool: YES
    forKey: @"AppleMomentumScrollSupported"];
}


#import <AppKit/AppKit.h>
#include <SDL3/SDL.h>

/* Hide the native title text and paint the title bar with the theme
   background so only the traffic lights remain. */
void macos_set_titlebar_color(SDL_Window *window, double r, double g, double b)
{ @autoreleasepool
{
    NSWindow *ns = (NSWindow *) SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!ns) return;
    ns.titlebarAppearsTransparent = YES;
    ns.titleVisibility = NSWindowTitleHidden;
    ns.backgroundColor = [NSColor colorWithSRGBRed: r green: g blue: b alpha: 1.0];
}}
