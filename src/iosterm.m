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

/* Head of the singly-linked list of iOS displays.  Generic code in
   frame.c iterates this to enumerate displays.  iOS has exactly one
   logical display per app, so the list is at most one element long;
   ios_term_init prepends to it.  */
struct ios_display_info *x_display_list = NULL;

struct terminal *
ios_term_init (void)
{
  /* TODO: allocate a struct terminal, install hooks
     (read_socket_hook = ios_read_socket, etc.), create the
     ios_display_info, and return the new terminal.  */
  return NULL;
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

void
syms_of_iosterm (void)
{
  /* Will define ios-specific symbols and variables in follow-up
     commits (parallel to syms_of_androidterm).  */
}

#endif /* HAVE_IOS */
