;;; ios-tests.el --- functional self-tests for the iOS port  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: FSF
;; Keywords: terminals, ios, tests

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

;; Battery of correctness checks the CI auto-input thread runs after
;; the demo round-trip.  Each check writes one PASS / FAIL / SKIP line
;; into ~/ios-test-results.txt; the workflow greps it and a single
;; FAIL fails the run.  Designed to be self-contained -- no network,
;; no UI interaction -- so it runs in the simulator's batch-ish
;; auto-input flow without any human poking.

;;; Code:

(require 'cl-lib)

(defvar ios-test--out nil
  "Buffer of result strings, flushed to disk at the end.")

(defmacro ios-test-deftest (name docstring &rest body)
  "Define an iOS port self-test NAME.
BODY signals on failure; the recording wrapper catches the signal and
records FAIL.  DOCSTRING is used as the test description in the log."
  (declare (indent defun) (doc-string 2))
  `(condition-case err
       (progn
         ,@body
         (push (format "PASS %s -- %s\n" ',name ,docstring) ios-test--out))
     (error
      (push (format "FAIL %s -- %s :: %S\n"
                    ',name ,docstring err)
            ios-test--out))))

(defun ios-test--writefile (path content)
  "Write CONTENT to PATH; return PATH."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert content)
    (let ((coding-system-for-write 'no-conversion))
      (write-region (point-min) (point-max) path nil 'silent)))
  path)

(defun ios-run-self-tests ()
  "Run the iOS port's functional self-tests.
Results land in ~/ios-test-results.txt; one line per test."
  (interactive)
  (setq ios-test--out nil)

  ;;; --- Sandbox / VFS primitives -----------------------------------

  (ios-test-deftest sandbox-paths-callable
    "VFS primitives return non-nil paths"
    (cl-assert (stringp (ios-bundle-directory)))
    (cl-assert (stringp (ios-documents-directory)))
    (cl-assert (stringp (ios-library-directory)))
    (cl-assert (stringp (ios-tmp-directory))))

  (ios-test-deftest home-is-documents
    "HOME equals ios-documents-directory"
    (cl-assert (equal (file-truename (expand-file-name "~"))
                      (file-truename (ios-documents-directory)))))

  (ios-test-deftest cwd-is-documents
    "Current working directory is the documents tree"
    (cl-assert (string-prefix-p
                (file-truename (ios-documents-directory))
                (file-truename default-directory))))

  ;;; --- File round-trip ---------------------------------------------

  (ios-test-deftest file-roundtrip
    "find-file / write / re-read round-trips through Documents"
    (let ((path (expand-file-name "ios-selftest.txt" "~")))
      (with-temp-file path (insert "tested\n"))
      (with-temp-buffer
        (insert-file-contents path)
        (cl-assert (equal (buffer-string) "tested\n")))
      (delete-file path)))

  ;;; --- Clipboard --------------------------------------------------

  (ios-test-deftest clipboard-roundtrip
    "Lisp -> UIPasteboard -> Lisp preserves text"
    (let ((before (ios-clipboard-exists-p)))
      (ios-set-clipboard "ios-selftest-marker")
      (cl-assert (equal "ios-selftest-marker" (ios-get-clipboard)))
      (cl-assert (eq t (ios-clipboard-exists-p)))
      (ignore before)))

  ;;; --- Display primitives -----------------------------------------

  (ios-test-deftest display-geometry
    "x-display-pixel-{width,height} report a real display"
    (cl-assert (> (x-display-pixel-width) 100))
    (cl-assert (> (x-display-pixel-height) 100))
    (cl-assert (> (x-display-mm-width) 10))
    (cl-assert (> (x-display-mm-height) 10)))

  (ios-test-deftest appearance-callable
    "ios-system-appearance returns dark or light"
    (cl-assert (memq (ios-system-appearance) '(dark light))))

  ;;; --- Images (the new subsystem) ---------------------------------

  (ios-test-deftest image-load-png
    "create-image on a 1x1 PNG returns a usable image object"
    (let* ((png-bytes (base64-decode-string
                       (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAA"
                               "fFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7w"
                               "AAAABJRU5ErkJggg==")))
           (path (ios-test--writefile
                  (expand-file-name "ios-selftest.png" "~")
                  png-bytes))
           (img  (create-image path 'png)))
      (cl-assert (eq 'image (car img)))
      ;; Force a size lookup; this calls into ios_load_image.
      (let ((sz (image-size img t)))
        (cl-assert (= 1 (car sz)))
        (cl-assert (= 1 (cdr sz))))
      (delete-file path)))

  ;;; --- Faces / frame parameters -----------------------------------

  (ios-test-deftest face-color-roundtrip
    "set-face-attribute followed by face-attribute returns input"
    (let ((orig (face-attribute 'default :foreground)))
      (unwind-protect
          (progn
            (set-face-attribute 'default nil :foreground "blue")
            (cl-assert (equal "blue"
                              (face-attribute 'default :foreground))))
        (set-face-attribute 'default nil :foreground orig))))

  (ios-test-deftest frame-bg-mode-set
    "frame-background-mode is one of light / dark"
    (cl-assert (memq frame-background-mode '(light dark))))

  ;;; --- Drag-n-drop handler ---------------------------------------

  (ios-test-deftest drag-n-drop-handler-bound
    "[drag-n-drop] is bound globally to a callable"
    (cl-assert (functionp (lookup-key (current-global-map)
                                      [drag-n-drop]))))

  ;;; --- Pinch / wheel events --------------------------------------

  (ios-test-deftest pinch-event-handler-bound
    "[pinch] is bound globally so two-finger pinches do something"
    (cl-assert (functionp (lookup-key (current-global-map) [pinch]))))

  (ios-test-deftest wheel-event-handler-bound
    "[wheel-up] / [wheel-down] are bound globally"
    (cl-assert (or (functionp (lookup-key (current-global-map)
                                          [wheel-up]))
                   (functionp (lookup-key (current-global-map)
                                          [mouse-wheel-up-event]))))
    (cl-assert (or (functionp (lookup-key (current-global-map)
                                          [wheel-down]))
                   (functionp (lookup-key (current-global-map)
                                          [mouse-wheel-down-event])))))

  ;;; --- Write the results -----------------------------------------

  (let ((path (expand-file-name "ios-test-results.txt" "~")))
    (with-temp-file path
      (insert (mapconcat #'identity (nreverse ios-test--out) "")))
    (message "ios-run-self-tests: wrote %s" path)))

(provide 'ios-tests)
;;; ios-tests.el ends here
