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
   tree of UIAlertController action sheets.

   On the Emacs thread we walk menu_items into an IOSMenuNode tree
   (the same data shape every port produces, just structured rather
   than flat-walked); on the UIKit thread we render the root sheet
   and chain into child sheets when the user picks a submenu.
   Selection feeds the serial-tagged channel in iosterm.m that the
   nested pump waits on.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>

#include "lisp.h"
#include "iosterm.h"
#include "frame.h"
#include "keyboard.h"
#include "coding.h"
#include "menu.h"

@interface IOSMenuNode : NSObject
@property (nonatomic, copy) NSString *title;
/* For leaves, the menu_items vector index of MENU_ITEMS_ITEM_NAME
   for this item (so MENU_ITEMS_ITEM_VALUE sits at item_index +
   MENU_ITEMS_ITEM_VALUE).  For branches and separators, -1.  */
@property (nonatomic) int item_index;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL separator;
/* Checkbox state: 0 = plain item, 1 = unchecked, 2 = checked.
   Radio items use 3 = unselected, 4 = selected.  */
@property (nonatomic) int checkmark;
@property (nonatomic) NSMutableArray<IOSMenuNode *> *children;
@end
@implementation IOSMenuNode
@end

/* Build an NSString from a Lisp string via UTF-8.  Caller is on
   the Emacs thread (where Lisp allocation is legal).  */
static NSString *
ios_nsstring_from_lisp (Lisp_Object s)
{
  if (!STRINGP (s) || SBYTES (s) == 0)
    return @"";
  return [NSString stringWithUTF8String:
                     SSDATA (ENCODE_UTF_8 (s))];
}

/* Walk menu_items into a tree rooted at ROOT.  Mirrors the
   structure androidmenu.c walks at lookup time: nil/Qlambda
   bracket submenus, Qt is a pane marker, Qquote is filler, and
   anything else is an MENU_ITEMS_ITEM_LENGTH-wide item.  An item
   whose slot immediately past its fields is nil heads a submenu
   -- that's the lookahead that distinguishes branches from
   leaves at construction time.  */
static void
ios_build_menu_tree (IOSMenuNode *root)
{
  NSMutableArray<IOSMenuNode *> *stack = [NSMutableArray array];
  [stack addObject:root];
  IOSMenuNode *(^top)(void) = ^{ return stack.lastObject; };

  /* The most recent item appended to the current top-of-stack.
     A nil marker promotes it into a branch.  */
  IOSMenuNode *last_item = nil;

  int i = 0;
  while (i < menu_items_used)
    {
      Lisp_Object head = AREF (menu_items, i);

      if (NILP (head))
        {
          /* Start of submenu.  Promote last_item to a branch and
             push it as the new parent.  */
          if (last_item == nil)
            {
              /* Unbalanced -- a submenu open with no preceding
                 item to attach to.  Synthesize an anonymous
                 branch so the structure stays valid.  */
              IOSMenuNode *anon = [IOSMenuNode new];
              anon.title = @"";
              anon.item_index = -1;
              anon.children = [NSMutableArray array];
              [top ().children addObject:anon];
              last_item = anon;
            }
          last_item.children = [NSMutableArray array];
          last_item.item_index = -1;
          [stack addObject:last_item];
          last_item = nil;
          i += 1;
        }
      else if (EQ (head, Qlambda))
        {
          /* End of submenu.  Pop.  */
          if (stack.count > 1)
            [stack removeLastObject];
          last_item = nil;
          i += 1;
        }
      else if (EQ (head, Qquote))
        {
          i += 1;
        }
      else if (EQ (head, Qt))
        {
          /* Pane marker.  Inside a submenu it's redundant; at
             top level with multiple panes, surface the pane name
             as a disabled separator row -- iOS action sheets
             have no section concept, so a disabled row is the
             closest visual match.  */
          if (stack.count == 1 && menu_items_n_panes >= 2)
            {
              Lisp_Object pane = AREF (menu_items, i + MENU_ITEMS_PANE_NAME);
              if (STRINGP (pane) && SBYTES (pane) > 0)
                {
                  IOSMenuNode *header = [IOSMenuNode new];
                  header.title = ios_nsstring_from_lisp (pane);
                  header.item_index = -1;
                  header.enabled = NO;
                  header.separator = YES;
                  [top ().children addObject:header];
                }
            }
          i += MENU_ITEMS_PANE_LENGTH;
        }
      else
        {
          Lisp_Object name = AREF (menu_items, i + MENU_ITEMS_ITEM_NAME);
          Lisp_Object en   = AREF (menu_items, i + MENU_ITEMS_ITEM_ENABLE);
          Lisp_Object def  = AREF (menu_items, i + MENU_ITEMS_ITEM_DEFINITION);
          Lisp_Object type = AREF (menu_items, i + MENU_ITEMS_ITEM_TYPE);
          Lisp_Object sel  = AREF (menu_items, i + MENU_ITEMS_ITEM_SELECTED);

          IOSMenuNode *node = [IOSMenuNode new];
          node.title = ios_nsstring_from_lisp (name);
          node.item_index = i;
          node.enabled = !NILP (en);
          if (EQ (type, QCtoggle))
            node.checkmark = NILP (sel) ? 1 : 2;
          else if (EQ (type, QCradio))
            node.checkmark = NILP (sel) ? 3 : 4;

          /* Emacs encodes separators as items whose definition is
             nil and whose name matches the separator pattern
             ("--", "---", etc.).  */
          if (NILP (def) && STRINGP (name)
              && menu_separator_name_p (SSDATA (name)))
            {
              node.separator = YES;
              node.enabled = NO;
              node.item_index = -1;
            }

          [top ().children addObject:node];
          last_item = node;
          i += MENU_ITEMS_ITEM_LENGTH;
        }
    }
}

