#!/bin/sh
# Check that configure enabled what the iOS build is supposed to have.
# Usage: check-features.sh CONFIGURE-OUTPUT

# Copyright (C) 2026 Free Software Foundation, Inc.

# This file is part of GNU Emacs.

# GNU Emacs is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# GNU Emacs is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

# configure --with-ios runs twice: a recursive pass for iOS, then the
# host pass that drives the build.  Both print the feature summary to
# the same output, the iOS pass first, so only the first answer to
# each question is the one about the app.

out=${1:?usage: check-features.sh CONFIGURE-OUTPUT}
status=0

check ()
{
  if grep "$1" "$out" | head -1 | grep -q 'yes[[:space:]]*$'; then
    echo "ok       $2"
  else
    echo "MISSING  $2"
    status=1
  fi
}

check 'Does Emacs use -lgnutls?'                 'GnuTLS'
check 'Does Emacs use -lxml2?'                   'libxml2'
check 'Does Emacs use -lsqlite3?'                'sqlite3'
check 'Does Emacs use -ltree-sitter?'            'tree-sitter'
check 'Does Emacs have threading support in lisp?' 'Lisp threads'

exit $status
