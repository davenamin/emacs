/* iOS-specific Emacs Lisp functions.
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

/* This file is the iOS analogue of src/androidfns.c / src/nsfns.m.
   It exposes Emacs Lisp primitives for frame creation, display
   geometry, tooltips, and other UIKit-backed user-visible features.

   Skeleton only; the real implementation lands in follow-up
   commits.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "lisp.h"
#include "coding.h"
#include "iosterm.h"
#include "frame.h"
#include "window.h"
#include "dispextern.h"
#include "font.h"
#include "fontset.h"

extern struct font_driver ios_font_driver;
extern void ios_launch_log (NSString *msg);

/* Resolve OBJECT to a Display_Info -- frame.c's Fx_get_resource and
   other frame-parameter primitives call this to find the display
   that applies to a given frame/terminal/display-name argument.  iOS
   has exactly one logical display, so this stub ignores OBJECT and
   returns the head of x_display_list (or signals an error if the
   display hasn't been initialized yet).  */
Display_Info *
check_x_display_info (Lisp_Object object)
{
  if (!x_display_list)
    error ("iOS display is not initialized");
  return x_display_list;
}

extern void ios_show_tooltip (const char *utf8, int x, int y,
                              double font_size);
extern bool ios_hide_tooltip (void);

DEFUN ("x-show-tip", Fx_show_tip, Sx_show_tip, 1, 6, 0,
       doc: /* Show STRING in a tooltip overlay near the cursor.
The full xfns.c signature is honored for source compatibility but
the iOS overlay only consults STRING, the foreground/background
faces (via current frame default), and an internal positioning
heuristic.  */)
  (Lisp_Object string, Lisp_Object frame, Lisp_Object parms,
   Lisp_Object timeout, Lisp_Object dx, Lisp_Object dy)
{
  (void) frame; (void) parms; (void) timeout;
  CHECK_STRING (string);
  Lisp_Object encoded
    = code_convert_string_norecord (string, Qutf_8, true);
  int x_off = FIXNUMP (dx) ? XFIXNUM (dx) : 8;
  int y_off = FIXNUMP (dy) ? XFIXNUM (dy) : 8;
  ios_show_tooltip (SSDATA (encoded), x_off, y_off, 13.0);
  return Qnil;
}

DEFUN ("x-hide-tip", Fx_hide_tip, Sx_hide_tip, 0, 0, 0,
       doc: /* Hide the current tooltip window, if there is any.
Value is t if tooltip was open, nil otherwise.  */)
  (void)
{
  return ios_hide_tooltip () ? Qt : Qnil;
}

DEFUN ("xw-display-color-p", Fxw_display_color_p, Sxw_display_color_p,
       0, 1, 0,
       doc: /* Return t if the display supports color.
The optional argument TERMINAL is ignored on iOS; iOS devices always
have a color display.  */)
  (Lisp_Object terminal)
{
  return Qt;
}

