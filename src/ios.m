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

   UIApplicationMain instantiates EmacsAppDelegate, which must be
   defined in this binary: classes in the bundle template sources
   (ios/Emacs/) are not compiled into the cross-built executable,
   so NSClassFromString would return nil.  The delegate redirects
   stdout/stderr into the app's Documents/ directory and runs
   ios_main() on a dedicated background thread so Emacs
   initialization never blocks the UI thread.  Launch breadcrumbs
   are appended to Documents/emacs-launch.log; NSLog alone is
   unreliable on Simulator launches that happen outside
   `xcrun simctl launch --console'.  */

#include <config.h>

#ifdef HAVE_IOS

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#include <pthread.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
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

/* Append a timestamped MSG line to Documents/emacs-launch.log and
   echo it via NSLog.  Both channels are kept: NSLog reaches
   `simctl launch --console` and the unified log, while the file stays
   reachable through the Files app or the simulator's data container.
   The line is also appended to the on-screen log view, if one is
   installed, so startup progress is visible on the device.  */
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


/* ---- Security-scoped bookmark persistence --------------------- */

/* startAccessingSecurityScopedResource grants die with the
   process.  To let the user re-visit a Files-app document after a
   relaunch (recentf, desktop-save, plain find-file from history),
   persist a security-scoped bookmark per external URL and resolve
   the lot at startup.  NSUserDefaults is documented thread-safe;
   the restore runs once on the main queue during launch.  */

static NSString *const ios_bookmark_key = @"EmacsSecurityBookmarks";
#define IOS_BOOKMARK_CAP 64

void
ios_save_bookmark (NSURL *url)
{
  if (url == nil)
    return;
  NSError *err = nil;
  NSData *bm = [url bookmarkDataWithOptions:
                      NSURLBookmarkCreationMinimalBookmark
               includingResourceValuesForKeys:nil
                                relativeToURL:nil
                                        error:&err];
  if (bm == nil)
    return;
  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary *all =
    [[ud dictionaryForKey:ios_bookmark_key] mutableCopy]
    ?: [NSMutableDictionary dictionary];
  all[url.path] = bm;
  /* Cap: drop arbitrary entries beyond the cap.  A proper LRU
     would store timestamps; eviction is rare enough (64 distinct
     external documents) that arbitrary eviction is acceptable.  */
  while (all.count > IOS_BOOKMARK_CAP)
    [all removeObjectForKey:all.allKeys.firstObject];
  [ud setObject:all forKey:ios_bookmark_key];
}

static void
ios_restore_bookmarks (void)
{
  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  NSDictionary *all = [ud dictionaryForKey:ios_bookmark_key];
  if (all.count == 0)
    return;
  NSMutableDictionary *kept = [NSMutableDictionary dictionary];
  for (NSString *path in all)
    {
      NSData *bm = all[path];
      if (![bm isKindOfClass:NSData.class])
        continue;
      BOOL stale = NO;
      NSError *err = nil;
      NSURL *url = [NSURL URLByResolvingBookmarkData:bm
                                             options:
                      NSURLBookmarkResolutionWithoutUI
                                       relativeToURL:nil
                                 bookmarkDataIsStale:&stale
                                               error:&err];
      if (url == nil)
        continue;          /* gone; prune */
      [url startAccessingSecurityScopedResource];
      if (stale)
        {
          NSData *fresh = [url bookmarkDataWithOptions:
                                 NSURLBookmarkCreationMinimalBookmark
                          includingResourceValuesForKeys:nil
                                           relativeToURL:nil
                                                   error:&err];
          if (fresh)
            kept[url.path] = fresh;
        }
      else
        kept[path] = bm;
    }
  [ud setObject:kept forKey:ios_bookmark_key];
  ios_launch_log ([NSString stringWithFormat:
                   @"restored %lu security-scoped bookmarks",
                   (unsigned long) kept.count]);
}

/* ---- EmacsUIView -- the glyph canvas -------------------------- */

/* Each drawing call from the Emacs redisplay engine on the
   background pthread renders immediately into a bitmap backing
   store owned by the view (the same architecture as every other
   port's pixmap / back buffer): painting is permanent until
   painted over, scrolling is a blit, and drawRect: on the main
   thread just composites the bitmap.  EmacsDrawCommand carries
   one operation's parameters from the C entry points to the
   renderer.  */
/* Command kinds: a draw command is either a glyph string or a
   cursor.  Cursor commands carry no text; just the rectangle and
   pixel.  */
typedef NS_ENUM (NSUInteger, EmacsDrawKind) {
  EmacsDrawKindText = 0,
  EmacsDrawKindCursorFilled,
  EmacsDrawKindCursorHollow,
  EmacsDrawKindCursorBar,
  EmacsDrawKindCursorHBar,
  EmacsDrawKindImage,
  /* Real Core Text glyphs: glyphData / glyphPos carry the CGGlyph and
     CGPoint arrays, ctFont the face.  */
  EmacsDrawKindGlyphs,
  /* Not a glyph op: blits the source band [y, y+height) within
     x-range [x, x+width) by shiftDy inside the backing store
     (scroll_run).  */
  EmacsDrawKindShift,
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
@property (nonatomic) CGFloat shiftDy;   /* EmacsDrawKindShift only */
/* Clip rectangle in Emacs (top-left) coordinates; clipWidth <= 0
   means unclipped.  Redisplay clips glyph strings to the window
   area that owns them -- most visibly the partially-visible last
   row of a window whose height is not an exact multiple of the
   line height, which must not paint over the mode line below.  */
@property (nonatomic) CGFloat clipX;
@property (nonatomic) CGFloat clipY;
@property (nonatomic) CGFloat clipWidth;
@property (nonatomic) CGFloat clipHeight;
/* Emacs cell (column) width in points.  Text is positioned per
   composed character on this grid rather than with Core Text's
   natural advances; 0 falls back to a single natural-advance
   CTLine (pre-grid behavior).  */
@property (nonatomic) CGFloat cellWidth;
/* For EmacsDrawKindImage: a manually-CGImageRetained image.  CGImage
   is not toll-free-bridged to NSObject, so an ARC strong id would
   leak: the setter manages the retain explicitly, and dealloc
   releases.  */
@property (nonatomic, assign) CGImageRef cgImage;
/* For EmacsDrawKindGlyphs: the CGGlyph array, a matching CGPoint array
   in Emacs (top-left, baseline-y) frame coordinates, and the face.
   Commands paint synchronously, so ctFont is only borrowed for the
   duration of the call and needs no retain.  */
@property (nonatomic, strong) NSData *glyphData;
@property (nonatomic, strong) NSData *glyphPos;
@property (nonatomic, assign) CTFontRef ctFont;
@end
@implementation EmacsDrawCommand
- (void) setCgImage:(CGImageRef)image
{
  if (_cgImage == image)
    return;
  if (_cgImage)
    CGImageRelease (_cgImage);
  _cgImage = image ? CGImageRetain (image) : NULL;
}
- (void) dealloc
{
  if (_cgImage)
    CGImageRelease (_cgImage);
}
@end

/* Implemented in iosterm.m; enqueues a code point into the
   input queue that ios_read_socket drains on the bg pthread.  */
extern void ios_enqueue_key (int codepoint);
extern void ios_enqueue_event (struct input_event *ie);
extern void ios_publish_canvas_size (double width, double height);
extern void ios_publish_mouse_motion (double x, double y);
extern void ios_publish_appearance_change (void);
extern void ios_publish_foreground_expose (void);
extern void ios_publish_open_file (const char *path);
extern void ios_publish_pinch (double x, double y, double dx, double dy,
                               double scale, double angle);

@interface EmacsUIView : UIView <UIKeyInput>
- (void) drawCommand:(EmacsDrawCommand *)cmd;
- (void) beginFrame;
- (void) endFrame;
/* When set, inputView returns an empty view so the soft keyboard
   stays hidden while the canvas remains first responder (hardware
   keys keep flowing).  */
- (void) setKeyboardSuppressed:(BOOL)flag;
/* Background pixel used when (re)creating the backing store.  */
- (void) setBackgroundPixel:(uint32_t)pixel;
@end

@implementation EmacsUIView
{
  /* The backing store.  _lock guards the context pointer and all
     drawing into it: the Emacs thread paints, the main thread
     snapshots it in drawRect: and swaps it in layoutSubviews.
     Dimensions are in points; the context's CTM carries the
     device scale.  */
  CGContextRef _backing;
  CGFloat _backingW, _backingH, _backingScale;
  uint32_t _bgPixel;
  NSLock *_lock;
  /* Non-nil replaces the system keyboard; see
     setKeyboardSuppressed.  */
  UIView *_suppressedInputView;
}

- (void) setKeyboardSuppressed:(BOOL)flag
{
  _suppressedInputView
    = flag ? [[UIView alloc] initWithFrame:CGRectZero] : nil;
}

- (UIView *) inputView
{
  return _suppressedInputView;
}

- (instancetype) initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame]))
    {
      /* Match the system appearance until Emacs pushes its real
         frame background (ios_canvas_set_background below), so
         unpainted margins and sub-row slack blend in under both
         light and dark appearance.  */
      self.backgroundColor = UIColor.systemBackgroundColor;
      self.opaque = YES;
      _bgPixel = 0xffffff;
      _lock = [[NSLock alloc] init];
      self.userInteractionEnabled = YES;
      /* Single-tap: become first responder (bringing up the soft
         keyboard) and synthesize a mouse-1 click; see handleTap.  */
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

/* Enqueue one half of a synthesized mouse-button event.  BUTTON
   is the Emacs button number (0 = mouse-1, 1 = mouse-2, ...);
   UPDOWN is down_modifier or up_modifier.

   frame_or_window is deliberately left nil: this runs on the
   UIKit thread, where reading frame state (Vframe_list,
   highlight_frame) would race frame deletion on the Emacs
   thread.  The drain in iosterm.m attaches the frame on the
   Emacs thread before storing the event.  */
/* Monotonic milliseconds for input_event.timestamp.  keyboard.c's
   click-count logic compares successive button timestamps against
   double-click-time, so button events need real timestamps; a
   constant would make every tap read as a multi-click.  */
static Time
ios_event_timestamp (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (Time) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void
ios_emit_button_event (int button, int updown, CGPoint pt)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = MOUSE_CLICK_EVENT;
  ie.code = button;
  ie.modifiers = updown;
  ie.x = make_fixnum ((int) pt.x);
  ie.y = make_fixnum ((int) pt.y);
  ie.frame_or_window = Qnil;
  ie.timestamp = ios_event_timestamp ();
  ios_enqueue_event (&ie);
}

/* Enqueue a wheel event at PT.  FORWARD true = scroll content
   forward (wheel-down in mwheel's terms).  Frame attached on the
   Emacs thread, as above.  */
static void
ios_emit_wheel_event (bool forward, CGPoint pt)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = WHEEL_EVENT;
  ie.code = 0;
  ie.modifiers = forward ? down_modifier : up_modifier;
  ie.x = make_fixnum ((int) pt.x);
  ie.y = make_fixnum ((int) pt.y);
  ie.frame_or_window = Qnil;
  ie.arg = Qnil;
  ie.timestamp = ios_event_timestamp ();
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
    {
      [_lock lock];
      [self ensureBackingForSize:sz];
      [_lock unlock];
      ios_publish_canvas_size (sz.width, sz.height);
    }
}

/* (Re)create the backing store for SZ points at the screen's
   scale.  Caller holds _lock.  The old content is copied in
   top-left-anchored so a resize shows stale-but-sane pixels for
   the moment until the resize-triggered full redisplay repaints;
   uncovered area is background.  */
- (void) ensureBackingForSize:(CGSize)sz
{
  CGFloat scale = self.window.screen.scale;
  if (scale <= 0)
    scale = UIScreen.mainScreen.scale;
  if (_backing != NULL && _backingW == sz.width
      && _backingH == sz.height && _backingScale == scale)
    return;
  size_t pw = (size_t) llround (sz.width * scale);
  size_t ph = (size_t) llround (sz.height * scale);
  if (pw == 0 || ph == 0)
    return;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB ();
  CGContextRef ctx =
    CGBitmapContextCreate (NULL, pw, ph, 8, 0, cs,
                           kCGImageAlphaPremultipliedFirst
                           | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease (cs);
  if (ctx == NULL)
    return;
  /* Draw in points; the CTM carries the device scale.  The
     context keeps Core Graphics's native bottom-left origin --
     the renderer flips y per operation, and Core Text needs the
     unflipped orientation anyway.  */
  CGContextScaleCTM (ctx, scale, scale);
  CGContextSetRGBFillColor (ctx,
                            ((_bgPixel >> 16) & 0xff) / 255.0,
                            ((_bgPixel >> 8) & 0xff) / 255.0,
                            (_bgPixel & 0xff) / 255.0, 1.0);
  CGContextFillRect (ctx, CGRectMake (0, 0, sz.width, sz.height));
  if (_backing != NULL)
    {
      CGImageRef old = CGBitmapContextCreateImage (_backing);
      if (old != NULL)
        {
          CGContextDrawImage (ctx,
                              CGRectMake (0, sz.height - _backingH,
                                          _backingW, _backingH),
                              old);
          CGImageRelease (old);
        }
      CGContextRelease (_backing);
    }
  _backing = ctx;
  _backingW = sz.width;
  _backingH = sz.height;
  _backingScale = scale;
}

- (void) setBackgroundPixel:(uint32_t)pixel
{
  [_lock lock];
  _bgPixel = pixel;
  [_lock unlock];
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
  /* Compact key strip above the soft keyboard.  The previous
     UIToolbar of UIBarButtonItems sized every button to the
     system's full-size bar metrics; ten items overflowed narrow
     iPhones with buttons clipped off the right edge.  A
     UIStackView with fillEqually distribution mathematically
     cannot overflow: every key gets width/10, and the compact
     font plus autoshrink keeps labels legible down to small
     phones.  UIInputView with InputViewStyleKeyboard matches the
     keyboard's own background/blur so the strip reads as part of
     the keyboard rather than a floating toolbar.  */
  static UIInputView *bar = nil;
  if (bar)
    return bar;
  bar = [[UIInputView alloc]
          initWithFrame:CGRectMake (0, 0, 0, 40)
          inputViewStyle:UIInputViewStyleKeyboard];
  bar.allowsSelfSizing = YES;
  bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

  UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
  row.axis = UILayoutConstraintAxisHorizontal;
  row.distribution = UIStackViewDistributionFillEqually;
  row.alignment = UIStackViewAlignmentFill;
  row.spacing = 4;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [bar addSubview:row];
  [NSLayoutConstraint activateConstraints:@[
    [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor
                                      constant:4],
    [row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor
                                       constant:-4],
    [row.topAnchor constraintEqualToAnchor:bar.topAnchor
                                  constant:4],
    [row.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor
                                     constant:-4],
    [bar.heightAnchor constraintEqualToConstant:40],
  ]];

  UIButton *(^mk)(NSString *, SEL) = ^UIButton *(NSString *t, SEL s) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13
                                          weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    b.layer.cornerRadius = 5;
    b.backgroundColor =
      [UIColor.systemGrayColor colorWithAlphaComponent:0.25];
    [b addTarget:self action:s
        forControlEvents:UIControlEventTouchUpInside];
    return b;
  };
  [row addArrangedSubview:mk (@"Esc",  @selector (accEsc))];
  [row addArrangedSubview:mk (@"Ctrl", @selector (accStickyCtrl))];
  [row addArrangedSubview:mk (@"Meta", @selector (accStickyMeta))];
  [row addArrangedSubview:mk (@"Tab",  @selector (accTab))];
  [row addArrangedSubview:mk (@"C-g",  @selector (accCg))];
  [row addArrangedSubview:mk (@"←", @selector (accLeft))];
  [row addArrangedSubview:mk (@"↓", @selector (accDown))];
  [row addArrangedSubview:mk (@"↑", @selector (accUp))];
  [row addArrangedSubview:mk (@"→", @selector (accRight))];
  [row addArrangedSubview:mk (@"M-x",  @selector (accMx))];
  return bar;
}

/* Push an X11-keysym function key (arrows etc.) through the rich
   event queue; frame attachment happens on the Emacs thread in the
   drain, same as every other UIKit-thread emitter.  */
static void
ios_emit_keysym (unsigned xk)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = NON_ASCII_KEYSTROKE_EVENT;
  ie.code = xk;
  ie.modifiers = (int) ios_sticky_mods;
  ie.frame_or_window = Qnil;
  ie.timestamp = 0;
  ios_enqueue_event (&ie);
  ios_sticky_mods = 0;
}

- (void) accStickyCtrl { ios_sticky_mods ^= CHAR_CTL; }
- (void) accStickyMeta { ios_sticky_mods ^= CHAR_META; }
- (void) accEsc        { ios_enqueue_key (0x1b); }
- (void) accTab        { ios_enqueue_key (0x09); }
/* C-g: the quit character.  read_socket's store path recognizes
   it and sets Vquit_flag immediately, and the polling atimer
   drains our queue even while Lisp is busy, so this gives
   touch-only users a working quit -- without it a stuck
   minibuffer prompt is inescapable.  */
- (void) accCg         { ios_enqueue_key (0x07); }
- (void) accLeft       { ios_emit_keysym (0xff51); }
- (void) accUp         { ios_emit_keysym (0xff52); }
- (void) accRight      { ios_emit_keysym (0xff53); }
- (void) accDown       { ios_emit_keysym (0xff54); }
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

  /* Resolve keys that stand for a control character by keyCode,
     before consulting -characters.  UIKit reports those as a sentinel
     name rather than the control code: -characters for Escape is the
     string "UIKeyInputEscape", so reading its first character yields
     `U'.  Backspace is handled earlier, in ios_hid_to_xkeysym.  */
  switch (key.keyCode)
    {
    case UIKeyboardHIDUsageKeyboardReturnOrEnter:
    case UIKeyboardHIDUsageKeypadEnter:
      return 0x0d | mods;
    case UIKeyboardHIDUsageKeyboardTab:
      return 0x09 | mods;
    case UIKeyboardHIDUsageKeyboardEscape:
      return 0x1b | mods;
    default:
      break;
    }

  /* For Control and Option combos prefer
     charactersIgnoringModifiers: C-Shift-a must produce 'a' (the
     canonicalization below turns it into 0x01), and with Option
     acting as Meta, key.characters would be the Option-layer
     glyph -- Option-f is a florin sign on a US layout -- so M-f
     would arrive as Meta plus that glyph instead of Meta-f.  For
     everything else use characters, which applies Shift
     layout-correctly: Shift+a is "A", Shift+1 on US is "!".  */
  NSString *chars =
    (key.modifierFlags & (UIKeyModifierControl | UIKeyModifierAlternate))
    ? key.charactersIgnoringModifiers
    : key.characters;
  if (chars.length == 0)
    chars = key.characters;
  if (chars.length == 0)
    chars = key.charactersIgnoringModifiers;
  if (chars.length == 0)
    return -1;

  /* Any remaining key whose -characters is a sentinel name is one the
     keyCode paths above do not cover; drop it rather than insert the
     first letter of the name.  */
  if ([chars hasPrefix:@"UIKeyInput"])
    return -1;

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
    /* Backspace must be intercepted here: UIKey.characters for the
       hardware delete key is "\b" (0x08), which the character
       packer would deliver as C-h, the help prefix.  0xff08 is
       XK_BackSpace, which keyboard.c turns into <backspace> and
       local-function-key-map remaps to DEL.  */
    case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return 0xff08;
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
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = NON_ASCII_KEYSTROKE_EVENT;
  ie.code = xk;
  ie.modifiers = mods;
  /* Frame attached by the drain on the Emacs thread.  */
  ie.frame_or_window = Qnil;
  ie.timestamp = ios_event_timestamp ();
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

