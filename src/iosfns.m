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

  /* Fontset starts unset; -1 is the "no fontset" sentinel that
     fontset.c recognizes.  */
  FRAME_FONTSET (f) = -1;

  fset_name (f, build_string ("GNU Emacs"));
  f->explicit_name = false;

  /* Geometry: derive from the display.  Pixels-per-character will
     stay 1x1 until a font is set; cols/rows will be wildly wrong
     until then, but they need SOME value so adjust_frame_size
     doesn't divide by zero.  */
  FRAME_COLS (f) = 80;
  FRAME_LINES (f) = 25;

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