DEFUN ("x-create-frame", Fx_create_frame, Sx_create_frame, 1, 1, 0,
       doc: /* SKIP: minimal iOS bring-up stub of x-create-frame.

Allocates a struct frame attached to the one iOS display, sets
output_method to output_ios, hooks up output_data.ios with sensible
defaults, and returns the new frame.  Does NOT load fonts, register
font drivers, draw anything, or wire input events: those are
follow-up commits.  The frame is just real enough that startup.el's
(make-frame ...) call completes and Lisp code can inspect frame
parameters without crashing.  */)
  (Lisp_Object parms)
{
  struct frame *f;
  Lisp_Object frame;
  struct ios_display_info *dpyinfo;
  struct kboard *kb;

  if (!x_display_list)
    error ("iOS display is not initialized");
  dpyinfo = x_display_list;
  kb = dpyinfo->terminal->kboard;

  parms = Fcopy_alist (parms);

  /* Allocate the bare frame with a minibuffer (the simple, single-
     frame case -- iOS apps don't host child or minibuffer-less
     frames yet).  */
  f = make_frame (true);
  XSETFRAME (frame, f);

  f->terminal = dpyinfo->terminal;
  f->output_method = output_ios;
  f->output_data.ios = xzalloc (sizeof *f->output_data.ios);
  f->output_data.ios->display_info = dpyinfo;
  f->output_data.ios->frame = f;

  /* Sentinel pixel values so face initialization doesn't try to
     free uninitialized colors.  */
  FRAME_FOREGROUND_PIXEL (f) = 0x000000;
  FRAME_BACKGROUND_PIXEL (f) = 0xffffff;
  f->output_data.ios->cursor_pixel = 0x000000;
  f->output_data.ios->cursor_foreground_pixel = 0xffffff;

  /* Stash foreground / background COLOR NAMES in param_alist so
     realize_default_face finds them: when FRAME_WINDOW_P (f) is
     true, the only fallback for an unspecified default face
     foreground / background is the corresponding entry in
     param_alist; otherwise realize_default_face returns false and
     init_frame_faces aborts.  */
  store_frame_param (f, Qforeground_color, build_string ("black"));
  store_frame_param (f, Qbackground_color, build_string ("white"));

  /* Fontset starts unset; -1 is the "no fontset" sentinel that
     fontset.c recognizes.  */
  FRAME_FONTSET (f) = -1;

  fset_name (f, build_string ("GNU Emacs"));
  f->explicit_name = false;

  /* Register the font driver on this frame, then open the default
     iOS font (Menlo via UIFont) so realize_default_face has a
     FRAME_FONT to point at.  Without this, init_frame_faces aborts
     because realize_default_face's XSETFONT(font_object, FRAME_FONT(f))
     dereferences a NULL pointer.  */
  register_font_driver (&ios_font_driver, f);
  /* Activate the driver.  register_font_driver sets list->on = 0
     by default; font_list_entities skips drivers whose ->on is 0,
     so without this call font_load_for_lface returns nil and
     realize_face later faceplants on a NULL font.  Passing Qt
     activates every registered driver.  */
  font_update_drivers (f, Qt);

  /* Call our driver's open_font hook directly, bypassing the
     font_open_by_name matching machinery (which iterates registered
     drivers and applies XLFD-style filtering that our minimal
     entity does not satisfy out of the box).  We pass an entity
     fabricated by our match hook -- the driver doesn't actually
     consult its fields beyond passing pixel_size through.  */
  Lisp_Object dummy_spec = Qnil;
  Lisp_Object entity = ios_font_driver.match (f, dummy_spec);
  Lisp_Object font_obj = ios_font_driver.open_font (f, entity, 14);
  if (NILP (font_obj))
    {
      delete_frame (frame, Qnoelisp);
      error ("ios: failed to open default Menlo font");
    }
  /* Install the font into the frame directly (no set_new_font_hook
     wired up yet on iOS).  These assignments mirror the relevant
     prefix of android_new_font.  */
  struct font *font = XFONT_OBJECT (font_obj);
  FRAME_FONT (f) = font;
  FRAME_BASELINE_OFFSET (f) = font->baseline_offset;
  FRAME_COLUMN_WIDTH (f) = font->average_width;
  FRAME_LINE_HEIGHT (f) = font->height;
  /* Allocate a fontset for this font.  realize_default_face does
     fontset_name(FRAME_FONTSET(f)), which is AREF(Vfontset_table, id)
     -- a negative id segfaults.  */
  FRAME_FONTSET (f) = fontset_from_font (font_obj);
  store_frame_param (f, Qfont, font_obj);

  /* Geometry: derive from the display.  Use logical width/height
     (NOT pixel) since CoreGraphics + CTLine work in points.
     UIScreen.bounds is in points already; pixel_* are points *
     scale.  Falling back to 40x20 if the display reports zero.
     The on-screen canvas is roughly 70% of the screen height
     (the live log occupies the top 30%), so bias height by 0.65
     to leave a margin for the safe-area insets.  Until the canvas
     reports its actual laid-out size back to the C side via
     change_frame_size, this static ratio is the best we can do.  */
  /* The on-screen canvas in landscape mode is roughly 600x300 pts
     on iPhone Pro Max; in portrait, 400x500.  Take the larger of
     UIScreen's width vs height so we cover both orientations.  */
  int logical_w = dpyinfo->logical_width;
  int logical_h = dpyinfo->logical_height;
  if (logical_w <= 0 || logical_h <= 0)
    { logical_w = 320; logical_h = 480; }
  if (logical_h > logical_w)
    {
      int swap = logical_w;
      logical_w = logical_h;
      logical_h = swap;
    }
  int cols  = logical_w / font->average_width;
  int lines = logical_h / font->height;
  if (cols < 10)  cols = 10;
  if (lines < 5)  lines = 5;
  FRAME_COLS (f) = cols;
  FRAME_LINES (f) = lines;
  /* Frame text-area pixel dimensions: cols/lines * cell size.  The
     redisplay engine uses these for clipping; if they stay at 0 it
     decides nothing fits and produces a single short glyph string.  */
  f->text_width  = cols * font->average_width;
  f->text_height = lines * font->height;
  f->pixel_width  = f->text_width;
  f->pixel_height = f->text_height;

  /* Initialize the face cache (allocates it via make_face_cache and
     calls realize_basic_faces).  This is the call that previously
     SIGSEGVd; it should succeed now that FRAME_FONT and color
     pixels are non-sentinel.  */
  init_frame_faces (f);

  /* Call change_frame_size so Emacs's window layout machinery
     recomputes the root window dimensions from the freshly-set
     pixel_width / pixel_height.  Without this, the window defaults
     to a tiny placeholder size and buffer text truncates at column
     ~8 even though FRAME_COLS reports the much larger value we
     wrote above.  */
  change_frame_size (f, f->text_width, f->text_height, false, false, false);

  /* DEBUG: verify the resize actually propagated into the root
     window.  make_frame builds the root window with pixel sizes
     computed while FRAME_COLUMN_WIDTH was still 1 (80px x 24px);
     if these log lines still show ~80x24 the resize path bailed
     somewhere.  */
  {
    struct window *rootw = XWINDOW (FRAME_ROOT_WINDOW (f));
    ios_launch_log ([NSString stringWithFormat:
                     @"x-create-frame: root window %dx%d px,"
                     @" %dx%d cells; frame %dx%d px %dx%d cells",
                     rootw->pixel_width, rootw->pixel_height,
                     rootw->total_cols, rootw->total_lines,
                     f->pixel_width, f->pixel_height,
                     FRAME_COLS (f), FRAME_LINES (f)]);
  }

  /* Mark the frame as visible so frame-initialize's
     (delete-frame terminal-frame) sees it as "the other frame".
     Without this the visibility flag stays zero and other_frames
     bails with "sole visible or iconified frame".  */
  SET_FRAME_VISIBLE (f, true);

  /* Add to the global frame list.  make_frame ONLY allocates the
     struct; it doesn't add to Vframe_list.  Without this our new
     frame is invisible to FOR_EACH_FRAME, so other_frames returns
     false even though the frame exists, and delete-frame on the
     initial terminal frame errors out.  */
  Vframe_list = Fcons (frame, Vframe_list);

  f->terminal->reference_count++;
  f->after_make_frame = true;

  (void) kb;    /* silence unused warning until kb is consumed below */
  (void) parms; /* same; parms is parsed for real in a follow-up */
  return frame;
}