- (void) drawCommand:(EmacsDrawCommand *)cmd
{
  [_lock lock];
  if (_backing != NULL)
    {
      if (cmd.kind == EmacsDrawKindShift)
        [self renderShift:cmd];
      else
        {
          CGContextSaveGState (_backing);
          if (cmd.clipWidth > 0)
            CGContextClipToRect (_backing,
                                 CGRectMake (cmd.clipX,
                                             _backingH - cmd.clipY
                                             - cmd.clipHeight,
                                             cmd.clipWidth,
                                             cmd.clipHeight));
          [self renderCommand:cmd];
          CGContextRestoreGState (_backing);
        }
    }
  [_lock unlock];
}

/* scroll_run: dispnew has decided the rows in the source band
   moved by shiftDy and will NOT redraw them, so the pixels must
   really move.  Blit the backing store onto itself, clipped to
   the destination band.  CGBitmapContextCreateImage is
   copy-on-write, so drawing back into the context reads the
   pre-blit pixels.  Caller holds _lock.  */
- (void) renderShift:(EmacsDrawCommand *)cmd
{
  CGFloat H = _backingH;
  CGFloat d0 = cmd.y + cmd.shiftDy;
  CGRect dest = CGRectMake (cmd.x, H - d0 - cmd.height,
                            cmd.width, cmd.height);
  CGImageRef snap = CGBitmapContextCreateImage (_backing);
  if (snap == NULL)
    return;
  CGContextSaveGState (_backing);
  CGContextClipToRect (_backing, dest);
  /* +shiftDy in Emacs's top-left space is -shiftDy in Core
     Graphics's bottom-left space.  */
  CGContextDrawImage (_backing,
                      CGRectMake (0, -cmd.shiftDy, _backingW, H),
                      snap);
  CGContextRestoreGState (_backing);
  CGImageRelease (snap);
}

