/* iOS app lifecycle bridge for GNU Emacs.
   Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

/* This file is the iOS analogue of src/android.c.  It bridges the
   UIKit application lifecycle (UIApplication / UIWindow) into the
   Emacs entry point and exposes a small set of C-callable helpers
   that the rest of the iOS port (iosterm.m, iosvfs.c, etc.) uses to
   talk back to UIKit.

   Phase 1 of the runtime bring-up (this commit): UIApplicationMain
   instantiates EmacsAppDelegate, which is defined IN THIS BINARY (it
   previously lived only in ios/Emacs/AppDelegate.m, which is part of
   the bundle template but is not compiled into the cross-built
   binary -- so NSClassFromString returned nil and UIApplicationMain
   sat on a nil delegate forever, producing the "launches but hangs"
   symptom).  EmacsAppDelegate shows a red "Emacs is loading..."
   screen so launch is visually confirmable, redirects stdout/stderr
   to a file in the app's Documents/ directory so any C-level print
   output is captured, and dispatches ios_main() to a background
   queue so the (still-stub-heavy) Emacs initialization does not
   block the UI thread.  Diagnostic breadcrumbs are appended to
   Documents/emacs-launch.log at every step -- NSLog alone is
   unreliable on Simulator launches that happen outside
   `xcrun simctl launch --console`.  */

#include <config.h>

#ifdef HAVE_IOS

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "lisp.h"
#include "iosterm.h"
#include "termhooks.h"
#include "frame.h"

/* Forward declaration of the renamed Emacs entry point.  On iOS,
   src/emacs.c's main() is renamed to ios_emacs_init() so the UIKit
   app shell can call it after the application has finished launching
   (analogous to how android.c calls into android_emacs_init).  */
extern int ios_emacs_init (int argc, char **argv, char *dump_file);


/* ---- Logging breadcrumbs -------------------------------------- */

/* Build a path inside the iOS app's Documents/ directory.  Returns
   nil if NSSearchPath cannot find one (which would only happen if
   the app sandbox is in a deeply broken state).  */
static NSString *
ios_documents_path (NSString *name)
{
  NSArray<NSString *> *dirs
    = NSSearchPathForDirectoriesInDomains (NSDocumentDirectory,
                                           NSUserDomainMask, YES);
  if (dirs.count == 0)
    return nil;
  return [dirs[0] stringByAppendingPathComponent:name];
}

/* Weakly-held reference to the on-screen log view installed by the
   AppDelegate.  ios_launch_log appends each message here too so the
   user can see live bring-up progress in the simulator / on a device,
   not just in the file logs.  Weak so the view can deallocate
   normally when the AppDelegate tears down at app termination.  */
__weak static UITextView *ios_log_view = nil;

/* Append a timestamped MSG line to Documents/emacs-launch.log, and
   echo via NSLog.  Two-channel logging on purpose: NSLog reaches
   `simctl launch --console` and the unified log; the file remains
   reachable via the Files app or by spelunking through
   ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/
   Data/Application/<app-uuid>/Documents/.

   Third channel: the on-screen UITextView (if installed) gets the
   line appended on the main thread.  This is what makes "the app
   launches but hangs" visibly NOT a hang -- the user sees the
   running progress trail through Emacs init.  */
void
ios_launch_log (NSString *msg)
{
  NSLog (@"emacs-launch: %@", msg);
  NSString *path = ios_documents_path (@"emacs-launch.log");
  if (path)
    {
      NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                        [NSDate date], msg];
      FILE *f = fopen (path.UTF8String, "a");
      if (f != NULL)
        {
          fputs (line.UTF8String, f);
          fclose (f);
        }
    }

  /* Ship to the on-screen log view (if any).  Main-queue dispatch so
     UIKit work happens on the UI thread regardless of caller.  */
  UITextView *view = ios_log_view;
  if (view != nil)
    {
      NSString *line = [NSString stringWithFormat:@"%@\n", msg];
      dispatch_async (dispatch_get_main_queue (), ^{
        view.text = [view.text stringByAppendingString:line];
        /* Auto-scroll to the bottom so the latest entry is visible.  */
        NSRange end = NSMakeRange (view.text.length, 0);
        [view scrollRangeToVisible:end];
      });
    }
}

/* Redirect stdout and stderr to Documents/emacs-stdout.log so any
   printf/fprintf the C-side Emacs code emits is captured.  iOS apps
   have no controlling terminal; without this redirect those writes
   would be silently dropped.  Line-buffered so the trail is fresh
   even if the process crashes mid-init.  */
static void
ios_redirect_stdio (void)
{
  NSString *path = ios_documents_path (@"emacs-stdout.log");
  if (!path)
    return;
  freopen (path.UTF8String, "a", stdout);
  freopen (path.UTF8String, "a", stderr);
  setvbuf (stdout, NULL, _IOLBF, 0);
  setvbuf (stderr, NULL, _IOLBF, 0);
}


/* ---- Sandbox paths -------------------------------------------- */

/* Return the sandboxed path at which emacs.pdmp lives.

   The dump file is written into ~/Library/Application Support/Emacs/
   on first launch and mmapped on every subsequent launch.  The
   returned string is malloc'd; callers should free it.  Returns NULL
   on error.  */

char *
ios_dump_path (void)
{
  @autoreleasepool {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *support = [[fm URLsForDirectory:NSApplicationSupportDirectory
                                inDomains:NSUserDomainMask] firstObject];
    if (!support)
      return NULL;

    NSURL *dir = [support URLByAppendingPathComponent:@"Emacs"
                                          isDirectory:YES];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:dir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&err])
      return NULL;

    /* Exclude this directory from iCloud / iTunes backup.  The dump
       is large and trivially regenerable.  */
    NSNumber *yes = [NSNumber numberWithBool:YES];
    [dir setResourceValue:yes
                   forKey:NSURLIsExcludedFromBackupKey
                    error:NULL];

    NSURL *dump = [dir URLByAppendingPathComponent:@"emacs.pdmp"];
    const char *path = [[dump path] UTF8String];
    return path ? strdup (path) : NULL;
  }
}


/* ---- EmacsUIView -- the glyph canvas -------------------------- */

/* Each draw_glyph_string call from the Emacs redisplay engine on
   the background pthread shovels one of these into the view's
   queue.  drawRect: replays them in order on the main thread.  The
   queue is short-lived: it is cleared at the start of every
   drawRect: so each redisplay tick produces a fresh frame.  */
/* Command kinds: a draw command is either a glyph string or a
   cursor.  Cursor commands carry no text; just the rectangle and
   pixel.  */
typedef NS_ENUM (NSUInteger, EmacsDrawKind) {
  EmacsDrawKindText = 0,
  EmacsDrawKindCursorFilled,
  EmacsDrawKindCursorHollow,
  EmacsDrawKindCursorBar,
  EmacsDrawKindCursorHBar,
};

