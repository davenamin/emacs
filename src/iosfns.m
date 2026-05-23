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

void
syms_of_iosfns (void)
{
  /* Frame parameter and x-* primitive definitions will be added in
     follow-up commits, in parallel to syms_of_androidfns.  */
}

#endif /* HAVE_IOS */