/* Redisplay tick brackets.  Painting is immediate, so opening a
   tick needs no work; closing one requests a composite of the
   backing store.  */
- (void) beginFrame
{
}

- (void) endFrame
{
  dispatch_async (dispatch_get_main_queue (), ^{
    [self setNeedsDisplay];
  });
}

/* Execute one glyph / cursor / image command into the backing
   store.  The context is in Core Graphics's native bottom-left
   orientation (Core Text needs it); Emacs's top-left y flips per
   operation.  Caller holds _lock; _backing is non-NULL.  */
- (void) renderCommand:(EmacsDrawCommand *)cmd
{
  CGContextRef cg = _backing;

  /* Decode packed RGB pixels into normalized components.  */
  CGFloat fr = ((cmd.fg >> 16) & 0xff) / 255.0;
  CGFloat fg = ((cmd.fg >>  8) & 0xff) / 255.0;
  CGFloat fb = ((cmd.fg      ) & 0xff) / 255.0;
  CGFloat br = ((cmd.bg >> 16) & 0xff) / 255.0;
  CGFloat bg = ((cmd.bg >>  8) & 0xff) / 255.0;
  CGFloat bb = ((cmd.bg      ) & 0xff) / 255.0;

  CGFloat by = _backingH - cmd.y - cmd.height;

  if (cmd.kind == EmacsDrawKindImage)
    {
      CGImageRef ref = cmd.cgImage;
      if (ref != NULL)
        {
          /* Image y is given top-down (Emacs coords); CG draws
             with origin at bottom-left, hence the flip via by.
             CGContextDrawImage handles aspect ratio itself when
             the dst rect's aspect differs.  */
          CGContextDrawImage (cg, CGRectMake (cmd.x, by,
                                              cmd.width,
                                              cmd.height), ref);
        }
      return;
    }

  if (cmd.kind == EmacsDrawKindGlyphs)
    {
      /* Real Core Text glyphs.  The backing context is in CG's native
         bottom-left orientation, so each glyph origin flips from the
         Emacs baseline (top-left, y-down) to y-up: cgy = H - y.  */
      if (cmd.ctFont == NULL || cmd.glyphData == nil || cmd.glyphPos == nil)
        return;
      NSUInteger n = cmd.glyphData.length / sizeof (CGGlyph);
      if (n == 0)
        return;
      const CGGlyph *glyphs = (const CGGlyph *) cmd.glyphData.bytes;
      const CGPoint *epos   = (const CGPoint *) cmd.glyphPos.bytes;
      CGPoint *pos = malloc (n * sizeof (CGPoint));
      if (pos == NULL)
        return;
      for (NSUInteger i = 0; i < n; i++)
        pos[i] = CGPointMake (epos[i].x, _backingH - epos[i].y);
      CGContextSetRGBFillColor (cg, fr, fg, fb, 1.0);
      CGContextSetTextMatrix (cg, CGAffineTransformIdentity);
      CTFontDrawGlyphs (cmd.ctFont, glyphs, pos, n, cg);
      free (pos);
      return;
    }

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
          CGContextFillRect (cg, CGRectMake (cmd.x, by,
                                             cmd.width > 0 ? cmd.width : 2,
                                             cmd.height));
          break;
        case EmacsDrawKindCursorHBar:
          CGContextFillRect (cg, CGRectMake (cmd.x, by, cmd.width, 2));
          break;
        default:
          break;
        }
      return;
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
    return;
  UIColor *uifg = [UIColor colorWithRed:fr green:fg blue:fb alpha:1.0];
  NSDictionary *attrs = @{
    NSFontAttributeName: font,
    NSForegroundColorAttributeName: uifg,
  };
  CGFloat baseline = _backingH - cmd.y - font.ascender;
  if (cmd.cellWidth > 0)
    {
      /* Position every composed character on Emacs's integer
         cell grid.  A single CTLine advances by Core Text's
         natural glyph widths (8.43pt for 14pt SF Mono), while
         Emacs computes glyph positions from the ceil'd cell
         width (9pt) -- so a run drawn with natural advances
         disagrees with any later single-character repaint at
         an Emacs-computed x (cursor passage), visibly
         re-typesetting the row.  Per-cell placement makes the
         two grids identical.  Characters whose natural width
         is closer to two cells (CJK) get two.  */
      __block CGFloat pen = cmd.x;
      CGFloat cell = cmd.cellWidth;
      [cmd.text enumerateSubstringsInRange:
                  NSMakeRange (0, cmd.text.length)
                options:
                  NSStringEnumerationByComposedCharacterSequences
                usingBlock:^(NSString *ch, NSRange sub,
                             NSRange encl, BOOL *stop) {
        (void) sub; (void) encl; (void) stop;
        NSAttributedString *cas =
          [[NSAttributedString alloc] initWithString:ch
                                          attributes:attrs];
        CTLineRef cl = CTLineCreateWithAttributedString
          ((__bridge CFAttributedStringRef) cas);
        if (cl != NULL)
          {
            double natural =
              CTLineGetTypographicBounds (cl, NULL, NULL, NULL);
            int ncells = (natural > cell * 1.5) ? 2 : 1;
            CGContextSetTextPosition (cg, pen, baseline);
            CTLineDraw (cl, cg);
            CFRelease (cl);
            pen += cell * ncells;
          }
        else
          pen += cell;
      }];
    }
  else
    {
      NSAttributedString *as = [[NSAttributedString alloc]
                                 initWithString:cmd.text
                                     attributes:attrs];
      CTLineRef line = CTLineCreateWithAttributedString
        ((__bridge CFAttributedStringRef) as);
      if (line == NULL)
        return;
      CGContextSetTextPosition (cg, cmd.x, baseline);
      CTLineDraw (line, cg);
      CFRelease (line);
    }

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

