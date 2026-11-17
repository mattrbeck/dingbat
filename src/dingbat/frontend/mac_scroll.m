// Scrolling in the game's window as a Mac app scrolls: a trackpad's own
// point deltas, momentum included, rather than SDL's line counts (which
// ImGui turns into five lines of text each). The window's scroll events are
// taken before SDL sees them; mac_scroll.nim hands the sum to ImGui.

#import <Cocoa/Cocoa.h>

static NSWindow *game;
static id monitor;
static double px_x, px_y, lines_x, lines_y;
static int touching;  // fingers on the trackpad, not yet lifted

static void add(NSEvent *e) {
  if (e.phase & (NSEventPhaseMayBegin | NSEventPhaseBegan | NSEventPhaseChanged)) touching = 1;
  if (e.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) touching = 0;
  if (e.momentumPhase != NSEventPhaseNone) touching = 0;
  if (e.hasPreciseScrollingDeltas) {
    px_x += e.scrollingDeltaX;
    px_y += e.scrollingDeltaY;
  } else {
    lines_x += e.scrollingDeltaX;
    lines_y += e.scrollingDeltaY;
  }
}

void dbsc_install(void *nswindow) {
  game = (__bridge NSWindow *)nswindow;
  if (monitor) return;
  monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                                  handler:^NSEvent *(NSEvent *e) {
    if (game == nil || e.window != game) return e;
    add(e);
    return nil;
  }];
}

int dbsc_take(double *px, double *py, double *lx, double *ly) {
  // Points (trackpads, Magic Mouse) and lines (wheel mice) since the last take
  int any = px_x != 0 || px_y != 0 || lines_x != 0 || lines_y != 0;
  *px = px_x; *py = px_y; *lx = lines_x; *ly = lines_y;
  px_x = px_y = lines_x = lines_y = 0;
  return any;
}

int dbsc_touching(void) { return touching; }

int dbsc_feed(double dy, int precise) {
  // For the GUI driver: a scroll as the trackpad (points) or a wheel mouse
  // (lines) sends it, through the same path. 1 when macOS marked it precise.
  CGEventRef c = CGEventCreateScrollWheelEvent2(
      NULL, precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 1, (int32_t)dy, 0, 0);
  if (precise) CGEventSetDoubleValueField(c, kCGScrollWheelEventPointDeltaAxis1, dy);
  NSEvent *e = [NSEvent eventWithCGEvent:c];
  CFRelease(c);
  add(e);
  return e.hasPreciseScrollingDeltas ? 1 : 0;
}
