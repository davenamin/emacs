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

/* The frame.c / xdisp.c code uses Emacs_Window as a port-neutral
   identifier for a top-level window.  On iOS there is exactly one
   real top-level window per frame, backed by a UIWindow.  */
typedef void *Emacs_Window;

/* X11-compatibility constants used by the generic frame-geometry
   code in frame.c (gui_set_frame_parameters_1 et al.).  These are
   plain numeric tokens, copied verbatim from androidgui.h /
   haikugui.h / pgtkgui.h -- every non-X port keeps a parallel set
   so the shared code can name window-gravity and geometry-flag
   constants without #ifdef'ing every reference.  */

#define ForgetGravity		0
#define NorthWestGravity	1
#define NorthGravity		2
#define NorthEastGravity	3
#define WestGravity		4
#define CenterGravity		5
#define EastGravity		6
#define SouthWestGravity	7
#define SouthGravity		8
#define SouthEastGravity	9
#define StaticGravity		10

#define NoValue		0x0000
#define XValue  	0x0001
#define YValue		0x0002
#define WidthValue  	0x0004
#define HeightValue  	0x0008
#define AllValues 	0x000F
#define XNegative 	0x0010
#define YNegative 	0x0020

/* Window-manager hint flags.  frame.c ORs these into
   window_prompting to record which geometry properties were
   user- vs program-supplied.  iOS has no window manager, so these
   are read but never acted on; the constants exist so the shared
   code compiles.  */
/* STORE_NATIVE_RECT writes into a NativeRectangle (aka
   Emacs_Rectangle).  NativeRectangle itself is #defined inside
   dispextern.h's HAVE_IOS block, before any prototype mentions it,
   to keep prototype and implementation types consistent.  */
#define STORE_NATIVE_RECT(nr, rx, ry, rwidth, rheight)	\
  ((nr).x = (rx), (nr).y = (ry),			\
   (nr).width = (rwidth), (nr).height = (rheight))

#define USPosition	(1L << 0)
#define USSize		(1L << 1)
#define PPosition	(1L << 2)
#define PSize		(1L << 3)
#define PMinSize	(1L << 4)
#define PMaxSize	(1L << 5)
#define PResizeInc	(1L << 6)
#define PAspect		(1L << 7)
#define PBaseSize	(1L << 8)
#define PWinGravity	(1L << 9)

/* Bitmap allocation -- per-display ring of small image records that
   image.c hands out IDs against.  Same shape as androidterm.h's
   android_bitmap_record.  */
struct ios_bitmap_record
{
  /* The image backing the bitmap and its mask.  */
  ios_pixmap pixmap, mask;

  /* The file from which it comes.  */
  char *file;

  /* The number of references to it.  */
  int refcount;

  /* The height and width and the depth.  */
  int height, width, depth;

  /* Whether or not there is a mask.  */
  bool have_mask;
};

struct ios_display_info
{
  struct ios_display_info *next;
  struct terminal *terminal;

  /* Logical and physical screen geometry, in points and pixels.  */
  int logical_width, logical_height;
  int pixel_width, pixel_height;
  double scale_factor;

  /* No X-style resource database on iOS -- iOS frames are
     configured via Lisp customization and Info.plist, not Xrm.  */

  /* Default font.  */
  struct font *font;
  int n_fonts;

  /* Reference frame used for fallback resolution.  */
  struct frame *highlight_frame;

  /* Smallest font dimensions seen on this display, in pixels.
     Consumed by FRAME_SMALLEST_FONT_HEIGHT / FRAME_SMALLEST_CHAR_WIDTH
     in frame.h; expected on every Display_Info regardless of port.  */
  int smallest_char_width;
  int smallest_font_height;

  /* Pixels per inch on each axis.  FRAME_RES_X / FRAME_RES_Y in
     frame.h read these.  ios_term_init will populate them from
     [UIScreen mainScreen] geometry (typically ~163 dpi for non-
     Retina, ~326 for Retina, ~458 for Super Retina).  */
  double resx, resy;

