// The native macOS Settings window for config_editor's tabs (driven from
// mac_settings.nim): one tab per SettingsTab, one row of AppKit controls per
// SettingRow. Each refresh walks the rows again; a tab whose shape
// (settings_model.signature) is unchanged is updated in place, so a field
// being typed in keeps its focus, and only a changed shape rebuilds it.
//
// Controls change the edit through the Nim side at once; Apply, OK, Revert,
// Reset to Defaults and closing are queued for the main loop
// (dingbat_settings_action), which also asks the questions they need.
//
// While a binding waits for its key the window keeps every key to itself and
// reports the key's release as an SDL scancode: SDL sends no key presses
// while none of its own windows has the keyboard.

#import <Cocoa/Cocoa.h>
#include <SDL3/SDL_scancode.h>

extern void dingbat_settings_set(int id, int value, const char *text);
extern void dingbat_settings_activate(int id, int arg);
extern void dingbat_settings_tab(int tab);
extern void dingbat_settings_action(int action);
extern int dingbat_settings_capturing(void);
extern void dingbat_settings_key(int scancode);

// settings_model.RowKind
enum { RK_LABEL, RK_TOGGLE, RK_CHOICE, RK_PATH, RK_NOTE, RK_TEXT, RK_SEPARATOR,
       RK_FOLD, RK_PRESET, RK_BINDING, RK_BUTTON };
// mac_settings.nim's actions
enum { SA_APPLY, SA_REVERT, SA_OK, SA_RESET_DEFAULTS, SA_CLOSE, SA_APPLY_CLOSE,
       SA_DISCARD_CLOSE };

enum { MAX_TABS = 8, CONTENT_W = 540 };

