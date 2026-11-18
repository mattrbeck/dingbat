// The macOS menu bar for menu_model's menus (driven from mac_menu.nim), and
// the native pieces around it: the Open panel, the system's recent documents,
// the title bar's document icon, the About panel.
//
// Item state is asked of the Nim side when AppKit validates an item (before
// a menu opens and before a key equivalent fires), so a shortcut never acts
// on a state the menu last showed. Dynamic menus are rebuilt each time they
// open (menuNeedsUpdate:). A chosen item is only queued (dingbat_menu_action):
// AppKit calls here while it tracks a menu, inside SDL's event pump.

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

extern void dingbat_menu_populate(void *menu, int top);
extern int dingbat_menu_state(int cmd, int arg, int *checked);
extern void dingbat_menu_action(int cmd, int arg);
extern void dingbat_open_panel_done(const char *path);
extern void dingbat_main_loop_blocked(void);

// menu_model.ShownKey
enum { SK_NONE, SK_TAB, SK_SHIFT_TAB, SK_F12 };
// Virtual key codes (HIToolbox kVK_Tab, kVK_F12)
enum { VK_TAB = 48, VK_F12 = 111 };

@interface DbmTag : NSObject
@property int cmd, arg, shown;
@property SEL edit;   // an Edit item's standard action, for a native field
@end
@implementation DbmTag
@end

@interface DbmMenu : NSMenu
@property int top;
@end
@implementation DbmMenu
@end

@interface DbmSlider : NSView
@property (strong) NSSlider *slider;
@property (strong) NSTextField *pct;
@property int cmd, done;
@end

@interface DbmController : NSObject <NSMenuDelegate>
@property (copy) NSString *version;
@end

static DbmController *controller;
static __weak NSWindow *game_window;   // SDL's: its text fields are ImGui's

// The game's window has the keyboard (or no window has: the GUI driver's
// hidden one)
static BOOL game_has_keys(void) {
  return NSApp.keyWindow == nil || NSApp.keyWindow == game_window;
}

@implementation DbmController

- (void)menuNeedsUpdate:(NSMenu *)menu {
  if (![menu isKindOfClass:DbmMenu.class]) return;
  [menu removeAllItems];
  dingbat_menu_populate((__bridge void *)menu, ((DbmMenu *)menu).top);
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  DbmTag *t = item.representedObject;
  if (![t isKindOfClass:DbmTag.class]) return YES;
  // Edit: the game's window asks ImGui; any other (Settings, a panel) asks
  // whoever in its responder chain takes the action
  if (t.edit && !game_has_keys())
    return [NSApp targetForAction:t.edit to:nil from:item] != nil;
  int checked = 0;
  BOOL on = dingbat_menu_state(t.cmd, t.arg, &checked) != 0;
  if (item.submenu == nil)
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
  return on;
}

- (void)dbmAction:(NSMenuItem *)item {
  DbmTag *t = item.representedObject;
  NSEvent *e = NSApp.currentEvent;
  if (e.type == NSEventTypeKeyDown) {
    // SDL's key handler takes these keys itself; the item only shows them
    if ((t.shown == SK_TAB || t.shown == SK_SHIFT_TAB) && e.keyCode == VK_TAB) return;
    if (t.shown == SK_F12 && e.keyCode == VK_F12) return;
    // A held shortcut fires once, as SDL's shortcut keys did
    if (e.isARepeat && item.keyEquivalent.length > 0) return;
  }
  dingbat_menu_action(t.cmd, t.arg);
}

- (void)dbmEdit:(NSMenuItem *)item {
  DbmTag *t = item.representedObject;
  if (!game_has_keys()) {
    [NSApp sendAction:t.edit to:nil from:item];
    return;
  }
  // Its own shortcut reached ImGui through SDL already
  NSEvent *e = NSApp.currentEvent;
  if (e.type == NSEventTypeKeyDown &&
      [e.charactersIgnoringModifiers.lowercaseString isEqualToString:item.keyEquivalent.lowercaseString])
    return;
  dingbat_menu_action(t.cmd, 0);
}

- (void)dbmSubmenu:(id)sender {}

- (void)dbmAbout:(id)sender {
  NSMutableDictionary *o = [NSMutableDictionary dictionary];
  // An unbundled build has no Info.plist version
  if (NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] == nil && self.version)
    o[NSAboutPanelOptionApplicationVersion] = self.version;
  NSDictionary *attrs = @{
    NSLinkAttributeName : [NSURL URLWithString:@"https://dingbat.gg"],
    NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
  };
  o[NSAboutPanelOptionCredits] = [[NSAttributedString alloc] initWithString:@"dingbat.gg"
                                                                 attributes:attrs];
  [NSApp orderFrontStandardAboutPanelWithOptions:o];
}

