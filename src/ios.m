/* iOS app lifecycle bridge for GNU Emacs.
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

/* This file is the iOS analogue of src/android.c.  It bridges the
   UIKit application lifecycle (UIApplication / UIScene / UIWindow)
   into the Emacs entry point and exposes a small set of C-callable
   helpers that the rest of the iOS port (iosterm.m, iosvfs.c, etc.)
   uses to talk back to UIKit.

   For now this is a skeleton: ios_main forwards to the regular Emacs
   main(), and ios_dump_path returns the sandboxed location where the
   pdumper image is generated on first launch.  The full UIKit
   integration is added in subsequent commits.  */

#include <config.h>

#ifdef HAVE_IOS

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "lisp.h"
#include "iosterm.h"

/* Forward declaration of the renamed Emacs entry point.  On iOS,
   src/emacs.c's main() is renamed to ios_emacs_init() so the UIKit
   app shell can call it after the application has finished launching
   (analogous to how android.c calls into android_emacs_init).  This
   declaration becomes live once the corresponding HAVE_IOS arm is
   added to emacs.c in a follow-up commit.  */
extern int ios_emacs_init (int argc, char **argv, char *dump_file);

/* Return the sandboxed path at which emacs.pdmp lives.

   The dump file is written into ~/Library/Application Support/Emacs/
   on first launch and mmapped on every subsequent launch.  The
   returned string is malloc'd; callers should free it.  Returns NULL
   on error.  */

char *
ios_dump_path (void)
{
  @autoreleasepool {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *support = [[fm URLsForDirectory:NSApplicationSupportDirectory
                                inDomains:NSUserDomainMask] firstObject];
    if (!support)
      return NULL;

    NSURL *dir = [support URLByAppendingPathComponent:@"Emacs"
                                          isDirectory:YES];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:dir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&err])
      return NULL;

    /* Exclude this directory from iCloud / iTunes backup.  The dump
       is large and trivially regenerable.  */
    NSNumber *yes = [NSNumber numberWithBool:YES];
    [dir setResourceValue:yes
                   forKey:NSURLIsExcludedFromBackupKey
                    error:NULL];

    NSURL *dump = [dir URLByAppendingPathComponent:@"emacs.pdmp"];
    const char *path = [[dump path] UTF8String];
    return path ? strdup (path) : NULL;
  }
}

/* Entry point invoked from the iOS app shell (ios/Emacs/main.m).

   In this skeleton commit ios_main does no real work; it only
   resolves the dump path and calls into the renamed Emacs entry
   point.  Future commits will, in order: (1) drive the UIApplication
   run loop with a custom delegate, (2) construct the
   EmacsViewController and EmacsUIView, (3) call ios_term_init() from
   iosterm.m, and (4) pump UIKit events into kbd_buffer_store_event
   via ios_read_socket.  */

int
ios_main (int argc, char **argv)
{
  char *dump_file = ios_dump_path ();
  int result = ios_emacs_init (argc, argv, dump_file);
  free (dump_file);
  return result;
}

/* Process entry point of the cross-built emacs Mach-O.

   The bundle's CFBundleExecutable IS this binary, so on launch iOS
   transfers control here directly.  We hand off to UIApplicationMain,
   which spins up the run loop and instantiates EmacsAppDelegate
   (defined in src/iosappdelegate.m once that file is folded into the
   cross-build; for now it lives in ios/Emacs/AppDelegate.m and is
   wired in via the bundle's Info.plist NSPrincipalClass).

   The renamed emacs.c entry point (ios_emacs_init) is called from
   ios_main() above, which the AppDelegate invokes after the UIKit
   stack is up.  */

int
main (int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain
      (argc, argv, nil,
       NSStringFromClass ([NSClassFromString (@"EmacsAppDelegate") class]));
  }
}

#endif /* HAVE_IOS */
