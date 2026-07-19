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

  (ios-test-deftest color-names-resolve
    "named X11 colors resolve through the bridged color table"
    (dolist (name '("gray40" "medium blue" "grey90" "RoyalBlue3"
                    "#88aa00"))
      (cl-assert (color-defined-p name)))
    (cl-assert (equal (color-values "red") '(65535 0 0))))

  (ios-test-deftest theme-face-specs-match
    "color face-spec display predicates match on the iOS frame"
    ;; The root cause of "themes have no effect": if display-graphic-p
    ;; omits ios, display-color-p routes to the tty path, display-type
    ;; becomes mono, and every (class color) theme spec fails to match.
    (frame-set-background-mode (selected-frame))
    (cl-assert (display-graphic-p))
    (cl-assert (display-color-p))
    (cl-assert (eq 'color (frame-parameter nil 'display-type)))
    (cl-assert (face-spec-set-match-display
                '((class color) (min-colors 89)) nil)))

  (ios-test-deftest frame-bar-parameters-numeric
    "menu/tab/tool-bar-lines frame parameters are numbers"
    ;; window-deletable-p and friends do arithmetic on these; a
    ;; port that fails to store them breaks every window dismissal.
    (dolist (p '(menu-bar-lines tab-bar-lines tool-bar-lines))
      (cl-assert (numberp (frame-parameter nil p)))))

  (ios-test-deftest libxml-available
    "libxml2 HTML/XML parsing primitives are present"
    ;; Enabled via the cross-compiled libxml2 in --with-ios-deps;
    ;; eww / shr / feed readers need libxml-parse-html-region.
    (cl-assert (fboundp 'libxml-parse-html-region))
    (cl-assert (fboundp 'libxml-parse-xml-region))
    ;; Parse a trivial document to confirm the library actually links.
    (with-temp-buffer
      (insert "<html><body><p>hi</p></body></html>")
      (let ((dom (libxml-parse-html-region (point-min) (point-max))))
        (cl-assert (eq 'html (car dom))))))

  (ios-test-deftest treesit-runtime-available
    "the tree-sitter parsing runtime is linked in"
    ;; Runtime only: language grammars are separate dylibs that must
    ;; be pre-built and bundled (see ios/README); none ship by
    ;; default, so this asserts the runtime, not a specific grammar.
    (cl-assert (treesit-available-p))
    (cl-assert (listp treesit-extra-load-path)))

  (ios-test-deftest sqlite-available
    "sqlite3 is linked and an in-memory round-trip works"
    ;; libsqlite3 comes from the iOS SDK (no cross-compiled dep);
    ;; enables M-x sqlite and packages using the built-in DB.
    (cl-assert (sqlite-available-p))
    (let ((db (sqlite-open)))
      (unwind-protect
          (progn
            (sqlite-execute db "CREATE TABLE t (x INTEGER);")
            (sqlite-execute db "INSERT INTO t VALUES (42);")
            (cl-assert (equal '((42))
                              (sqlite-select db "SELECT x FROM t;"))))
        (sqlite-close db))))

  (ios-test-deftest font-parameter-is-string
    "the `font' frame parameter is a name string, not a font object"
    ;; set-frame-font, frameset/desktop save, and describe-font all
    ;; expect a string; a font object here signals wrong-type-argument.
    (cl-assert (stringp (frame-parameter nil 'font))))

  (ios-test-deftest font-families-multiple
    "the Core Text driver lists more than one font family"
    ;; The old shim returned a single monospaced family; the real
    ;; driver enumerates UIFont.familyNames.
    (cl-assert (> (length (font-family-list)) 5)))

  (ios-test-deftest font-bold-italic-real
    "bold and italic resolve to actual fonts, not synthesised flags"
    (cl-assert (find-font (font-spec :weight 'bold)))
    (cl-assert (find-font (font-spec :slant 'italic))))

  (ios-test-deftest char-coverage-cjk
    "a CJK ideograph is displayable through the script fontset fallback"
    ;; U+6F22 (Han "kan"); hex escape avoids non-ASCII source bytes.
    (cl-assert (char-displayable-p ?\x6f22)))

  (ios-test-deftest char-coverage-emoji
    "an emoji is displayable through the Apple Color Emoji fallback"
    ;; U+1F600 GRINNING FACE.
    (cl-assert (char-displayable-p ?\x1f600)))

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

  ;;; --- TLS --------------------------------------------------------
  ;; No live handshake here: a probe blocking in the GnuTLS C layer
  ;; against an unreachable network could hang the whole battery
  ;; before the results file is written.  Presence checks are
  ;; deterministic; real handshakes are exercised interactively
  ;; (package refresh).

  (ios-test-deftest tls-available
    "gnutls-available-p reports the linked GnuTLS stack"
    (cl-assert (gnutls-available-p)))

  (ios-test-deftest tls-trust-anchors
    "bundled ca-bundle.pem exists and gnutls-trustfiles points at it"
    (let ((bundle (expand-file-name "ca-bundle.pem" data-directory)))
      (cl-assert (file-readable-p bundle))
      ;; Loading gnutls.el triggers the ios-win.el trustfile setup.
      (require 'gnutls)
      (cl-assert (member bundle gnutls-trustfiles))
      ;; The bundle must actually parse as a non-empty PEM set.
      (with-temp-buffer
        (insert-file-contents bundle nil 0 4096)
        (cl-assert (search-forward "BEGIN CERTIFICATE" nil t)))))

  ;;; --- Documentation ----------------------------------------------

  (ios-test-deftest doc-strings-available
    "built-in docstrings resolve through the bundled DOC file"
    (cl-assert (stringp (documentation 'car))))

  (ios-test-deftest info-manuals-present
    "bundled Info directory exists and INFOPATH points at it"
    (let ((dir (getenv "INFOPATH")))
      (cl-assert (stringp dir))
      (cl-assert (file-exists-p (expand-file-name "dir" dir)))))

  ;;; --- Write the results -----------------------------------------

  (let ((path (expand-file-name "ios-test-results.txt" "~")))
    (with-temp-file path
      (insert (mapconcat #'identity (nreverse ios-test--out) "")))
    (message "ios-run-self-tests: wrote %s" path)))

;;; --- Font demo (visual, for CI screenshots) ----------------------
;;
;; The self-test battery grades things a screenshot cannot -- but
;; shaping and coverage are the reverse: only visible to the eye.
;; ios-show-font-demo fills a buffer with text that exercises Core
;; Text shaping (Arabic joining, Devanagari/Tamil conjuncts and vowel
;; reordering), script coverage (CJK, emoji), and the proportional /
;; bold / italic faces, so the simulator screenshot the workflow
;; captures can be eyeballed for correctness.  Strings are built from
;; explicit code points to keep this source pure ASCII.

(defun ios-show-font-demo ()
  "Display a buffer of shaped and non-Latin text for CI screenshots."
  (interactive)
  (let ((buf (get-buffer-create "*iOS Font Demo*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "iOS font rendering demo\n\n")
      ;; SF Mono has no coding ligatures, so these stay discrete; a
      ;; ligature-carrying font would join them.
      (insert "Ligatures: -> => != >= <= === =~ |>\n")
      ;; Arabic: letters must join into cursive forms (shaping).
      (insert (format "Arabic:     %s\n"
                      (string #x627 #x644 #x639 #x631 #x628 #x64a #x629)))
      ;; Hebrew: right-to-left, no joining.
      (insert (format "Hebrew:     %s\n"
                      (string #x5e2 #x5d1 #x5e8 #x5d9 #x5ea)))
      ;; Devanagari "namaste": virama forms the s-t conjunct.
      (insert (format "Devanagari: %s\n"
                      (string #x928 #x92e #x938 #x94d #x924 #x947)))
      ;; Tamil: the i vowel sign reorders before its consonant.
      (insert (format "Tamil:      %s\n"
                      (string #xba4 #xbae #xbbf #xbb4 #xbcd)))
      (insert (format "CJK:        %s\n"
                      (string #x6f22 #x5b57 #x4e2d #x6587)))
      (insert (format "Emoji:      %s\n"
                      (string #x1f600 #x1f389 #x2764)))
      (insert "\n")
      (insert (propertize "variable-pitch proportional text\n"
                          'face 'variable-pitch))
      (insert (propertize "bold weight\n" 'face 'bold))
      (insert (propertize "italic slant\n" 'face 'italic))
      (goto-char (point-min)))
    (switch-to-buffer buf)))

(provide 'ios-tests)
;;; ios-tests.el ends here
