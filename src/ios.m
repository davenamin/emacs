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

#include <pthread.h>
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

/* Weakly-held reference to the on-screen log view installed by the
   AppDelegate.  ios_launch_log appends each message here too so the
   user can see live bring-up progress in the simulator / on a device,
   not just in the file logs.  Weak so the view can deallocate
   normally when the AppDelegate tears down at app termination.  */
__weak static UITextView *ios_log_view = nil;

/* Append a timestamped MSG line to Documents/emacs-launch.log, and
   echo via NSLog.  Two-channel logging on purpose: NSLog reaches
   `simctl launch --console` and the unified log; the file remains
   reachable via the Files app or by spelunking through
   ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/
   Data/Application/<app-uuid>/Documents/.

   Third channel: the on-screen UITextView (if installed) gets the
   line appended on the main thread.  This is what makes "the app
   launches but hangs" visibly NOT a hang -- the user sees the
   running progress trail through Emacs init.  */
void
ios_launch_log (NSString *msg)
{
  NSLog (@"emacs-launch: %@", msg);
  NSString *path = ios_documents_path (@"emacs-launch.log");
  if (path)
    {
      NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                        [NSDate date], msg];
      FILE *f = fopen (path.UTF8String, "a");
      if (f != NULL)
        {
          fputs (line.UTF8String, f);
          fclose (f);
        }
    }

  /* Ship to the on-screen log view (if any).  Main-queue dispatch so
     UIKit work happens on the UI thread regardless of caller.  */
  UITextView *view = ios_log_view;
  if (view != nil)
    {
      NSString *line = [NSString stringWithFormat:@"%@\n", msg];
      dispatch_async (dispatch_get_main_queue (), ^{
        view.text = [view.text stringByAppendingString:line];
        /* Auto-scroll to the bottom so the latest entry is visible.  */
        NSRange end = NSMakeRange (view.text.length, 0);
        [view scrollRangeToVisible:end];
      });
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


/* ---- Background-thread entry --------------------------------- */

/* pthread entry that drives Emacs init.  Defined as a real function
   rather than a dispatch_async block so we can guarantee a 16 MB
   stack -- see the pthread_create call in didFinishLaunchingWithOptions
   for the SIGILL-on-stack-overflow rationale.  Returns NULL; the
   detached pthread implicitly cleans itself up when ios_main eventually
   exits (which it never does in normal operation).  */
static void *
ios_emacs_bg_thread (void *unused)
{
  (void) unused;
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
  return NULL;
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
  self.window.backgroundColor = UIColor.blackColor;

  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = UIColor.blackColor;

  /* Title strip across the top, so the launch image is unambiguously
     "Emacs is starting" rather than "the simulator is broken".  */
  UILabel *title = [[UILabel alloc] init];
  title.text = @"GNU Emacs (iOS bring-up)";
  title.textColor = UIColor.whiteColor;
  title.font = [UIFont boldSystemFontOfSize:20];
  title.textAlignment = NSTextAlignmentCenter;
  title.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:title];

  /* Scrollable live log view filling the rest of the screen.  Each
     ios_launch_log call appends a line here from the bg pthread via
     main-queue dispatch.  Until a real EmacsUIView lands, this view
     IS the user interface -- it makes "Emacs is initializing on a
     background pthread" visible rather than presenting a black
     screen that looks like a hang.  */
  UITextView *logView = [[UITextView alloc] init];
  logView.backgroundColor = UIColor.blackColor;
  logView.textColor = UIColor.greenColor;
  logView.font = [UIFont fontWithName:@"Menlo" size:11];
  logView.editable = NO;
  logView.text = @"";
  logView.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:logView];

  /* Constraints: title at top, log fills the rest, both honor the
     safe-area inset so the home-indicator and notch don't clip.  */
  UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
      [title.topAnchor      constraintEqualToAnchor:safe.topAnchor
                                           constant:8],
      [title.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor
                                           constant:8],
      [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                           constant:-8],
      [logView.topAnchor      constraintEqualToAnchor:title.bottomAnchor
                                              constant:8],
      [logView.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor],
      [logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
      [logView.bottomAnchor   constraintEqualToAnchor:safe.bottomAnchor],
  ]];

  /* Install the log view BEFORE makeKeyAndVisible so the
     ios_launch_log calls after this point find it on first
     dispatch.  */
  ios_log_view = logView;

  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  ios_launch_log (@"AppDelegate window visible (log view installed)");

  /* Kick off Emacs initialization on a dedicated pthread.  ios_main
     never returns (Emacs's main loop runs forever), so blocking the
     UI thread on it would deadlock UIKit and trip the iOS launch
     watchdog.
     A dispatch_async background queue has only ~512 KB of stack on
     iOS, which the Emacs Lisp interpreter blows through in ~500
     levels of recursion -- loadup.el's preload pass hit a SIGILL
     stack overflow inside Fassq during eval_sub recursion.  Use a
     pthread with an explicit 16 MB stack instead.  */
  pthread_attr_t attr;
  pthread_attr_init (&attr);
  pthread_attr_setstacksize (&attr, 16 * 1024 * 1024);
  pthread_attr_setdetachstate (&attr, PTHREAD_CREATE_DETACHED);
  pthread_t tid;
  int pterr = pthread_create (&tid, &attr, ios_emacs_bg_thread, NULL);
  pthread_attr_destroy (&attr);
  ios_launch_log ([NSString stringWithFormat:
                   @"AppDelegate: pthread_create rc=%d", pterr]);

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
