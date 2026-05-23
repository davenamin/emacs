/* iOS font driver shim for GNU Emacs.
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

/* Thin shim that registers an iOS font driver.  The bulk of glyph
   layout and metrics handling is shared with src/nsfont.m via the
   NS_IMPL_IOS compile-time variant; this file only handles iOS-only
   plumbing (UIFont-based font enumeration and fallback chains).

   Skeleton only.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#include "lisp.h"
#include "frame.h"
#include "font.h"
#include "iosterm.h"

void
syms_of_iosfont (void)
{
}

#endif /* HAVE_IOS */
