;;;; lisp-markup.el
;;;; Charles Jackson
(require 'sgml-mode)
(require 'lisp-mode)

(defvar lisp-markup-minor-mode-map
  (let ((keymap (make-keymap)))
    (define-key keymap (kbd "/") #'lisp-markup-/-close-tag)
    (define-key keymap (kbd "C-c C-o") #'sgml-tag)
    (define-key keymap (kbd "<return>") #'newline-and-indent)
    keymap)
  "Additional key bindings for `lisp-markup-minor-mode'.")

(defvar lisp-markup-sgml-tag-syntax-table
  (let ((table (make-syntax-table sgml-tag-syntax-table)))
    (modify-syntax-entry ?' "." table)
    (modify-syntax-entry 40 "|" table)
    (modify-syntax-entry 41 "|" table)
    table)
  "A modified `sgml-tag-syntax-table' that effectively ignores
content between ?( and ?) by mapping them to symbol-escape
characters. Additionally maps ?' to be a punctuation character
which separates symbols.")

(defvar *lisp-markup-mode-keywords*
  '(("</?\\(:[^>/=[:space:]]+\\)" 1 font-lock-builtin-face)
    ;; regular tag names
    ("</?\\([^!>/=[:space:]]*\\)" 1 font-lock-function-name-face)
    ;; attribute names
    ("[[:space:]]\\([-[:alpha:]]+\\)=" 1 font-lock-constant-face)
    ;; deftag faces
    ("(\\(deftag\\)" 1 font-lock-keyword-face)
    ("(deftag \\([^ ]+\\) " 1 font-lock-function-name-face)
    ;; warning about single symbol lisp forms at the end of tags
    ("=[^[:space:]<>]+[^\"/) ]\\(/\\|>\\)" 1 font-lock-warning-face))
  "`font-lock' configuration for `lisp-markup-minor-mode' to
provide highlighting to HTML code within lisp files.")

(define-minor-mode lisp-markup-minor-mode
  "Enhance `lisp-mode' with additional features to support embedded HTML markup.

This changes syntax highlighting, indentation rules, and adds
some extra keybindings to make editing of markup in lisp files
easier."
  :lighter " markup"
  :keymap lisp-markup-minor-mode-map
  (if (eq major-mode 'lisp-mode)
      (if lisp-markup-minor-mode
          (enter-lisp-markup-minor-mode)
        (exit-lisp-markup-minor-mode))
    (progn
      (setf lisp-markup-minor-mode nil)
      (error "lisp-markup-minor-mode only supports running in lisp-mode"))))

(defun lisp-markup--font-lock-update ()
  (unless (version< emacs-version "28.1")
    (font-lock-update)))

(defun enter-lisp-markup-minor-mode ()
  "Perform the setup required by `lisp-markup-minor-mode'."
  (font-lock-add-keywords nil *lisp-markup-mode-keywords*)
  (lisp-markup--font-lock-update)
  (setq-local indent-line-function #'lisp-markup-indent-line
              indent-region-function #'indent-region-line-by-line ; Less efficient, but still correct
              forward-sexp-function #'lisp-markup-forward-sexp
              comment-region-function #'lisp-markup-comment-region
              syntax-propertize-function lisp-markup-syntax-propertize-function)
  (sgml-electric-tag-pair-mode 1))

(defun exit-lisp-markup-minor-mode ()
  "Undo the setup performed by `enter-lisp-markup-minor-mode'."
  (font-lock-remove-keywords nil *lisp-markup-mode-keywords*)
  (lisp-markup--font-lock-update)
  (setq-local indent-line-function #'lisp-indent-line
              indent-region-function #'lisp-indent-region
              forward-sexp-function nil
              comment-region-function #'comment-region-default
              syntax-propertize-function nil)
  (sgml-electric-tag-pair-mode -1))

(defvar lisp-markup-syntax-propertize-function
  (syntax-propertize-rules
   ("\\(<\\)!--" (1 "< b"))
   ("--[ \t\n]*\\(>\\)" (1 "> b"))
   ("\\(<\\)[?!]" (1 (prog1 "|>"
                       (sgml-syntax-propertize-inside end)))))
  "Function to apply syntax-propertize rules for mixed Lisp and HTML.

This handles adding the required syntax properties to HTML
comments embedded in Lisp code. This is mostly just stolen from
sgml-mode.")

(defun lisp-marker-infer-comment-settings (&optional noerror)
  "Infer the right comment characters when in `lisp-markup-minor-mode'.

This handles checking if we're in Lisp mode or HTML mode, and
setting `comment-start' and `comment-end' appropriately."
  (when lisp-markup-minor-mode ; Having this lets us use this as global advice on `comment-normalize-vars'
    (if (lisp-markup-in-html-p)
        (setq-local comment-start "<!-- "
                    comment-end " -->")
      (setq-local comment-start ";"
                  comment-end ""))))

(advice-add 'comment-normalize-vars :before #'lisp-marker-infer-comment-settings)

(defmacro lisp-markup-with-<>-as-brackets (&rest body)
  "Run BODY in a context where ?< and ?> behave as brackets, and ?(
and ?) behave as string delimiters. This is useful to run SGML
functions on code that contains both Lisp and HTML."
  (declare (indent 0))
  `(with-syntax-table (make-syntax-table (syntax-table))
     (modify-syntax-entry ?< "(")
     (modify-syntax-entry ?> ")")
     (modify-syntax-entry 40 "\"")
     (modify-syntax-entry 41 "\"")
     (progn ,@body)))

(defmacro lisp-markup-with-all-brackets (&rest body)
  "Run BODY in a context where ?< and ?> behave as brackets."
  (declare (indent 0))
  `(with-syntax-table (make-syntax-table (syntax-table))
     (modify-syntax-entry ?< "(")
     (modify-syntax-entry ?> ")")
     (progn ,@body)))

(defmacro lisp-markup-with-sgml-tag-table (&rest body)
  "Run BODY in a context where `sgml-tag-syntax-table' is resolved
to be our custom syntax table. This allows us to run SGML
functions which internally change the syntax table without them
getting confused by Lisp code.."
  `(let ((sgml-tag-syntax-table lisp-markup-sgml-tag-syntax-table))
     ,@body))

;;; Determining context
;;; ===================

(defun lisp-markup-in-html-p ()
  "Check if point is currently in an HTML context."
  (let ((html (lisp-markup-enclosing-html-tag)))
    (when html
      (let ((lisp (lisp-markup-enclosing-lisp-section)))
        (and (<= (car lisp) (car html))
             (<= (cdr html) (cdr lisp)))))))

(defun lisp-markup-find-enclosing (find-start goto-end not-found)
  "Find the nearest enclosing \"section\" defined by FIND-START and GOTO-END.

This function looks backwards in the buffer to find the start of
the nearest section by calling FIND-START. This function defines
what the start of a section is by moving point to be before the
first character of a section. This will often involve a call to
`search-backward-regexp' or similar. If FIND-START throws an
error the search will end and NOT-FOUND will be returned.

Once the start of a section has been found, GOTO-END will be
called to move point to the end of this section. If GOTO-END
throws an error, `point-max' will be used as the end value.

Returns a pair of beginning and end points, or NOT-FOUND."
  (save-excursion
    (catch 'return
      (let ((initial (point)))
        (while t
          (let* ((start (or (ignore-errors
                              (funcall find-start)
                              (while (or (nth 3 (syntax-ppss)) ; is in a string
                                         (nth 4 (syntax-ppss))) ; is in a comment
                                (funcall find-start)) ; so keep looking
                              (point))
                            (throw 'return not-found)))
                 (end (or (ignore-errors
                            (funcall goto-end)
                            (point))
                          (throw 'return (cons start (point-max))))))
            (when (and (<= start initial)
                       (< initial end))
              (throw 'return (cons start end)))
            ;; Reset for the next iteration
            (goto-char start)))))))

(defun lisp-markup-enclosing-lisp-section ()
  "Find the nearest enclosing Lisp section.

This function looks backwards in the buffer to find the start of
the nearest Lisp section, then looks forwards to find its end. If
no start/end is found, returns the values of `point-min' and
`point-max' as the beginning and end, respectively.

Returns a pair of beginning and end points."
  (lisp-markup-find-enclosing
   (lambda ()
     (search-backward-regexp ",(\\|,@\\|=("))
   (lambda ()
     (skip-chars-forward "=,@")
     (forward-sexp))
   (cons (point-min) (point-max))))

(defun lisp-markup-enclosing-html-tag ()
  "Find the nearest enclosing HTML tag.

This function looks backwards in the buffer to find the start of
the nearest HTML section, then looks forwards to find its end.

Returns a pair of beginning and end points. If no end is found,
returns a pair of start and `point-max'. If no start is found,
returns nil."
  (lisp-markup-find-enclosing
   (lambda ()
     (search-backward-regexp "<[^/=![:space:]()]"))
   (lambda ()
     (lisp-markup-with-sgml-tag-table
      (or (sgml-skip-tag-forward 1)
          (error "No end tag found!"))))
   nil))

(defun lisp-markup-enclosing-html-boundary ()
  "Find the nearest boundary between HTML and Lisp sections."
  (save-excursion
    (catch 'return
      (let (html)
        (while t
          (let ((tag (lisp-markup-enclosing-html-tag)))
            (if tag
                (setf html tag)
              (throw 'return html)))
          (goto-char (car html)))))))

;;; Indentation
;;; ===========

(defun lisp-markup-calculate-html-indent ()
  "Calculate the number of spaces to indent the current line in an
HTML context."
  (let ((html (lisp-markup-enclosing-html-boundary)))
    (+ (save-excursion
         (save-restriction
           ;; There are some non-obvious effects created by having
           ;; indented HTML earlier in the file, or by having HTML
           ;; tags start later in a line (i.e. after some Lisp).
           ;; Narrowing to the HTML boundary here avoids those
           ;; effects, but causes indentation to start in column 0.
           ;; The below term adds to the indentation to compensate.
           (narrow-to-region (car html) (cdr html))
           (lisp-markup-with-sgml-tag-table
            (lisp-markup-with-<>-as-brackets
              (sgml-calculate-indent)))))
       ;; If we're on the last line, or the second non-blank line, of
       ;; the HTML section then add extra indentation to align with
       ;; the start of the HTML section.
       (let ((second-line (save-excursion
                            (goto-char (car html))
                            (forward-line)
                            (beginning-of-line)
                            (while (looking-at-p "[[:space:]]*$")
                              (forward-line))
                            (line-number-at-pos (point))))
             (last-line (line-number-at-pos (cdr html))))
         (or (when (or (<= (line-number-at-pos (point))
                           second-line)
                       (>= (line-number-at-pos (point))
                           last-line))
               (save-excursion
                 (goto-char (car html))
                 (current-column)))
             0)))))

(defun lisp-markup-indent-line ()
  "Indent a line of Lisp or HTML, according to the line's context."
  (interactive)
  (save-excursion
    (back-to-indentation)
    (if (lisp-markup-in-html-p)
        (indent-line-to (lisp-markup-calculate-html-indent))
      (let ((indent (calculate-lisp-indent)))
        (when indent
          (indent-line-to (if (listp indent)
                              (car indent)
                            indent))))))
  (when (< (point) (save-excursion (back-to-indentation) (point)))
    (back-to-indentation)))

;;; Comments
;;; ========

(defun lisp-markup-comment-region (beg end &optional arg)
  "Comment region in the way you'd expect, depending on the context of BEG."
  (save-excursion
    (goto-char beg)
    (lisp-marker-infer-comment-settings))
  (comment-region-default beg end arg))

;;; Forward/backward by sexp
;;; ========================

(defun lisp-markup-run-without-forward-sexp-function (f &rest args)
  "Apply F to ARGS with `forward-sexp-function' set to NIL, if
`lisp-markup-minor-mode' is true. Otherwise, just apply F to ARGS
normally."
  (if lisp-markup-minor-mode
      (lisp-markup-with-all-brackets
        (let ((forward-sexp-function nil))
          (apply f args)))
    (apply f args)))

(advice-add 'up-list :around #'lisp-markup-run-without-forward-sexp-function)
(advice-add 'slime-parse-form-until :around #'lisp-markup-run-without-forward-sexp-function)

(defun lisp-markup-forward-sexp (&optional n interactive)
  "Move over the next \"sexp\" in the buffer, which includes an entire HTML tag.

This mostly tries to guess if the next thing is HTML or Lisp by
looking at the beginning of it. It's not foolproof, but it's
still pretty useful."
  (let ((n (or n 1)))
    (while (not (zerop n))
      (cond
       ((< 0 n)
        (if (looking-at-p "[[:space:]\n]*<[^/=\"![:space:]()]")
	    (lisp-markup-with-sgml-tag-table
             (sgml-skip-tag-forward 1))
          (let ((forward-sexp-function nil))
            (forward-sexp 1 interactive)))
        (setf n (1- n)))
       ((< n 0)
        (if (save-excursion (let ((whitespace-chars (string-to-list " \t\r\n")))
                              (while (member (char-before) whitespace-chars)
                                (backward-char)))
                            (backward-char 2)
                            (looking-at-p "[^[:space:]'()]>"))
	    (lisp-markup-with-sgml-tag-table
             (sgml-skip-tag-backward 1))
          (let ((forward-sexp-function nil))
            (forward-sexp -1 interactive)))
        (setf n (1+ n)))))))

;;; Automatic tag closing
;;; =====================

(defun lisp-markup-html-closed-p ()
  "Test whether the current HTML tag has a corresponding closing tag.

This method must be called with point before the opening < of a tag."
  (save-excursion
    (lisp-markup-with-sgml-tag-table
     (when (sgml-skip-tag-forward 1)
       (point)))))

(defun lisp-markup-find-unclosed-tag-name ()
  "This function only looks backwards to find unclosed tags, and
thus a tag that is closed further forwards in the file will not
be considered as being closed. Hence in an example like this:

  <div>
    <span></span>
    |
  </div>

with point at |, \"div\" will be returned."
  (let ((html (lisp-markup-enclosing-html-tag)))
    (if html
        (save-excursion
          (goto-char (car html))
          (buffer-substring-no-properties
           (+ (point) 1)
           (- (search-forward-regexp "[>/[:space:]]") 1)))
      (error "No HTML tag found to close"))))

(defun lisp-markup-html-close-tag ()
  "Insert a closing tag for the nearest tag before point that is unclosed.

This function only looks backwards to find unclosed tags, and
thus a tag that is closed further forwards in the file will not
be considered as being closed. Hence in an example like this:

  <div>
    <span></span>
    |
  </div>

with point at |, a </div> will be inserted."
  (interactive)
  (insert "</" (lisp-markup-find-unclosed-tag-name) ">"))

(defun lisp-markup-/-close-tag ()
  "Automatically insert a closing tag if this character was typed
after a <. Otherwise, just insert a /."
  (interactive)
  (insert "/")
  (when (save-excursion (backward-char 2)
                        (looking-at-p "</"))
    (insert (lisp-markup-find-unclosed-tag-name))
    (unless (looking-at-p ">")
      (insert ">"))
    (lisp-markup-indent-line)))

(defun lisp-markup--lisp-mode-hook ()
  "Detect if this Lisp file looks like a markup file, if so enable
 the minor mode."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           "^(\\(markup:enable-reader\\|named-readtables:in-readtable.*markup:syntax\\))"
           nil t)
      (lisp-markup-minor-mode))))

(add-hook 'lisp-mode-hook #'lisp-markup--lisp-mode-hook)

(provide 'lisp-markup)
;;; lisp-markup.el ends here
