/* Sandboxed virtual file system for the iOS port of GNU Emacs.
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

/* This file is the iOS analogue of src/androidvfs.c.  It exposes
   read-only access to the app bundle (bundle:// scheme), read/write
   access to the user's Documents directory (documents:// scheme),
   and proxies user-selected file URLs vended by
   UIDocumentPickerViewController through a per-bookmark vnode.

   Skeleton only; the real vnode dispatch table mirrors androidvfs.c
   and lands in follow-up commits.  */

#include <config.h>

#ifdef HAVE_IOS

#include "lisp.h"

void
syms_of_iosvfs (void)
{
}

#endif /* HAVE_IOS */