DEFUN ("x-display-grayscale-p", Fx_display_grayscale_p,
       Sx_display_grayscale_p, 0, 1, 0,
       doc: /* Return t if the display supports grayscale.
The optional argument TERMINAL is ignored on iOS.  Returns nil:
iOS displays are full color, not grayscale-only.  */)
  (Lisp_Object terminal)
{
  return Qnil;
}

DEFUN ("x-display-pixel-width", Fx_display_pixel_width,
       Sx_display_pixel_width, 0, 1, 0,
       doc: /* Return the width in pixels of the iOS display.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  return make_fixnum (d->pixel_width);
}

DEFUN ("x-display-pixel-height", Fx_display_pixel_height,
       Sx_display_pixel_height, 0, 1, 0,
       doc: /* Return the height in pixels of the iOS display.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  return make_fixnum (d->pixel_height);
}

DEFUN ("x-display-mm-width", Fx_display_mm_width,
       Sx_display_mm_width, 0, 1, 0,
       doc: /* Return the width in millimetres of the iOS display.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  if (d->resx <= 0) return make_fixnum (0);
  return make_fixnum ((int) (d->pixel_width / d->resx * 25.4));
}

DEFUN ("x-display-mm-height", Fx_display_mm_height,
       Sx_display_mm_height, 0, 1, 0,
       doc: /* Return the height in millimetres of the iOS display.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  if (d->resy <= 0) return make_fixnum (0);
  return make_fixnum ((int) (d->pixel_height / d->resy * 25.4));
}

DEFUN ("x-display-planes", Fx_display_planes, Sx_display_planes,
       0, 1, 0,
       doc: /* Return the bit depth of the iOS display.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  return make_fixnum (d->n_planes);
}

DEFUN ("x-display-color-cells", Fx_display_color_cells,
       Sx_display_color_cells, 0, 1, 0,
       doc: /* Return the number of distinguishable colors on TERMINAL.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  int n = d->n_planes > 24 ? 24 : d->n_planes;
  return make_fixnum (1 << n);
}

DEFUN ("x-display-screens", Fx_display_screens, Sx_display_screens,
       0, 1, 0,
       doc: /* Return the number of screens.  iOS has exactly one.  */)
  (Lisp_Object terminal)
{
  check_x_display_info (terminal);
  return make_fixnum (1);
}