// Mac virtual key code (HIToolbox kVK_*) -> SDL scancode, by name: kVK_ANSI_A ->
// SDL_SCANCODE_A, kVK_Delete -> BACKSPACE, kVK_Help -> INSERT (where a Mac
// keyboard has its Insert key). Generated from the SDK's Events.h and
// SDL_scancode.h; unlisted codes (kVK_Function) are 0, SDL_SCANCODE_UNKNOWN.
static const SDL_Scancode MAC_SCANCODES[128] = {
  [0x00] = SDL_SCANCODE_A,
  [0x01] = SDL_SCANCODE_S,
  [0x02] = SDL_SCANCODE_D,
  [0x03] = SDL_SCANCODE_F,
  [0x04] = SDL_SCANCODE_H,
  [0x05] = SDL_SCANCODE_G,
  [0x06] = SDL_SCANCODE_Z,
  [0x07] = SDL_SCANCODE_X,
  [0x08] = SDL_SCANCODE_C,
  [0x09] = SDL_SCANCODE_V,
  [0x0A] = SDL_SCANCODE_NONUSBACKSLASH,
  [0x0B] = SDL_SCANCODE_B,
  [0x0C] = SDL_SCANCODE_Q,
  [0x0D] = SDL_SCANCODE_W,
  [0x0E] = SDL_SCANCODE_E,
  [0x0F] = SDL_SCANCODE_R,
  [0x10] = SDL_SCANCODE_Y,
  [0x11] = SDL_SCANCODE_T,
  [0x12] = SDL_SCANCODE_1,
  [0x13] = SDL_SCANCODE_2,
  [0x14] = SDL_SCANCODE_3,
  [0x15] = SDL_SCANCODE_4,
  [0x16] = SDL_SCANCODE_6,
  [0x17] = SDL_SCANCODE_5,
  [0x18] = SDL_SCANCODE_EQUALS,
  [0x19] = SDL_SCANCODE_9,
  [0x1A] = SDL_SCANCODE_7,
  [0x1B] = SDL_SCANCODE_MINUS,
  [0x1C] = SDL_SCANCODE_8,
  [0x1D] = SDL_SCANCODE_0,
  [0x1E] = SDL_SCANCODE_RIGHTBRACKET,
  [0x1F] = SDL_SCANCODE_O,
  [0x20] = SDL_SCANCODE_U,
  [0x21] = SDL_SCANCODE_LEFTBRACKET,
  [0x22] = SDL_SCANCODE_I,
  [0x23] = SDL_SCANCODE_P,
  [0x24] = SDL_SCANCODE_RETURN,
  [0x25] = SDL_SCANCODE_L,
  [0x26] = SDL_SCANCODE_J,
  [0x27] = SDL_SCANCODE_APOSTROPHE,
  [0x28] = SDL_SCANCODE_K,
  [0x29] = SDL_SCANCODE_SEMICOLON,
  [0x2A] = SDL_SCANCODE_BACKSLASH,
  [0x2B] = SDL_SCANCODE_COMMA,
  [0x2C] = SDL_SCANCODE_SLASH,
  [0x2D] = SDL_SCANCODE_N,
  [0x2E] = SDL_SCANCODE_M,
  [0x2F] = SDL_SCANCODE_PERIOD,
  [0x30] = SDL_SCANCODE_TAB,
  [0x31] = SDL_SCANCODE_SPACE,
  [0x32] = SDL_SCANCODE_GRAVE,
  [0x33] = SDL_SCANCODE_BACKSPACE,
  [0x35] = SDL_SCANCODE_ESCAPE,
  [0x36] = SDL_SCANCODE_RGUI,
  [0x37] = SDL_SCANCODE_LGUI,
  [0x38] = SDL_SCANCODE_LSHIFT,
  [0x39] = SDL_SCANCODE_CAPSLOCK,
  [0x3A] = SDL_SCANCODE_LALT,
  [0x3B] = SDL_SCANCODE_LCTRL,
  [0x3C] = SDL_SCANCODE_RSHIFT,
  [0x3D] = SDL_SCANCODE_RALT,
  [0x3E] = SDL_SCANCODE_RCTRL,
  [0x40] = SDL_SCANCODE_F17,
  [0x41] = SDL_SCANCODE_KP_PERIOD,
  [0x43] = SDL_SCANCODE_KP_MULTIPLY,
  [0x45] = SDL_SCANCODE_KP_PLUS,
  [0x47] = SDL_SCANCODE_NUMLOCKCLEAR,
  [0x48] = SDL_SCANCODE_VOLUMEUP,
  [0x49] = SDL_SCANCODE_VOLUMEDOWN,
  [0x4A] = SDL_SCANCODE_MUTE,
  [0x4B] = SDL_SCANCODE_KP_DIVIDE,
  [0x4C] = SDL_SCANCODE_KP_ENTER,
  [0x4E] = SDL_SCANCODE_KP_MINUS,
  [0x4F] = SDL_SCANCODE_F18,
  [0x50] = SDL_SCANCODE_F19,
  [0x51] = SDL_SCANCODE_KP_EQUALS,
  [0x52] = SDL_SCANCODE_KP_0,
  [0x53] = SDL_SCANCODE_KP_1,
  [0x54] = SDL_SCANCODE_KP_2,
  [0x55] = SDL_SCANCODE_KP_3,
  [0x56] = SDL_SCANCODE_KP_4,
  [0x57] = SDL_SCANCODE_KP_5,
  [0x58] = SDL_SCANCODE_KP_6,
  [0x59] = SDL_SCANCODE_KP_7,
  [0x5A] = SDL_SCANCODE_F20,
  [0x5B] = SDL_SCANCODE_KP_8,
  [0x5C] = SDL_SCANCODE_KP_9,
  [0x5D] = SDL_SCANCODE_INTERNATIONAL3,
  [0x5E] = SDL_SCANCODE_INTERNATIONAL1,
  [0x5F] = SDL_SCANCODE_KP_COMMA,
  [0x60] = SDL_SCANCODE_F5,
  [0x61] = SDL_SCANCODE_F6,
  [0x62] = SDL_SCANCODE_F7,
  [0x63] = SDL_SCANCODE_F3,
  [0x64] = SDL_SCANCODE_F8,
  [0x65] = SDL_SCANCODE_F9,
  [0x66] = SDL_SCANCODE_LANG2,
  [0x67] = SDL_SCANCODE_F11,
  [0x68] = SDL_SCANCODE_LANG1,
  [0x69] = SDL_SCANCODE_F13,
  [0x6A] = SDL_SCANCODE_F16,
  [0x6B] = SDL_SCANCODE_F14,
  [0x6D] = SDL_SCANCODE_F10,
  [0x6E] = SDL_SCANCODE_APPLICATION,
  [0x6F] = SDL_SCANCODE_F12,
  [0x71] = SDL_SCANCODE_F15,
  [0x72] = SDL_SCANCODE_INSERT,
  [0x73] = SDL_SCANCODE_HOME,
  [0x74] = SDL_SCANCODE_PAGEUP,
  [0x75] = SDL_SCANCODE_DELETE,
  [0x76] = SDL_SCANCODE_F4,
  [0x77] = SDL_SCANCODE_END,
  [0x78] = SDL_SCANCODE_F2,
  [0x79] = SDL_SCANCODE_PAGEDOWN,
  [0x7A] = SDL_SCANCODE_F1,
  [0x7B] = SDL_SCANCODE_LEFT,
  [0x7C] = SDL_SCANCODE_RIGHT,
  [0x7D] = SDL_SCANCODE_DOWN,
  [0x7E] = SDL_SCANCODE_UP,
};

