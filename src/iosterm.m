/* iOS terminal driver for GNU Emacs.
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

/* This file is the iOS analogue of src/androidterm.c.  It is
   responsible for the terminal-driver side of the iOS port: bridging
   UIKit events (touches, gestures, hardware keyboard, IME) into
   Emacs input_event values, and the inverse direction of drawing the
   glass into a CALayer-backed UIView.

   This commit installs the skeleton only; the real implementation
   lands in follow-up commits that mirror the structure of
   androidterm.c.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>

#include <pthread.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>

#include "lisp.h"
#include "iosterm.h"
#include "termhooks.h"
#include "keyboard.h"
#include "frame.h"
#include "window.h"
#include "dispextern.h"
#include "font.h"
#include "coding.h"

/* Forward declaration so ios_launch_log can be called from this file.
   Implementation lives in ios.m.  */
extern void ios_launch_log (NSString *msg);

/* Head of the singly-linked list of iOS displays.  Generic code in
   frame.c iterates this to enumerate displays.  iOS has exactly one
   logical display per app, so the list is at most one element long;
   ios_term_init prepends to it.  */
struct ios_display_info *x_display_list = NULL;

/* Per-port frame parameter handler table.  gui_set_frame_parameters_1
   indexes this by `x-frame-parameter' symbol index; without a non-
   NULL pointer here the indexing dereferences NULL.  The size and
   slot ordering are fixed by frame.c's frame_parms[] table; gaps
   are left NULL.  */
static frame_parm_handler ios_frame_parm_handlers[];

/* Forward declarations for terminal hooks defined further down in
   this file but installed inside ios_term_init.  */
static bool ios_defined_color (struct frame *f, const char *color_name,
                               Emacs_Color *color, bool alloc_p,
                               bool make_index);

/* No-op redisplay hooks.  Generic redisplay reaches into the
   per-port draw functions via FRAME_RIF (f)->draw_glyph_string etc.;
   any NULL slot causes a NULL function-pointer SIGSEGV on the first
   redisplay tick that wants to render.  These stubs accept the
   arguments and return, so update_window_line / draw_glyphs etc.
   complete without actually drawing anything visible.  The bring-up
   trades visible glyphs for a non-crashing main loop; a CALayer
   renderer will replace these one-by-one.  */
/* The canvas-side text sink is implemented in ios.m so this file
   stays free of UIKit imports.  See ios_canvas_draw_text there.  */
extern void ios_canvas_draw_text (double x, double y,
                                  double width, double height,
                                  unsigned long fg_pixel,
                                  unsigned long bg_pixel,
                                  const char *utf8, double font_size,
                                  unsigned deco, double cell_width);

/* Decoration bits the canvas understands; must match the
   EmacsDrawDeco enum in ios.m.  */
enum
{
  IOS_DECO_UNDERLINE_SINGLE = 1 << 0,
  IOS_DECO_UNDERLINE_WAVE   = 1 << 1,
  IOS_DECO_OVERLINE         = 1 << 2,
  IOS_DECO_STRIKE_THROUGH   = 1 << 3,
  IOS_DECO_ITALIC           = 1 << 4,
  IOS_DECO_BOLD             = 1 << 5,
};
extern void ios_canvas_draw_cursor (double x, double y,
                                    double width, double height,
                                    unsigned long pixel, int style);
extern void ios_canvas_clear_rect (double x, double y,
                                   double width, double height,
                                   unsigned long bg_pixel);
extern void ios_canvas_begin_frame (void);
extern void ios_canvas_end_frame (void);
extern void ios_canvas_set_background (unsigned long pixel);
extern void ios_canvas_scroll (double x, double y,
                               double width, double height, double dy);

/* Diagnostic counters: how many begin/end/draw calls we've seen.
   Logged from update_end so a screenshot reveals whether the
   redisplay engine is asking us to render anything.  */
static int ios_dbg_begin = 0, ios_dbg_end = 0, ios_dbg_draw = 0;

/* Input event queue + wake pipe.  Hoisted above ios_term_init so
   the pipe-setup code there sees the storage; the queue plumbing
   itself is defined further down.  */
#define IOS_INPUT_QUEUE_CAP 256
static int ios_input_queue[IOS_INPUT_QUEUE_CAP];
static int ios_input_head = 0, ios_input_tail = 0;
static pthread_mutex_t ios_input_lock = PTHREAD_MUTEX_INITIALIZER;
static int ios_wake_pipe[2] = { -1, -1 };

/* Decode a glyph string's char2b array (per-glyph code points; our
   minimal font driver passes through plain Unicode codepoints) into
   a UTF-8 char buffer.  Returns a newly-malloc'd string; caller frees.
   Returns NULL on memory failure.  */
static char *
ios_glyph_string_to_utf8 (struct glyph_string *s)
{
  if (s == NULL || s->char2b == NULL || s->nchars <= 0)
    return NULL;
  /* Upper bound: each Unicode codepoint encodes to at most 4 UTF-8
     bytes; plus one NUL.  */
  size_t cap = (size_t) s->nchars * 4 + 1;
  char *buf = xmalloc (cap);
  size_t pos = 0;
  for (int i = 0; i < s->nchars; i++)
    {
      unsigned cp = s->char2b[i];
      if (cp == 0)
        continue;
      if (cp < 0x80)
        buf[pos++] = (char) cp;
      else if (cp < 0x800)
        {
          buf[pos++] = (char) (0xc0 | (cp >> 6));
          buf[pos++] = (char) (0x80 | (cp & 0x3f));
        }
      else if (cp < 0x10000)
        {
          buf[pos++] = (char) (0xe0 | (cp >> 12));
          buf[pos++] = (char) (0x80 | ((cp >> 6) & 0x3f));
          buf[pos++] = (char) (0x80 | (cp & 0x3f));
        }
      else
        {
          buf[pos++] = (char) (0xf0 | (cp >> 18));
          buf[pos++] = (char) (0x80 | ((cp >> 12) & 0x3f));
          buf[pos++] = (char) (0x80 | ((cp >> 6) & 0x3f));
          buf[pos++] = (char) (0x80 | (cp & 0x3f));
        }
    }
  buf[pos] = '\0';
  return buf;
}

/* Send a glyph string to the iOS canvas.  At this stage the font
   driver passes Unicode codepoints through as "glyph ids", so we
   reassemble them as UTF-8 and let the canvas render via Core Text.
   The geometry comes straight from struct glyph_string.  */
/* The canvas-side image sink lives in ios.m where UIKit is in
   scope; declared here so the IMAGE_GLYPH branch can call it.  */
extern void ios_canvas_draw_image (double x, double y,
                                   double width, double height,
                                   void *cgimage);

