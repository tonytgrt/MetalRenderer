/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Implementation of the cross-platform view controller.
*/

#import "AAPLViewController.h"
#import "AAPLRenderer.h"


@implementation AAPLViewController
{
    MTKView *_view;

    AAPLRenderer *_renderer;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _view = (MTKView *)self.view;
    
    _view.enableSetNeedsDisplay = YES;
    
    _view.device = MTLCreateSystemDefaultDevice();
    
    _view.clearColor = MTLClearColorMake(0, 0, 0, 1.0);

    _renderer = [[AAPLRenderer alloc] initWithMetalKitView:_view];

    if(!_renderer)
    {
        NSLog(@"Renderer initialization failed");
        return;
    }

    // Initialize the renderer with the view size.
    [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];

    
    _view.delegate = _renderer;
    
#if TARGET_OS_OSX
    [self _addMenuBarItem];
#endif
    
}

#if TARGET_OS_OSX
- (void)_addMenuBarItem
{
    // Build a "Background" top-level menu and insert it after "Edit".
    //
    // [NSApp mainMenu] is the shared NSMenu that drives the entire macOS menu bar.
    // Each top-level NSMenuItem holds a submenu; the submenu's title is what appears
    // in the bar.  We insert one new top-level item containing a single action item.

    NSMenu *bgMenu = [[NSMenu alloc] initWithTitle:@"Background"];

    // target:nil  →  AppKit walks the responder chain at action time to find the
    // first object that responds to _addBackgroundPressed:.  Because
    // AAPLViewController is the key window's content view controller it is always
    // in the chain, so no explicit target reference is needed.
    [bgMenu addItemWithTitle:@"Add Background…"
                     action:@selector(_addBackgroundPressed:)
              keyEquivalent:@""];

    NSMenuItem *topItem = [[NSMenuItem alloc] initWithTitle:@"Background"
                                                     action:nil
                                              keyEquivalent:@""];
    topItem.submenu = bgMenu;

    NSMenu  *mainMenu  = [NSApp mainMenu];
    NSInteger editIdx  = [mainMenu indexOfItemWithTitle:@"Edit"];
    NSInteger insertAt = (editIdx >= 0) ? editIdx + 1 : mainMenu.numberOfItems;
    [mainMenu insertItem:topItem atIndex:insertAt];
}

- (void)_addBackgroundPressed:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];

    // NSImage.imageTypes returns the UTI strings for every format AppKit can
    // decode (PNG, JPEG, HEIC, TIFF, GIF, BMP, …).  Using this avoids a hard
    // dependency on UniformTypeIdentifiers.framework.
    panel.allowedFileTypes       = NSImage.imageTypes;
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories    = NO;
    panel.message                 = @"Choose a background image";

    // beginSheetModalForWindow:completionHandler: shows the picker as a sheet
    // attached to the window (macOS HIG standard).  The completion handler is
    // called on the main thread, so Metal resource creation is safe here.
    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK)
        {
            [_renderer loadBackgroundFromURL:panel.URL];

            // With enableSetNeedsDisplay = YES the view only redraws when marked
            // dirty.  Force a redraw so the new texture appears immediately.
            [_view setNeedsDisplay:YES];
        }
    }];
}

#endif

@end
