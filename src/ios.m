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
   UIKit application lifecycle (UIApplication / UIWindow) into the
   Emacs entry point and exposes a small set of C-callable helpers
   that the rest of the iOS port (iosterm.m, iosvfs.c, etc.) uses to
   talk back to UIKit.

   Phase 1 of the runtime bring-up (this commit): UIApplicationMain
   instantiates EmacsAppDelegate, which is defined IN THIS BINARY (it
   previously lived only in ios/Emacs/AppDelegate.m, which is part of
   the bundle template but is not compiled into the cross-built
   binary -- so NSClassFromString returned nil and UIApplicationMain
   sat on a nil delegate forever, producing the "launches but hangs"
   symptom).  EmacsAppDelegate shows a red "Emacs is loading..."
   screen so launch is visually confirmable, redirects stdout/stderr
   to a file in the app's Documents/ directory so any C-level print
   output is captured, and dispatches ios_main() to a background
   queue so the (still-stub-heavy) Emacs initialization does not
   block the UI thread.  Diagnostic breadcrumbs are appended to
   Documents/emacs-launch.log at every step -- NSLog alone is
   unreliable on Simulator launches that happen outside
   `xcrun simctl launch --console`.  */

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
   (analogous to how android.c calls into android_emacs_init).  */
extern int ios_emacs_init (int argc, char **argv, char *dump_file);


/* ---- Logging breadcrumbs -------------------------------------- */

/* Build a path inside the iOS app's Documents/ directory.  Returns
   nil if NSSearchPath cannot find one (which would only happen if
   the app sandbox is in a deeply broken state).  */
static NSString *
ios_documents_path (NSString *name)
{
  NSArray<NSString *> *dirs
    = NSSearchPathForDirectoriesInDomains (NSDocumentDirectory,
                                           NSUserDomainMask, YES);
  if (dirs.count == 0)
    return nil;
  return [dirs[0] stringByAppendingPathComponent:name];
}

/* Append a timestamped MSG line to Documents/emacs-launch.log, and
   echo via NSLog.  Two-channel logging on purpose: NSLog reaches
   `simctl launch --console` and the unified log; the file remains
   reachable via the Files app or by spelunking through
   ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/
   Data/Application/<app-uuid>/Documents/.  */
void
ios_launch_log (NSString *msg)
{
  NSLog (@"emacs-launch: %@", msg);
  NSString *path = ios_documents_path (@"emacs-launch.log");
  if (!path)
    return;
  NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                    [NSDate date], msg];
  FILE *f = fopen (path.UTF8String, "a");
  if (f != NULL)
    {
      fputs (line.UTF8String, f);
      fclose (f);
    }
}

/* Redirect stdout and stderr to Documents/emacs-stdout.log so any
   printf/fprintf the C-side Emacs code emits is captured.  iOS apps
   have no controlling terminal; without this redirect those writes
   would be silently dropped.  Line-buffered so the trail is fresh
   even if the process crashes mid-init.  */
static void
ios_redirect_stdio (void)
{
  NSString *path = ios_documents_path (@"emacs-stdout.log");
  if (!path)
    return;
  freopen (path.UTF8String, "a", stdout);
  freopen (path.UTF8String, "a", stderr);
  setvbuf (stdout, NULL, _IOLBF, 0);
  setvbuf (stderr, NULL, _IOLBF, 0);
}


/* ---- Sandbox paths -------------------------------------------- */

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


/* ---- EmacsAppDelegate ----------------------------------------- */

/* UIApplicationDelegate that boots Emacs.  Defined in this binary so
   UIApplicationMain's NSClassFromString lookup succeeds.  Phase 1:
   shows a red placeholder screen, redirects stdio, and dispatches
   ios_main() to a background queue.  Phase 2 will replace the
   placeholder screen with an EmacsUIView once iosterm.m grows real
   drawing.  */

@interface EmacsAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation EmacsAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)opts
{
  ios_redirect_stdio ();
  ios_launch_log (@"AppDelegate didFinishLaunchingWithOptions: enter");

  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.backgroundColor = UIColor.systemRedColor;

  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = UIColor.systemRedColor;

