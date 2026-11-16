/* EmacsAppDelegate implementation, iOS app shell for GNU Emacs.
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

/* The Emacs C runtime is brought up on a background thread because
   it owns its own event loop (kbd_buffer + ns_read_socket / ios_read_socket
   driving select(2)) and that cannot share the UIKit main thread.
   The main thread continues to run the UIApplication loop and
   forwards UIKit events to Emacs through iosterm.m.

   This file is intentionally minimal; the corresponding C side
   (src/ios.m) is responsible for translating between UIKit lifecycle
   notifications and Emacs frame state.  */

#import "AppDelegate.h"

/* Forward declaration of the Emacs entry point, defined in src/ios.m.  */
extern int ios_main (int argc, char **argv);

@implementation EmacsAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  /* Boot the Emacs runtime on a background thread.  The real
     iosterm.m / src/ios.m implementation owns the scheduling between
     the UIKit main thread and the Emacs select() loop; for now we
     simply hand off control.  */
  dispatch_async (dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      char *argv[] = { (char *) "emacs", NULL };
      ios_main (1, argv);
    });
  return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options
{
  return [[UISceneConfiguration alloc]
             initWithName:@"Default Configuration"
                 sessionRole:connectingSceneSession.role];
}

@end