/* Bit flags for EmacsDrawCommand.deco.  Kept in sync with the
   face decorators tested in iosterm.m's draw_glyph_string hook.  */
typedef NS_OPTIONS (NSUInteger, EmacsDrawDeco) {
  EmacsDrawDecoNone           = 0,
  EmacsDrawDecoUnderlineSingle = 1 << 0,
  EmacsDrawDecoUnderlineWave   = 1 << 1,
  EmacsDrawDecoOverline        = 1 << 2,
  EmacsDrawDecoStrikeThrough   = 1 << 3,
  EmacsDrawDecoItalic          = 1 << 4,
  EmacsDrawDecoBold            = 1 << 5,
};

@interface EmacsDrawCommand : NSObject
@property (nonatomic) EmacsDrawKind kind;
@property (nonatomic) CGFloat x;
@property (nonatomic) CGFloat y;
@property (nonatomic) CGFloat width;   /* background rect width */
@property (nonatomic) CGFloat height;  /* background rect height */
@property (nonatomic) uint32_t fg;     /* 0x00RRGGBB */
@property (nonatomic) uint32_t bg;     /* 0x00RRGGBB */
@property (nonatomic, copy) NSString *text;
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) EmacsDrawDeco deco;
@end
@implementation EmacsDrawCommand
@end

/* Implemented in iosterm.m; enqueues a code point into the
   input queue that ios_read_socket drains on the bg pthread.  */
extern void ios_enqueue_key (int codepoint);
extern void ios_enqueue_event (struct input_event *ie);
extern void ios_publish_canvas_size (double width, double height);
extern void ios_publish_mouse_motion (double x, double y);
extern void ios_publish_appearance_change (void);
extern void ios_publish_open_file (const char *path);
extern void ios_publish_pinch (double x, double y, double dx, double dy,
                               double scale, double angle);

@interface EmacsUIView : UIView <UIKeyInput>
- (void) appendCommand:(EmacsDrawCommand *)cmd;
- (void) beginFrame;
- (void) endFrame;
@end

@implementation EmacsUIView
{
  /* _pending accumulates commands within the current redisplay
     tick.  At endFrame it's atomically promoted to _displayed,
     which drawRect: renders.  This avoids a race where the main
     thread's drawRect: could see a half-built frame because a
     subsequent tick had already cleared _pending.  */
  NSMutableArray<EmacsDrawCommand *> *_pending;
  NSArray<EmacsDrawCommand *> *_displayed;
  NSLock *_lock;
}

- (instancetype) initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame]))
    {
      self.backgroundColor = UIColor.whiteColor;
      self.opaque = YES;
      _pending = [NSMutableArray array];
      _displayed = @[];
      _lock = [[NSLock alloc] init];
      self.userInteractionEnabled = YES;
      /* A single-tap on the canvas pushes a RET into the input
         queue.  This is enough to dismiss the splash screen and
         get *scratch* to redisplay; multi-touch and real text
         entry follow in later commits.  */
      UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                     initWithTarget:self
                                     action:@selector (handleTap:)];
      [self addGestureRecognizer:tap];

      /* Long-press: synthesize mouse-2 (paste / yank).  iOS
         expects a long-press to bring up clipboard actions, so
         routing it to mouse-2 (which Emacs binds to yank in
         most modes) is the closest match.  */
      UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc]
          initWithTarget:self
                  action:@selector (handleLongPress:)];
      lp.minimumPressDuration = 0.5;
      [self addGestureRecognizer:lp];

      /* Two-finger pan: page up / page down via C-v / M-v.  A
         single-finger pan is reserved for future drag-to-select.  */
      UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                     initWithTarget:self
                                     action:@selector (handlePan:)];
      pan.minimumNumberOfTouches = 2;
      pan.maximumNumberOfTouches = 2;
      [self addGestureRecognizer:pan];

      /* Pinch: text-scale-increase / decrease.  */
      UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
                                         initWithTarget:self
                                         action:@selector (handlePinch:)];
      [self addGestureRecognizer:pinch];

      /* Single-finger pan: drag to select region.  Begin sends
         mouse-1 down, change sends a drag, end sends mouse-1 up.
         Configured to start after a small minimum displacement so
         a hesitant tap stays a tap.  */
      UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self
                                       action:@selector (handleDrag:)];
      drag.minimumNumberOfTouches = 1;
      drag.maximumNumberOfTouches = 1;
      [self addGestureRecognizer:drag];
    }
  return self;
}

/* The frame gesture events should target: the display's
   highlight frame if set, else the first live frame.  Safe to
   call from the UIKit thread -- it only reads tagged pointers,
   never allocates.  Returns NULL during early bring-up.  */
static struct frame *
ios_target_frame (void)
{
  if (!x_display_list)
    return NULL;
  struct frame *f = x_display_list->highlight_frame;
  if (!f && CONSP (Vframe_list))
    f = XFRAME (XCAR (Vframe_list));
  if (f && !FRAME_LIVE_P (f))
    f = NULL;
  return f;
}

/* Enqueue one half of a synthesized mouse-button event.  BUTTON
   is the Emacs button number (0 = mouse-1, 1 = mouse-2, ...);
   UPDOWN is down_modifier or up_modifier.  No-op when no frame
   exists yet.  */
static void
ios_emit_button_event (int button, int updown, CGPoint pt)
{
  struct frame *f = ios_target_frame ();
  if (!f)
    return;
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = MOUSE_CLICK_EVENT;
  ie.code = button;
  ie.modifiers = updown;
  ie.x = make_fixnum ((int) pt.x);
  ie.y = make_fixnum ((int) pt.y);
  XSETFRAME (ie.frame_or_window, f);
  ie.timestamp = 0;
  ios_enqueue_event (&ie);
}

/* Enqueue a wheel event at PT.  FORWARD true = scroll content
   forward (wheel-down in mwheel's terms).  */
static void
ios_emit_wheel_event (bool forward, CGPoint pt)
{
  struct frame *f = ios_target_frame ();
  if (!f)
    return;
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = WHEEL_EVENT;
  ie.code = 0;
  ie.modifiers = forward ? down_modifier : up_modifier;
  ie.x = make_fixnum ((int) pt.x);
  ie.y = make_fixnum ((int) pt.y);
  XSETFRAME (ie.frame_or_window, f);
  ie.arg = Qnil;
  ie.timestamp = 0;
  ios_enqueue_event (&ie);
}

- (void) handleTap:(UITapGestureRecognizer *)gr
{
  /* Become first-responder so hardware presses route through
     pressesBegan: and (via UIKeyInput) the soft keyboard slides
     up.  Also emit a synthesized mouse-1 click at the tap
     location so Emacs can move point / select / follow links.  */
  [self becomeFirstResponder];
  CGPoint pt = [gr locationInView:self];
  /* Mouse-1 down then up (Emacs synthesizes the click).  */
  ios_emit_button_event (0, down_modifier, pt);
  ios_emit_button_event (0, up_modifier, pt);
}