static void
ios_noop_draw_glyph_string (struct glyph_string *s)
{
  ios_dbg_draw++;
  if (s->first_glyph && s->first_glyph->type == IMAGE_GLYPH)
    {
      /* Image glyph: paint the image at the glyph string's
         rectangle.  CGImageRef ownership stays with img->pixmap;
         the canvas draw command CFBridgingRetains it for the
         queue's lifetime so a redisplay in flight survives
         image.c clearing the pixmap.  */
      if (s->img != NULL && s->img->pixmap != NULL)
        ios_canvas_draw_image ((double) s->x, (double) s->y,
                               (double) (s->slice.width > 0
                                         ? s->slice.width : s->width),
                               (double) (s->slice.height > 0
                                         ? s->slice.height : s->height),
                               (void *) s->img->pixmap);
      return;
    }
  char *utf8 = ios_glyph_string_to_utf8 (s);
  if (utf8 == NULL || *utf8 == '\0')
    {
      if (utf8) xfree (utf8);
      return;
    }
  double font_size = (s->font && s->font->pixel_size > 0)
                     ? (double) s->font->pixel_size
                     : 14.0;
  /* background_width covers the area redisplay considers "owned"
     by this glyph string -- using width here would leave thin
     un-erased margins at line wraps.  */
  double w = (s->background_width > 0) ? s->background_width : s->width;
  double h = (s->height > 0) ? s->height : (double) font_size;
  /* Foreground/background pixels live on the face; defined_color_hook
     stores them as 0x00RRGGBB which is what the canvas expects.
     Fall back to black-on-white when no face is attached.  */
  unsigned long fg = (s->face && s->face->foreground != ~0UL)
                     ? s->face->foreground : 0x000000;
  unsigned long bg = (s->face && s->face->background != ~0UL)
                     ? s->face->background : 0xffffff;

  /* Block cursor: draw_phys_cursor_glyph re-enters here with
     hl == DRAW_CURSOR expecting cursor colors -- character in
     the frame background color on a cursor-pixel block, the
     same fg/bg swap every other port performs.  */
  if (s->hl == DRAW_CURSOR)
    {
      struct frame *f = s->f;
      unsigned long cursor = f->output_data.ios->cursor_pixel;
      fg = bg;
      bg = cursor;
    }

  /* Translate face decorations into canvas flags.  Bold / italic
     come from the font weight & slant; underline/overline/strike-
     through come from the dedicated face bits.  */
  unsigned deco = 0;
  if (s->face)
    {
      switch (s->face->underline)
        {
        case FACE_UNDERLINE_SINGLE:
        case FACE_UNDERLINE_DOUBLE_LINE:
        case FACE_UNDERLINE_DOTS:
        case FACE_UNDERLINE_DASHES:
          deco |= IOS_DECO_UNDERLINE_SINGLE;
          break;
        case FACE_UNDERLINE_WAVE:
          deco |= IOS_DECO_UNDERLINE_WAVE;
          break;
        default:
          break;
        }
      if (s->face->overline_p)
        deco |= IOS_DECO_OVERLINE;
      if (s->face->strike_through_p)
        deco |= IOS_DECO_STRIKE_THROUGH;
    }
  if (s->font)
    {
      int slant = FONT_SLANT_NUMERIC (s->font);
      int weight = FONT_WEIGHT_NUMERIC (s->font);
      if (slant > 100)  deco |= IOS_DECO_ITALIC;
      if (weight > 100) deco |= IOS_DECO_BOLD;
    }

  /* Pass the frame's column width so the canvas can position
     every character on Emacs's integer cell grid.  Core Text's
     natural advances (e.g. 8.43pt for 14pt SF Mono) disagree
     with the ceil'd cell width Emacs lays out with (9pt), and
     mixing the two grids shows up the moment single characters
     are repainted -- cursor passage visibly re-typeset text
     during on-device testing.  */
  ios_canvas_draw_text ((double) s->x, (double) s->y,
                        w, h, fg, bg, utf8, font_size, deco,
                        (double) FRAME_COLUMN_WIDTH (s->f));
  xfree (utf8);
}

static void
ios_draw_fringe_bitmap (struct window *w, struct glyph_row *row,
                        struct draw_fringe_bitmap_params *p)
{
  (void) row;
  struct frame *f = XFRAME (WINDOW_FRAME (w));
  struct face *face = p->face;

  /* Fringe background strip for this row (skipped for overlaid
     bitmaps, matching the other ports).  */
  if (p->bx >= 0 && !p->overlay_p)
    ios_canvas_clear_rect ((double) p->bx, (double) p->by,
                           (double) p->nx, (double) p->ny,
                           (face && face->background != ~0UL)
                           ? face->background
                           : FRAME_BACKGROUND_PIXEL (f));

  if (!p->which || p->bits == NULL || p->wd <= 0 || p->h <= 0)
    return;

  unsigned long fg = p->cursor_p
    ? f->output_data.ios->cursor_pixel
    : ((face && face->foreground != ~0UL)
       ? face->foreground
       : FRAME_FOREGROUND_PIXEL (f));

  /* Rasterize the bitmap into horizontal runs of filled rects.
     Bit order per fringe.c's own bitmap art (the question-mark
     comment): within a wd-wide row, pixel column j (0 = left) is
     bit (wd - 1 - j).  p->dh skips source rows, as in
     x_draw_fringe_bitmap; the destination stays at p->y.
     Coalescing runs keeps this to a couple of commands per row --
     an arrow costs ~20 rects, not ~60 pixels.  */
  unsigned short *bits = p->bits + p->dh;
  for (int r = 0; r < p->h; r++)
    {
      unsigned short rowbits = bits[r];
      int j = 0;
      while (j < p->wd)
        {
          if (rowbits & (1 << (p->wd - 1 - j)))
            {
              int start = j;
              while (j < p->wd && (rowbits & (1 << (p->wd - 1 - j))))
                j++;
              ios_canvas_clear_rect ((double) (p->x + start),
                                     (double) (p->y + r),
                                     (double) (j - start), 1.0, fg);
            }
          else
            j++;
        }
    }
}

static void
ios_noop_define_fringe_bitmap (int which, unsigned short *bits, int h, int wd)
{
  (void) which; (void) bits; (void) h; (void) wd;
}

static void
ios_noop_destroy_fringe_bitmap (int which)
{
  (void) which;
}

static void
ios_noop_compute_glyph_string_overhangs (struct glyph_string *s)
{
  (void) s;
}

static void
ios_noop_define_frame_cursor (struct frame *f, Emacs_Cursor cursor)
{
  (void) f; (void) cursor;
}

static void
ios_noop_clear_frame_area (struct frame *f, int x, int y, int width, int height)
{
  unsigned long bg = (f && f->output_data.ios)
                     ? FRAME_BACKGROUND_PIXEL (f) : 0xffffff;
  ios_canvas_clear_rect ((double) x, (double) y,
                         (double) width, (double) height, bg);
}

static void
ios_noop_clear_under_internal_border (struct frame *f)
{
  (void) f;
}

static void
ios_noop_draw_window_cursor (struct window *w, struct glyph_row *glyph_row,
                             int x, int y, enum text_cursor_kinds cursor_type,
                             int cursor_width, bool on_p, bool active_p)
{
  (void) active_p;
  if (w == NULL || glyph_row == NULL)
    return;
  struct frame *f = XFRAME (WINDOW_FRAME (w));
  if (!FRAME_IOS_P (f))
    return;

  if (!on_p)
    /* Erasure is handled generically: erase_phys_cursor redraws
       the underlying glyph through draw_glyph_string, which our
       overpaint list renders on top of the stale cursor.  Nothing
       port-specific to do here.  */
    return;

  /* CRITICAL bookkeeping: erase_phys_cursor consults
     w->phys_cursor_on_p and returns without erasing when it is
     false.  Without these assignments the generic machinery never
     erases, and cursor motion without a text change (C-f, C-n,
     blink) leaves a trail of stale cursor marks -- the port's
     worst user-visible defect during on-device testing.  Mirrors
     android_draw_window_cursor.  */
  w->phys_cursor_type = cursor_type;
  w->phys_cursor_on_p = true;

  if (cursor_type == NO_CURSOR)
    return;

  /* Translate window-relative (x,y) into frame-relative pixel
     coordinates so the canvas receives the same coordinate space
     as draw_glyph_string.  */
  int abs_x = WINDOW_LEFT_EDGE_X (w) + x;
  int abs_y = WINDOW_TOP_EDGE_Y (w) + glyph_row->y;
  int w_px  = cursor_width > 0
              ? cursor_width
              : FRAME_COLUMN_WIDTH (f);
  int h_px  = glyph_row->height > 0
              ? glyph_row->height
              : FRAME_LINE_HEIGHT (f);
  unsigned long pixel = f->output_data.ios->cursor_pixel;

  if (cursor_type == FILLED_BOX_CURSOR)
    {
      /* Draw the character in cursor colors rather than hiding it
         under an opaque rectangle: route through the generic
         helper, which re-enters draw_glyph_string with
         hl == DRAW_CURSOR (handled there by swapping to the
         cursor face colors).  */
      draw_phys_cursor_glyph (w, glyph_row, DRAW_CURSOR);
      return;
    }

  /* enum text_cursor_kinds: FILLED_BOX=0, HOLLOW_BOX=1, BAR=2, HBAR=3.  */
  ios_canvas_draw_cursor ((double) abs_x, (double) abs_y,
                          (double) w_px, (double) h_px,
                          pixel, (int) cursor_type);
}