/* Strong reference to the on-screen sheet so the pump can dismiss
   it programmatically on C-g.  Main-thread access only.  */
static UIAlertController *ios_menu_top_sheet;

/* Serial of a menu invocation the pump abandoned (C-g).  Checked
   by ios_present_node before presenting, so a submenu chained
   through a dismiss-completion block cannot appear after its menu
   was quit -- during the dismiss animation ios_menu_top_sheet is
   nil and the quit path would otherwise have nothing to tear
   down.  Main-thread access only, so no lock.  */
static int ios_menu_cancelled_serial;

/* Walk up the connected-scene tree to find a presenter.  Returns
   nil if no window is on screen yet.  */
static UIViewController *
ios_root_presenter (void)
{
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
  return root;
}

/* Present a sheet for NODE's children from CTX.  SERIAL is the
   show-invocation tag the action handlers stamp into the
   selection channel.  On submenu navigation, the current sheet
   dismisses first, then presents the child sheet from the
   restored presenter (the dismiss completion block keeps the
   ordering correct; presenting on top of a dismissing controller
   is unreliable on iOS).  */
static void ios_present_node (IOSMenuNode *node, int serial,
                              int x, int y, BOOL as_dialog);

static void
ios_present_node (IOSMenuNode *node, int serial, int x, int y,
                  BOOL as_dialog)
{
  /* The pump may have abandoned this menu (C-g) while a submenu
     transition's dismiss animation was in flight.  Don't present
     an orphan.  */
  if (serial == ios_menu_cancelled_serial)
    return;

  UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:
                         (node.title.length ? node.title : nil)
                                        message:nil
                                 preferredStyle:
                                   (as_dialog
                                    ? UIAlertControllerStyleAlert
                                    : UIAlertControllerStyleActionSheet)];

  for (IOSMenuNode *child in node.children)
    {
      NSString *title = child.title.length ? child.title : @" ";
      /* Checkbox / radio state.  UIAlertAction has no checkmark
         accessory, so encode the state as a leading glyph the way
         tmm does in the minibuffer.  */
      switch (child.checkmark)
        {
        case 1: title = [@"\u2610 " stringByAppendingString:title]; break;
        case 2: title = [@"\u2611 " stringByAppendingString:title]; break;
        case 3: title = [@"\u25cb " stringByAppendingString:title]; break;
        case 4: title = [@"\u25c9 " stringByAppendingString:title]; break;
        default: break;
        }
      if (child.children.count > 0)
        /* Disclosure marker so the user sees the chain.  */
        title = [title stringByAppendingString:@" ▸"];

      UIAlertAction *act;
      if (child.children.count > 0)
        {
          IOSMenuNode *captured = child;
          act = [UIAlertAction actionWithTitle:title
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *a) {
            /* Dismiss this sheet first, then chain into the
               submenu from the freshly-uncovered presenter.  */
            UIViewController *presenter = sheet.presentingViewController;
            ios_menu_top_sheet = nil;
            [presenter dismissViewControllerAnimated:NO
                                          completion:^{
              ios_present_node (captured, serial, x, y, as_dialog);
            }];
          }];
          act.enabled = child.enabled;
        }
      else if (child.separator || child.item_index < 0)
        {
          act = [UIAlertAction actionWithTitle:title
                                         style:UIAlertActionStyleDefault
                                       handler:nil];
          act.enabled = NO;
        }
      else
        {
          int item = child.item_index;
          act = [UIAlertAction actionWithTitle:title
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *a) {
            ios_menu_top_sheet = nil;
            ios_publish_menu_selection (serial, item);
          }];
          act.enabled = child.enabled;
        }
      [sheet addAction:act];
    }

  if (!as_dialog)
    [sheet addAction:
       [UIAlertAction actionWithTitle:@"Cancel"
                                style:UIAlertActionStyleCancel
                              handler:^(UIAlertAction *a) {
         ios_menu_top_sheet = nil;
         ios_publish_menu_selection (serial, -1);
       }]];

  UIViewController *root = ios_root_presenter ();
  if (root == nil)
    {
      ios_publish_menu_selection (serial, -1);
      return;
    }
  /* iPad: action sheets present as popovers; anchor at (x, y) so
     they appear near the touch point.  */
  UIPopoverPresentationController *pop
    = sheet.popoverPresentationController;
  if (pop != nil)
    {
      pop.sourceView = root.view;
      pop.sourceRect = CGRectMake (x, y, 1, 1);
      pop.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
  ios_menu_top_sheet = sheet;
  [root presentViewController:sheet animated:YES completion:nil];
}