/* Long-press: synthesize a mouse-2 click at the press location.
   Fires once at gesture-begin so the user sees an instant action
   rather than waiting for finger-lift.  */
- (void) handleLongPress:(UILongPressGestureRecognizer *)gr
{
  if (gr.state != UIGestureRecognizerStateBegan)
    return;
  [self becomeFirstResponder];
  CGPoint pt = [gr locationInView:self];
  ios_emit_button_event (1, down_modifier, pt);
  ios_emit_button_event (1, up_modifier, pt);
}

/* Two-finger drag: emit WHEEL_EVENTs, the same thing a mouse
   wheel or trackpad produces, so mwheel.el's bindings (and any
   user rebinding of wheel-up / wheel-down) apply.  Direction
   follows the iOS convention: content tracks the finger, so a
   drag up scrolls forward.  */
- (void) handlePan:(UIPanGestureRecognizer *)gr
{
  static CGFloat accum_y = 0;
  if (gr.state == UIGestureRecognizerStateBegan)
    {
      accum_y = 0;
      return;
    }
  if (gr.state != UIGestureRecognizerStateChanged)
    return;
  CGPoint t = [gr translationInView:self];
  accum_y += t.y;
  [gr setTranslation:CGPointZero inView:self];
  CGPoint pt = [gr locationInView:self];

  /* One wheel click per ~20pt of drag; mwheel scrolls a few
     lines per click, so this tracks the finger closely without
     flooding the queue.  */
  const CGFloat threshold = 20.0;
  while (accum_y <= -threshold)
    {
      ios_emit_wheel_event (true, pt);   /* drag up = scroll forward */
      accum_y += threshold;
    }
  while (accum_y >= threshold)
    {
      ios_emit_wheel_event (false, pt);
      accum_y -= threshold;
    }
}

/* Pinch: publish cumulative scale updates; the Emacs thread
   turns them into PINCH_EVENTs which the global map binds to
   text-scale-pinch.  The dx=dy=angle=0 marker at gesture begin
   tells text-scale-pinch to snapshot the starting scale.  */
- (void) handlePinch:(UIPinchGestureRecognizer *)gr
{
  static CGPoint last_centroid;
  CGPoint pt = [gr locationInView:self];
  if (gr.state == UIGestureRecognizerStateBegan)
    {
      last_centroid = pt;
      ios_publish_pinch (pt.x, pt.y, 0.0, 0.0, 1.0, 0.0);
      return;
    }
  if (gr.state != UIGestureRecognizerStateChanged)
    return;
  double dx = pt.x - last_centroid.x;
  double dy = pt.y - last_centroid.y;
  last_centroid = pt;
  /* dx = dy = angle = 0 is the sequence-start marker; nudge dx
     so an update with a stationary centroid isn't mistaken for
     one.  */
  if (dx == 0.0 && dy == 0.0)
    dx = 0.001;
  /* gr.scale is cumulative since gesture start (we never reset
     it), exactly the SCALE term text-scale-pinch expects.  */
  ios_publish_pinch (pt.x, pt.y, dx, dy, (double) gr.scale, 0.0);
}

/* When UIKit rotates the device, the multitasking split view
   resizes us, or the keyboard slides up/down, our bounds change.
   Publish the new size to a static the Emacs main thread polls
   from inside ios_read_socket; it'll call change_frame_size on its
   own thread before draining the next batch of events.  */
- (void) layoutSubviews
{
  [super layoutSubviews];
  CGSize sz = self.bounds.size;
  if (sz.width > 0 && sz.height > 0)
    ios_publish_canvas_size (sz.width, sz.height);
}

/* User toggled dark / light in Settings while Emacs is running.
   Push the new appearance into Lisp by running
   ios-appearance-changed-hook (defined in ios-win.el) -- the
   binding edits frame-background-mode and re-realizes faces so
   the buffer colors flip live.  */
- (void) traitCollectionDidChange:(UITraitCollection *)previous
{
  [super traitCollectionDidChange:previous];
  if (previous != nil
      && previous.userInterfaceStyle
         == self.traitCollection.userInterfaceStyle)
    return;
  ios_publish_appearance_change ();
}

/* Single-finger drag: emit mouse-1 down at gesture begin and
   mouse-1 up at gesture end, leaving Emacs's existing click vs
   drag promotion to do the rest.  Intermediate updates publish
   the finger position so the region highlight tracks live.  */
- (void) handleDrag:(UIPanGestureRecognizer *)gr
{
  CGPoint pt = [gr locationInView:self];

  if (gr.state == UIGestureRecognizerStateBegan)
    {
      [self becomeFirstResponder];
      ios_publish_mouse_motion (pt.x, pt.y);
      ios_emit_button_event (0, down_modifier, pt);
      return;
    }
  if (gr.state == UIGestureRecognizerStateChanged)
    {
      /* Publish position so ios_read_socket's pending-motion
         drain calls note_mouse_highlight and the region
         highlight follows the finger.  No input_event is
         emitted; only the position dirty bit.  */
      ios_publish_mouse_motion (pt.x, pt.y);
      return;
    }
  if (gr.state == UIGestureRecognizerStateEnded
      || gr.state == UIGestureRecognizerStateCancelled)
    ios_emit_button_event (0, up_modifier, pt);
}

- (BOOL) canBecomeFirstResponder { return YES; }

/* ---- UIKeyInput ---- */

- (BOOL) hasText { return YES; }   /* Allow Backspace to dispatch.  */

- (void) insertText:(NSString *)text
{
  for (NSUInteger i = 0; i < text.length; i++)
    {
      unichar c = [text characterAtIndex:i];
      int packed = (int) c | (int) ios_sticky_mods;
      /* Map control-letter combos to the canonical 0x01..0x1A
         (same convention as ios_pack_uikey) so existing keymaps
         match.  */
      if ((ios_sticky_mods & CHAR_CTL) && c >= 'a' && c <= 'z')
        packed = (c - 'a' + 1) | (ios_sticky_mods & ~CHAR_CTL);
      else if ((ios_sticky_mods & CHAR_CTL) && c >= 'A' && c <= 'Z')
        packed = (c - 'A' + 1) | (ios_sticky_mods & ~CHAR_CTL);
      ios_enqueue_key (packed);
    }
  /* Sticky modifiers apply to one character then clear, matching
     the iOS sticky-key convention.  */
  ios_sticky_mods = 0;
}

- (void) deleteBackward
{
  ios_enqueue_key (0x7f);   /* DEL / Backspace */
}

/* Default text-input traits that make sense for an editor.  */
- (UIKeyboardType) keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType) autocorrectionType
{
  return UITextAutocorrectionTypeNo;
}
- (UITextAutocapitalizationType) autocapitalizationType
{
  return UITextAutocapitalizationTypeNone;
}
- (UITextSpellCheckingType) spellCheckingType
{
  return UITextSpellCheckingTypeNo;
}
- (BOOL) enablesReturnKeyAutomatically { return NO; }
- (UIReturnKeyType) returnKeyType { return UIReturnKeyDefault; }