/* Separator between side-by-side windows (C-x 3).  Without it the
   windows visually bleed into each other -- same defect family as
   the other silently-empty drawing stubs found after on-device
   testing.  A one-pixel line in the vertical-border face's
   foreground (frame foreground when the face isn't realized),
   painted through the same clear-rect command the erase path
   uses.  */
static void
ios_draw_vertical_window_border (struct window *w, int x, int y_0, int y_1)
{
  struct frame *f = XFRAME (WINDOW_FRAME (w));
  struct face *face = FACE_FROM_ID_OR_NULL (f, VERTICAL_BORDER_FACE_ID);
  unsigned long color = (face && face->foreground != ~0UL)
                        ? face->foreground
                        : FRAME_FOREGROUND_PIXEL (f);
  ios_canvas_clear_rect ((double) x, (double) y_0,
                         1.0, (double) (y_1 - y_0), color);
}

static void
ios_draw_window_divider (struct window *w, int x_0, int x_1,
                         int y_0, int y_1)
{
  struct frame *f = XFRAME (WINDOW_FRAME (w));
  struct face *face = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_FACE_ID);
  unsigned long color = (face && face->foreground != ~0UL)
                        ? face->foreground
                        : FRAME_FOREGROUND_PIXEL (f);
  ios_canvas_clear_rect ((double) x_0, (double) y_0,
                         (double) (x_1 - x_0), (double) (y_1 - y_0),
                         color);
}

static void
ios_noop_shift_glyphs_for_insert (struct frame *f, int x, int y, int width,
                                  int height, int shift_by)
{
  (void) f; (void) x; (void) y; (void) width; (void) height; (void) shift_by;
}

static void
ios_noop_show_hourglass (struct frame *f) { (void) f; }
static void
ios_noop_hide_hourglass (struct frame *f) { (void) f; }
static void
ios_noop_default_font_parameter (struct frame *f, Lisp_Object parms)
{
  (void) f; (void) parms;
}

static void
ios_noop_after_update_window_line (struct window *w,
                                   struct glyph_row *desired_row)
{
  (void) w; (void) desired_row;
}

static void
ios_noop_update_window_begin (struct window *w) { (void) w; }
static void
ios_noop_update_window_end (struct window *w, bool cursor_on_p,
                            bool mouse_face_overwritten_p)
{
  (void) w; (void) cursor_on_p; (void) mouse_face_overwritten_p;
}

/* Terminal-level frame bracket.  Installed as
   terminal->update_begin_hook / update_end_hook -- those fire ONCE
   per frame redisplay (across all that frame's windows), so they
   give a clean clear / request-draw bracket the per-window hooks
   above can't.  */

extern void ios_launch_log (NSString *);

static void
ios_term_update_begin (struct frame *f)
{
  (void) f;
  ios_dbg_begin++;
  ios_canvas_begin_frame ();
}
static void
ios_term_update_end (struct frame *f)
{
  ios_dbg_end++;
  /* Keep the view background aligned with the frame background
     (no-op unless the color changed).  */
  if (f && FRAME_IOS_P (f))
    ios_canvas_set_background (FRAME_BACKGROUND_PIXEL (f));
  ios_canvas_end_frame ();
  /* Light heartbeat: first few ticks then every 100th, with the
     root window's live dims.  Cheap and has repeatedly proven its
     diagnostic worth during bring-up.  */
  if (ios_dbg_end <= 3 || (ios_dbg_end % 100) == 0)
    {
      struct window *rootw = XWINDOW (FRAME_ROOT_WINDOW (f));
      ios_launch_log ([NSString stringWithFormat:
                       @"redisplay #%d draws=%d root=%dx%dpx %dx%dcell",
                       ios_dbg_end, ios_dbg_draw,
                       rootw->pixel_width, rootw->pixel_height,
                       rootw->total_cols, rootw->total_lines]);
    }
}
static void
ios_noop_flush_display (struct frame *f) { (void) f; }
/* dispnew calls this AFTER deciding the run's rows moved on
   screen; it will not redraw them.  An empty implementation
   therefore leaves stale pixels behind on every scroll -- the
   dominant "draws uncleanly" defect from on-device testing
   (buffer scrolling, and the row shuffle when the minibuffer
   grows and shrinks).  Geometry and mode-line clipping mirror
   xterm's x_scroll_run.  */
static void
ios_scroll_run (struct window *w, struct run *run)
{
  int x, y, width, height, from_y, to_y, bottom_y;

  window_box (w, ANY_AREA, &x, &y, &width, &height);

  from_y = WINDOW_TO_FRAME_PIXEL_Y (w, run->current_y);
  to_y = WINDOW_TO_FRAME_PIXEL_Y (w, run->desired_y);
  bottom_y = y + height;

  if (to_y < from_y)
    {
      /* Scrolling up: don't copy part of the mode line.  */
      if (from_y + run->height > bottom_y)
        height = bottom_y - from_y;
      else
        height = run->height;
    }
  else
    {
      /* Scrolling down: don't copy over the mode line.  */
      if (to_y + run->height > bottom_y)
        height = bottom_y - to_y;
      else
        height = run->height;
    }

  /* Cursor off; switched back on in gui_update_window_end.  */
  gui_clear_cursor (w);

  ios_canvas_scroll ((double) x, (double) from_y,
                     (double) width, (double) height,
                     (double) (to_y - from_y));
}

/* Redisplay interface for iOS frames.  Wire up the shared gui_*
   helpers (defined in xdisp.c) for the produce/write/insert/
   clear/glyph paths so init_iterator's first call to PRODUCE_GLYPHS
   doesn't NULL-deref.  CALayer-backed drawing (draw_glyph_string,
   draw_window_cursor, ...) is still NULL; we'll fill those in once
   the EmacsUIView has a real Core Graphics back-end.  */
static struct redisplay_interface ios_redisplay_interface =
  {
    ios_frame_parm_handlers,
    gui_produce_glyphs,
    gui_write_glyphs,
    gui_insert_glyphs,
    gui_clear_end_of_line,
    ios_scroll_run,
    ios_noop_after_update_window_line,
    ios_noop_update_window_begin,
    ios_noop_update_window_end,
    ios_noop_flush_display,
    gui_clear_window_mouse_face,
    gui_get_glyph_overhangs,
    gui_fix_overlapping_area,
    ios_draw_fringe_bitmap,
    ios_noop_define_fringe_bitmap,
    ios_noop_destroy_fringe_bitmap,
    ios_noop_compute_glyph_string_overhangs,
    ios_noop_draw_glyph_string,
    ios_noop_define_frame_cursor,
    ios_noop_clear_frame_area,
    ios_noop_clear_under_internal_border,
    ios_noop_draw_window_cursor,
    ios_draw_vertical_window_border,
    ios_draw_window_divider,
    ios_noop_shift_glyphs_for_insert,
    ios_noop_show_hourglass,
    ios_noop_hide_hourglass,
    ios_noop_default_font_parameter,
  };