/* Composite the backing store.  The UIKit context arrives with a
   top-left origin; flip it so the CG-oriented backing image draws
   upright, anchored to the view's top-left even while a resize
   has the two sizes momentarily different.  */
- (void) drawRect:(CGRect)rect
{
  (void) rect;
  CGContextRef cg = UIGraphicsGetCurrentContext ();
  if (cg == NULL)
    return;
  [_lock lock];
  CGImageRef img = _backing ? CGBitmapContextCreateImage (_backing) : NULL;
  CGFloat w = _backingW, h = _backingH;
  [_lock unlock];
  if (img == NULL)
    return;
  CGFloat viewH = self.bounds.size.height;
  CGContextSaveGState (cg);
  CGContextTranslateCTM (cg, 0, viewH);
  CGContextScaleCTM (cg, 1, -1);
  CGContextSetInterpolationQuality (cg, kCGInterpolationNone);
  CGContextDrawImage (cg, CGRectMake (0, viewH - h, w, h), img);
  CGContextRestoreGState (cg);
  CGImageRelease (img);
}
@end

/* Weakly-held reference to the installed canvas so the C-side
   draw_glyph_string can push commands without going through the
   Lisp side.  Weak so it auto-clears at app shutdown.  */
__weak static EmacsUIView *ios_canvas = nil;

