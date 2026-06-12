/* iOS pasteboard / selection bridge for GNU Emacs.
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

/* iOS analogue of src/androidselect.c / src/nsselect.m.  Wires
   UIPasteboard.generalPasteboard onto the standard
   interprogram-cut-function / interprogram-paste-function
   protocol via three small Lisp primitives.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>

#include "lisp.h"
#include "coding.h"
#include "iosterm.h"

DEFUN ("ios-set-clipboard", Fios_set_clipboard, Sios_set_clipboard,
       1, 1, 0,
       doc: /* Copy STRING to the iOS general pasteboard.  */)
  (Lisp_Object string)
{
  CHECK_STRING (string);
  Lisp_Object encoded = code_convert_string_norecord (string, Qutf_8, true);
  NSString *ns = [[NSString alloc]
                   initWithBytes:SSDATA (encoded)
                          length:SBYTES (encoded)
                        encoding:NSUTF8StringEncoding];
  if (ns == nil)
    return Qnil;
  dispatch_async (dispatch_get_main_queue (), ^{
    UIPasteboard.generalPasteboard.string = ns;
  });
  return Qt;
}

DEFUN ("ios-get-clipboard", Fios_get_clipboard, Sios_get_clipboard,
       0, 0, 0,
       doc: /* Return the contents of the iOS general pasteboard.
Value is a multibyte string, or nil if the pasteboard holds no
plain-text item.  */)
  (void)
{
  /* current-kill consults interprogram-paste-function on every
     yank and many kill-ring accesses, and each .string read both
     round-trips to the main thread and (on iOS 14+) can pop the
     system "pasted from ..." banner.  changeCount is a cheap
     monotonic counter bumped whenever any app writes the
     pasteboard; only re-read the text when it moved.  */
  static NSInteger cached_change = -1;
  static NSString *cached_string = nil;
  __block NSString *captured = nil;
  void (^fetch) (void) = ^{
    NSInteger change = UIPasteboard.generalPasteboard.changeCount;
    if (change != cached_change)
      {
        cached_string = UIPasteboard.generalPasteboard.string;
        cached_change = change;
      }
    captured = cached_string;
  };
  if ([NSThread isMainThread])
    fetch ();
  else
    dispatch_sync (dispatch_get_main_queue (), fetch);
  if (captured == nil || captured.length == 0)
    return Qnil;
  const char *utf8 = [captured UTF8String];
  if (utf8 == NULL)
    return Qnil;
  Lisp_Object raw = make_unibyte_string (utf8, strlen (utf8));
  return code_convert_string_norecord (raw, Qutf_8, false);
}

DEFUN ("ios-clipboard-exists-p", Fios_clipboard_exists_p,
       Sios_clipboard_exists_p, 0, 0, 0,
       doc: /* Return t if the iOS pasteboard currently holds text.  */)
  (void)
{
  __block BOOL has = NO;
  if ([NSThread isMainThread])
    has = UIPasteboard.generalPasteboard.hasStrings;
  else
    dispatch_sync (dispatch_get_main_queue (), ^{
      has = UIPasteboard.generalPasteboard.hasStrings;
    });
  return has ? Qt : Qnil;
}

void
syms_of_iosselect (void)
{
  defsubr (&Sios_set_clipboard);
  defsubr (&Sios_get_clipboard);
  defsubr (&Sios_clipboard_exists_p);
}

#endif /* HAVE_IOS */
