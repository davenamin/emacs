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
#include <fcntl.h>
#include <unistd.h>

#include "lisp.h"
#include "iosterm.h"
#include "termhooks.h"
#include "keyboard.h"
#include "frame.h"
#include "window.h"
#include "dispextern.h"

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
   NULL pointer here the indexing dereferences NULL.  Every slot is
   left NULL for now; the iOS port doesn't yet implement any
   parameter-specific frame attribute setters.  Size of 64 covers all
   currently-known indices in src/frame.c's `frame_parms' table.  */
static frame_parm_handler ios_frame_parm_handlers[64];

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
                                  const char *utf8, double font_size);
extern void ios_canvas_draw_cursor (double x, double y,
                                    double width, double height,
                                    unsigned long pixel, int style);
extern void ios_canvas_clear_rect (double x, double y,
                                   double width, double height,
                                   unsigned long bg_pixel);
extern void ios_canvas_begin_frame (void);
extern void ios_canvas_end_frame (void);

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
static void
ios_noop_draw_glyph_string (struct glyph_string *s)
{
  ios_dbg_draw++;
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
  ios_canvas_draw_text ((double) s->x, (double) s->y,
                        w, h, fg, bg, utf8, font_size);
  xfree (utf8);
}

static void
ios_noop_draw_fringe_bitmap (struct window *w, struct glyph_row *row,
                             struct draw_fringe_bitmap_params *p)
{
  (void) w; (void) row; (void) p;
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
  if (!on_p || cursor_type == NO_CURSOR || w == NULL || glyph_row == NULL)
    return;
  struct frame *f = XFRAME (WINDOW_FRAME (w));
  if (!FRAME_IOS_P (f))
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
  /* enum text_cursor_kinds: FILLED_BOX=0, HOLLOW_BOX=1, BAR=2, HBAR=3.  */
  ios_canvas_draw_cursor ((double) abs_x, (double) abs_y,
                          (double) w_px, (double) h_px,
                          pixel, (int) cursor_type);
}

static void
ios_noop_draw_vertical_window_border (struct window *w, int x, int y_0, int y_1)
{
  (void) w; (void) x; (void) y_0; (void) y_1;
}

static void
ios_noop_draw_window_divider (struct window *w, int x_0, int x_1,
                              int y_0, int y_1)
{
  (void) w; (void) x_0; (void) x_1; (void) y_0; (void) y_1;
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
  (void) f;
  ios_dbg_end++;
  ios_canvas_end_frame ();
  /* Log every redisplay until we hit 30 so we can see exactly how
     many ticks happen during a CI run, then every 50th afterwards.  */
  if (ios_dbg_end <= 30 || (ios_dbg_end % 50) == 0)
    ios_launch_log ([NSString stringWithFormat:
                     @"redisplay #%d draws=%d", ios_dbg_end,
                     ios_dbg_draw]);
}
static void
ios_noop_flush_display (struct frame *f) { (void) f; }
static void
ios_noop_scroll_run (struct window *w, struct run *run)
{
  (void) w; (void) run;
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
    ios_noop_scroll_run,
    ios_noop_after_update_window_line,
    ios_noop_update_window_begin,
    ios_noop_update_window_end,
    ios_noop_flush_display,
    gui_clear_window_mouse_face,
    gui_get_glyph_overhangs,
    gui_fix_overlapping_area,
    ios_noop_draw_fringe_bitmap,
    ios_noop_define_fringe_bitmap,
    ios_noop_destroy_fringe_bitmap,
    ios_noop_compute_glyph_string_overhangs,
    ios_noop_draw_glyph_string,
    ios_noop_define_frame_cursor,
    ios_noop_clear_frame_area,
    ios_noop_clear_under_internal_border,
    ios_noop_draw_window_cursor,
    ios_noop_draw_vertical_window_border,
    ios_noop_draw_window_divider,
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
        /* iPhones run roughly 163 PPI base * scale.  This is the
           same heuristic the Android port uses for its DPI.  */
        dpyinfo->resx = 163.0 * (double) s;
        dpyinfo->resy = 163.0 * (double) s;
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
  if (ios_wake_pipe[1] >= 0)
    {
      char b = 1;
      ssize_t r = write (ios_wake_pipe[1], &b, 1);
      (void) r;  /* best-effort; ignore EAGAIN if pipe is full */
    }
}

int
ios_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  (void) hold_quit;
  /* Drain the wake pipe -- we only used it to be selectable; the
     actual data are in ios_input_queue.  */
  if (ios_wake_pipe[0] >= 0)
    {
      char buf[64];
      while (read (ios_wake_pipe[0], buf, sizeof buf) > 0)
        continue;
    }
  static int ios_dbg_rs = 0;
  ios_dbg_rs++;
  pthread_mutex_lock (&ios_input_lock);
  int pending = (ios_input_tail - ios_input_head + IOS_INPUT_QUEUE_CAP)
                % IOS_INPUT_QUEUE_CAP;
  pthread_mutex_unlock (&ios_input_lock);
  if (ios_dbg_rs <= 20 || (ios_dbg_rs % 50) == 0 || pending > 0)
    ios_launch_log ([NSString stringWithFormat:
                     @"read_socket #%d pending=%d", ios_dbg_rs, pending]);
  int n = 0;
  pthread_mutex_lock (&ios_input_lock);
  while (ios_input_head != ios_input_tail)
    {
      int c = ios_input_queue[ios_input_head];
      ios_input_head = (ios_input_head + 1) % IOS_INPUT_QUEUE_CAP;
      pthread_mutex_unlock (&ios_input_lock);

      /* Build an ASCII keystroke event.  For now we encode all
         input as plain ASCII codepoints; modifiers are TBD when
         we wire UIKeyCommand.  */
      struct input_event ie;
      EVENT_INIT (ie);
      ie.kind = ASCII_KEYSTROKE_EVENT;
      ie.code = c;
      ie.modifiers = 0;
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

#endif /* HAVE_IOS */