/* Background lifecycle flag.  Set by applicationDidEnterBackground,
   cleared by applicationDidBecomeActive.  Atomic so the Emacs
   thread can poll it without locking.  When set, all the
   ios_canvas_* entry points return early -- redisplay still runs
   on the Emacs side but produces no UIKit work, so a sleeping app
   doesn't keep draining the wake pipe to no purpose and doesn't
   trip iOS's background-CPU watchdog.  */
static _Atomic bool ios_backgrounded = false;

void
ios_set_backgrounded (bool flag)
{
  atomic_store (&ios_backgrounded, flag);
}

/* The canvas view, for main-thread UIKit code that needs to anchor
   presentation relative to Emacs frame coordinates (iosmenu.m's
   popovers).  Frame pixels and canvas points are the same space, so
   a popover sourceRect built from Emacs event coordinates is only
   correct when its sourceView is this view -- anchoring to the root
   view offset every popover by the safe-area inset.  Main thread
   only; may return nil during launch.  */
UIView *
ios_menu_anchor_view (void)
{
  return ios_canvas;
}

static inline bool
ios_is_backgrounded (void)
{
  return atomic_load (&ios_backgrounded);
}

/* Tooltip overlay.  Main-thread-only access; the Lisp primitives
   in iosfns.m hop here via dispatch_async so the Emacs thread
   never touches UIKit directly.  We reuse the canvas's own
   superview as the host instead of allocating a new UIWindow
   (which the deployment target supports but which adds chrome
   that's hard to suppress on iPad).  */
static __weak UILabel *ios_tooltip_label = nil;

