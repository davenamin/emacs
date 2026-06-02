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

#include "lisp.h"
#include "iosterm.h"
#include "termhooks.h"
#include "keyboard.h"
#include "frame.h"

/* Forward declaration so ios_launch_log can be called from this file.
   Implementation lives in ios.m.  */
extern void ios_launch_log (NSString *msg);

/* Head of the singly-linked list of iOS displays.  Generic code in
   frame.c iterates this to enumerate displays.  iOS has exactly one
   logical display per app, so the list is at most one element long;
   ios_term_init prepends to it.  */
struct ios_display_info *x_display_list = NULL;

/* Redisplay interface for iOS frames.  All hooks are NULL stubs for
   now -- generic redisplay code checks for NULL before invoking
   each, so the bring-up survives without a real backend.  Future
   commits will fill these in (CALayer-backed drawing in iosterm.m's
   EmacsUIView).  */
static struct redisplay_interface ios_redisplay_interface = {0};

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

  /* Install the only real hook we have for now.  Everything else is
     NULL and the generic code checks before calling.  */
  terminal->read_socket_hook = ios_read_socket;

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

int
ios_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  /* TODO: drain the UIKit event queue and translate touches,
     UIKeyCommand presses, and UITextInput delegate callbacks into
     input_event records via kbd_buffer_store_event_hold.  */
  (void) terminal;
  (void) hold_quit;
  return 0;
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

void
syms_of_iosterm (void)
{
  DEFSYM (Qios, "ios");
  Fprovide (Qios, Qnil);
}

#endif /* HAVE_IOS */