@interface DbsRow : NSObject
@property int kind, sid, arg;
@property (strong) NSView *view;            // hidden with the row
@property (strong) NSControl *control;      // checkbox, field, pop-up or button
@property (strong) NSTextField *label;      // title, note or text
@property (strong) NSButton *help;
@property (strong) NSArray<NSButton *> *radios;
@property (strong) NSArray<NSNumber *> *values;
@property (strong) NSStackView *children;
@end
@implementation DbsRow
@end

@interface DbsFlipped : NSView
@end
@implementation DbsFlipped
- (BOOL)isFlipped { return YES; }
@end

@interface DbsWindow : NSWindow
@end

@interface DbsController : NSObject <NSWindowDelegate, NSTabViewDelegate, NSTextFieldDelegate>
@end

static DbsController *ctl;
static DbsWindow *window;
static NSTabView *tab_view;
static NSStackView *roots[MAX_TABS];
static NSMutableArray<DbsRow *> *rows[MAX_TABS];
static NSString *sigs[MAX_TABS];
static int ntabs, cur_tab, counter;
static BOOL building;
static BOOL asking;   // the hidden window's discard question, for dbs_do

static NSString *str(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }

// The rows write "..." (ImGui's font has no ellipsis)
static NSString *title(const char *s) {
  return [str(s) stringByReplacingOccurrencesOfString:@"..." withString:@"…"];
}

static NSInteger tag_of(int tab, int index) { return (NSInteger)tab << 16 | index; }

static DbsRow *row_of(NSInteger tag) {
  int tab = (int)(tag >> 16), index = (int)(tag & 0xFFFF);
  if (tab < 0 || tab >= ntabs || index >= (int)rows[tab].count) return nil;
  return rows[tab][index];
}

@implementation DbsWindow

- (void)report:(unsigned short)key_code {
  if (key_code < 128 && MAC_SCANCODES[key_code] != SDL_SCANCODE_UNKNOWN)
    dingbat_settings_key((int)MAC_SCANCODES[key_code]);
}

- (void)sendEvent:(NSEvent *)e {
  NSEventType t = e.type;
  if ((t == NSEventTypeKeyDown || t == NSEventTypeKeyUp || t == NSEventTypeFlagsChanged) &&
      dingbat_settings_capturing()) {
    // A binding takes a key when it is let go, as in the ImGui window
    if (t == NSEventTypeKeyUp) [self report:e.keyCode];
    if (t == NSEventTypeFlagsChanged) {
      NSEventModifierFlags f = e.modifierFlags, m = 0;
      switch (e.keyCode) {
      case 0x38: case 0x3C: m = NSEventModifierFlagShift; break;
      case 0x3B: case 0x3E: m = NSEventModifierFlagControl; break;
      case 0x3A: case 0x3D: m = NSEventModifierFlagOption; break;
      case 0x37: case 0x36: m = NSEventModifierFlagCommand; break;
      }
      if (m && !(f & m)) [self report:e.keyCode];
    }
    return;
  }
  [super sendEvent:e];
}

- (BOOL)performKeyEquivalent:(NSEvent *)e {
  // Waiting for a key, Cmd+key is that key, not a menu's shortcut
  if (dingbat_settings_capturing()) return YES;
  return [super performKeyEquivalent:e];
}

@end

@implementation DbsController

- (void)toggled:(NSButton *)b {
  DbsRow *r = row_of(b.tag);
  if (r) dingbat_settings_set(r.sid, b.state == NSControlStateValueOn, "");
}

- (void)chose:(NSButton *)b {
  DbsRow *r = row_of(b.tag);
  NSUInteger i = [r.radios indexOfObject:b];
  if (r && i != NSNotFound) dingbat_settings_set(r.sid, r.values[i].intValue, "");
}