void
ios_show_tooltip (const char *utf8, int x, int y, double font_size)
{
  if (utf8 == NULL || ios_is_backgrounded ())
    return;
  NSString *text = [NSString stringWithUTF8String:utf8];
  if (text == nil)
    return;
  dispatch_async (dispatch_get_main_queue (), ^{
    EmacsUIView *canvas = ios_canvas;
    UIView *host = canvas.superview;
    if (host == nil)
      return;
    UILabel *label = ios_tooltip_label;
    if (label == nil)
      {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 0;
        label.layer.cornerRadius = 6;
        label.layer.masksToBounds = YES;
        label.backgroundColor =
          [UIColor colorWithWhite:0.0 alpha:0.85];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentLeft;
        label.userInteractionEnabled = NO;
        ios_tooltip_label = label;
      }
    label.text = [NSString stringWithFormat:@"  %@  ", text];
    label.font = [UIFont systemFontOfSize:font_size];
    CGSize fit = [label sizeThatFits:
                   CGSizeMake (host.bounds.size.width - 32, 1e6)];
    /* Position near the lower-left of the canvas; help-echo
       readers expect the tip not to overlap point.  A future
       improvement: track the latest mouse position and anchor
       near it, biased away from the screen edge.  */
    CGFloat px = MAX (8, MIN (host.bounds.size.width - fit.width - 8,
                              (CGFloat) x));
    /* Anchor at the bottom of the canvas, offset upward by y --
       mirrors the help-echo convention of showing the tip beneath
       the cursor without occluding it.  */
    CGFloat py = host.bounds.size.height - fit.height - 8 - y;
    if (py < 8) py = 8;
    label.frame = CGRectMake (px, py, fit.width, fit.height);
    [host addSubview:label];

    /* Auto-hide after 6 seconds.  Mirrors the standard tooltip
       behaviour on every other port; users who want a longer or
       shorter dwell can rebind tooltip-delay / tooltip-hide-delay.
       Cancel a previously-pending hide by tagging the label with
       a generation counter -- the same label being shown rapidly
       (e.g. mouse-over a long line) shouldn't compound timers.  */
    static int gen = 0;
    int my_gen = ++gen;
    dispatch_after (dispatch_time (DISPATCH_TIME_NOW,
                                   6 * NSEC_PER_SEC),
                    dispatch_get_main_queue (), ^{
      if (gen == my_gen)
        {
          UILabel *l = ios_tooltip_label;
          if (l != nil && l.superview != nil)
            [l removeFromSuperview];
        }
    });
  });
}

bool
ios_hide_tooltip (void)
{
  __block bool was_open = false;
  void (^hide) (void) = ^{
    UILabel *label = ios_tooltip_label;
    if (label != nil && label.superview != nil)
      {
        was_open = true;
        [label removeFromSuperview];
      }
  };
  if ([NSThread isMainThread])
    hide ();
  else
    dispatch_sync (dispatch_get_main_queue (), hide);
  return was_open;
}

/* Show or hide the software keyboard from Lisp (via the
   ios-show-keyboard / ios-hide-keyboard primitives in iosfns.m).
   Called on the Emacs thread; hops to the main queue because
   responder and input-view changes are UI-thread-only.

   The canvas must never resign first responder to dismiss the
   soft keyboard: hardware key events (pressesBegan:) arrive only
   while it is first responder, and the minibuffer hooks hide the
   keyboard on every exit -- resigning would leave external
   keyboards dead from then on.  Instead swap in an empty
   inputView, which hides the soft keyboard while keeping
   responder status.  */
void
ios_set_keyboard_visible (bool visible)
{
  dispatch_async (dispatch_get_main_queue (), ^{
    EmacsUIView *v = ios_canvas;
    if (v == nil)
      return;
    [v setKeyboardSuppressed:!visible];
    [v reloadInputViews];
    [v becomeFirstResponder];
  });
}

void
ios_canvas_draw_text (double x, double y, double width, double height,
                      unsigned long fg_pixel, unsigned long bg_pixel,
                      const char *utf8, double font_size,
                      unsigned deco, double cell_width,
                      double clip_x, double clip_y,
                      double clip_width, double clip_height)
{
  if (ios_is_backgrounded ())
    return;
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
  cmd.cellWidth = cell_width;
  cmd.clipX = clip_x;
  cmd.clipY = clip_y;
  cmd.clipWidth = clip_width;
  cmd.clipHeight = clip_height;
  [v drawCommand:cmd];
}

/* Draw N real Core Text glyphs.  GLYPHS are CGGlyph indices; XPOS gives
   each glyph's x origin and BASELINE_Y the shared baseline, both in
   Emacs (top-left) frame pixels.  CTFONT is borrowed for the duration
   of this synchronous call (the struct font owns the +1 reference).  */
void
ios_canvas_draw_glyphs (void *ctfont,
                        const unsigned short *glyphs,
                        const double *xpos, int n,
                        double baseline_y,
                        unsigned long fg_pixel,
                        double clip_x, double clip_y,
                        double clip_width, double clip_height)
{
  if (ios_is_backgrounded ())
    return;
  EmacsUIView *v = ios_canvas;
  if (v == nil || ctfont == NULL || glyphs == NULL || n <= 0)
    return;

  CGGlyph *g = malloc ((size_t) n * sizeof (CGGlyph));
  CGPoint *p = malloc ((size_t) n * sizeof (CGPoint));
  if (g == NULL || p == NULL)
    {
      free (g);
      free (p);
      return;
    }
  for (int i = 0; i < n; i++)
    {
      g[i] = (CGGlyph) glyphs[i];
      p[i] = CGPointMake (xpos[i], baseline_y);
    }

  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  cmd.kind = EmacsDrawKindGlyphs;
  cmd.ctFont = (CTFontRef) ctfont;
  cmd.glyphData = [NSData dataWithBytes:g length:(NSUInteger) n * sizeof (CGGlyph)];
  cmd.glyphPos  = [NSData dataWithBytes:p length:(NSUInteger) n * sizeof (CGPoint)];
  cmd.fg = (uint32_t) (fg_pixel & 0xffffff);
  cmd.clipX = clip_x;
  cmd.clipY = clip_y;
  cmd.clipWidth = clip_width;
  cmd.clipHeight = clip_height;
  free (g);
  free (p);
  [v drawCommand:cmd];
}