/* Accessory bar sitting above the soft keyboard with the
   Emacs-specific chord keys (Ctrl, Meta, Esc, Tab, M-x) that
   iOS doesn't expose elsewhere.  Tapping a modifier toggles a
   sticky bit; the next typed character is packed with the
   accumulated modifiers and then the sticky state resets.  */
static unsigned ios_sticky_mods = 0;

- (UIView *) inputAccessoryView
{
  static UIToolbar *bar = nil;
  if (bar)
    return bar;
  bar = [[UIToolbar alloc] initWithFrame:CGRectMake (0, 0, 320, 40)];
  bar.translucent = NO;
  UIBarButtonItem *(^mk)(NSString *, SEL) =
    ^UIBarButtonItem *(NSString *t, SEL s) {
      UIBarButtonItem *b
        = [[UIBarButtonItem alloc] initWithTitle:t
                                           style:UIBarButtonItemStylePlain
                                          target:self
                                          action:s];
      return b;
    };
  UIBarButtonItem *flex
    = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil action:nil];
  bar.items = @[mk (@"Ctrl", @selector (accStickyCtrl)),
                mk (@"Meta", @selector (accStickyMeta)),
                flex,
                mk (@"Esc",  @selector (accEsc)),
                mk (@"Tab",  @selector (accTab)),
                mk (@"M-x",  @selector (accMx))];
  return bar;
}

- (void) accStickyCtrl { ios_sticky_mods ^= CHAR_CTL; }
- (void) accStickyMeta { ios_sticky_mods ^= CHAR_META; }
- (void) accEsc        { ios_enqueue_key (0x1b); }
- (void) accTab        { ios_enqueue_key (0x09); }
- (void) accMx
{
  /* M-x runs execute-extended-command in the standard global map.  */
  ios_enqueue_key (CHAR_META | 'x');
}


/* Translate a UIKey into the packed codepoint+modifiers our queue
   expects.  Returns -1 if the key has no codepoint we know how to
   handle (raw modifier presses, dead keys, etc).  */
/* Translate UIKey modifier flags into Emacs CHAR_* bits.
   Option maps to Meta and Command to Super, matching the macOS
   port's default conventions.  Shift is only included when
   INCLUDE_SHIFT: for printable characters the shift is already
   reflected in the character itself, but for function keys
   (arrows, F-keys) Emacs expects an explicit shift bit.  */
static int
ios_mods_from_flags (UIKeyModifierFlags m, bool include_shift)
{
  int mods = 0;
  if (m & UIKeyModifierControl)   mods |= CHAR_CTL;
  if (m & UIKeyModifierAlternate) mods |= CHAR_META;
  if (m & UIKeyModifierCommand)   mods |= CHAR_SUPER;
  if (include_shift && (m & UIKeyModifierShift))
    mods |= CHAR_SHIFT;
  return mods;
}

static int
ios_pack_uikey (UIKey *key)
{
  if (key == nil)
    return -1;

  /* Shift is not requested: for printables the character itself
     already reflects it.  */
  int mods = ios_mods_from_flags (key.modifierFlags, false);

  /* Prefer the unmodified character so Control / Meta combinations
     produce the lowercase base letter, mirroring how X / macOS
     route them to Emacs.  */
  NSString *chars = key.charactersIgnoringModifiers;
  if (chars.length == 0)
    chars = key.characters;
  if (chars.length == 0)
    {
      /* Map common non-character keys by keyCode.  Only the most
         common ones for an editor.  More to follow.  */
      switch (key.keyCode)
        {
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        case UIKeyboardHIDUsageKeypadEnter:
          return 0x0d | mods;
        case UIKeyboardHIDUsageKeyboardDeleteOrBackspace:
          return 0x7f | mods;
        case UIKeyboardHIDUsageKeyboardTab:
          return 0x09 | mods;
        case UIKeyboardHIDUsageKeyboardEscape:
          return 0x1b | mods;
        default:
          return -1;
        }
    }

  unichar c = [chars characterAtIndex:0];
  /* Most ASCII control-letter combos: Control flips the high
     bits.  For C-a we want code 1 ('a' & 0x1f), not 'a' with
     CHAR_CTL set -- Emacs accepts either but treating it like
     the X/Cocoa ports keeps existing keymaps unchanged.  */
  if ((mods & CHAR_CTL) && c >= 'A' && c <= 'Z')
    c |= 0x20;   /* lowercase first */
  if ((mods & CHAR_CTL) && c >= 'a' && c <= 'z')
    {
      int packed = (c - 'a' + 1) | (mods & ~CHAR_CTL);
      return packed;
    }
  return (int) c | mods;
}

/* Map a UIKeyboardHIDUsage to an X11-keysym value in 0xff00..0xffff
   (the FUNCTION_KEY_OFFSET range that keyboard.c's lispy_function_keys
   indexes).  Returns 0 for keys that should fall through to
   ios_pack_uikey.  */
static unsigned
ios_hid_to_xkeysym (long hid)
{
  switch (hid)
    {
    case UIKeyboardHIDUsageKeyboardLeftArrow:    return 0xff51;
    case UIKeyboardHIDUsageKeyboardUpArrow:      return 0xff52;
    case UIKeyboardHIDUsageKeyboardRightArrow:   return 0xff53;
    case UIKeyboardHIDUsageKeyboardDownArrow:    return 0xff54;
    case UIKeyboardHIDUsageKeyboardHome:         return 0xff50;
    case UIKeyboardHIDUsageKeyboardEnd:          return 0xff57;
    case UIKeyboardHIDUsageKeyboardPageUp:       return 0xff55;
    case UIKeyboardHIDUsageKeyboardPageDown:     return 0xff56;
    case UIKeyboardHIDUsageKeyboardInsert:       return 0xff63;
    case UIKeyboardHIDUsageKeyboardDeleteForward: return 0xffff;
    case UIKeyboardHIDUsageKeyboardF1:  return 0xffbe;
    case UIKeyboardHIDUsageKeyboardF2:  return 0xffbf;
    case UIKeyboardHIDUsageKeyboardF3:  return 0xffc0;
    case UIKeyboardHIDUsageKeyboardF4:  return 0xffc1;
    case UIKeyboardHIDUsageKeyboardF5:  return 0xffc2;
    case UIKeyboardHIDUsageKeyboardF6:  return 0xffc3;
    case UIKeyboardHIDUsageKeyboardF7:  return 0xffc4;
    case UIKeyboardHIDUsageKeyboardF8:  return 0xffc5;
    case UIKeyboardHIDUsageKeyboardF9:  return 0xffc6;
    case UIKeyboardHIDUsageKeyboardF10: return 0xffc7;
    case UIKeyboardHIDUsageKeyboardF11: return 0xffc8;
    case UIKeyboardHIDUsageKeyboardF12: return 0xffc9;
    default: return 0;
    }
}