static Lisp_Object
ios_menu_show_1 (struct frame *f, int x, int y, int menuflags,
                 Lisp_Object title, const char **error_name,
                 BOOL as_dialog)
{
  *error_name = NULL;

  IOSMenuNode *root = [IOSMenuNode new];
  root.title = STRINGP (title) ? ios_nsstring_from_lisp (title) : @"";
  root.item_index = -1;
  root.children = [NSMutableArray array];
  ios_build_menu_tree (root);

  if (root.children.count == 0)
    {
      *error_name = "Empty menu";
      return Qnil;
    }

  int serial = ios_menu_next_serial ();
  dispatch_async (dispatch_get_main_queue (), ^{
    ios_present_node (root, serial, x, y, as_dialog);
  });

  /* Nested input pump, the same shape as every other port's modal
     menu loop: keep draining input so type-ahead lands in the kbd
     buffer and a typed C-g sets Vquit_flag.  Exits on selection,
     cancellation, or quit -- all events -- so there is no
     wall-clock timeout to guess at.  */
  int sel = -1;
  for (;;)
    {
      if (ios_take_menu_selection (serial, &sel))
        break;
      if (!NILP (Vquit_flag))
        {
          int quit_serial = serial;
          dispatch_async (dispatch_get_main_queue (), ^{
            /* Mark the serial cancelled FIRST so a submenu
               transition completing after this block cannot
               re-present; then tear down whatever is up.  */
            ios_menu_cancelled_serial = quit_serial;
            UIAlertController *sheet = ios_menu_top_sheet;
            ios_menu_top_sheet = nil;
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

Lisp_Object
ios_menu_show (struct frame *f, int x, int y, int menuflags,
               Lisp_Object title, const char **error_name)
{
  return ios_menu_show_1 (f, x, y, menuflags, title, error_name, NO);
}

/* terminal->popup_dialog_hook.  CONTENTS is (TITLE (BUTTON .
   VALUE)...); HEADER selects question vs information styling,
   which UIAlertController does not distinguish, so it is ignored.
   Mirrors android_popup_dialog: populate menu_items via
   list_of_panes, then drive the shared presenter in alert style.
   Dialogs get no injected Cancel action -- the caller's buttons
   are the only choices, and C-g through the pump remains the
   escape hatch, quitting like the X dialog path does.  */
Lisp_Object
ios_popup_dialog (struct frame *f, Lisp_Object header,
                  Lisp_Object contents)
{
  (void) header;
  Lisp_Object title;
  const char *error_name = NULL;
  Lisp_Object selection;
  specpdl_ref count = SPECPDL_INDEX ();

  check_window_system (f);

  title = Fcar (contents);
  CHECK_STRING (title);
  record_unwind_protect_void (unuse_menu_items);

  /* No buttons specified: add an "Ok" so the dialog can pop
     down.  */
  if (NILP (Fcar (Fcdr (contents))))
    contents = list2 (title, Fcons (build_string ("Ok"), Qt));

  list_of_panes (list1 (contents));
  selection = ios_menu_show_1 (f, 0, 0, 0, title, &error_name, YES);
  unbind_to (count, Qnil);
  discard_menu_items ();

  if (error_name)
    error ("%s", error_name);
  return selection;
}

void
syms_of_iosmenu (void)
{
}

#endif /* HAVE_IOS */
