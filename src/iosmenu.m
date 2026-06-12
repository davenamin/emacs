/* iOS menu support for GNU Emacs.
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

/* iOS has no menu bar; this file maps Emacs popup-menu requests
   (x-popup-menu, mouse-3 context menus, tmm fallbacks) onto a
   UIAlertController action sheet.

   V1 limitations relative to androidmenu.c: panes and submenus are
   flattened into one list (pane names become disabled separator
   rows), and help-echo strings are not shown.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>

#include "lisp.h"
#include "iosterm.h"
#include "frame.h"
#include "keyboard.h"
#include "coding.h"
#include "menu.h"

/* Serial of the menu invocation currently (or most recently) on
   screen.  Handlers capture their own invocation's serial and
   publish through ios_publish_menu_selection, which discards
   anything whose serial does not match what the pump is waiting
   for -- a tap on a stale sheet cannot leak into a newer menu.  */
static int ios_menu_serial_counter;

/* Strong reference to the on-screen sheet so the pump can dismiss
   it programmatically on C-g.  Main-thread access only.  */
static UIAlertController *ios_menu_sheet;

/* terminal->menu_show_hook.  Walks the shared menu_items vector
   (already populated by menu.c), presents an action sheet, blocks
   until selection, and returns the chosen item's value.  */
Lisp_Object
ios_menu_show (struct frame *f, int x, int y, int menuflags,
               Lisp_Object title, const char **error_name)
{
  *error_name = NULL;

  /* Collect item titles + enabled bits + menu_items indices on the
     Emacs thread; only ObjC containers cross to the UI thread.  */
  NSMutableArray<NSString *> *titles = [NSMutableArray array];
  NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
  NSMutableArray<NSNumber *> *enabled = [NSMutableArray array];

  int i = 0;
  while (i < menu_items_used)
    {
      Lisp_Object head = AREF (menu_items, i);
      if (NILP (head) || EQ (head, Qlambda) || EQ (head, Qquote))
        i += 1;
      else if (EQ (head, Qt))
        {
          /* Pane: show its name as a disabled separator row.  */
          Lisp_Object pane = AREF (menu_items, i + MENU_ITEMS_PANE_NAME);
          if (STRINGP (pane) && SBYTES (pane) > 0)
            {
              [titles addObject:
                 [NSString stringWithUTF8String:SSDATA (ENCODE_UTF_8 (pane))]];
              [indices addObject:@(-1)];
              [enabled addObject:@NO];
            }
          i += MENU_ITEMS_PANE_LENGTH;
        }
      else
        {
          Lisp_Object name = AREF (menu_items, i + MENU_ITEMS_ITEM_NAME);
          Lisp_Object en = AREF (menu_items, i + MENU_ITEMS_ITEM_ENABLE);
          if (STRINGP (name))
            {
              [titles addObject:
                 [NSString stringWithUTF8String:SSDATA (ENCODE_UTF_8 (name))]];
              [indices addObject:@(i)];
              [enabled addObject:(NILP (en) ? @NO : @YES)];
            }
          i += MENU_ITEMS_ITEM_LENGTH;
        }
    }

  if (titles.count == 0)
    {
      *error_name = "Empty menu";
      return Qnil;
    }

  NSString *sheet_title = nil;
  if (STRINGP (title))
    sheet_title =
      [NSString stringWithUTF8String:SSDATA (ENCODE_UTF_8 (title))];

  int serial = ++ios_menu_serial_counter;

  dispatch_async (dispatch_get_main_queue (), ^{
    UIAlertController *sheet =
      [UIAlertController alertControllerWithTitle:sheet_title
                                          message:nil
                                   preferredStyle:
                                     UIAlertControllerStyleActionSheet];
    for (NSUInteger k = 0; k < titles.count; k++)
      {
        int item_index = indices[k].intValue;
        UIAlertAction *act =
          [UIAlertAction actionWithTitle:titles[k]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *a) {
            ios_menu_sheet = nil;
            ios_publish_menu_selection (serial, item_index);
          }];
        act.enabled = enabled[k].boolValue && item_index >= 0;
        [sheet addAction:act];
      }
    [sheet addAction:
       [UIAlertAction actionWithTitle:@"Cancel"
                                style:UIAlertActionStyleCancel
                              handler:^(UIAlertAction *a) {
         ios_menu_sheet = nil;
         ios_publish_menu_selection (serial, -1);
       }]];

    UIWindow *window = nil;
    for (UIScene *scene in
           UIApplication.sharedApplication.connectedScenes)
      {
        if (![scene isKindOfClass:[UIWindowScene class]])
          continue;
        UIWindowScene *ws = (UIWindowScene *) scene;
        window = ws.keyWindow;
        if (window == nil && ws.windows.count > 0)
          window = ws.windows.firstObject;
        if (window != nil)
          break;
      }
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController != nil)
      root = root.presentedViewController;
    if (root == nil)
      {
        ios_publish_menu_selection (serial, -1);
        return;
      }
    /* iPad: action sheets present as popovers and need an anchor;
       anchor at the requested (x, y) in the root view.  */
    UIPopoverPresentationController *pop
      = sheet.popoverPresentationController;
    if (pop != nil)
      {
        pop.sourceView = root.view;
        pop.sourceRect = CGRectMake (x, y, 1, 1);
      }
    ios_menu_sheet = sheet;
    [root presentViewController:sheet animated:YES completion:nil];
  });

  /* Nested input pump, the same shape as every other port's modal
     menu loop: keep draining input so type-ahead lands in the kbd
     buffer and a typed C-g sets Vquit_flag (the drain path detects
     the quit character in kbd_buffer_store_event).  Exits on
     selection, cancellation, or quit -- all events, so there is no
     wall-clock timeout to guess at.  */
  int sel = -1;
  for (;;)
    {
      if (ios_take_menu_selection (serial, &sel))
        break;
      if (!NILP (Vquit_flag))
        {
          /* User quit from the keyboard: tear the sheet down and
             let the pending quit propagate.  */
          dispatch_async (dispatch_get_main_queue (), ^{
            UIAlertController *sheet = ios_menu_sheet;
            ios_menu_sheet = nil;
            [sheet.presentingViewController
              dismissViewControllerAnimated:YES completion:nil];
          });
          sel = -1;
          break;
        }
      ios_pump_input (200);
    }
  if (sel < 0 || sel + MENU_ITEMS_ITEM_VALUE >= menu_items_used)
    {
      if (!(menuflags & MENU_FOR_CLICK))
        quit ();
      return Qnil;
    }

  Lisp_Object entry = AREF (menu_items, sel + MENU_ITEMS_ITEM_VALUE);
  if (menuflags & MENU_KEYMAPS)
    entry = list1 (entry);
  return entry;
}

void
syms_of_iosmenu (void)
{
}

#endif /* HAVE_IOS */