/* Emit a NON_ASCII_KEYSTROKE_EVENT for an X11-style function-key
   code, carrying the same Control / Meta / Super / Shift modifier
   bits we pack for ASCII.  Returns YES if the press was consumed.  */
static BOOL
ios_emit_function_key (UIKey *key)
{
  unsigned xk = ios_hid_to_xkeysym ((long) key.keyCode);
  if (xk == 0)
    return NO;
  int mods = ios_mods_from_flags (key.modifierFlags, true);
  struct frame *f = ios_target_frame ();
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = NON_ASCII_KEYSTROKE_EVENT;
  ie.code = xk;
  ie.modifiers = mods;
  if (f)
    XSETFRAME (ie.frame_or_window, f);
  ie.timestamp = 0;
  ios_enqueue_event (&ie);
  return YES;
}

- (void) pressesBegan:(NSSet<UIPress *> *)presses
            withEvent:(UIPressesEvent *)event
{
  (void) event;
  BOOL handled = NO;
  for (UIPress *p in presses)
    {
      if (ios_emit_function_key (p.key))
        {
          handled = YES;
          continue;
        }
      int packed = ios_pack_uikey (p.key);
      if (packed >= 0)
        {
          ios_enqueue_key (packed);
          handled = YES;
        }
    }
  if (!handled)
    [super pressesBegan:presses withEvent:event];
}

- (void) appendCommand:(EmacsDrawCommand *)cmd
{
  [_lock lock];
  [_pending addObject:cmd];
  [_lock unlock];
}

/* Frame open: seed _pending with whatever's currently displayed,
   so a tick that only emits a few delta glyphs (Emacs's redisplay
   is incremental: many ticks update just the modeline or one row)
   keeps the older content underneath.  Each glyph string that
   draws over an existing position naturally overpaints the older
   one because Core Text draws in list order.

   This means _pending can grow without bound across many partial
   ticks.  Cap it at 2000 entries -- a full screenful of glyphs is
   well under that for typical font sizes.  Once over, drop the
   oldest in favor of the newest.  */
- (void) beginFrame
{
  [_lock lock];
  [_pending setArray:_displayed];
  [_lock unlock];
}

/* Frame close: promote the accumulated draft and request a paint.
   Always copies, even when no draws happened this tick -- because
   _pending was seeded from _displayed at beginFrame, copying it
   back produces a stable identity transition.  */
- (void) endFrame
{
  [_lock lock];
  NSUInteger n = _pending.count;
  if (n > 2000)
    [_pending removeObjectsInRange:NSMakeRange (0, n - 2000)];
  _displayed = [_pending copy];
  [_pending removeAllObjects];
  [_lock unlock];
  dispatch_async (dispatch_get_main_queue (), ^{
    [self setNeedsDisplay];
  });
}

- (void) drawRect:(CGRect)rect
{
  (void) rect;
  CGContextRef cg = UIGraphicsGetCurrentContext ();
  if (cg == NULL)
    return;

  [_lock lock];
  NSArray<EmacsDrawCommand *> *snapshot = _displayed;
  [_lock unlock];


  /* Flip the y-axis: Core Graphics has origin at bottom-left, UIKit
     and Emacs both use top-left.  */
  CGContextSaveGState (cg);
  CGContextTranslateCTM (cg, 0, self.bounds.size.height);
  CGContextScaleCTM (cg, 1, -1);

  for (EmacsDrawCommand *cmd in snapshot)
    {
      /* Decode packed RGB pixels into normalized components.  */
      CGFloat fr = ((cmd.fg >> 16) & 0xff) / 255.0;
      CGFloat fg = ((cmd.fg >>  8) & 0xff) / 255.0;
      CGFloat fb = ((cmd.fg      ) & 0xff) / 255.0;
      CGFloat br = ((cmd.bg >> 16) & 0xff) / 255.0;
      CGFloat bg = ((cmd.bg >>  8) & 0xff) / 255.0;
      CGFloat bb = ((cmd.bg      ) & 0xff) / 255.0;

      CGFloat by = self.bounds.size.height - cmd.y - cmd.height;

      if (cmd.kind != EmacsDrawKindText)
        {
          /* Cursor commands: just paint the rectangle.  */
          CGContextSetRGBFillColor (cg, fr, fg, fb, 1.0);
          switch (cmd.kind)
            {
            case EmacsDrawKindCursorFilled:
              CGContextFillRect (cg, CGRectMake (cmd.x, by,
                                                 cmd.width, cmd.height));
              break;
            case EmacsDrawKindCursorHollow:
              CGContextSetRGBStrokeColor (cg, fr, fg, fb, 1.0);
              CGContextSetLineWidth (cg, 1);
              CGContextStrokeRect (cg, CGRectMake (cmd.x + 0.5, by + 0.5,
                                                   cmd.width - 1,
                                                   cmd.height - 1));
              break;
            case EmacsDrawKindCursorBar:
              CGContextFillRect (cg, CGRectMake (cmd.x, by, 2, cmd.height));
              break;
            case EmacsDrawKindCursorHBar:
              CGContextFillRect (cg, CGRectMake (cmd.x, by, cmd.width, 2));
              break;
            default:
              break;
            }
          continue;
        }

      /* Weight + italic from the face decoration flags.  Cache
         resolved fonts: drawRect runs once per redisplay over
         hundreds of commands, and UIFont lookup + descriptor
         mutation per command dominated the profile.  Key packs
         (size << 2 | bold | italic<<1); sizes are whole points
         in practice so the int cast is lossless.  */
      static NSMutableDictionary<NSNumber *, UIFont *> *fontCache;
      if (!fontCache)
        fontCache = [NSMutableDictionary dictionary];
      BOOL wantBold   = (cmd.deco & EmacsDrawDecoBold) != 0;
      BOOL wantItalic = (cmd.deco & EmacsDrawDecoItalic) != 0;
      NSNumber *fontKey = @(((int) cmd.fontSize << 2)
                            | (wantBold ? 1 : 0)
                            | (wantItalic ? 2 : 0));
      UIFont *font = fontCache[fontKey];
      if (!font)
        {
          UIFontWeight wt = wantBold ? UIFontWeightBold
                                     : UIFontWeightRegular;
          font = [UIFont monospacedSystemFontOfSize:cmd.fontSize
                                             weight:wt];
          if (!font)
            font = [UIFont systemFontOfSize:cmd.fontSize];
          if (wantItalic)
            {
              UIFontDescriptor *d = [font.fontDescriptor
                                      fontDescriptorWithSymbolicTraits:
                                      UIFontDescriptorTraitItalic];
              if (d)
                font = [UIFont fontWithDescriptor:d size:cmd.fontSize];
            }
          if (font)
            fontCache[fontKey] = font;
        }

      if (cmd.width > 0 && cmd.height > 0)
        {
          CGContextSetRGBFillColor (cg, br, bg, bb, 1.0);
          CGContextFillRect (cg, CGRectMake (cmd.x, by,
                                             cmd.width, cmd.height));
        }
      if (cmd.text.length == 0)
        continue;
      UIColor *uifg = [UIColor colorWithRed:fr green:fg blue:fb alpha:1.0];
      NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: uifg,
      };
      NSAttributedString *as = [[NSAttributedString alloc]
                                 initWithString:cmd.text attributes:attrs];
      CTLineRef line = CTLineCreateWithAttributedString
        ((__bridge CFAttributedStringRef) as);
      if (line == NULL)
        continue;
      CGFloat baseline = self.bounds.size.height - cmd.y - font.ascender;
      CGContextSetTextPosition (cg, cmd.x, baseline);
      CTLineDraw (line, cg);
      CFRelease (line);

      /* Decorations: stroke the same fg color underneath / above /
         through the text.  Coordinates are in the flipped CG
         space, so "below text" means smaller y, "above" larger.  */
      if (cmd.deco & (EmacsDrawDecoUnderlineSingle
                      | EmacsDrawDecoUnderlineWave
                      | EmacsDrawDecoOverline
                      | EmacsDrawDecoStrikeThrough))
        {
          CGContextSetRGBStrokeColor (cg, fr, fg, fb, 1.0);
          CGContextSetLineWidth (cg, 1.0);
          CGFloat textWidth = (cmd.width > 0) ? cmd.width : 1;
          if (cmd.deco & (EmacsDrawDecoUnderlineSingle
                          | EmacsDrawDecoUnderlineWave))
            {
              CGFloat uy = baseline - 1.5;
              if (cmd.deco & EmacsDrawDecoUnderlineWave)
                {
                  /* Sketch a sine-ish wave below the baseline.  */
                  CGFloat amp = 1.5;
                  CGFloat step = 3.0;
                  CGContextBeginPath (cg);
                  CGContextMoveToPoint (cg, cmd.x, uy);
                  for (CGFloat xx = cmd.x; xx < cmd.x + textWidth; xx += step)
                    {
                      CGFloat ny = uy + ((((int)(xx - cmd.x) / (int) step) & 1)
                                          ? amp : -amp);
                      CGContextAddLineToPoint (cg, xx + step, ny);
                    }
                  CGContextStrokePath (cg);
                }
              else
                {
                  CGContextStrokeRect (cg, CGRectMake (cmd.x, uy,
                                                       textWidth, 0));
                }
            }
          if (cmd.deco & EmacsDrawDecoOverline)
            {
              CGFloat oy = baseline + font.ascender;
              CGContextStrokeRect (cg, CGRectMake (cmd.x, oy,
                                                   textWidth, 0));
            }
          if (cmd.deco & EmacsDrawDecoStrikeThrough)
            {
              CGFloat sy = baseline + font.ascender * 0.4;
              CGContextStrokeRect (cg, CGRectMake (cmd.x, sy,
                                                   textWidth, 0));
            }
        }
    }

  CGContextRestoreGState (cg);
}
@end