/* Translate a port-specific keysym to its Lisp symbol name.
   keyboard.c's modify_event_symbol calls this when it can't find a
   keysym in the prebuilt tables.  iOS doesn't surface raw keysyms
   yet (input arrives as NSString via UIKeyCommand / UITextInput);
   return an empty static buffer for now so the call links.  Once
   UIKeyCommand handling lands, this will look up the matching
   Emacs symbol name.  */
char *
get_keysym_name (int keysym)
{
  static char buffer[64];
  buffer[0] = '\0';
  return buffer;
}

/* Allocate the ios_display_info / struct terminal pair and wire it
   into the generic terminal infrastructure.  Mirrors
   android_term_init / x_term_init in shape: one display per app on
   iOS, so this is called exactly once at startup from init_display.

   The terminal returned here has only its read_socket_hook hooked up
   (to ios_read_socket, which is itself a stub draining nothing yet).
   The remaining redisplay hooks stay NULL; xdisp.c's update_frame
   path tolerates NULL hooks on non-window frames during early bring-
   up.  The frame that we're attached to is the initial frame
   (output_initial); a real output_ios frame will be created when
   Fx_create_frame is implemented.  */

/* terminal->set_new_font_hook.  Called by gui_set_font and
   x-create-frame to install FONT_OBJECT as the frame's primary
   font and resize the laid-out cell grid to match.  Mirrors the
   shape of android_new_font; the bare minimum that adjust_frame_size
   needs to know is FRAME_FONT, FRAME_BASELINE_OFFSET,
   FRAME_COLUMN_WIDTH, FRAME_LINE_HEIGHT.  */
static Lisp_Object
ios_new_font (struct frame *f, Lisp_Object font_object, int fontset)
{
  struct font *font = XFONT_OBJECT (font_object);
  int font_ascent, font_descent;

  if (fontset < 0)
    fontset = fontset_from_font (font_object);
  FRAME_FONTSET (f) = fontset;
  if (FRAME_FONT (f) == font)
    return font_object;

  get_font_ascent_descent (font, &font_ascent, &font_descent);
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_new_font: pixel_size=%d avg_width=%d"
                   @" height=%d (asc %d desc %d)",
                   font->pixel_size, font->average_width,
                   font->height, font_ascent, font_descent]);
  /* Refuse to install a font with degenerate cell metrics --
     adjust_frame_size below would compute cols == pixels and the
     frame collapses to unreadable 1px cells.  The font object is
     still returned so the face layer can use it for glyphs, but
     the frame keeps its current grid.  */
  if (font->average_width < 3 || font_ascent + font_descent < 6)
    return font_object;

  FRAME_FONT (f) = font;
  FRAME_BASELINE_OFFSET (f) = font->baseline_offset;
  FRAME_COLUMN_WIDTH (f) = font->average_width;
  FRAME_LINE_HEIGHT (f) = font_ascent + font_descent;
  FRAME_TAB_BAR_HEIGHT (f)
    = FRAME_TAB_BAR_LINES (f) * FRAME_LINE_HEIGHT (f);

  if (FRAME_LIVE_P (f) && !FRAME_TOOLTIP_P (f))
    adjust_frame_size (f, FRAME_COLS (f) * FRAME_COLUMN_WIDTH (f),
                       FRAME_LINES (f) * FRAME_LINE_HEIGHT (f), 3,
                       false, Qfont);
  return font_object;
}

/* terminal->ring_bell_hook.  iOS has no audible bell; the
   user-facing convention is a single haptic tap (matches
   what other apps do when they want a discreet "no" beep).
   Dispatched to the main queue because UIImpactFeedbackGenerator
   wants the UI thread.  */
/* Hoisted up here so ios_mouse_position below can reference them
   directly; the publish / drain helpers further down use the same
   storage.  */
static pthread_mutex_t ios_motion_lock = PTHREAD_MUTEX_INITIALIZER;
static int  ios_motion_x = 0;
static int  ios_motion_y = 0;
static bool ios_motion_dirty = false;

/* User toggled system appearance.  Set from
   traitCollectionDidChange on the UI thread; consumed inside
   ios_read_socket which runs ios-appearance-changed-hook.
   Guarded by ios_motion_lock -- it's a UI-thread-publishes /
   Emacs-thread-drains flag exactly like the motion state, and
   sharing the (uncontended) lock keeps the cross-thread
   publishing protocol uniform.  */
static bool ios_appearance_dirty = false;

static void
ios_ring_bell (struct frame *f)
{
  (void) f;
  dispatch_async (dispatch_get_main_queue (), ^{
    UIImpactFeedbackGenerator *gen
      = [[UIImpactFeedbackGenerator alloc]
          initWithStyle:UIImpactFeedbackStyleMedium];
    [gen prepare];
    [gen impactOccurred];
  });
}

/* terminal->mouse_position_hook.  Emacs calls this whenever it
   needs the current cursor coordinates (e.g. mouse-position,
   minibuffer help).  Reports the last finger position cached by
   ios_publish_mouse_motion; if nothing has touched yet, returns
   coordinates of (0,0) which is harmless for the limited callers
   that probe this from idle.  */
static void
ios_mouse_position (struct frame **fp, int insist,
                    Lisp_Object *bar_window,
                    enum scroll_bar_part *part,
                    Lisp_Object *xp, Lisp_Object *yp,
                    Time *time)
{
  (void) insist;
  if (x_display_list && CONSP (Vframe_list))
    *fp = XFRAME (XCAR (Vframe_list));
  else
    *fp = NULL;
  *bar_window = Qnil;
  *part = scroll_bar_above_handle;
  int x = 0, y = 0;
  pthread_mutex_lock (&ios_motion_lock);
  x = ios_motion_x; y = ios_motion_y;
  pthread_mutex_unlock (&ios_motion_lock);
  XSETINT (*xp, x);
  XSETINT (*yp, y);
  *time = 0;
}

