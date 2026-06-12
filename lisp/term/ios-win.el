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

(declare-function ios-system-appearance "iosfns.m" ())

(defvar ios-appearance-changed-hook
  '(ios--reapply-appearance)
  "Hook run when the iOS system appearance toggles dark / light.
The iOS terminal calls this from `ios_read_socket' shortly after
UIKit's `traitCollectionDidChange:'.  Default binding refreshes
`frame-background-mode' and re-realizes faces on every live frame.")

(defun ios--reapply-appearance ()
  "Sync `frame-background-mode' to the current iOS appearance."
  (when (fboundp 'ios-system-appearance)
    (let ((mode (ios-system-appearance)))
      (when (memq mode '(dark light))
        (setq frame-background-mode mode)
        (mapc #'frame-set-background-mode (frame-list))))))

(cl-defmethod window-system-initialization (&context (window-system ios)
                                                     &optional _display)
  "Set up the iOS window system.
WINDOW-SYSTEM is `ios'.  DISPLAY is ignored.  This is a minimal stub
that lets startup.el's window-system bring-up reach completion; the
underlying terminal (the one ios_term_init will produce) is the
actual graphics back end and is still being filled in."
  (create-default-fontset)
  ;; Seed frame-background-mode from the OS-wide appearance so the
  ;; default theme picks dark or light accordingly.  Defensive: a
  ;; stub binary built before ios-system-appearance landed would
  ;; signal void-function and break startup.
  (when (fboundp 'ios-system-appearance)
    (let ((mode (ios-system-appearance)))
      (when (memq mode '(dark light))
        (setq frame-background-mode mode))))
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

;; Files-app integration.  ios-pick-file is implemented in C; it
;; presents UIDocumentPickerViewController and blocks until the user
;; picks something or cancels.
(declare-function ios-pick-file "iosfns.m" ())

(defun ios-find-file ()
  "Pick a file via the iOS Files app and open it."
  (interactive)
  (let ((path (ios-pick-file)))
    (when (and path (file-readable-p path))
      (find-file path))))

(defun ios-handle-drag-n-drop (event)
  "Visit the files in the drag-n-drop EVENT.
The iOS terminal generates one of these when another app hands
Emacs a file (Files.app share sheet, Mail attachment, etc.)."
  (interactive "e")
  (dolist (file (nth 2 event))
    (when (stringp file)
      (find-file file))))

(global-set-key [drag-n-drop] #'ios-handle-drag-n-drop)

(provide 'ios-win)

;;; ios-win.el ends here