- (void)controlTextDidChange:(NSNotification *)n {
  NSTextField *f = n.object;
  DbsRow *r = row_of(f.tag);
  if (r) dingbat_settings_set(r.sid, 0, f.stringValue.UTF8String);
}

- (void)browse:(NSButton *)b {
  DbsRow *r = row_of(b.tag);
  if (!r) return;
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES;
  p.canChooseDirectories = NO;
  NSString *cur = ((NSTextField *)r.control).stringValue;
  if (cur.length > 0)
    p.directoryURL = [NSURL fileURLWithPath:cur.stringByDeletingLastPathComponent isDirectory:YES];
  void (^done)(NSModalResponse) = ^(NSModalResponse res) {
    if (res != NSModalResponseOK) return;
    ((NSTextField *)r.control).stringValue = p.URL.path;
    dingbat_settings_set(r.sid, 0, p.URL.fileSystemRepresentation);
  };
  if (window.visible) [p beginSheetModalForWindow:window completionHandler:done];
  else [p beginWithCompletionHandler:done];
}

- (void)picked:(NSPopUpButton *)p {
  DbsRow *r = row_of(p.tag);
  // A pull-down's first item is its title
  if (r && p.indexOfSelectedItem > 0) dingbat_settings_activate(r.sid, (int)p.indexOfSelectedItem - 1);
}

- (void)pressed:(NSButton *)b {
  DbsRow *r = row_of(b.tag);
  if (r) dingbat_settings_activate(r.sid, r.arg);
}

