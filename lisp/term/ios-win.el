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
;; iOS windowing: window-system setup, pasteboard integration,
;; Files-app access, drag-and-drop, soft-keyboard hooks, TLS trust
;; anchors, and dired configuration.  It is the iOS counterpart to
;; lisp/term/android-win.el and lisp/term/ns-win.el.

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

(defun ios--setup-fontset-fallbacks ()
  "Map non-Latin scripts and emoji to iOS system font families.
The default face uses the monospaced system font, which covers
Latin and punctuation but not CJK, emoji, or most complex scripts.
Core Text draws a fixed glyph run, so unlike the old string-reshape
path it does not substitute a covering font automatically; naming a
family per script lets the fontset pick one the driver can open."
  ;; Missing families are ignored (ignore-errors), and the driver falls
  ;; back to the system font for any that do not resolve, so listing a
  ;; family iOS lacks is harmless.
  (dolist (entry '((han        . "PingFang SC")
                   (kana       . "Hiragino Sans")
                   (cjk-misc   . "PingFang SC")
                   (bopomofo   . "PingFang TC")
                   (hangul     . "Apple SD Gothic Neo")
                   (thai       . "Thonburi")
                   (lao        . "Lao Sangam MN")
                   (khmer      . "Khmer Sangam MN")
                   (burmese    . "Myanmar Sangam MN")
                   (arabic     . "Geeza Pro")
                   (hebrew     . "Arial Hebrew")
                   (devanagari . "Kohinoor Devanagari")
                   (bengali    . "Bangla Sangam MN")
                   (gujarati   . "Gujarati Sangam MN")
                   (gurmukhi   . "Gurmukhi MN")
                   (kannada    . "Kannada Sangam MN")
                   (malayalam  . "Malayalam Sangam MN")
                   (oriya      . "Oriya Sangam MN")
                   (sinhala    . "Sinhala Sangam MN")
                   (tamil      . "Tamil Sangam MN")
                   (telugu     . "Telugu Sangam MN")
                   (tibetan    . "Kailasa")
                   (ethiopic   . "Kefa")
                   (emoji      . "Apple Color Emoji")
                   (symbol     . "Apple Symbols")))
    (ignore-errors
      (set-fontset-font t (car entry)
                        (font-spec :family (cdr entry))
                        nil 'prepend))))

(cl-defmethod window-system-initialization (&context (window-system ios)
                                                     &optional _display)
  "Set up the iOS window system.
WINDOW-SYSTEM is `ios'.  DISPLAY is ignored."
  (create-default-fontset)
  (ios--setup-fontset-fallbacks)
  ;; Seed frame-background-mode from the OS-wide appearance so the
  ;; default theme picks dark or light accordingly.
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

(defcustom ios-auto-show-keyboard t
  "If non-nil, automatically show the soft keyboard when entering the minibuffer.
Hardware-keyboard users may prefer to disable this so the on-screen
keyboard never covers the canvas during M-x.  Auto-hide on
minibuffer exit is unconditional once shown by this hook."
  :group 'ios
  :type 'boolean)

(declare-function ios-show-keyboard "iosfns.m" ())
(declare-function ios-hide-keyboard "iosfns.m" ())

(defvar ios--keyboard-shown-by-minibuffer nil
  "Non-nil when the current minibuffer session brought up the keyboard.")

(defun ios--minibuffer-setup ()
  (when ios-auto-show-keyboard
    (setq ios--keyboard-shown-by-minibuffer t)
    (ios-show-keyboard)))

(defun ios--minibuffer-exit ()
  (when ios--keyboard-shown-by-minibuffer
    (setq ios--keyboard-shown-by-minibuffer nil)
    (ios-hide-keyboard)))

(add-hook 'minibuffer-setup-hook #'ios--minibuffer-setup)
(add-hook 'minibuffer-exit-hook #'ios--minibuffer-exit)

;; Named colors.  The C-level color lookup resolves hex literals
;; and the tty pseudo colors on its own; the full X11 name table
;; is bridged over from tty-colors.el here (both are preloaded, in
;; this order, by loadup.el).  Without this every named face color
;; (gray40, medium blue, ...) fails to resolve.
(declare-function ios-internal-register-colors "iosterm.m" (alist))
(when (fboundp 'ios-internal-register-colors)
  (ios-internal-register-colors color-name-rgb-alist))

;; TLS trust anchors.  The bundle ships etc/ca-bundle.pem (Apple's
;; root-CA set, exported from the build host by ios/Makefile); none
;; of gnutls-trustfiles' built-in defaults (/etc/ssl and friends)
;; exist inside the iOS sandbox, so without this every certificate
;; verification would fail.  Harmless when the build carries no
;; GnuTLS: the form only runs if something loads gnutls.el, and a
;; missing bundle file leaves the defaults untouched.
(with-eval-after-load 'gnutls
  (let ((bundle (expand-file-name "ca-bundle.pem" data-directory)))
    (when (file-readable-p bundle)
      (setq gnutls-trustfiles (list bundle)))))

;; tree-sitter grammars.  The parsing runtime is linked in, but the
;; language grammars are separate dynamic libraries.  On iOS they
;; cannot be installed at runtime -- treesit-install-language-grammar
;; needs a C compiler (no subprocesses) and would dlopen a dylib
;; outside the app bundle (barred by the sandbox).  Pre-built
;; grammars shipped inside the signed app bundle can be dlopen'd,
;; so point treesit-extra-load-path at the bundle's tree-sitter dir.
(when (and (fboundp 'ios-bundle-directory)
           (boundp 'treesit-extra-load-path))
  (add-to-list 'treesit-extra-load-path
               (file-name-as-directory
                (expand-file-name "tree-sitter" (ios-bundle-directory)))))

;; iOS forbids subprocesses (posix_spawn is sandboxed away), so
;; dired must use the pure-Lisp ls emulation instead of spawning
;; `ls' -- the same arrangement Android uses, but keyed here off
;; the window system because the iOS build reports system-type
;; `darwin', which ls-lisp's own default treats as
;; has-working-ls.  Without this, dired fails with "Searching for
;; program: No such file or directory, ls".
(require 'ls-lisp)
(setq ls-lisp-use-insert-directory-program nil)

;; Self-test entry point.  lisp/term is not on load-path by default
;; (terminal init files are loaded by emacs.c's window-system probe,
;; not via require), so the autoload file argument must include the
;; subdirectory or the load fails with "No such file" on first use.
(autoload 'ios-run-self-tests "term/ios-tests"
  "Run the iOS port's functional self-tests." t)
(autoload 'ios-show-font-demo "term/ios-tests"
  "Show a buffer of shaped and non-Latin text for visual inspection." t)

(provide 'ios-win)

;;; ios-win.el ends here