- (void)dbmSlid:(NSSlider *)s {
  DbmSlider *v = (DbmSlider *)s.superview;
  int value = (int)lround(s.doubleValue);
  v.pct.stringValue = [NSString stringWithFormat:@"%d%%", value];
  dingbat_menu_action(v.cmd, value);
  if (NSApp.currentEvent.type == NSEventTypeLeftMouseUp) dingbat_menu_action(v.done, value);
}

@end

@implementation DbmSlider
@end

static NSString *str(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }

// A menu title: the shared menus write "..." (ImGui's font has no ellipsis)
static NSString *title(const char *s) {
  return [str(s) stringByReplacingOccurrencesOfString:@"..." withString:@"…"];
}

static NSMenuItem *tagged(NSString *title, SEL action, int cmd, int arg) {
  NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  it.target = controller;
  DbmTag *t = [DbmTag new];
  t.cmd = cmd;
  t.arg = arg;
  it.representedObject = t;
  return it;
}

void dbm_install(const char **titles, const int *fixed, int n, const char *version,
                 void *sdl_window) {
  if (controller == nil) controller = [DbmController new];
  // Video has its own Enter Full Screen: AppKit is not to add a second
  [NSUserDefaults.standardUserDefaults registerDefaults:@{@"NSFullScreenMenuItemEverywhere" : @NO}];
  game_window = (__bridge NSWindow *)sdl_window;
  controller.version = str(version);
  NSMenu *bar = [NSMenu new];
  for (int i = 0; i < n; i++) {
    NSMenuItem *top = [NSMenuItem new];
    NSMenu *m;
    if (fixed[i]) {
      m = [[NSMenu alloc] initWithTitle:str(titles[i])];
    } else {
      DbmMenu *d = [[DbmMenu alloc] initWithTitle:str(titles[i])];
      d.top = i;
      d.delegate = controller;
      m = d;
    }
    top.submenu = m;
    [bar addItem:top];
    dingbat_menu_populate((__bridge void *)m, i);
    if ([m.title isEqualToString:@"Window"]) NSApp.windowsMenu = m;
    if ([m.title isEqualToString:@"Help"]) NSApp.helpMenu = m;
  }
  NSApp.mainMenu = bar;
}

void dbm_add_action(void *menu, const char *name, int cmd, int arg, const char *key, int alt,
                    int shown) {
  NSMenuItem *it = tagged(title(name), @selector(dbmAction:), cmd, arg);
  ((DbmTag *)it.representedObject).shown = shown;
  if (key && *key) {
    it.keyEquivalent = str(key);
    it.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | (alt ? NSEventModifierFlagOption : 0);
  } else if (shown == SK_TAB || shown == SK_SHIFT_TAB) {
    it.keyEquivalent = @"\t";
    it.keyEquivalentModifierMask = shown == SK_SHIFT_TAB ? NSEventModifierFlagShift : 0;
  } else if (shown == SK_F12) {
    unichar f12 = NSF12FunctionKey;
    it.keyEquivalent = [NSString stringWithCharacters:&f12 length:1];
    it.keyEquivalentModifierMask = 0;
  }
  [(__bridge NSMenu *)menu addItem:it];
}

void *dbm_add_submenu(void *menu, const char *name, int cmd) {
  NSMenuItem *it = tagged(title(name), @selector(dbmSubmenu:), cmd, 0);
  NSMenu *sub = [[NSMenu alloc] initWithTitle:title(name)];
  it.submenu = sub;
  [(__bridge NSMenu *)menu addItem:it];
  return (__bridge void *)sub;
}

void dbm_add_edit(void *menu, const char *name, int cmd, const char *selector, const char *key,
                  int shift) {
  NSMenuItem *it = tagged(title(name), @selector(dbmEdit:), cmd, 0);
  ((DbmTag *)it.representedObject).edit = NSSelectorFromString(str(selector));
  it.keyEquivalent = str(key);
  it.keyEquivalentModifierMask = NSEventModifierFlagCommand | (shift ? NSEventModifierFlagShift : 0);
  [(__bridge NSMenu *)menu addItem:it];
}

void dbm_add_separator(void *menu) { [(__bridge NSMenu *)menu addItem:NSMenuItem.separatorItem]; }

