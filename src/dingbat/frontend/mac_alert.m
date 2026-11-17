// The app's notices as alerts (driven from mac_alert.nim): a sheet on the
// game's window, the notice's first paragraph as its title, the rest and the
// hint below, one OK that Return, Enter and Escape all press. Silent, as the
// web's and iOS's notices are. The answer is only queued (dingbat_alert_answered):
// AppKit calls back inside SDL's event pump.
//
// A hidden game window (the GUI driver's) cannot carry a sheet: the alert is
// built but only `asking`, and dba_answer / dba_key stand in for the click.

#import <Cocoa/Cocoa.h>

extern void dingbat_alert_answered(int serial);

// HIToolbox kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape
enum { VK_RETURN = 36, VK_KEYPAD_ENTER = 76, VK_ESCAPE = 53 };

static NSAlert *shown;
static __weak NSWindow *parent;   // the window its sheet is on (or queued for)
static int shown_serial;
static BOOL asking;
static id key_monitor;

static NSString *str(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }

static void forget(void) {
  if (key_monitor) [NSEvent removeMonitor:key_monitor];
  key_monitor = nil;
  shown = nil;
  asking = NO;
}

static void answer(void) {
  if (shown == nil) return;
  int serial = shown_serial;
  if (asking) {
    forget();
    dingbat_alert_answered(serial);
  } else {
    [parent endSheet:shown.window returnCode:NSAlertFirstButtonReturn];
  }
}

static BOOL is_ok_key(NSEvent *e) {
  return e.keyCode == VK_RETURN || e.keyCode == VK_KEYPAD_ENTER || e.keyCode == VK_ESCAPE;
}

void dba_close(void) {
  // Gone without an answer: the notice was cleared, or another takes its place
  if (shown && !asking) [parent endSheet:shown.window returnCode:NSModalResponseAbort];
  forget();
}

void dba_show(void *nswindow, int serial, const char *text, const char *hint) {
  dba_close();
  NSAlert *a = [NSAlert new];
  // The first paragraph is the title; any more goes above the hint
  NSString *title = str(text), *more = @"", *h = str(hint);
  NSRange br = [title rangeOfString:@"\n\n"];
  if (br.location != NSNotFound) {
    more = [title substringFromIndex:NSMaxRange(br)];
    title = [title substringToIndex:br.location];
  }
  a.messageText = title;
  a.informativeText = more.length && h.length ? [NSString stringWithFormat:@"%@\n\n%@", more, h]
                                              : (more.length ? more : h);
  [a addButtonWithTitle:@"OK"];
  shown = a;
  shown_serial = serial;
  // A single OK takes Return by itself; Escape means it too
  key_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                      handler:^NSEvent *(NSEvent *e) {
    BOOL ours = asking || (shown && NSApp.keyWindow == shown.window);
    if (!ours || !is_ok_key(e) || e.isARepeat) return e;
    answer();
    return nil;
  }];
  NSWindow *w = (__bridge NSWindow *)nswindow;
  if (w && w.visible) {
    parent = w;
    [a beginSheetModalForWindow:w completionHandler:^(NSModalResponse r) {
      if (shown_serial != serial) return;   // a later alert took its place
      forget();
      if (r == NSAlertFirstButtonReturn) dingbat_alert_answered(serial);
    }];
  } else {
    [a layout];
    asking = YES;
  }
}

// ── For the GUI driver (gui_driver.nim) ──

char *dba_dump(void) {
  if (shown == nil) return strdup("none\n");
  NSString *s = [NSString stringWithFormat:@"%@\n%@\n%@\n", asking ? @"asking" : @"sheet",
                                           shown.messageText, shown.informativeText];
  return strdup(s.UTF8String);
}

int dba_answer(void) {
  if (shown == nil) return 0;
  answer();
  return 1;
}

int dba_key(int key_code) {
  // A key pressed, as AppKit's queue delivers it: 1 the alert took it
  if (shown == nil) return 0;
  NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                               timestamp:0 windowNumber:0 context:nil
                              characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO
                                 keyCode:(unsigned short)key_code];
  [NSApp postEvent:e atStart:NO];
  return 1;
}

int dba_snapshot(const char *path) {
  // The alert as drawn, on screen or not. Its labels are layer-drawn, which
  // cacheDisplayInRect leaves out: the layer tree is rendered instead.
  if (shown == nil) return 0;
  NSView *v = shown.window.contentView;
  [v layoutSubtreeIfNeeded];
  [v displayIfNeeded];
  CGFloat scale = shown.window.backingScaleFactor;
  NSSize sz = v.bounds.size;
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(sz.width * scale)
                    pixelsHigh:(NSInteger)(sz.height * scale) bitsPerSample:8 samplesPerPixel:4
                      hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                   bytesPerRow:0 bitsPerPixel:0];
  NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  CGContextRef c = g.CGContext;
  CGContextSetFillColorWithColor(c, NSColor.windowBackgroundColor.CGColor);
  CGContextFillRect(c, CGRectMake(0, 0, sz.width * scale, sz.height * scale));
  CGContextScaleCTM(c, scale, scale);
  [v.layer renderInContext:c];
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return [png writeToFile:str(path) atomically:YES] ? 1 : 0;
}
