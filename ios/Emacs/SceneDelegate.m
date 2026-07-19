/* EmacsSceneDelegate implementation, iOS app shell for GNU Emacs.
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

/* Per-scene lifecycle owner.  Each UIScene corresponds to one Emacs
   frame in multi-window iPadOS layouts.  The real frame attachment
   (UIView <-> struct frame) is implemented in src/iosterm.m; this
   delegate currently only sets up an empty root view controller so
   first launch can succeed before the Emacs C side is fully wired.  */

#import "SceneDelegate.h"

@implementation EmacsSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions
{
  if (![scene isKindOfClass:[UIWindowScene class]])
    return;
  UIWindowScene *windowScene = (UIWindowScene *) scene;
  self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
  self.window.rootViewController = [[UIViewController alloc] init];
  self.window.rootViewController.view.backgroundColor =
      [UIColor systemBackgroundColor];
  [self.window makeKeyAndVisible];
}

@end