struct terminal *
ios_term_init (void)
{
  if (x_display_list)
    /* init_display can be called more than once if the user toggles
       window-system; on iOS that never happens, but defend anyway.  */
    return x_display_list->terminal;

  struct ios_display_info *dpyinfo = xzalloc (sizeof *dpyinfo);
  struct terminal *terminal
    = create_terminal (output_ios, &ios_redisplay_interface);

  terminal->display_info.ios = dpyinfo;
  dpyinfo->terminal = terminal;

  /* Allocate a kboard so keyboard.c has somewhere to record terminal-
     local keymaps, prefix args, etc.  Mirrors android.  */
  terminal->kboard = allocate_kboard (Qios);
  terminal->kboard->reference_count++;

  /* Install the only real hooks we have for now.  Everything else is
     NULL and the generic code checks before calling.  */
  terminal->read_socket_hook = ios_read_socket;
  terminal->defined_color_hook = ios_defined_color;
  terminal->update_begin_hook = ios_term_update_begin;
  terminal->update_end_hook = ios_term_update_end;
  terminal->mouse_position_hook = ios_mouse_position;
  terminal->ring_bell_hook = ios_ring_bell;
  terminal->menu_show_hook = ios_menu_show;
  terminal->popup_dialog_hook = ios_popup_dialog;
  terminal->set_new_font_hook = ios_new_font;
  terminal->free_pixmap = ios_free_pixmap;

  /* Create the input wake pipe and register the read end with
     Emacs so wait_reading_process_input wakes on writes.  */
  if (pipe (ios_wake_pipe) == 0)
    {
      /* Make both ends non-blocking: writes from the UI thread
         must not stall, and the read in read_socket_hook should
         return immediately when the pipe is empty.  */
      fcntl (ios_wake_pipe[0], F_SETFL,
             fcntl (ios_wake_pipe[0], F_GETFL) | O_NONBLOCK);
      fcntl (ios_wake_pipe[1], F_SETFL,
             fcntl (ios_wake_pipe[1], F_GETFL) | O_NONBLOCK);
      add_keyboard_wait_descriptor (ios_wake_pipe[0]);
    }

  /* Populate display geometry from UIKit.  This runs on the iOS bg
     pthread, not the main thread; UIScreen.mainScreen is documented
     thread-safe for property reads.  Fall back to sensible defaults
     if a UIScreen isn't yet available (shouldn't happen post-launch
     but the bring-up touches edge cases).  */
  @autoreleasepool {
    UIScreen *screen = UIScreen.mainScreen;
    if (screen)
      {
        CGRect b = screen.bounds;
        CGFloat s = screen.scale;
        dpyinfo->logical_width = (int) b.size.width;
        dpyinfo->logical_height = (int) b.size.height;
        dpyinfo->scale_factor = (double) s;
        dpyinfo->pixel_width = (int) (b.size.width * s);
        dpyinfo->pixel_height = (int) (b.size.height * s);
        /* Resolution must describe the coordinate space the port
           actually draws in, which for us is LOGICAL POINTS (the
           canvas bounds, frame pixel_width/height, and font
           pixel_size are all point-valued; Core Graphics applies
           the Retina scale underneath).  Multiplying by scale here
           (physical ppi) made the face engine's point<->pixel
           conversions disagree with the geometry by 2-3x: a
           14px-at-489dpi font is 2.1pt, and any code that
           round-trips a face height through points came back with
           a collapsed, near-zero pixel size.

           Logical density differs by device family: iPhone
           logical space is ~163 ppi, iPad's is ~132 ppi.  Using
           the iPhone value on an iPad skews every point-derived
           font size by ~23%.  */
        {
          double logical_ppi =
            (UIDevice.currentDevice.userInterfaceIdiom
             == UIUserInterfaceIdiomPad) ? 132.0 : 163.0;
          dpyinfo->resx = logical_ppi;
          dpyinfo->resy = logical_ppi;
        }
      }
    else
      {
        dpyinfo->logical_width = dpyinfo->logical_height = 0;
        dpyinfo->pixel_width = dpyinfo->pixel_height = 0;
        dpyinfo->scale_factor = 1.0;
        dpyinfo->resx = dpyinfo->resy = 96.0;
      }
  }

  /* The iOS framebuffer is always RGB; 24-bit is the conservative
     answer for color/bitmap discrimination in image.c.  */
  dpyinfo->n_planes = 24;

  /* https://lists.gnu.org/r/emacs-devel/2015-11/msg00194.html  */
  dpyinfo->smallest_font_height = 1;
  dpyinfo->smallest_char_width = 1;

  dpyinfo->name_list_element = Fcons (build_string ("ios"), Qnil);

  /* Display "connection" is permanent for the life of the app.  */
  terminal->reference_count = 30000;
  terminal->name = xstrdup ("ios");

  /* Set baud_rate to a value that disables baud-throttling in the
     redisplay code -- same value the X / Android ports use.  */
  baud_rate = 19200;

  /* Publish.  Generic frame-enumeration code walks this list.  */
  x_display_list = dpyinfo;

  ios_launch_log ([NSString stringWithFormat:
                   @"ios_term_init: terminal=%p dpyinfo=%p"
                   @" logical=%dx%d pixel=%dx%d scale=%.1f",
                   terminal, dpyinfo,
                   dpyinfo->logical_width, dpyinfo->logical_height,
                   dpyinfo->pixel_width, dpyinfo->pixel_height,
                   dpyinfo->scale_factor]);
  return terminal;
}

/* ---- Input event queue ---------------------------------------- */

/* The queue + wake pipe storage is hoisted above ios_term_init;
   only the producer / drainer code lives here.  */

/* Poke the wake pipe so wait_reading_process_input returns and
   read_socket_hook runs.  Shared by every publish/enqueue path;
   best-effort (EAGAIN on a full pipe is fine -- the reader is
   already scheduled to wake).  */
static void
ios_wake (void)
{
  if (ios_wake_pipe[1] >= 0)
    {
      char b = 1;
      ssize_t r = write (ios_wake_pipe[1], &b, 1);
      (void) r;
    }
}

/* Queue for "rich" events (mouse clicks) alongside the keystroke
   queue.  Producer (UI thread) appends; consumer (ios_read_socket)
   drains and hands each to kbd_buffer_store_event_hold.  Capacity
   is small -- gestures rarely buffer up.  */
#define IOS_EVENT_QUEUE_CAP 64
static struct input_event ios_event_queue[IOS_EVENT_QUEUE_CAP];
static int ios_event_head = 0, ios_event_tail = 0;

/* C-callable producer for a single fully-formed input_event.
   Called from the UI thread.  Drops on overflow.  Wakes the
   wait-for-input select() through the same pipe as keys.  */
void
ios_enqueue_event (struct input_event *ie)
{
  pthread_mutex_lock (&ios_input_lock);
  int next = (ios_event_tail + 1) % IOS_EVENT_QUEUE_CAP;
  if (next != ios_event_head)
    {
      ios_event_queue[ios_event_tail] = *ie;
      ios_event_tail = next;
    }
  pthread_mutex_unlock (&ios_input_lock);
  ios_wake ();
}

/* Pending canvas resize, published from EmacsUIView's
   layoutSubviews on the UIKit thread and consumed by
   ios_read_socket on the Emacs thread.  Only the most recent
   request matters; coalesced via overwrite under the lock.  */
static pthread_mutex_t ios_resize_lock = PTHREAD_MUTEX_INITIALIZER;
static int ios_pending_canvas_w = 0;
static int ios_pending_canvas_h = 0;
static bool ios_pending_canvas_valid = false;

/* Last known mouse / finger position lives further up (above
   ios_mouse_position, which reads it directly).  */

void
ios_publish_mouse_motion (double x, double y)
{
  pthread_mutex_lock (&ios_motion_lock);
  ios_motion_x = (int) x;
  ios_motion_y = (int) y;
  ios_motion_dirty = true;
  pthread_mutex_unlock (&ios_motion_lock);
  ios_wake ();
}

/* Pinch updates.  PINCH_EVENT's arg is a Lisp list, which can
   only be consed on the Emacs thread, so the UIKit gesture
   handler publishes raw floats into this ring and the drain
   below builds the events.  A ring (not a single slot) because
   the sequence-start marker (dx = dy = angle = 0) must not be
   overwritten by the first update before the Emacs thread gets
   a chance to drain -- text-scale-pinch uses that marker to
   snapshot the starting text scale.  */
struct ios_pinch_update
{
  int x, y;
  double dx, dy, scale, angle;
};
#define IOS_PINCH_QUEUE_CAP 16
static struct ios_pinch_update ios_pinch_queue[IOS_PINCH_QUEUE_CAP];
static int ios_pinch_head = 0, ios_pinch_tail = 0;

void
ios_publish_pinch (double x, double y, double dx, double dy,
                   double scale, double angle)
{
  pthread_mutex_lock (&ios_motion_lock);
  int next = (ios_pinch_tail + 1) % IOS_PINCH_QUEUE_CAP;
  if (next != ios_pinch_head)
    {
      struct ios_pinch_update *u = &ios_pinch_queue[ios_pinch_tail];
      u->x = (int) x;
      u->y = (int) y;
      u->dx = dx;
      u->dy = dy;
      u->scale = scale;
      u->angle = angle;
      ios_pinch_tail = next;
    }
  pthread_mutex_unlock (&ios_motion_lock);
  ios_wake ();
}

