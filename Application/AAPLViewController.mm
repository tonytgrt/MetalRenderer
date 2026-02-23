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
    
    _view.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);

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
    [self _addBackgroundButton];
#endif
    
}

#if TARGET_OS_OSX
- (void)_addBackgroundButton
{
    NSButton *btn = [NSButton buttonWithTitle:@"Add Background"
    target:self
    action:@selector(_addBackgroundPressed:)];

    btn.translatesAutoresizingMaskIntoConstraints = NO;

    [_view addSubview:btn];

    [NSLayoutConstraint activateConstraints:@[
        [btn.topAnchor     constraintEqualToAnchor:_view.topAnchor     constant:8.0],
        [btn.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8.0],
    ]];
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
