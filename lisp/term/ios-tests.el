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

;; Battery of correctness checks for the iOS port.  Each check writes
;; one PASS, FAIL or SKIP line into ~/ios-test-results.txt, so an
;; automated run can grep the file and fail on any FAIL.  The checks
;; are self-contained -- no network and no UI interaction -- so they
;; can run unattended in a simulator.

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

  (ios-test-deftest char-coverage-bengali
    "Bengali resolves through the script fontset fallback"
    (cl-assert (char-displayable-p ?\x0985)))     ; BENGALI LETTER A

  (ios-test-deftest char-coverage-telugu
    "Telugu resolves through the script fontset fallback"
    (cl-assert (char-displayable-p ?\x0c05)))     ; TELUGU LETTER A

  (ios-test-deftest font-named-family-opens
    "a named family (Courier) resolves to a real font"
    (cl-assert (find-font (font-spec :family "Courier"))))

  (ios-test-deftest font-default-is-fixed-pitch
    "the default face renders fixed-pitch: i and W measure the same"
    ;; Exercises the monospaced text-extents fast path end to end.
    (cl-assert (= (string-pixel-width "iiiiiiii")
                  (string-pixel-width "WWWWWWWW"))))

  (ios-test-deftest font-variable-pitch-is-proportional
    "variable-pitch renders proportional: W is wider than i"
    ;; Proves real per-glyph Core Text advances, not a monospace cell.
    (cl-assert (> (string-pixel-width
                   (propertize "WWWWWWWW" 'face 'variable-pitch))
                  (string-pixel-width
                   (propertize "iiiiiiii" 'face 'variable-pitch)))))

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

  ;;; --- Hardware key translation -----------------------------------

  ;; `ios-translate-key' runs the same translation a real key press
  ;; goes through, so these cover the hardware keyboard path on a
  ;; simulator that has none attached.  HID usages and modifier masks
  ;; are written out rather than named, since UIKit's constants are
  ;; not visible from Lisp.

  (let ((hid-a 4) (hid-comma 54) (hid-f 9)
        (hid-escape 41) (hid-tab 43) (hid-return 40) (hid-left 80)
        (shift 131072) (control 262144) (option 524288))
    (cl-flet ((xlate (&rest args) (apply #'ios-translate-key args)))

      (ios-test-deftest key-escape-is-esc
        "Escape yields ESC, not the first letter of UIKeyInputEscape"
        ;; UIKit reports the placeholder name as the key's characters;
        ;; reading its first letter would produce `U'.
        (cl-assert (equal '(ascii 27 0)
                          (xlate hid-escape 0
                                 "UIKeyInputEscape" "UIKeyInputEscape"))))

      (ios-test-deftest key-tab-and-return
        "Tab and Return yield their control codes"
        (cl-assert (equal '(ascii 9 0) (xlate hid-tab 0)))
        (cl-assert (equal '(ascii 13 0) (xlate hid-return 0))))

      (ios-test-deftest key-arrow-is-function-key
        "Left arrow yields the XK_Left keysym as a non-ASCII event"
        (cl-assert (equal '(non-ascii #xff51 0) (xlate hid-left 0))))

      (ios-test-deftest key-plain-letter
        "an unmodified letter passes through"
        (cl-assert (equal (list 'ascii ?a 0) (xlate hid-a 0 "a" "a"))))

      (ios-test-deftest key-control-letter-folds
        "C-a folds to 1, and Shift does not change that"
        (cl-assert (equal '(ascii 1 0) (xlate hid-a control "a" "a")))
        (cl-assert (equal '(ascii 1 0)
                          (xlate hid-a (logior control shift) "A" "a"))))

      (ios-test-deftest key-option-is-meta-when-asked
        "with ios-option-modifier meta, Option-f is M-f"
        ;; -characters reports the Option layer's florin sign here, so
        ;; the base character has to come from the other string.
        (let ((ios-option-modifier 'meta))
          (let ((r (xlate hid-f option (string #x192) "f")))
            (cl-assert (eq 'ascii (nth 0 r)))
            (cl-assert (= ?f (nth 1 r)))
            (cl-assert (/= 0 (logand (nth 2 r) (ash 1 27)))))))

      (ios-test-deftest key-option-default-keeps-layer
        "by default Option enters the layer glyph on an ordinary key"
        (let ((r (xlate hid-f option (string #x192) "f")))
          (cl-assert (= #x192 (nth 1 r)))
          (cl-assert (= 0 (logand (nth 2 r) (ash 1 27))))))

      (ios-test-deftest key-option-default-takes-shifted-char
        "by default the character comes from the shifted string"
        ;; With Option left to the layout there is no reason to read
        ;; the unshifted string, which would report a comma here.
        (let ((r (xlate hid-comma (logior option shift) "<" ",")))
          (cl-assert (= ?< (nth 1 r)))
          (cl-assert (= 0 (logand (nth 2 r) (ash 1 27))))))

      (ios-test-deftest key-option-plist-per-kind
        "the plist form applies per event kind"
        (let ((ios-option-modifier (list :function 'meta)))
          ;; A function key takes Meta ...
          (let ((r (xlate hid-left option nil nil)))
            (cl-assert (eq 'non-ascii (nth 0 r)))
            (cl-assert (/= 0 (logand (nth 2 r) (ash 1 27)))))
          ;; ... while an ordinary key is left to the layout.
          (let ((r (xlate hid-f option (string #x192) "f")))
            (cl-assert (= #x192 (nth 1 r)))
            (cl-assert (= 0 (logand (nth 2 r) (ash 1 27)))))))

      (ios-test-deftest key-control-keeps-shift
        "Control combinations keep the shifted character"
        ;; -charactersIgnoringModifiers is always unshifted, so using
        ;; it for Control would turn C-< into C-comma.
        (cl-assert (equal (list 'ascii ?< (ash 1 26))
                          (xlate hid-comma (logior control shift)
                                 "<" ","))))

      (ios-test-deftest key-extra-keyboard-modifiers
        "extra-keyboard-modifiers is merged in"
        (let ((extra-keyboard-modifiers (ash 1 27)))
          (cl-assert (/= 0 (logand (nth 2 (xlate hid-a 0 "a" "a"))
                                   (ash 1 27))))))

      (ios-test-deftest key-modifier-only-press
        "a press with neither key code nor character yields nothing"
        (cl-assert (null (xlate 0 option))))

      ;; The accessory bar stays on screen with a hardware keyboard
      ;; attached, so a modifier latched there is taken by the next
      ;; key from either keyboard.

      (ios-test-deftest key-latched-ctrl-reaches-hardware
        "a latched Ctrl folds a hardware letter to its control code"
        (cl-assert (equal '(ascii 1 0)
                          (xlate hid-a 0 "a" "a" (ash 1 26)))))

      (ios-test-deftest key-latched-meta-reaches-hardware
        "a latched Meta sets Meta on a hardware letter"
        (let ((r (xlate hid-a 0 "a" "a" (ash 1 27))))
          (cl-assert (= ?a (nth 1 r)))
          (cl-assert (/= 0 (logand (nth 2 r) (ash 1 27))))))

      (ios-test-deftest key-latched-modifier-on-function-key
        "a latched modifier reaches a function key too"
        (let ((r (xlate hid-left 0 nil nil (ash 1 27))))
          (cl-assert (eq 'non-ascii (nth 0 r)))
          (cl-assert (= #xff51 (nth 1 r)))
          (cl-assert (/= 0 (logand (nth 2 r) (ash 1 27))))))

      (ios-test-deftest key-latched-combines-with-held
        "a latched Meta combines with a Control held on the keyboard"
        (let ((r (xlate hid-a control "a" "a" (ash 1 27))))
          (cl-assert (= 1 (nth 1 r)))
          (cl-assert (/= 0 (logand (nth 2 r) (ash 1 27))))))))

  ;;; --- Write the results -----------------------------------------

  (let ((path (expand-file-name "ios-test-results.txt" "~")))
    (with-temp-file path
      (insert (mapconcat #'identity (nreverse ios-test--out) "")))
    (message "ios-run-self-tests: wrote %s" path)))

;;; --- Font demo (visual) ------------------------------------------
;;
;; Shaping and script coverage are hard to grade programmatically but
;; obvious on sight.  `ios-show-font-demo' fills a buffer with text
;; exercising Core Text shaping (Arabic joining, Devanagari and Tamil
;; conjuncts and vowel reordering), script coverage (CJK, emoji) and
;; the proportional, bold and italic faces, so a screenshot can be
;; inspected for correctness.  Strings are built from explicit code
;; points to keep this source pure ASCII.

(defun ios-show-font-demo ()
  "Display a buffer of shaped and non-Latin text for visual inspection."
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