void dbm_add_system(void *menu, const char *title, const char *selector, const char *key,
                    int alt, int shift) {
  NSMenu *m = (__bridge NSMenu *)menu;
  NSString *sel = str(selector);
  NSMenuItem *it;
  if ([sel isEqualToString:@"services"]) {
    it = [[NSMenuItem alloc] initWithTitle:str(title) action:nil keyEquivalent:@""];
    NSMenu *services = [[NSMenu alloc] initWithTitle:str(title)];
    it.submenu = services;
    NSApp.servicesMenu = services;
  } else if ([sel isEqualToString:@"about"]) {
    it = [[NSMenuItem alloc] initWithTitle:str(title) action:@selector(dbmAbout:) keyEquivalent:@""];
    it.target = controller;
  } else {
    it = [[NSMenuItem alloc] initWithTitle:str(title)
                                    action:NSSelectorFromString(sel)
                             keyEquivalent:str(key)];
    if (key && *key)
      it.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                     (alt ? NSEventModifierFlagOption : 0) |
                                     (shift ? NSEventModifierFlagShift : 0);
  }
  [m addItem:it];
}

void dbm_add_slider(void *menu, const char *title, int cmd, int done, int lo, int hi, int value) {
  DbmSlider *v = [[DbmSlider alloc] initWithFrame:NSMakeRect(0, 0, 250, 26)];
  v.cmd = cmd;
  v.done = done;
  NSTextField *label = [NSTextField labelWithString:str(title)];
  label.frame = NSMakeRect(20, 4, 56, 17);
  NSSlider *s = [NSSlider sliderWithValue:value minValue:lo maxValue:hi
                                   target:controller action:@selector(dbmSlid:)];
  s.frame = NSMakeRect(78, 3, 124, 20);
  s.continuous = YES;
  NSTextField *pct = [NSTextField labelWithString:[NSString stringWithFormat:@"%d%%", value]];
  pct.frame = NSMakeRect(206, 4, 40, 17);
  pct.textColor = NSColor.secondaryLabelColor;
  [v addSubview:label];
  [v addSubview:s];
  [v addSubview:pct];
  v.slider = s;
  v.pct = pct;
  // An item without an action would be greyed out, its slider with it
  NSMenuItem *it = tagged(str(title), @selector(dbmSubmenu:), 0, 0);
  it.view = v;
  [(__bridge NSMenu *)menu addItem:it];
}

// ── Beside the menus ──

void dbm_open_panel(void *nswindow, const char *exts_csv, const char *dir, const char *message) {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  if (message && *message) p.message = title(message);
  p.canChooseFiles = YES;
  p.canChooseDirectories = NO;
  p.allowsMultipleSelection = NO;
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (NSString *ext in [str(exts_csv) componentsSeparatedByString:@","]) {
    UTType *t = [UTType typeWithFilenameExtension:ext];
    if (t) [types addObject:t];
  }
  p.allowedContentTypes = types;
  if (dir && *dir) p.directoryURL = [NSURL fileURLWithPath:str(dir) isDirectory:YES];
  void (^done)(NSModalResponse) = ^(NSModalResponse r) {
    dingbat_open_panel_done(r == NSModalResponseOK ? p.URL.fileSystemRepresentation : NULL);
  };
  NSWindow *w = (__bridge NSWindow *)nswindow;
  // A sheet keeps the main loop (and the game behind it) running
  if (w && w.visible) [p beginSheetModalForWindow:w completionHandler:done];
  else [p beginWithCompletionHandler:done];
}

int dbm_close_key_window(void) {
  NSWindow *k = NSApp.keyWindow;
  if (k == nil || k == game_window) return 0;
  [k performClose:nil];
  return 1;
}

void dbm_note_recent(const char *path) {
  [NSDocumentController.sharedDocumentController
      noteNewRecentDocumentURL:[NSURL fileURLWithPath:str(path)]];
}

void dbm_clear_recents(void) { [NSDocumentController.sharedDocumentController clearRecentDocuments:nil]; }

void dbm_set_document(void *nswindow, const char *path) {
  NSWindow *w = (__bridge NSWindow *)nswindow;
  w.representedURL = (path && *path) ? [NSURL fileURLWithPath:str(path)] : nil;
}

void dbm_free_aspect(void *nswindow) {
  // SDL frees the ratio with a 0:0 content aspect ratio, which AppKit does
  // not take as none; resize increments of 1 are its documented reset
  ((__bridge NSWindow *)nswindow).contentResizeIncrements = NSMakeSize(1, 1);
}