/* Clear a rectangular region.  Used by clear_frame_area /
   clear_under_internal_border to erase stale content.  Implemented
   as an EmacsDrawKindText command with empty text -- the background
   fill in drawRect: handles the actual paint.  */
void
ios_canvas_clear_rect (double x, double y, double width, double height,
                       unsigned long bg_pixel)
{
  if (ios_is_backgrounded ())
    return;
  EmacsUIView *v = ios_canvas;
  if (v == nil) return;
  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  cmd.kind = EmacsDrawKindText;
  cmd.x = x; cmd.y = y;
  cmd.width = width; cmd.height = height;
  cmd.bg = (uint32_t) (bg_pixel & 0xffffff);
  cmd.text = @"";
  [v drawCommand:cmd];
}

/* Image draw: enqueue an EmacsDrawKindImage command holding a
   bridged-retained CGImageRef.  The caller's CGImageRef remains
   owned by img->pixmap; the command keeps its own +1 retain (via
   CFBridgingRetain) so a redisplay still in flight when image.c
   clears the pixmap stays safe.  */
void
ios_canvas_draw_image (double x, double y, double width, double height,
                       void *cgimage,
                       double clip_x, double clip_y,
                       double clip_width, double clip_height)
{
  if (ios_is_backgrounded ())
    return;
  EmacsUIView *v = ios_canvas;
  if (v == nil || cgimage == NULL)
    return;
  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  cmd.kind = EmacsDrawKindImage;
  cmd.x = x;
  cmd.y = y;
  cmd.width = width;
  cmd.height = height;
  cmd.cgImage = (CGImageRef) cgimage;   /* setter retains */
  cmd.clipX = clip_x;
  cmd.clipY = clip_y;
  cmd.clipWidth = clip_width;
  cmd.clipHeight = clip_height;
  [v drawCommand:cmd];
}

/* Cursor "command": just a rectangle of the given style.  kind
   encodes the style; the caller picks based on the redisplay
   engine's cursor type.  */
void
ios_canvas_draw_cursor (double x, double y, double width, double height,
                        unsigned long pixel, int style /* enum text_cursor_kinds */)
{
  if (ios_is_backgrounded ())
    return;
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
  [v drawCommand:cmd];
}

/* scroll_run support: shift the accumulated command band
   [y, y+height) within window x-range [x, x+width) by dy points.
   The transform runs synchronously under the queue lock on the
   calling (Emacs) thread, keeping ordering with surrounding
   draw commands exact.  */
void
ios_canvas_scroll (double x, double y, double width, double height,
                   double dy)
{
  EmacsUIView *v = ios_canvas;
  if (v == nil)
    return;
  EmacsDrawCommand *cmd = [[EmacsDrawCommand alloc] init];
  cmd.kind = EmacsDrawKindShift;
  cmd.x = x;
  cmd.y = y;
  cmd.width = width;
  cmd.height = height;
  cmd.shiftDy = dy;
  [v drawCommand:cmd];
}

/* Keep the view's own background in sync with the Emacs frame
   background so unpainted regions (sub-row slack at the bottom,
   margins during rotation) show the buffer's background instead
   of a mismatched system color.  Called from the update_end hook
   on every redisplay; the cached comparison makes the steady
   state free and the main-queue hop only happens on an actual
   color change (theme switch, appearance flip).  */
void
ios_canvas_set_background (unsigned long pixel)
{
  static unsigned long last = ~0UL;
  if (pixel == last)
    return;
  last = pixel;
  CGFloat r = ((pixel >> 16) & 0xff) / 255.0;
  CGFloat g = ((pixel >>  8) & 0xff) / 255.0;
  CGFloat b = ( pixel        & 0xff) / 255.0;
  EmacsUIView *cv = ios_canvas;
  if (cv != nil)
    /* Recorded for backing-store (re)creation fills.  */
    [cv setBackgroundPixel:(uint32_t) pixel];
  dispatch_async (dispatch_get_main_queue (), ^{
    EmacsUIView *v = ios_canvas;
    if (v != nil)
      v.backgroundColor = [UIColor colorWithRed:r green:g blue:b
                                          alpha:1.0];
  });
}

/* C-callable hooks for the terminal-level update_begin / update_end
   bracket.  Painting is immediate; end requests a composite of the
   backing store.  */
void
ios_canvas_begin_frame (void)
{
  if (ios_is_backgrounded ())
    return;
  EmacsUIView *v = ios_canvas;
  if (v) [v beginFrame];
}

void
ios_canvas_end_frame (void)
{
  if (ios_is_backgrounded ())
    return;
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

  /* File round-trip: visit a file under HOME (the sandboxed
     Documents directory), insert text, save.  The modeline /
     echo area showing "Wrote .../ci-roundtrip.txt" in the
     screenshot, plus the file appearing in the data-container
     listing the workflow captures afterwards, verify the full
     find-file -> save-buffer -> POSIX write path end to end.  */
  sleep (2);
  ios_launch_log (@"auto-input(thread): C-x C-f ci-roundtrip.txt");
  const char *findf = "\x18\x06" "ci-roundtrip.txt\r";
  for (const char *p = findf; *p; p++)
    ios_enqueue_key ((int) (unsigned char) *p);
  sleep (2);
  const char *body = "saved on iOS";
  for (const char *p = body; *p; p++)
    ios_enqueue_key ((int) (unsigned char) *p);
  ios_launch_log (@"auto-input(thread): C-x C-s (save)");
  ios_enqueue_key (0x18);   /* C-x */
  ios_enqueue_key (0x13);   /* C-s */

  /* Run the self-test battery, which writes ~/ios-test-results.txt
     with one line per probe for the caller to check.  */
  sleep (3);
  ios_launch_log (@"auto-input(thread): M-x ios-run-self-tests RET");
  const char *cmd = "\x1bxios-run-self-tests\r";
  for (const char *p = cmd; *p; p++)
    ios_enqueue_key ((int) (unsigned char) *p);

  /* Leave the font demo on screen.  It renders shaped Arabic,
     Devanagari and Tamil, RTL Hebrew, CJK, emoji and the
     proportional, bold and italic faces, so a screenshot shows
     shaping and coverage that the self-tests cannot grade.  */
  sleep (3);
  ios_launch_log (@"auto-input(thread): M-x ios-show-font-demo RET");
  const char *demo = "\x1bxios-show-font-demo\r";
  for (const char *p = demo; *p; p++)
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

/* UIApplicationDelegate that boots Emacs.  Defined in this binary
   so UIApplicationMain's NSClassFromString lookup succeeds.  Sets
   up the window, canvas, and (in debug builds) the launch-log
   strip, then starts the Emacs thread.  */

@interface EmacsAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation EmacsAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)opts
{
  ios_redirect_stdio ();
  ios_launch_log (@"AppDelegate didFinishLaunchingWithOptions: enter");
  /* Re-acquire access to external documents the user opened in
     previous sessions, before Emacs init starts visiting files
     from recentf / desktop.  */
  ios_restore_bookmarks ();

  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.backgroundColor = UIColor.blackColor;

  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = UIColor.blackColor;