/* Drain pinch updates into PINCH_EVENTs.  Emacs thread only.  */
static void
ios_apply_pending_pinch (struct input_event *hold_quit)
{
  if (!x_display_list || !CONSP (Vframe_list))
    return;
  struct frame *f = XFRAME (XCAR (Vframe_list));
  if (!f || !FRAME_LIVE_P (f))
    return;
  for (;;)
    {
      struct ios_pinch_update u;
      bool have = false;
      pthread_mutex_lock (&ios_motion_lock);
      if (ios_pinch_head != ios_pinch_tail)
        {
          u = ios_pinch_queue[ios_pinch_head];
          ios_pinch_head = (ios_pinch_head + 1) % IOS_PINCH_QUEUE_CAP;
          have = true;
        }
      pthread_mutex_unlock (&ios_motion_lock);
      if (!have)
        break;
      struct input_event ie;
      EVENT_INIT (ie);
      ie.kind = PINCH_EVENT;
      ie.code = 0;
      ie.modifiers = 0;
      ie.x = make_fixnum (u.x);
      ie.y = make_fixnum (u.y);
      XSETFRAME (ie.frame_or_window, f);
      ie.arg = list4 (make_float (u.dx), make_float (u.dy),
                      make_float (u.scale), make_float (u.angle));
      ie.timestamp = 0;
      kbd_buffer_store_event_hold (&ie, hold_quit);
    }
}

/* Path of a file another app asked us to open (Files.app share
   sheet, Mail attachment, ...).  Published from the UIKit
   thread's application:openURL:; the Emacs thread drains it
   into a DRAG_N_DROP_EVENT, building the Lisp string on the
   correct thread (Lisp allocation is not legal on the UIKit
   thread).  Guarded by ios_motion_lock like the other
   publish/drain channels.  */
static char *ios_pending_open_path = NULL;

void
ios_publish_open_file (const char *path)
{
  if (path == NULL || *path == 0)
    return;
  char *copy = strdup (path);
  if (copy == NULL)
    return;
  pthread_mutex_lock (&ios_motion_lock);
  free (ios_pending_open_path);
  ios_pending_open_path = copy;
  pthread_mutex_unlock (&ios_motion_lock);
  ios_wake ();
}

/* Turn a pending open-file request into a DRAG_N_DROP_EVENT.
   Runs on the Emacs thread inside read_socket, where building
   Lisp strings is safe.  The Lisp side (ios-win.el) binds
   [drag-n-drop] to a handler that visits the file.  */
static void
ios_apply_pending_open (struct input_event *hold_quit)
{
  char *path = NULL;
  pthread_mutex_lock (&ios_motion_lock);
  path = ios_pending_open_path;
  ios_pending_open_path = NULL;
  pthread_mutex_unlock (&ios_motion_lock);
  if (path == NULL)
    return;
  if (x_display_list && CONSP (Vframe_list))
    {
      struct frame *f = XFRAME (XCAR (Vframe_list));
      if (f && FRAME_LIVE_P (f))
        {
          struct input_event ie;
          EVENT_INIT (ie);
          ie.kind = DRAG_N_DROP_EVENT;
          ie.code = 0;
          ie.modifiers = 0;
          ie.x = make_fixnum (0);
          ie.y = make_fixnum (0);
          XSETFRAME (ie.frame_or_window, f);
          ie.arg = list1 (DECODE_FILE (build_unibyte_string (path)));
          ie.timestamp = 0;
          kbd_buffer_store_event_hold (&ie, hold_quit);
        }
    }
  free (path);
}

/* Publish appearance change.  Cheap on the UI thread; the
   Emacs thread picks it up on its next read_socket tick.  */
void
ios_publish_appearance_change (void)
{
  pthread_mutex_lock (&ios_motion_lock);
  ios_appearance_dirty = true;
  pthread_mutex_unlock (&ios_motion_lock);
  ios_wake ();
}

/* Run ios-appearance-changed-hook if the UI side flipped the
   dirty bit.  Wrapped in safe_run_hooks so a malformed user
   binding can't crash the read-socket path.  */
static void
ios_apply_pending_appearance (void)
{
  bool dirty;
  pthread_mutex_lock (&ios_motion_lock);
  dirty = ios_appearance_dirty;
  ios_appearance_dirty = false;
  pthread_mutex_unlock (&ios_motion_lock);
  if (!dirty)
    return;
  safe_run_hooks (intern_c_string ("ios-appearance-changed-hook"));
}

/* Consume the dirty bit and call note_mouse_highlight on the
   selected frame so the region highlight follows the finger
   during drag-select.  No-op if no motion has been published
   since last drain.  Runs on the Emacs thread.  */
static void
ios_apply_pending_motion (void)
{
  int x = 0, y = 0;
  bool dirty = false;
  pthread_mutex_lock (&ios_motion_lock);
  if (ios_motion_dirty)
    {
      x = ios_motion_x;
      y = ios_motion_y;
      dirty = true;
      ios_motion_dirty = false;
    }
  pthread_mutex_unlock (&ios_motion_lock);
  if (!dirty || !x_display_list || !CONSP (Vframe_list))
    return;
  struct frame *f = XFRAME (XCAR (Vframe_list));
  if (!f || !FRAME_LIVE_P (f))
    return;
  note_mouse_highlight (f, x, y);
}

void
ios_publish_canvas_size (double width, double height)
{
  pthread_mutex_lock (&ios_resize_lock);
  int w = (int) width;
  int h = (int) height;
  if (ios_pending_canvas_w != w || ios_pending_canvas_h != h)
    {
      ios_pending_canvas_w = w;
      ios_pending_canvas_h = h;
      ios_pending_canvas_valid = true;
    }
  pthread_mutex_unlock (&ios_resize_lock);
  ios_wake ();
}

/* Last published canvas size, for x-create-frame: UIKit lays the
   canvas out during app launch, seconds before loadup finishes and
   the first frame is created, so by frame-creation time the real
   canvas bounds are known.  Sizing the frame from them directly
   avoids the whole-screen guess (and its visible snap when the
   first resize event lands).  Returns false if no layout pass has
   published yet (headless early startup).  */
bool
ios_get_canvas_size (int *w, int *h)
{
  bool have = false;
  pthread_mutex_lock (&ios_resize_lock);
  if (ios_pending_canvas_w > 0 && ios_pending_canvas_h > 0)
    {
      *w = ios_pending_canvas_w;
      *h = ios_pending_canvas_h;
      have = true;
    }
  pthread_mutex_unlock (&ios_resize_lock);
  return have;
}

/* Called from the Emacs thread at the top of read_socket.  If a
   new canvas size is pending and it actually differs from the
   frame's current pixel dims, call change_frame_size.  */
static void
ios_apply_pending_resize (void)
{
  int w = 0, h = 0;
  bool valid = false;
  pthread_mutex_lock (&ios_resize_lock);
  if (ios_pending_canvas_valid)
    {
      w = ios_pending_canvas_w;
      h = ios_pending_canvas_h;
      valid = true;
      ios_pending_canvas_valid = false;
    }
  pthread_mutex_unlock (&ios_resize_lock);
  if (!valid || !x_display_list)
    return;
  Lisp_Object frames = Vframe_list;
  if (!CONSP (frames))
    return;
  struct frame *f = XFRAME (XCAR (frames));
  if (!f || !FRAME_LIVE_P (f))
    return;
  if (f->pixel_width == w && f->pixel_height == h)
    return;
  change_frame_size (f, w, h, false, false, false);
  ios_launch_log ([NSString stringWithFormat:
                   @"resize: canvas -> %dx%d px, frame now %dx%d cells",
                   w, h, FRAME_COLS (f), FRAME_LINES (f)]);
}

/* The key-event queue stores 32-bit values: lower 22 bits are the
   character code (CHARACTERBITS in lisp.h), upper bits CHAR_CTL /
   CHAR_META / CHAR_SHIFT etc.  ASCII_KEYSTROKE_EVENT's `code' and
   `modifiers' fields decode straight from this packing.  */