// While AppKit runs its own loop (a menu open, a live resize, a modal panel)
// the main loop stands still; this timer runs only in those modes.
void dbm_watch_blocked(void) {
  NSTimer *t = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
    dingbat_main_loop_blocked();
  }];
  [NSRunLoop.mainRunLoop addTimer:t forMode:NSEventTrackingRunLoopMode];
  [NSRunLoop.mainRunLoop addTimer:t forMode:NSModalPanelRunLoopMode];
}

void dbm_refresh(void) {
  // Key equivalents are matched against the items a menu holds, which
  // AppKit does not rebuild first: a menu whose shortcuts changed (Cmd+W,
  // Close Game or Close Window) is rebuilt when they change
  for (NSMenuItem *top in NSApp.mainMenu.itemArray)
    if ([top.submenu isKindOfClass:DbmMenu.class]) [controller menuNeedsUpdate:top.submenu];
}

// ── For the GUI driver (gui_driver.nim) ──

// The main loop held in the run loop's menu-tracking mode for `ms`, as
// while a menu is open
void dbm_track_for(int ms) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:ms / 1000.0];
  while (until.timeIntervalSinceNow > 0)
    CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode,
                       until.timeIntervalSinceNow, false);
}

int dbm_perform_key(const char *chars, int shift) {
  NSEventModifierFlags f = NSEventModifierFlagCommand | (shift ? NSEventModifierFlagShift : 0);
  NSString *c = str(chars);
  NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                location:NSZeroPoint
                           modifierFlags:f
                               timestamp:0
                            windowNumber:0
                                 context:nil
                              characters:c
             charactersIgnoringModifiers:c
                               isARepeat:NO
                                 keyCode:0];
  return [NSApp.mainMenu performKeyEquivalent:e] ? 1 : 0;
}

static void refresh(NSMenu *m) {
  if ([m isKindOfClass:DbmMenu.class]) [controller menuNeedsUpdate:m];
  [m update];  // validation: enabled and ticked as they would show
}

static void dump(NSMenu *m, int depth, NSMutableString *out) {
  refresh(m);
  for (NSMenuItem *it in m.itemArray) {
    for (int i = 0; i < depth; i++) [out appendString:@"  "];
    if (it.separatorItem) {
      [out appendString:@"---\n"];
      continue;
    }
    [out appendString:it.title];
    if (it.view && [it.view isKindOfClass:DbmSlider.class])
      [out appendFormat:@" [slider %d]", (int)lround(((DbmSlider *)it.view).slider.doubleValue)];
    if (it.state == NSControlStateValueOn) [out appendString:@" [x]"];
    if (!it.enabled) [out appendString:@" [off]"];
    if (it.keyEquivalent.length > 0) {
      NSEventModifierFlags f = it.keyEquivalentModifierMask;
      NSString *k = it.keyEquivalent;
      if ([k isEqualToString:@"\t"]) k = @"Tab";
      else if ([k characterAtIndex:0] == NSF12FunctionKey) k = @"F12";
      else k = k.uppercaseString;
      [out appendFormat:@" [%@%@%@%@]", (f & NSEventModifierFlagShift) ? @"Shift+" : @"",
                        (f & NSEventModifierFlagOption) ? @"Opt+" : @"",
                        (f & NSEventModifierFlagCommand) ? @"Cmd+" : @"", k];
    }
    [out appendString:@"\n"];
    if (it.submenu && it.submenu != NSApp.servicesMenu) dump(it.submenu, depth + 1, out);
  }
}

char *dbm_dump(void) {
  NSMutableString *out = [NSMutableString string];
  for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
    [out appendFormat:@"%@\n", top.submenu.title];
    dump(top.submenu, 1, out);
  }
  return strdup(out.UTF8String);
}

int dbm_pick(const char *path) {
  // 1 chosen, 0 no such item, -1 greyed out
  NSArray<NSString *> *parts = [title(path) componentsSeparatedByString:@">"];
  NSMenu *m = nil;
  for (NSMenuItem *top in NSApp.mainMenu.itemArray)
    if ([top.submenu.title isEqualToString:parts[0]]) m = top.submenu;
  for (NSUInteger i = 1; m && i < parts.count; i++) {
    refresh(m);
    NSInteger idx = [m indexOfItemWithTitle:parts[i]];
    if (idx < 0) return 0;
    NSMenuItem *it = [m itemAtIndex:idx];
    if (!it.enabled) return -1;
    if (i + 1 == parts.count) {
      [m performActionForItemAtIndex:idx];
      return 1;
    }
    m = it.submenu;
  }
  return 0;
}