/* Weakly-held reference to the installed canvas so the C-side
   draw_glyph_string can push commands without going through the
   Lisp side.  Weak so it auto-clears at app shutdown.  */
__weak static EmacsUIView *ios_canvas = nil;

void
ios_canvas_draw_text (double x, double y, double width, double height,
                      unsigned long fg_pixel, unsigned long bg_pixel,
                      const char *utf8, double font_size,
                      unsigned deco)
{
  EmacsUIView *v = ios_canvas;
  if (v == nil || utf8 == NULL)
    return;
  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  cmd.kind = EmacsDrawKindText;
  cmd.x = x;
  cmd.y = y;
  cmd.width = width;
  cmd.height = height;
  cmd.fg = (uint32_t) (fg_pixel & 0xffffff);
  cmd.bg = (uint32_t) (bg_pixel & 0xffffff);
  cmd.text = [NSString stringWithUTF8String:utf8];
  cmd.fontSize = font_size > 0 ? font_size : 14;
  cmd.deco = (EmacsDrawDeco) deco;
  [v appendCommand:cmd];
}

/* Clear a rectangular region.  Used by clear_frame_area /
   clear_under_internal_border to erase stale content.  Implemented
   as an EmacsDrawKindText command with empty text -- the background
   fill in drawRect: handles the actual paint.  */
void
ios_canvas_clear_rect (double x, double y, double width, double height,
                       unsigned long bg_pixel)
{
  EmacsUIView *v = ios_canvas;
  if (v == nil) return;
  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  cmd.kind = EmacsDrawKindText;
  cmd.x = x; cmd.y = y;
  cmd.width = width; cmd.height = height;
  cmd.bg = (uint32_t) (bg_pixel & 0xffffff);
  cmd.text = @"";
  [v appendCommand:cmd];
}

/* Cursor "command": just a rectangle of the given style.  kind
   encodes the style; the caller picks based on the redisplay
   engine's cursor type.  */
void
ios_canvas_draw_cursor (double x, double y, double width, double height,
                        unsigned long pixel, int style /* enum text_cursor_kinds */)
{
  EmacsUIView *v = ios_canvas;
  if (v == nil) return;
  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  switch (style)
    {
    case 1: cmd.kind = EmacsDrawKindCursorHollow; break;  /* HOLLOW_BOX */
    case 2: cmd.kind = EmacsDrawKindCursorBar; break;     /* BAR */
    case 3: cmd.kind = EmacsDrawKindCursorHBar; break;    /* HBAR */
    default: cmd.kind = EmacsDrawKindCursorFilled; break; /* FILLED_BOX */
    }
  cmd.x = x; cmd.y = y;
  cmd.width = width; cmd.height = height;
  cmd.fg = (uint32_t) (pixel & 0xffffff);
  [v appendCommand:cmd];
}

/* C-callable hooks for the terminal-level update_begin / update_end
   bracket.  begin clears the in-progress draft; end atomically
   promotes it to the displayed snapshot and requests a paint.  */
void
ios_canvas_begin_frame (void)
{
  EmacsUIView *v = ios_canvas;
  if (v) [v beginFrame];
}

void
ios_canvas_end_frame (void)
{
  EmacsUIView *v = ios_canvas;
  if (v) [v endFrame];
}


/* ---- Auto-input thread (CI screenshot driver) ----------------- */