/* C-callable producer.  Called from UI thread.  Drops the event
   on a full queue (better to lose a key than block UIKit), then
   writes a byte to the wake pipe so wait_reading_process_input
   returns and read_socket_hook fires.  */
void
ios_enqueue_key (int codepoint)
{
  pthread_mutex_lock (&ios_input_lock);
  int next = (ios_input_tail + 1) % IOS_INPUT_QUEUE_CAP;
  if (next != ios_input_head)
    {
      ios_input_queue[ios_input_tail] = codepoint;
      ios_input_tail = next;
    }
  pthread_mutex_unlock (&ios_input_lock);
  ios_wake ();
}

static int
ios_drain_events (struct terminal *terminal, struct input_event *hold_quit)
{
  /* Pick up any pending UIView-bounds change (orientation, split
     view, keyboard) before processing events.  */
  ios_apply_pending_resize ();
  /* And any pending finger-motion so the highlight stays under
     the user's finger while a drag-select is in progress.  */
  ios_apply_pending_motion ();
  /* And run ios-appearance-changed-hook if dark / light just
     flipped under us.  */
  ios_apply_pending_appearance ();
  /* And turn any open-this-file request from another app into a
     drag-n-drop event.  */
  ios_apply_pending_open (hold_quit);
  /* And pinch-gesture updates into PINCH_EVENTs.  */
  ios_apply_pending_pinch (hold_quit);
  int n = 0;
  /* Drain the rich event queue first -- mouse clicks should
     get to Emacs before whatever keystrokes piled up next.  */
  pthread_mutex_lock (&ios_input_lock);
  while (ios_event_head != ios_event_tail)
    {
      struct input_event ie = ios_event_queue[ios_event_head];
      ios_event_head = (ios_event_head + 1) % IOS_EVENT_QUEUE_CAP;
      pthread_mutex_unlock (&ios_input_lock);
      /* The UIKit thread leaves frame_or_window nil -- reading
         frame state over there would race frame deletion here.
         Attach the frame on this (the Emacs) thread, and drop the
         event if no frame exists yet.  */
      if (NILP (ie.frame_or_window))
        {
          struct frame *f
            = (terminal->display_info.ios
               && terminal->display_info.ios->highlight_frame)
              ? terminal->display_info.ios->highlight_frame
              : (FRAMEP (selected_frame) ? XFRAME (selected_frame) : NULL);
          if (f && FRAME_LIVE_P (f))
            {
              XSETFRAME (ie.frame_or_window, f);
              kbd_buffer_store_event_hold (&ie, hold_quit);
              n++;
            }
        }
      else
        {
          kbd_buffer_store_event_hold (&ie, hold_quit);
          n++;
        }
      pthread_mutex_lock (&ios_input_lock);
    }
  while (ios_input_head != ios_input_tail)
    {
      int c = ios_input_queue[ios_input_head];
      ios_input_head = (ios_input_head + 1) % IOS_INPUT_QUEUE_CAP;
      pthread_mutex_unlock (&ios_input_lock);

      /* Decode the packed code: lower CHARACTERBITS hold the
         codepoint, upper bits hold Emacs modifier flags.  */
      int codepoint = c & ((1 << CHARACTERBITS) - 1);
      int modifiers = c & CHAR_MODIFIER_MASK;
      struct input_event ie;
      EVENT_INIT (ie);
      ie.kind = ASCII_KEYSTROKE_EVENT;
      ie.code = codepoint;
      ie.modifiers = modifiers;
      XSETFRAME (ie.frame_or_window,
                 (terminal->display_info.ios
                  && terminal->display_info.ios->highlight_frame)
                 ? terminal->display_info.ios->highlight_frame
                 : XFRAME (selected_frame));
      ie.timestamp = 0;
      kbd_buffer_store_event_hold (&ie, hold_quit);
      n++;

      pthread_mutex_lock (&ios_input_lock);
    }
  pthread_mutex_unlock (&ios_input_lock);
  return n;
}

int
ios_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  /* Drain the wake pipe -- we only used it to be selectable; the
     actual data are in the queues ios_drain_events consumes.  */
  if (ios_wake_pipe[0] >= 0)
    {
      char buf[64];
      while (read (ios_wake_pipe[0], buf, sizeof buf) > 0)
        continue;
    }
  return ios_drain_events (terminal, hold_quit);
}

/* Nested input pump for synchronous UI (popup menus).  Waits up to
   TIMEOUT_MS for wake-pipe traffic, then runs one normal drain so
   queued keystrokes land in the kbd buffer for later and -- the
   point of pumping instead of sleeping -- a typed quit character
   sets Vquit_flag through kbd_buffer_store_event's quit detection.
   Emacs thread only.  */
void
ios_pump_input (int timeout_ms)
{
  if (ios_wake_pipe[0] >= 0)
    {
      struct pollfd pfd = { ios_wake_pipe[0], POLLIN, 0 };
      poll (&pfd, 1, timeout_ms);
      char buf[64];
      while (read (ios_wake_pipe[0], buf, sizeof buf) > 0)
        continue;
    }
  if (x_display_list && x_display_list->terminal)
    ios_drain_events (x_display_list->terminal, NULL);
}

/* Menu-selection channel.  The action-sheet handlers publish the
   chosen menu_items index tagged with the show-invocation's serial;
   the pump loop in ios_menu_show takes it only when the serial
   matches, so a tap on a stale, torn-down sheet can never leak into
   a newer menu.  */
static pthread_mutex_t ios_menu_lock = PTHREAD_MUTEX_INITIALIZER;
static int ios_menu_done_serial = 0;   /* 0 = nothing published */
static int ios_menu_done_index = -1;
static int ios_menu_serial_counter = 0;

int
ios_menu_next_serial (void)
{
  int s;
  pthread_mutex_lock (&ios_menu_lock);
  s = ++ios_menu_serial_counter;
  pthread_mutex_unlock (&ios_menu_lock);
  return s;
}

void
ios_publish_menu_selection (int serial, int index)
{
  pthread_mutex_lock (&ios_menu_lock);
  ios_menu_done_serial = serial;
  ios_menu_done_index = index;
  pthread_mutex_unlock (&ios_menu_lock);
  ios_wake ();
}

bool
ios_take_menu_selection (int serial, int *index)
{
  bool hit = false;
  pthread_mutex_lock (&ios_menu_lock);
  if (ios_menu_done_serial == serial)
    {
      *index = ios_menu_done_index;
      ios_menu_done_serial = 0;
      hit = true;
    }
  pthread_mutex_unlock (&ios_menu_lock);
  return hit;
}

/* Cross-port required entry point: frame.c calls this from inside
   #ifdef HAVE_WINDOW_SYSTEM to implement (set-mouse-position FRAME X Y).
   iOS has no programmatic mouse cursor (touch input is event-driven,
   not pointer-driven), so this is a documented no-op.  */
void
frame_set_mouse_pixel_position (struct frame *f, int pix_x, int pix_y)
{
  (void) f;
  (void) pix_x;
  (void) pix_y;
}

/* terminal->defined_color_hook implementation.  Resolve a color name
   to an RGB triple.  load_color2 in xfaces.c calls this via the
   terminal struct -- if the hook is NULL the call segfaults.  This
   minimal version recognises black, white, and #rrggbb literals;
   anything else returns false and the caller falls back to the
   frame's foreground/background pixel.  */
