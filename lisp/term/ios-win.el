;;; ios-win.el --- terminal set up for iOS  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: FSF
;; Keywords: terminals, i18n, ios

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file contains the support for initializing the Lisp side of
;; iOS windowing.  It is the iOS counterpart to lisp/term/android-win.el
;; and lisp/term/ns-win.el, and is currently a stub: subsequent commits
;; will populate it with clipboard, drag-and-drop, gesture, and frame
;; handling functions in parallel to android-win.el.

;;; Code:


(unless (featurep 'ios)
  (error "%s: Loading ios-win without having iOS"
         invocation-name))

;; Documentation-purposes only: actually loaded in loadup.el.
(require 'frame)
(require 'mouse)
(require 'fontset)
(require 'dnd)
(require 'touch-screen)

(defvar ios-initialized nil
  "Non-nil when the iOS terminal has been initialized.")

(declare-function ios-handle-args "iosfns.m")

(add-to-list 'display-format-alist '(".*" . ios))

(cl-defmethod window-system-initialization (&context (window-system ios)
                                                     &optional _display)
  "Set up the iOS window system.
WINDOW-SYSTEM is `ios'.  DISPLAY is ignored.  This is a minimal stub
that lets startup.el's window-system bring-up reach completion; the
underlying terminal (the one ios_term_init will produce) is the
actual graphics back end and is still being filled in."
  (create-default-fontset)
  (setq ios-initialized t))

(cl-defmethod handle-args-function (args &context (window-system ios))
  ;; No iOS-specific command-line arguments yet.
  args)

(cl-defmethod frame-creation-function (params &context (window-system ios))
  (x-create-frame-with-faces params))

;; Pasteboard glue.  The C primitives live in src/iosselect.m.
(declare-function ios-set-clipboard "iosselect.m" (string))
(declare-function ios-get-clipboard "iosselect.m" ())
(declare-function ios-clipboard-exists-p "iosselect.m" ())

(defun ios-interprogram-cut (text)
  "Send TEXT to the iOS general pasteboard."
  (ios-set-clipboard text))

(defun ios-interprogram-paste ()
  "Return the current iOS general-pasteboard text, or nil if none."
  (when (ios-clipboard-exists-p)
    (ios-get-clipboard)))

(setq interprogram-cut-function   #'ios-interprogram-cut)
(setq interprogram-paste-function #'ios-interprogram-paste)

(provide 'ios-win)

;;; ios-win.el ends here
