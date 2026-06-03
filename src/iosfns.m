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

#include "lisp.h"
#include "iosterm.h"
#include "frame.h"
#include "dispextern.h"
#include "font.h"
#include "fontset.h"

extern struct font_driver ios_font_driver;

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

DEFUN ("x-hide-tip", Fx_hide_tip, Sx_hide_tip, 0, 0, 0,
       doc: /* Hide the current tooltip window, if there is any.
Value is t if tooltip was open, nil otherwise.

iOS stub: returns nil unconditionally.  A real tooltip implementation
backed by a UILabel-on-UIWindow overlay is a follow-up.  */)
  (void)
{
  return Qnil;
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
     scale.  Falling back to 40x20 if the display reports zero.  */
  int logical_w = dpyinfo->logical_width;
  int logical_h = dpyinfo->logical_height;
  if (logical_w <= 0 || logical_h <= 0)
    { logical_w = 320; logical_h = 480; }
  int cols  = logical_w / font->average_width;
  int lines = logical_h / font->height;
  if (cols < 10)  cols = 10;
  if (lines < 5) lines = 5;
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

void
syms_of_iosfns (void)
{
  defsubr (&Sx_hide_tip);
  defsubr (&Sxw_display_color_p);
  defsubr (&Sx_display_grayscale_p);
  defsubr (&Sx_create_frame);
}

#endif /* HAVE_IOS */
