/* iOS app shell entry point for GNU Emacs.
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

/* Entry point of the iOS app bundle.  UIKit owns process startup on
   iOS: control flows from this main() into UIApplicationMain, which
   eventually instantiates EmacsAppDelegate.  The delegate is
   responsible for booting the Emacs C runtime via ios_main() declared
   in src/iosterm.h.  */

#import <UIKit/UIKit.h>

int
main (int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain (argc, argv, nil,
                              NSStringFromClass ([NSClassFromString (@"EmacsAppDelegate") class]));
  }
}