DEFUN ("x-server-vendor", Fx_server_vendor, Sx_server_vendor,
       0, 1, 0,
       doc: /* Return the vendor of the iOS display.  Always "Apple".  */)
  (Lisp_Object terminal)
{
  check_x_display_info (terminal);
  return build_string ("Apple");
}

DEFUN ("x-server-version", Fx_server_version, Sx_server_version,
       0, 1, 0,
       doc: /* Return the version of the iOS runtime as (MAJOR MINOR PATCH).  */)
  (Lisp_Object terminal)
{
  check_x_display_info (terminal);
  NSOperatingSystemVersion v
    = [NSProcessInfo processInfo].operatingSystemVersion;
  return list3i (v.majorVersion, v.minorVersion, v.patchVersion);
}

DEFUN ("x-display-backing-store", Fx_display_backing_store,
       Sx_display_backing_store, 0, 1, 0,
       doc: /* Return the backing-store policy.  iOS pixels persist
while the layer is mapped, so this returns `when-mapped'.  */)
  (Lisp_Object terminal)
{
  check_x_display_info (terminal);
  return Qwhen_mapped;
}

DEFUN ("x-display-visual-class", Fx_display_visual_class,
       Sx_display_visual_class, 0, 1, 0,
       doc: /* Return the visual class.  iOS displays are 24-bit
direct-color, reported as `true-color'.  */)
  (Lisp_Object terminal)
{
  struct ios_display_info *d = check_x_display_info (terminal);
  if (d->n_planes < 24)
    return Qstatic_gray;
  return Qtrue_color;
}

DEFUN ("x-display-list", Fx_display_list, Sx_display_list, 0, 0, 0,
       doc: /* Return the list of display names known to Emacs.
On iOS there is exactly one display, returned as a single-element list.  */)
  (void)
{
  if (!x_display_list)
    return Qnil;
  return list1 (XCAR (x_display_list->name_list_element));
}

/* UIDocumentPickerViewController delegate.  Picked files feed the
   same async channel as application:openURL: -- the path is
   published to the Emacs thread, which builds a DRAG_N_DROP_EVENT,
   and the [drag-n-drop] binding in ios-win.el visits the file.
   Nothing blocks, so the user can browse the picker indefinitely
   and Emacs (timers, redisplay, C-g) stays fully alive.

   The delegate property on the picker is weak; this single static
   instance keeps it pinned for the app's lifetime.  */
@interface IOSPickerDelegate
  : NSObject <UIDocumentPickerDelegate>
@end
@implementation IOSPickerDelegate
- (void) documentPicker:(UIDocumentPickerViewController *)c
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  for (NSURL *url in urls)
    {
      /* Hold the security scope open for the process lifetime so
         the sandboxed-out path stays readable.  */
      [url startAccessingSecurityScopedResource];
      if (url.path.length > 0)
        ios_publish_open_file (url.fileSystemRepresentation);
    }
}
- (void) documentPickerWasCancelled:(UIDocumentPickerViewController *)c
{
  /* Nothing to do: no thread is waiting.  */
}
@end

static IOSPickerDelegate *ios_picker_delegate;