  /* Color depth in bits.  image.c branches on n_planes >= 2 to
     decide between color and bitmap rendering paths.  iOS displays
     are always 24-bit RGB (or 30-bit on newer devices); 24 is the
     conservative answer.  */
  int n_planes;

  /* Mouse-highlight state shared across all frames on this display.
     Expected by MOUSE_HL_INFO in frame.h.  */
  Mouse_HLInfo mouse_highlight;

  /* Frame-list-element of the form (name . display-name).  Stored
     here so frame.c can XCAR it without each port reinventing the
     bookkeeping.  iOS has only one display, so it's a single-element
     list.  */
  Lisp_Object name_list_element;

  /* The "root window" of the display.  X uses this to identify the
     screen's background window; on iOS there is no such concept and
     the value stays NULL, but frame.c reads it unconditionally.  */
  Emacs_Window root_window;

  /* Mouse-tracking state.  frame.c (and xdisp/keyboard.c eventually)
     reads these to drive mouse-region/hover logic that on iOS
     corresponds to touch and pointer events.  Defaults to 0/NULL
     until iosterm.m starts populating them.  */
  int grabbed;
  struct frame *last_mouse_frame;
  struct frame *last_mouse_motion_frame;
  int last_mouse_motion_x, last_mouse_motion_y;

  /* Bitmap allocator: ring of ios_bitmap_record indexed by 1-based
     bitmap IDs.  image.c expands/uses these to look up images by ID.
     Starts NULL/0; first allocation triggers xpalloc.  */
  struct ios_bitmap_record *bitmaps;
  ptrdiff_t bitmaps_size;
  ptrdiff_t bitmaps_last;
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

  /* "Parent" window.  On X this is the actual parent in the window
     hierarchy; on iOS there is no nesting and this stays NULL, but
     frame.c reads it to fill the `parent-id' frame parameter.  */
  Emacs_Window parent_desc;

  /* Default font for this frame.  */
  struct font *font;
  int baseline_offset;

  /* Fontset ID.  Returned by FRAME_FONTSET below.  */
  int fontset;

  /* Cursor colours.  */
  unsigned long cursor_pixel;
  unsigned long cursor_foreground_pixel;

  /* Mouse-cursor handles for each role.  iOS does not have hardware
     mouse cursors in the X11 sense; UIPointerInteraction (iPadOS
     13.4+) provides system pointer effects keyed by UIPointerStyle.
     For now these stay NULL (Emacs_Cursor is void *) and the
     generic xdisp.c code that reads them just gets a no-op pointer
     identity.  Future work: map each role to a UIPointerStyle.  */
  Emacs_Cursor text_cursor;
  Emacs_Cursor nontext_cursor;
  Emacs_Cursor modeline_cursor;
  Emacs_Cursor hand_cursor;
  Emacs_Cursor hourglass_cursor;
  Emacs_Cursor horizontal_drag_cursor;
  Emacs_Cursor vertical_drag_cursor;
  Emacs_Cursor current_cursor;
  Emacs_Cursor left_edge_cursor;
  Emacs_Cursor top_left_corner_cursor;
  Emacs_Cursor top_edge_cursor;
  Emacs_Cursor top_right_corner_cursor;
  Emacs_Cursor right_edge_cursor;
  Emacs_Cursor bottom_right_corner_cursor;
  Emacs_Cursor bottom_edge_cursor;
  Emacs_Cursor bottom_left_corner_cursor;
};

#define FRAME_IOS_WINDOW(f)        ((f)->output_data.ios->window)
#define FRAME_IOS_VIEW(f)          ((f)->output_data.ios->view)
#define FRAME_DISPLAY_INFO(f)      ((f)->output_data.ios->display_info)
#define FRAME_FONT(f)              ((f)->output_data.ios->font)
#define FRAME_FONTSET(f)           ((f)->output_data.ios->fontset)
#define FRAME_BASELINE_OFFSET(f)   ((f)->output_data.ios->baseline_offset)

/* Port-neutral accessors that frame.c / xdisp.c expand on any
   window-system build.  FRAME_OUTPUT_DATA returns the per-port
   output struct; FRAME_NATIVE_WINDOW returns the toplevel window
   handle (an Emacs_Window).  */