  UILabel *label = [[UILabel alloc] init];
  label.text = @"Emacs is loading...";
  label.textColor = UIColor.whiteColor;
  label.font = [UIFont systemFontOfSize:28];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
      [label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
      [label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
      [label.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:vc.view.leadingAnchor
                                    constant:20],
      [label.trailingAnchor
        constraintLessThanOrEqualToAnchor:vc.view.trailingAnchor
                                 constant:-20],
  ]];

  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  ios_launch_log (@"AppDelegate window visible (red placeholder)");

  /* Kick off Emacs initialization on a background queue.  ios_main
     never returns (Emacs's main loop runs forever), so blocking the
     UI thread on it would deadlock UIKit and trip the iOS launch
     watchdog.  The launch log will show how far into Emacs init we
     get before any hang.  */
  dispatch_async (dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                  ^{
    ios_launch_log (@"emacs-bg: dispatched, about to call ios_main");

    /* Synthesize argc/argv from NSProcessInfo.  argv[0] is the
       process path Apple's launcher gave us, which Emacs uses to
       locate its install directory.  */
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    int argc_ = (int) args.count;
    char **argv_ = malloc (sizeof (char *) * (argc_ + 1));
    for (int i = 0; i < argc_; i++)
      argv_[i] = strdup (args[i].UTF8String);
    argv_[argc_] = NULL;
    ios_launch_log ([NSString stringWithFormat:
                     @"emacs-bg: argc=%d argv[0]=%s",
                     argc_, argv_[0] ?: "(null)"]);

    int rc = ios_main (argc_, argv_);
    ios_launch_log ([NSString stringWithFormat:
                     @"emacs-bg: ios_main returned %d", rc]);
  });

  ios_launch_log (@"AppDelegate didFinishLaunchingWithOptions: returning YES");
  return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationDidBecomeActive");
}

- (void)applicationWillResignActive:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationWillResignActive");
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationDidEnterBackground");
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  ios_launch_log (@"AppDelegate applicationWillTerminate");
}

@end


/* ---- Entry points --------------------------------------------- */

/* C-level Emacs entry point invoked from the AppDelegate on its
   background queue.  Resolves the dump file path, then hands off to
   the renamed emacs.c main().  Wraps the call with launch-log lines
   so a hang inside ios_emacs_init can be localized.  */

/* Point Emacs at the bundled lisp/ and etc/ trees.  Without this the
   stock $prefix/share/emacs/$VERSION paths apply -- those resolve
   into /usr/local on the runner and into the simulator's sandbox
   root on a device, neither of which exists.  Setting EMACSLOADPATH
   and EMACSDATA before ios_emacs_init is the same mechanism the
   Android port uses; the load-path bootstrap in emacs.c reads these
   envvars before computing the built-in fallback list.  */
static void
ios_setenv_bundle_paths (void)
{
  NSString *bundle = [NSBundle mainBundle].bundlePath;
  if (!bundle)
    return;
  NSString *lisp = [bundle stringByAppendingPathComponent:@"lisp"];
  NSString *etc  = [bundle stringByAppendingPathComponent:@"etc"];
  setenv ("EMACSLOADPATH", lisp.UTF8String, 1);
  setenv ("EMACSDATA",     etc.UTF8String,  1);
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_setenv_bundle_paths: EMACSLOADPATH=%@ EMACSDATA=%@",
                   lisp, etc]);
}

int
ios_main (int argc, char **argv)
{
  ios_launch_log (@"ios_main: entered");
  ios_setenv_bundle_paths ();
  char *dump_file = ios_dump_path ();
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_main: dump_file=%s, calling ios_emacs_init",
                   dump_file ?: "(null)"]);
  int result = ios_emacs_init (argc, argv, dump_file);
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_main: ios_emacs_init returned %d", result]);
  free (dump_file);
  return result;
}

/* Process entry point of the cross-built emacs Mach-O.

   The bundle's CFBundleExecutable IS this binary, so on launch iOS
   transfers control here directly.  We hand off to UIApplicationMain
   with EmacsAppDelegate (defined above), which spins up the run
   loop and triggers didFinishLaunchingWithOptions.  */

int
main (int argc, char *argv[])
{
  @autoreleasepool {
    ios_launch_log (@"main: entered, calling UIApplicationMain");
    int rc = UIApplicationMain (argc, argv, nil,
                                NSStringFromClass ([EmacsAppDelegate class]));
    ios_launch_log ([NSString stringWithFormat:
                     @"main: UIApplicationMain returned %d", rc]);
    return rc;
  }
}

#endif /* HAVE_IOS */