  /* With EMACS_IOS_DEBUG_LOG set, a title and log strip occupy the
     top of the window; otherwise the canvas gets the entire safe
     area.  */
  BOOL debug_ui = (getenv ("EMACS_IOS_DEBUG_LOG") != NULL);

  EmacsUIView *canvas = [[EmacsUIView alloc] initWithFrame:CGRectZero];
  canvas.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:canvas];

  UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
  NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
  [cs addObject:[canvas.leadingAnchor
                  constraintEqualToAnchor:safe.leadingAnchor]];
  [cs addObject:[canvas.trailingAnchor
                  constraintEqualToAnchor:safe.trailingAnchor]];
  /* Bottom-pin to the KEYBOARD layout guide, not the safe area:
     the soft keyboard overlays the safe area without changing it,
     so a safe-area-pinned canvas would keep its full height and
     the keyboard would cover the bottom rows -- precisely the
     minibuffer.  UIKeyboardLayoutGuide (iOS 15+, our deployment
     floor) tracks the keyboard's top edge and follows the
     safe-area bottom when the keyboard is hidden, so this one
     constraint provides shrink-on-show / grow-on-dismiss through
     the existing layoutSubviews -> resize channel.  */
  [cs addObject:[canvas.bottomAnchor
                  constraintEqualToAnchor:
                    vc.view.keyboardLayoutGuide.topAnchor]];

  UITextView *logView = nil;
  if (debug_ui)
    {
      UILabel *title = [[UILabel alloc] init];
      title.text = @"GNU Emacs (iOS bring-up)";
      title.textColor = UIColor.whiteColor;
      title.font = [UIFont boldSystemFontOfSize:20];
      title.textAlignment = NSTextAlignmentCenter;
      title.translatesAutoresizingMaskIntoConstraints = NO;
      [vc.view addSubview:title];

      logView = [[UITextView alloc] init];
      logView.backgroundColor = UIColor.blackColor;
      logView.textColor = UIColor.greenColor;
      logView.font = [UIFont fontWithName:@"Menlo" size:10];
      logView.editable = NO;
      logView.text = @"";
      logView.translatesAutoresizingMaskIntoConstraints = NO;
      [vc.view addSubview:logView];

      [cs addObjectsFromArray:@[
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
        [logView.heightAnchor   constraintEqualToConstant:120],
        [canvas.topAnchor       constraintEqualToAnchor:logView.bottomAnchor
                                                constant:8],
      ]];
    }
  else
    {
      [cs addObject:[canvas.topAnchor
                      constraintEqualToAnchor:safe.topAnchor]];
    }
  [NSLayoutConstraint activateConstraints:cs];

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

  /* Automated runs synthesize keystrokes a few seconds after launch
     so a screenshot captures a working session rather than the
     startup splash.  This is gated on EMACS_IOS_AUTO_INPUT, which
     simctl passes through as SIMCTL_CHILD_EMACS_IOS_AUTO_INPUT, so
     an ordinary launch is never driven.  The keys are sent from a
     dedicated thread using sleep() rather than dispatch_after on the
     main queue: taking a screenshot perturbs the app lifecycle in a
     way that can drop queued main-queue blocks.  */
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
  ios_set_backgrounded (false);
  /* Force a full repaint: the backing store received no draws
     while backgrounded, so parts of it are stale until Emacs
     redraws from scratch.  */
  ios_publish_foreground_expose ();
  /* UIKit resigns the first responder around scene deactivation;
     without re-acquiring it here, hardware keyboard input is dead
     after returning to the app until the user taps the canvas.  */
  [ios_canvas becomeFirstResponder];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationWillResignActive");
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationDidEnterBackground");
  /* Suspend redisplay output: the canvas isn't visible, and iOS
     terminates backgrounded apps that keep doing work.  The Emacs
     thread keeps running so timers stay accurate, but
     ios_canvas_draw_text et al. become no-ops until the app
     returns to the foreground.  */
  ios_set_backgrounded (true);
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
  (void) scoped;
  ios_save_bookmark (url);
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
  NSString *info = [bundle stringByAppendingPathComponent:@"info"];
  setenv ("EMACSLOADPATH", lisp.UTF8String, 1);
  setenv ("EMACSDATA",     etc.UTF8String,  1);
  /* Built-in docstrings (etc/DOC) and the Info manuals also live
     in the bundle; doc-directory follows EMACSDOC and info.el
     seeds Info-directory-list from INFOPATH.  */
  setenv ("EMACSDOC",      etc.UTF8String,  1);
  setenv ("INFOPATH",      info.UTF8String, 1);
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
      /* Also make it the working directory: iOS launches apps with
         cwd "/", which Emacs would adopt as
         command-line-default-directory, so every relative file
         operation (C-x C-f at startup, autosaves before any
         buffer-local default-directory exists) would aim at the
         read-only root.  */
      if (chdir (docs) != 0)
        ios_launch_log (@"ios_setenv_bundle_paths: chdir(HOME) failed");
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
  /* loadup.el dumps to EMACS_PDMP on first launch (see the iOS clause
     there).  emacs.c loads the same path via the dump_file argument
     on later launches.  Keep the two in sync through this one env
     var so the write target and the read target never diverge.  */
  if (dump_file)
    setenv ("EMACS_PDMP", dump_file, 1);
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