static bool
ios_defined_color (struct frame *f, const char *color_name,
                   Emacs_Color *color, bool alloc_p, bool make_index)
{
  (void) f; (void) alloc_p; (void) make_index;
  if (!color_name)
    return false;

  unsigned r = 0, g = 0, b = 0;
  bool ok = false;

  if (strcasecmp (color_name, "black") == 0)
    { r = g = b = 0; ok = true; }
  else if (strcasecmp (color_name, "white") == 0)
    { r = g = b = 0xff; ok = true; }
  else if (strcasecmp (color_name, "red") == 0)
    { r = 0xff; ok = true; }
  else if (strcasecmp (color_name, "green") == 0)
    { g = 0xff; ok = true; }
  else if (strcasecmp (color_name, "blue") == 0)
    { b = 0xff; ok = true; }
  else if (color_name[0] == '#' && strlen (color_name) == 7)
    {
      unsigned v;
      if (sscanf (color_name + 1, "%6x", &v) == 1)
        {
          r = (v >> 16) & 0xff;
          g = (v >>  8) & 0xff;
          b = (v      ) & 0xff;
          ok = true;
        }
    }

  if (!ok)
    return false;
  /* Pack into pixel: 0x00RRGGBB -- iOS draws via Core Graphics which
     takes normalized floats, but the same packed form is used
     throughout the redisplay engine and is what FRAME_FOREGROUND_PIXEL
     stores.  */
  color->pixel = (r << 16) | (g << 8) | b;
  color->red   = r * 257;   /* X11 16-bit per channel */
  color->green = g * 257;
  color->blue  = b * 257;
  return true;
}

/* Cross-port "x-*" variables: cus-start.el bails ("not bound")
   during loadup if these symbols are unbound while Fx_create_frame
   is fboundp.  DEFVAR_BOOL's expansion synthesizes the backing
   storage in globals.h -- declaring it by hand collides with that.  */

void
syms_of_iosterm (void)
{
  DEFSYM (Qios, "ios");
  Fprovide (Qios, Qnil);

  /* Cross-port "x-*" variables that cus-start.el expects to be bound
     whenever (fboundp 'x-create-frame) is true.  Documented in
     xterm.c; we mirror the Android port's defaults here.  */
  DEFVAR_BOOL ("x-use-underline-position-properties",
               x_use_underline_position_properties,
     doc: /* SKIP: real doc in xterm.c.  */);
  x_use_underline_position_properties = true;

  DEFVAR_BOOL ("x-underline-at-descent-line",
               x_underline_at_descent_line,
     doc: /* SKIP: real doc in xterm.c.  */);
  x_underline_at_descent_line = false;

}

/* ---- Frame parameter setters --------------------------------- */

/* Resolve a color spec to an RGB pixel.  Falls back to FALLBACK on
   parse failure.  ios_defined_color is the canonical decoder
   (named colors + #rrggbb literals).  */
static unsigned long
ios_decode_color (struct frame *f, Lisp_Object arg, unsigned long fallback)
{
  if (!STRINGP (arg))
    return fallback;
  Emacs_Color c;
  if (ios_defined_color (f, SSDATA (arg), &c, true, false))
    return c.pixel;
  return fallback;
}

static void
ios_set_background_color (struct frame *f, Lisp_Object arg,
                          Lisp_Object oldval)
{
  (void) oldval;
  unsigned long bg = ios_decode_color (f, arg, 0xffffff);
  FRAME_BACKGROUND_PIXEL (f) = bg;
  update_face_from_frame_parameter (f, Qbackground_color, arg);
  if (FRAME_VISIBLE_P (f))
    SET_FRAME_GARBAGED (f);
}

static void
ios_set_foreground_color (struct frame *f, Lisp_Object arg,
                          Lisp_Object oldval)
{
  (void) oldval;
  unsigned long fg = ios_decode_color (f, arg, 0x000000);
  FRAME_FOREGROUND_PIXEL (f) = fg;
  update_face_from_frame_parameter (f, Qforeground_color, arg);
  if (FRAME_VISIBLE_P (f))
    SET_FRAME_GARBAGED (f);
}

static void
ios_set_cursor_color (struct frame *f, Lisp_Object arg,
                      Lisp_Object oldval)
{
  (void) oldval;
  unsigned long pixel = ios_decode_color (f, arg, 0x000000);
  /* Make sure the cursor stays distinguishable from the
     background -- if equal, flip to the foreground color, same
     fallback chain androidterm.c uses.  */
  if (pixel == FRAME_BACKGROUND_PIXEL (f))
    pixel = FRAME_FOREGROUND_PIXEL (f);
  f->output_data.ios->cursor_pixel = pixel;
  f->output_data.ios->cursor_foreground_pixel
    = FRAME_BACKGROUND_PIXEL (f);
  update_face_from_frame_parameter (f, Qcursor_color, arg);
  if (FRAME_VISIBLE_P (f))
    SET_FRAME_GARBAGED (f);
}

static void
ios_set_cursor_type (struct frame *f, Lisp_Object arg,
                     Lisp_Object oldval)
{
  set_frame_cursor_types (f, arg);
  (void) oldval;
}

/* Indexing must match frame.c's frame_parms[].  Setters we don't
   yet implement (scroll bars, fringes, etc.) stay NULL; the few
   shared GUI handlers (gui_set_font, gui_set_alpha, ...) take
   their place where they apply portably.  */
static frame_parm_handler ios_frame_parm_handlers[] =
{
  gui_set_autoraise,                         /* auto-raise */
  gui_set_autolower,                         /* auto-lower */
  ios_set_background_color,                  /* background-color */
  NULL,                                      /* border-color */
  gui_set_border_width,                      /* border-width */
  ios_set_cursor_color,                      /* cursor-color */
  ios_set_cursor_type,                       /* cursor-type */
  gui_set_font,                              /* font */
  ios_set_foreground_color,                  /* foreground-color */
  NULL,                                      /* icon-name */
  NULL,                                      /* icon-type */
  NULL,                                      /* child-frame-border-width */
  NULL,                                      /* internal-border-width */
  gui_set_right_divider_width,               /* right-divider-width */
  gui_set_bottom_divider_width,              /* bottom-divider-width */
  NULL,                                      /* menu-bar-lines */
  NULL,                                      /* mouse-color */
  NULL,                                      /* name */
  gui_set_scroll_bar_width,                  /* scroll-bar-width */
  gui_set_scroll_bar_height,                 /* scroll-bar-height */
  NULL,                                      /* title */
  gui_set_unsplittable,                      /* unsplittable */
  gui_set_vertical_scroll_bars,              /* vertical-scroll-bars */
  gui_set_horizontal_scroll_bars,            /* horizontal-scroll-bars */
  gui_set_visibility,                        /* visibility */
  NULL,                                      /* tab-bar-lines */
  NULL,                                      /* tool-bar-lines */
  NULL,                                      /* scroll-bar-foreground */
  NULL,                                      /* scroll-bar-background */
  gui_set_screen_gamma,                      /* screen-gamma */
  gui_set_line_spacing,                      /* line-spacing */
  gui_set_left_fringe,                       /* left-fringe */
  gui_set_right_fringe,                      /* right-fringe */
  NULL,                                      /* wait-for-wm */
  gui_set_fullscreen,                        /* fullscreen */
  gui_set_font_backend,                      /* font-backend */
  NULL,                                      /* alpha */
  NULL,                                      /* sticky */
  NULL,                                      /* tool-bar-position */
  NULL,                                      /* inhibit-double-buffering */
  NULL,                                      /* undecorated */
  NULL,                                      /* parent-frame */
  NULL,                                      /* skip-taskbar */
  NULL,                                      /* no-focus-on-map */
  NULL,                                      /* no-accept-focus */
  NULL,                                      /* z-group */
  NULL,                                      /* override-redirect */
  gui_set_no_special_glyphs,                 /* no-special-glyphs */
  NULL,                                      /* alpha-background */
  gui_set_borders_respect_alpha_background,  /* borders-respect-alpha-background */
  NULL,                                      /* use-frame-synchronization */
};

#endif /* HAVE_IOS */
