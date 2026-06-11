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

/* The iOS sandbox exposes every accessible path as a POSIX path, so
   unlike androidvfs.c we do not need a vnode dispatch layer.  This
   file just publishes the sandboxed directory paths Lisp code is
   likely to want -- bundle root (read-only), Documents (user data),
   Library (app caches, dump file), tmpdir -- as Lisp primitives.
   Callers use them to portable across iOS-vs-non-iOS configurations.  */

#include <config.h>

#ifdef HAVE_IOS

#include <stdlib.h>
#include <string.h>

#include "lisp.h"

extern const char *ios_sandbox_directory (int which);

enum
  {
    IOS_SBX_BUNDLE = 0,
    IOS_SBX_DOCUMENTS,
    IOS_SBX_LIBRARY,
    IOS_SBX_CACHES,
    IOS_SBX_TMPDIR,
  };

static Lisp_Object
ios_sandbox_path (int which)
{
  const char *p = ios_sandbox_directory (which);
  if (p == NULL || *p == 0)
    return Qnil;
  return build_string (p);
}

DEFUN ("ios-bundle-directory", Fios_bundle_directory,
       Sios_bundle_directory, 0, 0, 0,
       doc: /* Return the path of the app bundle (read-only).  */)
  (void)
{
  return ios_sandbox_path (IOS_SBX_BUNDLE);
}

DEFUN ("ios-documents-directory", Fios_documents_directory,
       Sios_documents_directory, 0, 0, 0,
       doc: /* Return the user-visible Documents directory.
This is the same path Emacs uses for HOME on iOS, and the only
sandbox subtree exposed through the iOS Files app.  */)
  (void)
{
  return ios_sandbox_path (IOS_SBX_DOCUMENTS);
}

DEFUN ("ios-library-directory", Fios_library_directory,
       Sios_library_directory, 0, 0, 0,
       doc: /* Return the app-private Library directory.
Used for state that should persist across launches but stay invisible
to the user, e.g. the pre-dumped emacs.pdmp under Application Support/Emacs/.  */)
  (void)
{
  return ios_sandbox_path (IOS_SBX_LIBRARY);
}

DEFUN ("ios-caches-directory", Fios_caches_directory,
       Sios_caches_directory, 0, 0, 0,
       doc: /* Return the Library/Caches/ directory.
Files here may be evicted by the system under disk pressure;
suitable for regeneratable caches such as compiled .elc files.  */)
  (void)
{
  return ios_sandbox_path (IOS_SBX_CACHES);
}

DEFUN ("ios-tmp-directory", Fios_tmp_directory,
       Sios_tmp_directory, 0, 0, 0,
       doc: /* Return the app-private temporary directory.
Files here may disappear between launches.  */)
  (void)
{
  return ios_sandbox_path (IOS_SBX_TMPDIR);
}

void
syms_of_iosvfs (void)
{
  defsubr (&Sios_bundle_directory);
  defsubr (&Sios_documents_directory);
  defsubr (&Sios_library_directory);
  defsubr (&Sios_caches_directory);
  defsubr (&Sios_tmp_directory);
}

#endif /* HAVE_IOS */