static void *
ios_auto_input_thread (void *unused)
{
  (void) unused;
  sleep (5);
  /* Escape the splash buffer: it has its own keymap and won't
     route C-x b until we quit it.  Send `q' which runs
     `quit-window' from view-mode / fundamental-mode splash.  */
  ios_launch_log (@"auto-input(thread): q (quit splash)");
  ios_enqueue_key ('q');
  sleep (2);
  ios_launch_log (@"auto-input(thread): C-x b *scratch* RET");
  const char *switchb = "\x18" "b*scratch*\r";
  for (const char *p = switchb; *p; p++)
    ios_enqueue_key ((int) (unsigned char) *p);
  sleep (2);
  ios_launch_log (@"auto-input(thread): typing demo text");
  const char *msg = "hello from Emacs on iOS!";
  for (const char *p = msg; *p; p++)
    ios_enqueue_key ((int) (unsigned char) *p);
  return NULL;
}


/* ---- Background-thread entry --------------------------------- */

/* pthread entry that drives Emacs init.  Defined as a real function
   rather than a dispatch_async block so we can guarantee a 16 MB
   stack -- see the pthread_create call in didFinishLaunchingWithOptions
   for the SIGILL-on-stack-overflow rationale.  Returns NULL; the
   detached pthread implicitly cleans itself up when ios_main eventually
   exits (which it never does in normal operation).  */
static void *
ios_emacs_bg_thread (void *unused)
{
  (void) unused;
  ios_launch_log (@"emacs-bg: dispatched, about to call ios_main");

  /* Synthesize argc/argv from NSProcessInfo.  argv[0] is the
     process path Apple's launcher gave us, which Emacs uses to
     locate its install directory.  */
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  int argc_ = (int) args.count;
  char **argv_ = malloc (sizeof (char *) * (argc_ + 1));
  for (int i = 0; i < argc_; i++)
    argv_[i] = strdup (args[i].UTF8String);
  argv_[argc_] = NULL;
  ios_launch_log ([NSString stringWithFormat:
                   @"emacs-bg: argc=%d argv[0]=%s",
                   argc_, argv_[0] ?: "(null)"]);

  int rc = ios_main (argc_, argv_);
  ios_launch_log ([NSString stringWithFormat:
                   @"emacs-bg: ios_main returned %d", rc]);
  return NULL;
}


/* ---- EmacsAppDelegate ----------------------------------------- */

/* UIApplicationDelegate that boots Emacs.  Defined in this binary so
   UIApplicationMain's NSClassFromString lookup succeeds.  Phase 1:
   shows a red placeholder screen, redirects stdio, and dispatches
   ios_main() to a background queue.  Phase 2 will replace the
   placeholder screen with an EmacsUIView once iosterm.m grows real
   drawing.  */

@interface EmacsAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation EmacsAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)opts
{
  ios_redirect_stdio ();
  ios_launch_log (@"AppDelegate didFinishLaunchingWithOptions: enter");

  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.backgroundColor = UIColor.blackColor;

  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = UIColor.blackColor;

  /* Title strip across the top, so the launch image is unambiguously
     "Emacs is starting" rather than "the simulator is broken".  */
  UILabel *title = [[UILabel alloc] init];
  title.text = @"GNU Emacs (iOS bring-up)";
  title.textColor = UIColor.whiteColor;
  title.font = [UIFont boldSystemFontOfSize:20];
  title.textAlignment = NSTextAlignmentCenter;
  title.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:title];

  /* Split layout: log at the top third, EmacsUIView at the bottom
     two thirds.  The log keeps the bring-up visibly progressing
     while the canvas surfaces whatever the iOS redisplay engine
     pushes through draw_glyph_string.  */
  UITextView *logView = [[UITextView alloc] init];
  logView.backgroundColor = UIColor.blackColor;
  logView.textColor = UIColor.greenColor;
  logView.font = [UIFont fontWithName:@"Menlo" size:10];
  logView.editable = NO;
  logView.text = @"";
  logView.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:logView];

  EmacsUIView *canvas = [[EmacsUIView alloc] initWithFrame:CGRectZero];
  canvas.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:canvas];

  UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
      [title.topAnchor      constraintEqualToAnchor:safe.topAnchor
                                           constant:8],
      [title.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor
                                           constant:8],
      [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                           constant:-8],
      [logView.topAnchor      constraintEqualToAnchor:title.bottomAnchor
                                              constant:8],
      [logView.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor],
      [logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
      /* Log strip stays ~one notebook-tab tall.  Was 30% of the
         safe area, which left the canvas with barely more than
         half the screen on iPhone; users want most of the screen
         for actual Emacs.  Diagnostics fit comfortably in 120pt
         and a long tail scrolls inside the UITextView.  */
      [logView.heightAnchor   constraintEqualToConstant:120],
      [canvas.topAnchor       constraintEqualToAnchor:logView.bottomAnchor
                                              constant:8],
      [canvas.leadingAnchor   constraintEqualToAnchor:safe.leadingAnchor],
      [canvas.trailingAnchor  constraintEqualToAnchor:safe.trailingAnchor],
      [canvas.bottomAnchor    constraintEqualToAnchor:safe.bottomAnchor],
  ]];

  ios_log_view = logView;
  ios_canvas   = canvas;

  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  ios_launch_log (@"AppDelegate window visible (log view installed)");

  /* Kick off Emacs initialization on a dedicated pthread.  ios_main
     never returns (Emacs's main loop runs forever), so blocking the
     UI thread on it would deadlock UIKit and trip the iOS launch
     watchdog.
     A dispatch_async background queue has only ~512 KB of stack on
     iOS, which the Emacs Lisp interpreter blows through in ~500
     levels of recursion -- loadup.el's preload pass hit a SIGILL
     stack overflow inside Fassq during eval_sub recursion.  Use a
     pthread with an explicit 16 MB stack instead.  */
  pthread_attr_t attr;
  pthread_attr_init (&attr);
  pthread_attr_setstacksize (&attr, 16 * 1024 * 1024);
  pthread_attr_setdetachstate (&attr, PTHREAD_CREATE_DETACHED);
  pthread_t tid;
  int pterr = pthread_create (&tid, &attr, ios_emacs_bg_thread, NULL);
  pthread_attr_destroy (&attr);
  ios_launch_log ([NSString stringWithFormat:
                   @"AppDelegate: pthread_create rc=%d", pterr]);

  ios_launch_log (@"AppDelegate didFinishLaunchingWithOptions: returning YES");

  /* CI diagnostic: synthesize an input event a few seconds after
     launch so the simulator screenshot captures something other
     than the loadup splash.  On a real device the user provides
     these via tap/keyboard; without this the headless CI run
     never moves past `Welcome / Loading'.

     5s = startup-init complete (loadup is ~3s on macOS arm64
     simulators), 8s = pre-screenshot.  */
  /* CI screenshot driver: send keys on a dedicated pthread instead
     of dispatch_after on the main queue.  The +10s main-queue
     dispatch never fired in past runs -- the simulator screenshot
     operation appears to nudge the app's lifecycle in a way that
     drops queued blocks.  A standalone pthread with sleep() is
     immune to that.  */
  /* Only run the auto-typing driver when CI asks for it
     (simctl launch inherits SIMCTL_CHILD_* variables into the
     app's environment).  A real user's launch must not have demo
     keystrokes injected 5 seconds in.  */
  if (getenv ("EMACS_IOS_AUTO_INPUT"))
    {
      pthread_t auto_thread;
      pthread_attr_t auto_attr;
      pthread_attr_init (&auto_attr);
      pthread_attr_setdetachstate (&auto_attr, PTHREAD_CREATE_DETACHED);
      pthread_create (&auto_thread, &auto_attr,
                      ios_auto_input_thread, NULL);
      pthread_attr_destroy (&auto_attr);
    }
  return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationDidBecomeActive");
}