#define FRAME_OUTPUT_DATA(f)       ((f)->output_data.ios)
#define FRAME_NATIVE_WINDOW(f)     ((f)->output_data.ios->window)

/* Head of the singly-linked list of displays.  Defined in iosterm.m.
   Generic code (frame.c) iterates this to enumerate displays.  */
extern struct ios_display_info *x_display_list;

/* Entry points implemented in src/ios.m and src/iosterm.m.  Declared
   here so plain C code (emacs.c, keyboard.c, pdumper.c) can call them
   without importing UIKit.  */
extern int ios_main (int argc, char **argv);
extern char *ios_dump_path (void);
extern struct terminal *ios_term_init (void);
extern bool ios_defined_color (struct frame *, const char *,
                               Emacs_Color *, bool, bool);
extern int ios_read_socket (struct terminal *terminal,
                            struct input_event *hold_quit);

/* syms_of_* registrars for each ios*.m translation unit.  emacs.c's
   syms_of cascade calls each at startup so the DEFUNs inside become
   visible to Lisp.  Parallel to androidterm.h's syms_of_android*
   declarations.  */
extern void syms_of_iosterm (void);
extern void syms_of_iosfns (void);
extern void syms_of_iosmenu (void);
extern void syms_of_iosselect (void);
extern void syms_of_iosfont (void);
extern void syms_of_iosvfs (void);

/* Popup-menu hook implementation in iosmenu.m, registered on the
   terminal in ios_term_init.  */
extern Lisp_Object ios_menu_show (struct frame *f, int x, int y,
                                  int menuflags, Lisp_Object title,
                                  const char **error_name);
extern Lisp_Object ios_popup_dialog (struct frame *f, Lisp_Object header,
                                     Lisp_Object contents);

/* Nested input pump + serial-tagged menu-selection channel
   (iosterm.m).  The pump runs one normal input drain so the menu
   loop stays responsive to C-g; the channel carries the action
   sheet's chosen menu_items index back to the pump.  */
extern void ios_pump_input (int timeout_ms);
extern int  ios_menu_next_serial (void);
extern void ios_publish_menu_selection (int serial, int index);
extern bool ios_take_menu_selection (int serial, int *index);

/* Async file-arrival channel (iosterm.m): the path is drained into
   a DRAG_N_DROP_EVENT on the Emacs thread.  Fed by openURL: and by
   the document-picker delegate.  */
extern void ios_publish_open_file (const char *path);

/* Last published canvas size in logical points (iosterm.m);
   consumed by x-create-frame so the initial frame matches the
   real canvas instead of a whole-screen guess.  */
extern bool ios_get_canvas_size (int *w, int *h);

/* Retained CTFontRef backing a struct font, as an opaque pointer so
   this plain-C header need not import Core Text (iosfont.m).  NULL for
   a font not opened by the iOS driver.  */
extern void *ios_font_ctfont (struct font *font);

/* Paint N Core Text glyphs into the backing store (ios.m).  GLYPHS are
   CGGlyph indices; XPOS holds each glyph's x origin and BASELINE_Y the
   shared baseline, in Emacs (top-left) frame pixels.  */
extern void ios_canvas_draw_glyphs (void *ctfont,
                                    const unsigned short *glyphs,
                                    const double *xpos, int n,
                                    double baseline_y,
                                    unsigned long fg_pixel,
                                    double clip_x, double clip_y,
                                    double clip_width, double clip_height);

#ifdef __OBJC__
/* Persist a security-scoped bookmark for URL so a relaunch can
   restore access (ios.m).  Safe from any thread.  */
@class NSURL;
extern void ios_save_bookmark (NSURL *url);
#endif

/* Image-loading bridge (iosimage.m) -- the HAVE_NATIVE_IMAGE_API
   path in image.c routes here.  */
extern bool ios_can_use_native_image_api (Lisp_Object type);
extern bool ios_load_image (struct frame *f, struct image *img,
                            Lisp_Object spec_file,
                            Lisp_Object spec_data);
extern void ios_free_pixmap (struct frame *f, Emacs_Pixmap pixmap);

#endif /* HAVE_IOS */
#endif /* IOSTERM_H */
