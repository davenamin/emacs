/* Definitions and headers for communication with iOS.
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

#ifndef IOSTERM_H
#define IOSTERM_H

#ifdef HAVE_IOS

#include "dispextern.h"
#include "frame.h"
#include "termhooks.h"

/* Opaque handles for UIKit objects, so this header can be included
   from plain C translation units that do not import UIKit.  In the
   Objective-C translation units (ios*.m) these are cast back to their
   real UIKit types.  */
typedef void *ios_window;       /* UIWindow * */
typedef void *ios_view;         /* UIView *   */
typedef void *ios_drawable;     /* CALayer *  */
typedef void *ios_pixmap;       /* CGImageRef */
typedef void *ios_cursor;       /* unused on iOS, kept for parity */

struct ios_display_info
{
  struct ios_display_info *next;
  struct terminal *terminal;

  /* Logical and physical screen geometry, in points and pixels.  */
  int logical_width, logical_height;
  int pixel_width, pixel_height;
  double scale_factor;

  /* Resource database, parallel to x_display_info::rdb.  */
  XrmDatabase rdb;

  /* Default font.  */
  struct font *font;
  int n_fonts;

  /* Reference frame used for fallback resolution.  */
  struct frame *highlight_frame;
};

struct ios_output
{
  /* Backpointer to the frame this struct belongs to.  */
  struct frame *frame;

  /* The display this frame is on.  */
  struct ios_display_info *display_info;

  /* UIKit objects backing the frame.  */
  ios_window window;
  ios_view view;

  /* Default font for this frame.  */
  struct font *font;
  int baseline_offset;

  /* Cursor colours.  */
  unsigned long cursor_pixel;
  unsigned long cursor_foreground_pixel;
};

#define FRAME_IOS_WINDOW(f)        ((f)->output_data.ios->window)
#define FRAME_IOS_VIEW(f)          ((f)->output_data.ios->view)
#define FRAME_DISPLAY_INFO(f)      ((f)->output_data.ios->display_info)
#define FRAME_FONT(f)              ((f)->output_data.ios->font)
#define FRAME_BASELINE_OFFSET(f)   ((f)->output_data.ios->baseline_offset)

/* Entry points implemented in src/ios.m and src/iosterm.m.  Declared
   here so plain C code (emacs.c, keyboard.c, pdumper.c) can call them
   without importing UIKit.  */
extern int ios_main (int argc, char **argv);
extern char *ios_dump_path (void);
extern struct terminal *ios_term_init (void);
extern int ios_read_socket (struct terminal *terminal,
                            struct input_event *hold_quit);

#endif /* HAVE_IOS */
#endif /* IOSTERM_H */