- (void)applicationWillResignActive:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationWillResignActive");
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationDidEnterBackground");
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationWillTerminate");
}

/* iOS hands files opened from Files / Mail / Safari / share
   sheet to the app via this callback.  The URL is security-scoped;
   start access, then enqueue a synthetic key sequence that lands
   in *scratch* as (find-file "PATH") -- Emacs's command loop
   evaluates it and the user sees the file open.

   Building a NON_ASCII_KEYSTROKE_EVENT for each char keeps us out
   of any Lisp eval machinery on the wrong thread; the keystrokes
   simply replay as if the user typed them.  */
- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  if (url == nil)
    return NO;
  BOOL scoped = [url startAccessingSecurityScopedResource];
  NSString *path = url.path;
  if (path.length == 0)
    {
      if (scoped) [url stopAccessingSecurityScopedResource];
      return NO;
    }
  ios_launch_log ([NSString stringWithFormat:
                   @"AppDelegate openURL: %@", path]);
  /* Publish the path; the Emacs thread builds a DRAG_N_DROP_EVENT
     from it inside read_socket (Lisp allocation is unsafe on
     this thread, and synthesizing keystrokes would misfire if
     the minibuffer happens to be active).  */
  ios_publish_open_file (path.fileSystemRepresentation);
  return YES;
}

@end


/* ---- Entry points --------------------------------------------- */

/* C-level Emacs entry point invoked from the AppDelegate on its
   background queue.  Resolves the dump file path, then hands off to
   the renamed emacs.c main().  Wraps the call with launch-log lines
   so a hang inside ios_emacs_init can be localized.  */

/* Point Emacs at the bundled lisp/ and etc/ trees.  Without this the
   stock $prefix/share/emacs/$VERSION paths apply -- those resolve
   into /usr/local on the runner and into the simulator's sandbox
   root on a device, neither of which exists.  Setting EMACSLOADPATH
   and EMACSDATA before ios_emacs_init is the same mechanism the
   Android port uses; the load-path bootstrap in emacs.c reads these
   envvars before computing the built-in fallback list.  */
/* C-callable accessor for the sandbox path enumeration declared
   in iosvfs.c.  Returns a pointer into an internal cache; callers
   must not free.  */
const char *
ios_sandbox_directory (int which)
{
  static NSString *cache[5] = {0};
  if (which < 0 || which > 4)
    return NULL;
  if (cache[which])
    return cache[which].fileSystemRepresentation;
  NSArray<NSString *> *arr = nil;
  switch (which)
    {
    case 0: cache[0] = [NSBundle mainBundle].bundlePath; break;
    case 1:
      arr = NSSearchPathForDirectoriesInDomains
            (NSDocumentDirectory, NSUserDomainMask, YES);
      if (arr.count > 0) cache[1] = arr[0];
      break;
    case 2:
      arr = NSSearchPathForDirectoriesInDomains
            (NSLibraryDirectory, NSUserDomainMask, YES);
      if (arr.count > 0) cache[2] = arr[0];
      break;
    case 3:
      arr = NSSearchPathForDirectoriesInDomains
            (NSCachesDirectory, NSUserDomainMask, YES);
      if (arr.count > 0) cache[3] = arr[0];
      break;
    case 4: cache[4] = NSTemporaryDirectory (); break;
    }
  return cache[which] ? cache[which].fileSystemRepresentation : NULL;
}

static void
ios_setenv_bundle_paths (void)
{
  NSString *bundle = [NSBundle mainBundle].bundlePath;
  if (!bundle)
    return;
  NSString *lisp = [bundle stringByAppendingPathComponent:@"lisp"];
  NSString *etc  = [bundle stringByAppendingPathComponent:@"etc"];
  setenv ("EMACSLOADPATH", lisp.UTF8String, 1);
  setenv ("EMACSDATA",     etc.UTF8String,  1);
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_setenv_bundle_paths: EMACSLOADPATH=%@ EMACSDATA=%@",
                   lisp, etc]);

  /* Point HOME at the Documents/ subtree of the sandbox.  iOS
     defaults getenv("HOME") to the app container's root, but the
     directory users see in the Files app -- and the only one
     visible in iCloud sync -- is Documents/.  Files saved
     anywhere else are effectively invisible to the user.

     If Documents/ doesn't exist yet (first launch), create it.
     Also create an Emacs/ subfolder there for user-init-file and
     stash that as XDG_CONFIG_HOME so site-start.el's lookup
     points inside it.  */
  const char *docs = ios_sandbox_directory (1 /* IOS_SBX_DOCUMENTS */);
  if (docs != NULL)
    {
      NSString *home = [NSString stringWithUTF8String:docs];
      [[NSFileManager defaultManager] createDirectoryAtPath:home
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
      setenv ("HOME", docs, 1);
      NSString *cfg = [home stringByAppendingPathComponent:@".emacs.d"];
      [[NSFileManager defaultManager] createDirectoryAtPath:cfg
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
      ios_launch_log ([NSString stringWithFormat:
                       @"ios_setenv_bundle_paths: HOME=%@", home]);
    }
}

int
ios_main (int argc, char **argv)
{
  ios_launch_log (@"ios_main: entered");
  ios_setenv_bundle_paths ();
  char *dump_file = ios_dump_path ();
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_main: dump_file=%s, calling ios_emacs_init",
                   dump_file ?: "(null)"]);
  int result = ios_emacs_init (argc, argv, dump_file);
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_main: ios_emacs_init returned %d", result]);
  free (dump_file);
  return result;
}

/* Process entry point of the cross-built emacs Mach-O.

   The bundle's CFBundleExecutable IS this binary, so on launch iOS
   transfers control here directly.  We hand off to UIApplicationMain
   with EmacsAppDelegate (defined above), which spins up the run
   loop and triggers didFinishLaunchingWithOptions.  */

int
main (int argc, char *argv[])
{
  @autoreleasepool {
    ios_launch_log (@"main: entered, calling UIApplicationMain");
    int rc = UIApplicationMain (argc, argv, nil,
                                NSStringFromClass ([EmacsAppDelegate class]));
    ios_launch_log ([NSString stringWithFormat:
                     @"main: UIApplicationMain returned %d", rc]);
    return rc;
  }
}

#endif /* HAVE_IOS */