DEFUN ("ios-system-appearance", Fios_system_appearance,
       Sios_system_appearance, 0, 0, 0,
       doc: /* Return the system-wide appearance, `dark' or `light'.
Reads UIScreen.mainScreen.traitCollection.userInterfaceStyle on
the main thread.  Lisp init code in ios-win.el calls this to
seed frame-background-mode so the user's default theme matches
the OS-wide setting at launch.  */)
  (void)
{
  __block UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
  if ([NSThread isMainThread])
    style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
  else
    dispatch_sync (dispatch_get_main_queue (), ^{
      style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    });
  return style == UIUserInterfaceStyleDark
         ? intern_c_string ("dark")
         : intern_c_string ("light");
}

extern void ios_set_keyboard_visible (bool visible);

DEFUN ("ios-show-keyboard", Fios_show_keyboard, Sios_show_keyboard,
       0, 0, 0,
       doc: /* Bring up the software keyboard.  */)
  (void)
{
  ios_set_keyboard_visible (true);
  return Qnil;
}

DEFUN ("ios-hide-keyboard", Fios_hide_keyboard, Sios_hide_keyboard,
       0, 0, 0,
       doc: /* Dismiss the software keyboard.
The hardware keyboard, if any, keeps working; this only slides the
on-screen keyboard away to reclaim canvas space.  */)
  (void)
{
  ios_set_keyboard_visible (false);
  return Qnil;
}

DEFUN ("ios-pick-file", Fios_pick_file, Sios_pick_file, 0, 0, 0,
       doc: /* Present the iOS Files picker.
Returns immediately; when the user picks a document, it arrives as a
drag-n-drop event (see `ios-handle-drag-n-drop') and is visited like
a file handed to Emacs by any other app.  Returns nil.  */)
  (void)
{
  dispatch_async (dispatch_get_main_queue (), ^{
    UIDocumentPickerViewController *picker
      = [[UIDocumentPickerViewController alloc]
          initForOpeningContentTypes:@[UTTypeItem]];
    if (ios_picker_delegate == nil)
      ios_picker_delegate = [[IOSPickerDelegate alloc] init];
    picker.delegate = ios_picker_delegate;
    picker.allowsMultipleSelection = NO;
    /* UIApplication.windows is deprecated; walk the connected
       scenes instead (UIWindowScene.keyWindow needs iOS 15,
       which is the port's deployment floor).  */
    UIWindow *window = nil;
    for (UIScene *scene in
           UIApplication.sharedApplication.connectedScenes)
      {
        if (![scene isKindOfClass:[UIWindowScene class]])
          continue;
        UIWindowScene *ws = (UIWindowScene *) scene;
        window = ws.keyWindow;
        if (window == nil && ws.windows.count > 0)
          window = ws.windows.firstObject;
        if (window != nil)
          break;
      }
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController != nil)
      root = root.presentedViewController;
    if (root != nil)
      [root presentViewController:picker animated:YES completion:nil];
  });
  return Qnil;
}

void
syms_of_iosfns (void)
{
  DEFSYM (Qtrue_color, "true-color");
  DEFSYM (Qstatic_gray, "static-gray");
  DEFSYM (Qwhen_mapped, "when-mapped");

  defsubr (&Sx_show_tip);
  defsubr (&Sx_hide_tip);
  defsubr (&Sxw_display_color_p);
  defsubr (&Sx_display_grayscale_p);
  defsubr (&Sx_create_frame);
  defsubr (&Sx_display_pixel_width);
  defsubr (&Sx_display_pixel_height);
  defsubr (&Sx_display_mm_width);
  defsubr (&Sx_display_mm_height);
  defsubr (&Sx_display_planes);
  defsubr (&Sx_display_color_cells);
  defsubr (&Sx_display_screens);
  defsubr (&Sx_server_vendor);
  defsubr (&Sx_server_version);
  defsubr (&Sx_display_backing_store);
  defsubr (&Sx_display_visual_class);
  defsubr (&Sx_display_list);
  defsubr (&Sios_pick_file);
  defsubr (&Sios_system_appearance);
  defsubr (&Sios_show_keyboard);
  defsubr (&Sios_hide_keyboard);
}

#endif /* HAVE_IOS */
