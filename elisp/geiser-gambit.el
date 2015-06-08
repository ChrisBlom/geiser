;; geiser-gambit.el -- gambit's implementation of the geiser protocols

;; Copyright (C) 2015 Chris Blom

;; Based on geiser-chicken.el by Daniel Leslie

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the Modified BSD License. You should
;; have received a copy of the license along with this program. If
;; not, see <http://www.xfree86.org/3.3.6/COPYRIGHT2.html#5>.

(require 'geiser-connection)
(require 'geiser-syntax)
(require 'geiser-custom)
(require 'geiser-base)
(require 'geiser-eval)
(require 'geiser-edit)
(require 'geiser-log)
(require 'geiser)

(require 'compile)
(require 'info-look)

(eval-when-compile (require 'cl))


(defconst geiser-gambit-builtin-keywords
  '("##debug-repl"))

;;; Customization:

(defgroup geiser-gambit nil
  "Customization for Geiser's Gambit flavour."
  :group 'geiser)

(geiser-custom--defcustom geiser-gambit-binary
  (cond ((eq system-type 'windows-nt) "gsi.exe")
        ((eq system-type 'darwin) "gsi")
        (t "gsi"))
  "Name to use to call the Gambit executable when starting a REPL."
  :type '(choice string (repeat string))
  :group 'geiser-gambit)

(geiser-custom--defcustom geiser-gambit-load-path nil
  "A list of paths to be added to Gambit's load path when it's
started."
  :type '(repeat file)
  :group 'geiser-gambit)

(geiser-custom--defcustom geiser-gambit-compile-geiser-p t
  "Non-nil means that the Geiser runtime will be compiled on load."
  :type 'boolean
  :group 'geiser-gambit)

(geiser-custom--defcustom geiser-gambit-init-file "~/.gambit-geiser"
  "Initialization file with user code for the Gambit REPL.
If all you want is to load ~/.csirc, set
`geiser-gambit-load-init-file-p' instead."
  :type 'string
  :group 'geiser-gambit)

(geiser-custom--defcustom geiser-gambit-load-init-file-p nil
  "Whether to load ~/.gambit when starting Gambit.
Note that, due to peculiarities in the way Gambit loads its init
file, using `geiser-gambit-init-file' is not equivalent to setting
this variable to t."
  :type 'boolean
  :group 'geiser-gambit)

(geiser-custom--defcustom geiser-gambit-extra-keywords nil
  "Extra keywords highlighted in Gambit scheme buffers."
  :type '(repeat string)
  :group 'geiser-gambit)

(geiser-custom--defcustom geiser-gambit-case-sensitive-p t
  "Non-nil means keyword highlighting is case-sensitive."
  :type 'boolean
  :group 'geiser-gambit)


;;; REPL support:

(defun geiser-gambit--binary ()
  (if (listp geiser-gambit-binary)
      (car geiser-gambit-binary)
    geiser-gambit-binary))

(defun geiser-gambit--parameters ()
  "Return a list with all parameters needed to start Gambit.
This function uses `geiser-gambit-init-file' if it exists."
  (let ((init-file (and (stringp geiser-gambit-init-file)
                        (expand-file-name geiser-gambit-init-file)))
        (n-flags (when (not geiser-gambit-load-init-file-p) '("-f"))))
  `(,@(and (listp geiser-gambit-binary) (cdr geiser-gambit-binary))
    ,@n-flags "-e" ,(format "(include \"%semacs.scm\")" (expand-file-name "gambit/" geiser-scheme-dir))
    ,@(apply 'append (mapcar (lambda (p) (list "-include-path" p))
                             geiser-gambit-load-path))
    ,@(and init-file (file-readable-p init-file) (list init-file))
    "-"
    )))

; (geiser-gambit--parameters)

(defun geiser-gambit--parameters () '("-:d-"))

; (run-geiser 'gambit)

(defconst geiser-gambit--prompt-regexp "[0-9]*> ")

;;; Evaluation support:

(defun geiser-gambit--geiser-procedure (proc &rest args)
  (let ((fmt
         (case proc
           ((eval compile)
            (let ((form (mapconcat 'identity (cdr args) " ")))
              (format ",geiser-eval %s %s" (or (car args) "#f") form)))
           ((load-file compile-file)
            (format ",geiser-load-file %s" (car args)))
           ((no-values)
            ",geiser-no-values")
           (t
            (let ((form (mapconcat 'identity args " ")))
              (format "(geiser-%s %s)" proc form))))))
    ;;(message fmt)
    fmt))

(defconst geiser-gambit--module-re
  "( *module +\\(([^)]+)\\|[^ ]+\\)\\|( *define-library +\\(([^)]+)\\|[^ ]+\\)")

(defun geiser-gambit--get-module (&optional module)
  (cond ((null module)
         (save-excursion
           (geiser-syntax--pop-to-top)
           (if (or (re-search-backward geiser-gambit--module-re nil t)
                   (looking-at geiser-gambit--module-re)
                   (re-search-forward geiser-gambit--module-re nil t))
               (geiser-gambit--get-module (match-string-no-properties 1))
             :f)))
        ((listp module) module)
        ((stringp module)
         (condition-case nil
             (car (geiser-syntax--read-from-string module))
           (error :f)))
        (t :f)))

(defun geiser-gambit--module-cmd (module fmt &optional def)
  (when module
    (let* ((module (geiser-gambit--get-module module))
           (module (cond ((or (null module) (eq module :f)) def)
                         (t (format "%s" module)))))
      (and module (format fmt module)))))

(defun geiser-gambit--import-command (module)
  (geiser-gambit--module-cmd module "(use %s)"))

(defun geiser-gambit--enter-command (module)
  (geiser-gambit--module-cmd module ",m %s" module))

(defun geiser-gambit--exit-command () ",q")

(defun geiser-gambit--symbol-begin (module)
  (save-excursion (skip-syntax-backward "^-()>") (point)))

;;; Error display

(defun geiser-gambit--display-error (module key msg)
  (newline)
  (when (stringp msg)
    (save-excursion (insert msg))
    (geiser-edit--buttonize-files))
  (and (not key) msg (not (zerop (length msg)))))

;;; Trying to ascertain whether a buffer is Gambit Scheme:

(defconst geiser-gambit--guess-re
  (regexp-opt (append '("gsi" "gambit") geiser-gambit-builtin-keywords)))

(defun geiser-gambit--guess ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward geiser-gambit--guess-re nil t)))

(defun geiser-gambit--external-help (id module)
  "Loads gambit doc into a buffer"
  (browse-url (format "http://api.call-cc.org/cdoc?q=%s&query-name=Look+up" id)))

;;; Keywords and syntax

(defun geiser-gambit--keywords ()
  `((,(format "[[(]%s\\>" (regexp-opt geiser-gambit-builtin-keywords 1)) . 1)))

(geiser-syntax--scheme-indent
 (receive 2)
 (match 1)
 (match-lambda 0)
 (match-lambda* 0)
 (match-let scheme-let-indent)
 (match-let* 1)
 (match-letrec 1)
 (declare 0)
 (cond-expand 0)
 (let-values scheme-let-indent)
 (let*-values scheme-let-indent)
 (letrec-values 1)
 (letrec* 1)
 (parameterize scheme-let-indent)
 (let-location 1)
 (foreign-lambda 2)
 (foreign-lambda* 2)
 (foreign-primitive 2)
 (foreign-safe-lambda 2)
 (foreign-safe-lambda* 2)
 (set! 1)
 (let-optionals* 2)
 (let-optionals 2)
 (condition-case 1)
 (fluid-let 1)
 (and-let* 1)
 (assume 1)
 (cut 1)
 (cute 1)
 (when 1)
 (unless 1)
 (dotimes 1)
 (compiler-typecase 1)
 (ecase 1)
 (use 0)
 (require-extension 0)
 (import 0)
 (handle-exceptions 2)
 (regex-case 1)
 (define-inline 1)
 (define-constant 1)
 (define-syntax-rule 1)
 (define-record-type 1)
 (define-values 1)
 (define-record 1)
 (define-specialization 1)
 (define-type 1)
 (with-input-from-pipe 1)
 (select 1)
 (functor 3)
 (define-interface 1)
 (module 2))

;;; REPL startup

(defconst geiser-gambit-minimum-version "v4.7.3")

(defun geiser-gambit--version (binary)
  (shell-command-to-string (format "%s -e \"(display (##system-version-string))\""
                                   binary)))

(defun connect-to-gambit ()
  "Start a Gambit REPL connected to a remote process."
  (interactive)
  (geiser-connect 'gambit))

(defun geiser-gambit--startup (remote)
  (compilation-setup t)
  (let ((geiser-log-verbose-p t)
        (geiser-gambit-load-file (expand-file-name "gambit/geiser/emacs.scm" geiser-scheme-dir)))
    (if geiser-gambit-compile-geiser-p
      (geiser-eval--send/wait (format "(use utils)(compile-file \"%s\")(import geiser)"
                                      geiser-gambit-load-file))
      (geiser-eval--send/wait (format "(load \"%s\")"
                                      geiser-gambit-load-file)))))

;;; Implementation definition:

(define-geiser-implementation gambit
  (unsupported-procedures '(callers callees generic-methods))
  (binary geiser-gambit--binary)
  (arglist geiser-gambit--parameters)
  (version-command geiser-gambit--version)
  (minimum-version geiser-gambit-minimum-version)
  (repl-startup geiser-gambit--startup)
  (prompt-regexp geiser-gambit--prompt-regexp)
  (debugger-prompt-regexp nil)
  (enter-debugger nil)
  (marshall-procedure geiser-gambit--geiser-procedure)
  (find-module geiser-gambit--get-module)
  (enter-command geiser-gambit--enter-command)
  (exit-command geiser-gambit--exit-command)
  (import-command geiser-gambit--import-command)
  (find-symbol-begin geiser-gambit--symbol-begin)
  (display-error geiser-gambit--display-error)
  (external-help geiser-gambit--external-help)
  (check-buffer geiser-gambit--guess)
  (keywords geiser-gambit--keywords)
  (case-sensitive geiser-gambit-case-sensitive-p))

(geiser-impl--add-to-alist 'regexp "\\.scm$" 'gambit t)
(geiser-impl--add-to-alist 'regexp "\\.release-info$" 'gambit t)
(geiser-impl--add-to-alist 'regexp "\\.meta$" 'gambit t)
(geiser-impl--add-to-alist 'regexp "\\.setup$" 'gambit t)

(provide 'geiser-gambit)