- (void)help:(NSButton *)b {
  NSTextField *t = [NSTextField wrappingLabelWithString:b.toolTip ?: @""];
  t.preferredMaxLayoutWidth = 320;
  t.translatesAutoresizingMaskIntoConstraints = NO;
  NSViewController *vc = [NSViewController new];
  NSView *v = [NSView new];
  [v addSubview:t];
  [NSLayoutConstraint activateConstraints:@[
    [t.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
    [t.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
    [t.topAnchor constraintEqualToAnchor:v.topAnchor constant:12],
    [t.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-12],
    [t.widthAnchor constraintLessThanOrEqualToConstant:320],
  ]];
  vc.view = v;
  NSPopover *pop = [NSPopover new];
  pop.behavior = NSPopoverBehaviorTransient;
  pop.contentViewController = vc;
  [pop showRelativeToRect:b.bounds ofView:b preferredEdge:NSRectEdgeMaxX];
}

- (void)footer:(NSButton *)b {
  if (b.tag == SA_RESET_DEFAULTS) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Restore all settings to their defaults?";
    a.informativeText = @"Your ROMs, saves, recents and BIOS paths are kept.";
    [a addButtonWithTitle:@"Reset"];
    [a addButtonWithTitle:@"Cancel"];
    a.alertStyle = NSAlertStyleWarning;
    void (^done)(NSModalResponse) = ^(NSModalResponse res) {
      if (res == NSAlertFirstButtonReturn) dingbat_settings_action(SA_RESET_DEFAULTS);
    };
    if (window.visible) [a beginSheetModalForWindow:window completionHandler:done];
    else done(NSAlertFirstButtonReturn);   // the GUI driver's hidden window
    return;
  }
  dingbat_settings_action((int)b.tag);
}

- (BOOL)windowShouldClose:(NSWindow *)w {
  // The main loop closes it, or asks first (dbs_ask_discard)
  dingbat_settings_action(SA_CLOSE);
  return NO;
}

- (void)tabView:(NSTabView *)tv didSelectTabViewItem:(NSTabViewItem *)item {
  dingbat_settings_tab((int)[tv indexOfTabViewItem:item]);
}

@end

static NSButton *help_button(const char *help) {
  NSButton *h = [NSButton buttonWithTitle:@"" target:ctl action:@selector(help:)];
  h.bezelStyle = NSBezelStyleHelpButton;
  h.toolTip = str(help);
  return h;
}

static NSStackView *hstack(NSArray<NSView *> *views) {
  NSStackView *s = [NSStackView stackViewWithViews:views];
  s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  s.alignment = NSLayoutAttributeFirstBaseline;
  s.spacing = 8;
  return s;
}

static NSStackView *vstack(void) {
  NSStackView *s = [NSStackView new];
  s.orientation = NSUserInterfaceLayoutOrientationVertical;
  s.alignment = NSLayoutAttributeLeading;
  s.spacing = 8;
  return s;
}

static NSTextField *note_label(NSString *text) {
  NSTextField *t = [NSTextField wrappingLabelWithString:text];
  t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  t.textColor = NSColor.secondaryLabelColor;
  t.preferredMaxLayoutWidth = CONTENT_W - 40;
  return t;
}

// ── For mac_settings.nim ──

void dbs_open(const char **titles, int n, int hidden) {
  if (window == nil) {
    ctl = [DbsController new];
    ntabs = n < MAX_TABS ? n : MAX_TABS;
    window = [[DbsWindow alloc] initWithContentRect:NSMakeRect(0, 0, CONTENT_W + 40, 540)
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    window.title = @"Settings";
    window.releasedWhenClosed = NO;
    window.delegate = ctl;
    window.contentMinSize = NSMakeSize(CONTENT_W + 40, 360);
    [window setFrameAutosaveName:@"dingbat Settings"];

    tab_view = [NSTabView new];
    tab_view.translatesAutoresizingMaskIntoConstraints = NO;
    for (int i = 0; i < ntabs; i++) {
      NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@(i)];
      item.label = str(titles[i]);
      NSScrollView *sv = [NSScrollView new];
      sv.hasVerticalScroller = YES;
      sv.drawsBackground = NO;
      sv.borderType = NSNoBorder;
      DbsFlipped *doc = [DbsFlipped new];
      doc.translatesAutoresizingMaskIntoConstraints = NO;
      NSStackView *root = vstack();
      root.translatesAutoresizingMaskIntoConstraints = NO;
      root.edgeInsets = NSEdgeInsetsMake(12, 16, 16, 16);
      [doc addSubview:root];
      sv.documentView = doc;
      [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
        [doc.leadingAnchor constraintEqualToAnchor:sv.contentView.leadingAnchor],
        [doc.trailingAnchor constraintEqualToAnchor:sv.contentView.trailingAnchor],
        [doc.topAnchor constraintEqualToAnchor:sv.contentView.topAnchor],
      ]];
      item.view = sv;
      [tab_view addTabViewItem:item];
      roots[i] = root;
      rows[i] = [NSMutableArray array];
      sigs[i] = nil;
    }
    tab_view.delegate = ctl;

    NSButton *reset = [NSButton buttonWithTitle:@"Reset to Defaults…"
                                         target:ctl action:@selector(footer:)];
    reset.tag = SA_RESET_DEFAULTS;
    NSButton *revert = [NSButton buttonWithTitle:@"Revert" target:ctl action:@selector(footer:)];
    revert.tag = SA_REVERT;
    NSButton *apply = [NSButton buttonWithTitle:@"Apply" target:ctl action:@selector(footer:)];
    apply.tag = SA_APPLY;
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:ctl action:@selector(footer:)];
    ok.tag = SA_OK;
    ok.keyEquivalent = @"\r";
    NSView *gap = [NSView new];
    [gap setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = hstack(@[ reset, gap, revert, apply, ok ]);
    footer.alignment = NSLayoutAttributeCenterY;
    footer.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = window.contentView;
    [content addSubview:tab_view];
    [content addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
      [tab_view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
      [tab_view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
      [tab_view.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
      [footer.topAnchor constraintEqualToAnchor:tab_view.bottomAnchor constant:12],
      [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
      [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
      [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
    ]];
    [window center];
  }
  dingbat_settings_tab((int)[tab_view indexOfTabViewItem:tab_view.selectedTabViewItem]);
  if (!hidden) [window makeKeyAndOrderFront:nil];
}

void dbs_close(void) { [window orderOut:nil]; }

int dbs_is_key(void) { return window != nil && window.keyWindow; }

void dbs_ask_discard(void) {
  NSAlert *a = [NSAlert new];
  a.messageText = @"These settings have not been applied.";
  [a addButtonWithTitle:@"Apply"];
  [a addButtonWithTitle:@"Discard"];
  [a addButtonWithTitle:@"Cancel"];
  void (^done)(NSModalResponse) = ^(NSModalResponse res) {
    if (res == NSAlertFirstButtonReturn) dingbat_settings_action(SA_APPLY_CLOSE);
    else if (res == NSAlertSecondButtonReturn) dingbat_settings_action(SA_DISCARD_CLOSE);
  };
  if (window.visible) [a beginSheetModalForWindow:window completionHandler:done];
  else asking = YES;
}

void *dbs_begin(int tab, const char *sig) {
  // Rebuilt when the shape changed, else updated in place
  cur_tab = tab;
  counter = 0;
  NSString *s = str(sig);
  building = ![s isEqualToString:sigs[tab]];
  if (building) {
    sigs[tab] = s;
    for (NSView *v in roots[tab].arrangedSubviews.copy) {
      [roots[tab] removeArrangedSubview:v];
      [v removeFromSuperview];
    }
    [rows[tab] removeAllObjects];
  }
  return (__bridge void *)roots[tab];
}

static void build(DbsRow *r, NSStackView *parent, const char *t, const char *help,
                  const char *hint, const char *options, int inline_, float width, int nkids) {
  NSInteger tag = tag_of(cur_tab, counter);
  NSView *v = nil;
  switch (r.kind) {
  case RK_LABEL:
  case RK_FOLD: {
    NSStackView *box = vstack();
    if (t && *t) {
      r.label = [NSTextField labelWithString:title(t)];
      if (r.kind == RK_FOLD) r.label.font = [NSFont boldSystemFontOfSize:0];
      NSMutableArray *line = [NSMutableArray arrayWithObject:r.label];
      if (help && *help) [line addObject:(r.help = help_button(help))];
      [box addArrangedSubview:hstack(line)];
    }
    if (nkids > 0) {
      r.children = vstack();
      // Under a title the rows are indented; a fold's sit under its heading
      r.children.edgeInsets = NSEdgeInsetsMake(0, r.kind == RK_FOLD ? 0 : 20, 0, 0);
      [box addArrangedSubview:r.children];
    }
    v = box;
    break;
  }
  case RK_TOGGLE: {
    NSButton *b = [NSButton checkboxWithTitle:title(t) target:ctl action:@selector(toggled:)];
    b.tag = tag;
    r.control = b;
    v = (help && *help) ? hstack(@[ b, (r.help = help_button(help)) ]) : b;
    break;
  }
  case RK_CHOICE: {
    NSStackView *s = inline_ ? hstack(@[]) : vstack();
    if (!inline_) s.spacing = 4;
    NSMutableArray *radios = [NSMutableArray array];
    for (NSString *opt in [str(options) componentsSeparatedByString:@"\n"]) {
      NSButton *b = [NSButton radioButtonWithTitle:opt target:ctl action:@selector(chose:)];
      b.tag = tag;
      [radios addObject:b];
      [s addArrangedSubview:b];
    }
    r.radios = radios;
    v = s;
    break;
  }
  case RK_PATH: {
    NSTextField *name = [NSTextField labelWithString:title(t)];
    [name.widthAnchor constraintEqualToConstant:110].active = YES;
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.placeholderString = str(hint);
    f.delegate = ctl;
    f.tag = tag;
    [f.widthAnchor constraintEqualToConstant:250].active = YES;
    NSButton *choose = [NSButton buttonWithTitle:@"Choose…" target:ctl action:@selector(browse:)];
    choose.tag = tag;
    r.control = f;
    r.label = name;
    v = hstack(@[ name, f, choose, (r.help = help_button(help)) ]);
    break;
  }
  case RK_NOTE:
    v = r.label = note_label(@"");
    break;
  case RK_TEXT:
    v = r.label = [NSTextField labelWithString:@""];
    break;
  case RK_SEPARATOR: {
    NSBox *b = [NSBox new];
    b.boxType = NSBoxSeparator;
    [b.widthAnchor constraintEqualToConstant:CONTENT_W - 40].active = YES;
    v = b;
    break;
  }
  case RK_PRESET: {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [p addItemWithTitle:title(hint)];
    for (NSString *opt in [str(options) componentsSeparatedByString:@"\n"]) [p addItemWithTitle:opt];
    p.target = ctl;
    p.action = @selector(picked:);
    p.tag = tag;
    r.control = p;
    v = hstack(@[ [NSTextField labelWithString:title(t)], p ]);
    break;
  }
  case RK_BINDING: {
    NSButton *b = [NSButton buttonWithTitle:@"" target:ctl action:@selector(pressed:)];
    [b setButtonType:NSButtonTypePushOnPushOff];
    b.tag = tag;
    [b.widthAnchor constraintEqualToConstant:width > 60 ? 130 : 110].active = YES;
    r.control = b;
    r.label = [NSTextField labelWithString:@""];
    v = hstack(@[ b, r.label ]);
    break;
  }
  case RK_BUTTON: {
    NSButton *b = [NSButton buttonWithTitle:title(t) target:ctl action:@selector(pressed:)];
    b.tag = tag;
    r.control = b;
    v = b;
    break;
  }
  }
  r.view = v;
  [parent addArrangedSubview:v];
}

void *dbs_row(void *parent, int kind, int sid, int arg, const char *t, const char *help,
              const char *hint, const char *text, int on, int value, const char *options,
              const char *values, const char *option_on, int inline_, int enabled, int shown,
              int valid, float width, int nkids) {
  DbsRow *r;
  if (building) {
    r = [DbsRow new];
    r.kind = kind;
    r.sid = sid;
    r.arg = arg;
    NSMutableArray *vals = [NSMutableArray array];
    for (NSString *x in [str(values) componentsSeparatedByString:@","])
      if (x.length) [vals addObject:@(x.intValue)];
    r.values = vals;
    build(r, (__bridge NSStackView *)parent, t, help, hint, options, inline_, width, nkids);
    [rows[cur_tab] addObject:r];
  } else {
    if (counter >= (int)rows[cur_tab].count) return NULL;
    r = rows[cur_tab][counter];
  }
  counter++;

  // Values, every refresh
  r.view.hidden = !shown;
  if (r.help) r.help.toolTip = str(help);
  NSString *txt = [str(text) stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
  switch (kind) {
  case RK_TOGGLE:
    ((NSButton *)r.control).state = on ? NSControlStateValueOn : NSControlStateValueOff;
    r.control.enabled = enabled;
    break;
  case RK_CHOICE:
    for (NSUInteger i = 0; i < r.radios.count; i++) {
      NSButton *b = r.radios[i];
      b.state = (i < r.values.count && r.values[i].intValue == value) ? NSControlStateValueOn
                                                                       : NSControlStateValueOff;
      b.enabled = enabled && option_on && i < strlen(option_on) && option_on[i] == '1';
    }
    break;
  case RK_PATH: {
    NSTextField *f = (NSTextField *)r.control;
    // Not under the player's cursor: the field holds what they are typing
    if (f.currentEditor == nil && ![f.stringValue isEqualToString:str(text)])
      f.stringValue = str(text);
    f.textColor = valid ? NSColor.controlTextColor : NSColor.systemRedColor;
    break;
  }
  case RK_NOTE:
  case RK_TEXT:
    if (![r.label.stringValue isEqualToString:txt]) r.label.stringValue = txt;
    break;
  case RK_BINDING: {
    NSButton *b = (NSButton *)r.control;
    NSString *k = title(text);
    if (![b.title isEqualToString:k]) b.title = k;
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.bezelColor = on ? NSColor.controlAccentColor : nil;
    NSString *name = title(t);
    if (![r.label.stringValue isEqualToString:name]) r.label.stringValue = name;
    break;
  }
  default:
    break;
  }
  return (__bridge void *)r.children;
}

// ── For the GUI driver (gui_driver.nim) ──

static void dump_rows(int tab, NSMutableString *out) {
  for (DbsRow *r in rows[tab]) {
    if (r.view.hidden) continue;
    switch (r.kind) {
    case RK_LABEL:
    case RK_FOLD:
      if (r.label) [out appendFormat:@"label %@\n", r.label.stringValue];
      break;
    case RK_TOGGLE: {
      NSButton *b = (NSButton *)r.control;
      [out appendFormat:@"toggle %@%@%@\n", b.title, b.state ? @" [x]" : @"",
                        b.enabled ? @"" : @" [off]"];
      break;
    }
    case RK_CHOICE:
      for (NSButton *b in r.radios)
        [out appendFormat:@"option %@%@%@\n", b.title, b.state ? @" [x]" : @"",
                          b.enabled ? @"" : @" [off]"];
      break;
    case RK_PATH: {
      NSTextField *f = (NSTextField *)r.control;
      [out appendFormat:@"path %@ = %@%@\n", r.label.stringValue, f.stringValue,
                        [f.textColor isEqual:NSColor.systemRedColor] ? @" [invalid]" : @""];
      break;
    }
    case RK_NOTE: [out appendFormat:@"note %@\n", r.label.stringValue]; break;
    case RK_TEXT: [out appendFormat:@"text %@\n", r.label.stringValue]; break;
    case RK_SEPARATOR: [out appendString:@"---\n"]; break;
    case RK_PRESET: [out appendFormat:@"preset %@\n", ((NSPopUpButton *)r.control).itemTitles[0]]; break;
    case RK_BINDING: {
      NSButton *b = (NSButton *)r.control;
      [out appendFormat:@"binding %@ = %@%@\n", r.label.stringValue, b.title, b.state ? @" [waiting]" : @""];
      break;
    }
    case RK_BUTTON: [out appendFormat:@"button %@\n", ((NSButton *)r.control).title]; break;
    }
  }
}

char *dbs_dump(void) {
  NSMutableString *out = [NSMutableString string];
  if (window == nil) return strdup("");
  [out appendFormat:@"window %@%@\n", window.visible ? @"shown" : @"hidden",
                    asking ? @" [asking]" : @""];
  for (int i = 0; i < ntabs; i++) {
    [out appendFormat:@"tab %@%@\n", [tab_view tabViewItemAtIndex:i].label,
                      tab_view.selectedTabViewItem == [tab_view tabViewItemAtIndex:i] ? @" [x]" : @""];
    dump_rows(i, out);
  }
  return strdup(out.UTF8String);
}

static BOOL press(NSControl *c) {
  if (!c.enabled) return NO;
  [c performClick:nil];
  return YES;
}

int dbs_do(const char *tab_name, const char *item, const char *value) {
  // A control by its tab and title, as a click (or typing `value` into a
  // path) would: 1 done, 0 not found, -1 greyed out. Tab "" is the footer.
  NSString *want = title(item), *tn = str(tab_name);
  if (tn.length == 0 && asking) {
    asking = NO;
    if ([want isEqualToString:@"Apply"]) dingbat_settings_action(SA_APPLY_CLOSE);
    else if ([want isEqualToString:@"Discard"]) dingbat_settings_action(SA_DISCARD_CLOSE);
    return [want isEqualToString:@"Cancel"] || [want isEqualToString:@"Apply"] ||
                   [want isEqualToString:@"Discard"]
               ? 1 : 0;
  }
  if (tn.length == 0) {
    for (NSView *v in window.contentView.subviews)
      if ([v isKindOfClass:NSStackView.class])
        for (NSView *b in ((NSStackView *)v).arrangedSubviews)
          if ([b isKindOfClass:NSButton.class] && [((NSButton *)b).title isEqualToString:want])
            return press((NSButton *)b) ? 1 : -1;
    return 0;
  }
  NSInteger t = [tab_view indexOfTabViewItemWithIdentifier:@0];
  for (int i = 0; i < ntabs; i++)
    if ([[tab_view tabViewItemAtIndex:i].label isEqualToString:tn]) t = i;
  if ([want isEqualToString:@""]) {
    [tab_view selectTabViewItemAtIndex:t];
    return 1;
  }
  for (DbsRow *r in rows[t]) {
    if (r.view.hidden) continue;
    switch (r.kind) {
    case RK_TOGGLE:
    case RK_BUTTON:
      if ([((NSButton *)r.control).title isEqualToString:want]) return press(r.control) ? 1 : -1;
      break;
    case RK_CHOICE:
      for (NSButton *b in r.radios)
        if ([b.title isEqualToString:want]) return press(b) ? 1 : -1;
      break;
    case RK_BINDING:
      if ([r.label.stringValue isEqualToString:want]) return press(r.control) ? 1 : -1;
      break;
    case RK_PATH:
      if ([r.label.stringValue isEqualToString:want]) {
        NSTextField *f = (NSTextField *)r.control;
        f.stringValue = str(value);
        [ctl controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                object:f]];
        return 1;
      }
      break;
    case RK_PRESET: {
      NSPopUpButton *p = (NSPopUpButton *)r.control;
      NSInteger i = [p indexOfItemWithTitle:str(value)];
      if (i > 0) {
        [p selectItemAtIndex:i];
        [ctl picked:p];
        return 1;
      }
      break;
    }
    default:
      break;
    }
  }
  return 0;
}

void dbs_key(int key_code) {
  // A key let go, as the window takes it while a binding waits
  NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0
                               timestamp:0 windowNumber:window.windowNumber context:nil
                              characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO
                                 keyCode:(unsigned short)key_code];
  [window sendEvent:e];
}

void dbs_close_button(void) { [window performClose:nil]; }

int dbs_snapshot(const char *path) {
  // The window as drawn, on screen or not
  NSView *v = window.contentView;
  [v layoutSubtreeIfNeeded];
  NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
  [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return [png writeToFile:str(path) atomically:YES] ? 1 : 0;
}
