;;; minicomp.el --- Minimalistic vertical minibuffer completion system -*- lexical-binding: t -*-

;; Author: Daniel Mendler
;; Maintainer: Daniel Mendler
;; Created: 2021
;; License: GPL-3.0-or-later
;; Version: 0.1
;; Package-Requires: ((emacs "27"))
;; Homepage: https://github.com/minad/minicomp

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a vertical completion system, which is based on the
;; default completion system. By reusing the default system, we achieve full
;; compatibility with built-in Emacs commands and completion tables. The
;; completion system is pretty bare-bone and only provides a minimal set of
;; commands.

;;; Code:

(require 'seq)
(eval-when-compile
  (require 'subr-x))

(defgroup minicomp nil
  "Minimal completion system."
  :group 'convenience
  :prefix "minicomp-")

(defcustom minicomp-sort-threshold 20000
  "Candidates will only be sorted if there are fewer than this threshold."
  :type 'integer)

(defcustom minicomp-count-format
  (cons "%-6s " "%s/%s")
  "Format string used for the candidate count."
  :type '(choice (const nil) (cons string string)))

(defcustom minicomp-group-format
  (concat
   #("    " 0 4 (face minicomp-group-separator))
   #(" %s " 0 4 (face minicomp-group-title))
   #(" " 0 1 (face minicomp-group-separator display (space :align-to right))))
  "Format string used for the group title."
  :type '(choice (const nil) string))

(defcustom minicomp-count 10
  "Maximal number of candidates to show."
  :type 'integer)

(defgroup minicomp-faces nil
  "Faces used by Minicomp."
  :group 'minicomp
  :group 'faces)

(defface minicomp-group-title
  '((t :inherit shadow :slant italic))
  "Face used for the title text of the candidate group headlines.")

(defface minicomp-group-separator
  '((t :inherit shadow :strike-through t))
  "Face used for the separator lines of the candidate groups.")

(defface minicomp-current
  '((t :inherit highlight :extend t))
  "Face used to highlight the currently selected candidate.")

(defvar minicomp-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map [remap beginning-of-buffer] #'minicomp-beginning-of-buffer)
    (define-key map [remap minibuffer-beginning-of-buffer] #'minicomp-beginning-of-buffer)
    (define-key map [remap end-of-buffer] #'minicomp-end-of-buffer)
    (define-key map [remap scroll-down-command] #'minicomp-scroll-down)
    (define-key map [remap scroll-up-command] #'minicomp-scroll-up)
    (define-key map [remap next-line] #'minicomp-next)
    (define-key map [remap previous-line] #'minicomp-previous)
    (define-key map [remap next-line-or-history-element] #'minicomp-next)
    (define-key map [remap previous-line-or-history-element] #'minicomp-previous)
    (define-key map [remap exit-minibuffer] #'minicomp-exit)
    (define-key map [remap kill-ring-save] #'minicomp-save)
    (define-key map [C-return] #'minicomp-exit-input)
    (define-key map "\t" #'minicomp-insert)
    map)
  "Minibuffer keymap.")

(defvar minicomp--highlight-function (lambda (_input _metadata cands) cands)
  "Highlighting function.")

(defvar-local minicomp--history-hash nil
  "History hash table.")

(defvar-local minicomp--history-dir nil
  "Directory of `minicomp--history-hash'.")

(defvar-local minicomp--candidates-ov nil
  "Overlay showing the candidates.")

(defvar-local minicomp--count-ov nil
  "Overlay showing the number of candidates.")

(defvar-local minicomp--index 0
  "Index of current candidate or negative for prompt selection.")

(defvar-local minicomp--input nil
  "Current input string or t.")

(defvar-local minicomp--candidates nil
  "List of candidates.")

(defvar-local minicomp--base 0
  "Size of the base string, which is concatenated with the candidate.")

(defvar-local minicomp--total 0
  "Length of the candidate list `minicomp--candidates'.")

(defvar-local minicomp--keep nil
  "Keep current candidate index `minicomp--index'.")

(defun minicomp--pred (x y)
  "Compare X and Y."
  (or (< (cdr x) (cdr y))
      (and (= (cdr x) (cdr y))
           (string< (car x) (car y)))))

(defun minicomp--sort (input candidates)
  "Sort CANDIDATES by history position, length and alphabetically, given current INPUT."
  ;; Store the history position first in a hashtable in order to allow O(1) history lookup. File
  ;; names get special treatment. In principle, completion tables with boundaries should also get
  ;; special treatment, but files are the most important.
  (cond
   ((eq minibuffer-history-variable 'file-name-history)
    (let ((dir (expand-file-name (substitute-in-file-name
                                  (or (file-name-directory input)
                                      default-directory)))))
      (unless (equal minicomp--history-dir dir)
        (setq minicomp--history-hash (make-hash-table :test #'equal :size (length file-name-history))
              minicomp--history-dir dir)
        (let* ((index 0)
               (adir (abbreviate-file-name dir))
               (dlen (length dir))
               (alen (length adir)))
          (dolist (elem file-name-history)
            (let* ((len (length elem))
                   (file (cond
                          ((and (> len dlen)
                                (eq t (compare-strings dir 0 dlen elem 0 dlen)))
                           (substring elem dlen))
                          ((and (> len alen)
                                (eq t (compare-strings adir 0 alen elem 0 alen)))
                           (substring elem alen)))))
            (when file
              (when-let (slash (string-match-p "/" file))
                (setq file (substring file 0 (1+ slash))))
              (unless (gethash file minicomp--history-hash)
                (puthash file index minicomp--history-hash)))
            (setq index (1+ index))))))))
   ((not minicomp--history-hash)
    (let ((index 0)
          ;; History disabled if `minibuffer-history-variable' eq `t'.
          (hist (and (not (eq minibuffer-history-variable t))
                     (symbol-value minibuffer-history-variable))))
      (setq minicomp--history-hash (make-hash-table :test #'equal :size (length hist)))
      (dolist (elem hist)
        (unless (gethash elem minicomp--history-hash)
          (puthash elem index minicomp--history-hash))
        (setq index (1+ index))))))
  ;; Decorate each candidate with (index<<13) + length. This way we sort first by index and then by
  ;; length. We assume that the candidates are shorter than 2**13 characters and that the history is
  ;; shorter than 2**16 entries.
  (let ((cand candidates))
    (while cand
      (setcar cand (cons (car cand)
                         (+ (lsh (gethash (car cand) minicomp--history-hash #xFFFF) 13)
                            (length (car cand)))))
      (setq cand (cdr cand))))
  (setq candidates (sort candidates #'minicomp--pred))
  ;; Drop decoration from the candidates
  (let ((cand candidates))
    (while cand
      (setcar cand (caar cand))
      (setq cand (cdr cand))))
  candidates)

(defun minicomp--annotate (metadata candidates)
  "Annotate CANDIDATES with annotation function specified by METADATA."
  (let ((aff (or (completion-metadata-get metadata 'affixation-function)
                 (plist-get completion-extra-properties :affixation-function)))
        (ann (or (completion-metadata-get metadata 'annotation-function)
                 (plist-get completion-extra-properties :annotation-function))))
    (cond
     (aff (funcall aff candidates))
     (ann (mapcar (lambda (cand) (list cand (or (funcall ann cand) ""))) candidates))
     (t candidates))))

(defun minicomp--candidates (input metadata)
  "Recompute candidates with INPUT string and METADATA."
  (let* ((all (completion-all-completions
               input
               minibuffer-completion-table
               minibuffer-completion-predicate
               (- (point) (minibuffer-prompt-end))
               metadata))
         (base (if-let (last (last all))
                   (prog1 (cdr last)
                     (setcdr last nil))
                 0))
         (total))
    (when (eq (completion-metadata-get metadata 'category) 'file)
      (setq all (delete "../" (delete "./" all))))
    (setq total (length all)
          all (if (> total minicomp-sort-threshold)
                  all
                (if-let (sort (completion-metadata-get metadata 'display-sort-function))
                    (funcall sort all)
                  (minicomp--sort input all))))
    (when-let* ((def (cond
                      ((stringp (car-safe minibuffer-default)) (car minibuffer-default))
                      ((stringp minibuffer-default) minibuffer-default)))
                (rest (member def all)))
      (setq all (nconc (list (car rest)) (delete def all))))
    (when-let (group (completion-metadata-get metadata 'x-group-function))
      (setq all (mapcan #'cdr (funcall group all))))
    (list base total all)))

(defun minicomp--recompute (input metadata)
  "Preprocess candidates with INPUT string and METADATA."
  (pcase (let ((while-no-input-ignore-events '(selection-request)))
           (while-no-input (minicomp--candidates input metadata)))
    ('nil (abort-recursive-edit))
    (`(,base ,total ,candidates)
     (unless (and minicomp--keep (< minicomp--index 0))
       (if-let* ((old (and candidates
                           minicomp--keep
                           (>= minicomp--index 0)
                           (nth minicomp--index minicomp--candidates)))
                 (idx (seq-position candidates old)))
           (setq minicomp--index idx)
         (setq minicomp--keep nil
               minicomp--index (if candidates 0 -1))))
     (setq minicomp--base base
           minicomp--input input
           minicomp--total total
           minicomp--candidates candidates))))

(defun minicomp--replace-prop (prop fun str)
  "Replace STR parts with PROP using FUN."
  (let ((len (length str)) (pos 0) (chunks))
    (while (/= pos len)
      (let ((end (next-single-property-change pos prop str len)))
        (push (if-let (val (get-text-property pos prop str))
                  (funcall fun val)
                (substring str pos end))
              chunks)
        (setq pos end)))
    (apply #'concat (nreverse chunks))))

(defun minicomp--display (input metadata)
  "Display current candidates with INPUT string and METADATA."
  (let* ((index (min (max 0 (- minicomp--index (/ minicomp-count 2)))
                     (max 0 (- minicomp--total minicomp-count))))
         (candidates (seq-subseq minicomp--candidates index
                                 (min (+ index minicomp-count)
                                      minicomp--total)))
         (ann-candidates
          (minicomp--annotate
           metadata
           (funcall
            minicomp--highlight-function
            (substring input
                       (car (completion-boundaries input minibuffer-completion-table
                                                   minibuffer-completion-predicate "")))
            metadata
            candidates)))
         (title nil)
         (displayed " ")
         (group (completion-metadata-get metadata 'x-group-function)))
    (dolist (ann-cand ann-candidates)
      (setq displayed (concat displayed
                              (if (= index (1+ minicomp--index))
                                  (propertize "\n" 'face 'minicomp-current)
                                "\n")))
      (let ((prefix "") (suffix "") (cand))
        (pcase ann-cand
          (`(,c ,s) (setq cand c suffix s))
          (`(,c ,p ,s) (setq cand c prefix p suffix s))
          (_ (setq cand ann-cand)))
        (when-let (new-title (and minicomp-group-format group (caar (funcall group (list cand)))))
          (unless (equal title new-title)
            (setq displayed (concat displayed (format minicomp-group-format new-title) "\n")
                  title new-title)))
        (setq cand (thread-last cand
                     (replace-regexp-in-string "[\t ]+" " ")
                     (replace-regexp-in-string "\n+" "⤶")
                     (string-trim)
                     (minicomp--replace-prop 'display (lambda (x) (if (stringp x) x "")))
                     (minicomp--replace-prop 'invisible (lambda (_) ""))))
        (setq cand (concat prefix cand
                           (if (text-property-not-all 0 (length suffix) 'face nil suffix)
                               suffix
                             (propertize suffix 'face 'completions-annotations))))
        (when (= index minicomp--index)
          (setq cand (concat cand))
          (add-face-text-property 0 (length cand) 'minicomp-current 'append cand))
        (setq displayed (concat displayed cand)
              index (1+ index))))
    (put-text-property 0 1 'cursor t displayed)
    (if (and (< minicomp--index 0) (not (minicomp--require-match)))
        (add-text-properties (minibuffer-prompt-end) (point-max) '(face minicomp-current))
      (remove-text-properties (minibuffer-prompt-end) (point-max) '(face nil)))
    (move-overlay minicomp--candidates-ov (point-max) (point-max))
    (overlay-put minicomp--candidates-ov 'after-string displayed)
    (when minicomp-count-format
      (move-overlay minicomp--count-ov (point-min) (point-min))
      (overlay-put minicomp--count-ov 'before-string
                   (format (car minicomp-count-format)
                           (format (cdr minicomp-count-format)
                                   (if (< minicomp--index 0) "*" (1+ minicomp--index))
                                   minicomp--total))))))

(defun minicomp--exhibit ()
  "Exhibit completion UI."
  (let ((metadata (completion--field-metadata (minibuffer-prompt-end)))
        (input (minibuffer-contents-no-properties)))
    (unless (equal minicomp--input input)
      (minicomp--recompute input metadata))
    (minicomp--display input metadata)))

(defun minicomp--require-match ()
  "Match is required."
  (not (memq minibuffer--require-match '(nil confirm confirm-after-completion))))

(defun minicomp--goto (index)
  "Go to INDEX."
  (setq minicomp--keep t
        minicomp--index
        (max
         (if (and (minicomp--require-match) (> minicomp--total 0))
             0
           -1)
         (min index (- minicomp--total 1)))))

(defun minicomp-beginning-of-buffer ()
  "Go to first candidate."
  (interactive)
  (minicomp--goto 0))

(defun minicomp-end-of-buffer ()
  "Go to last candidate."
  (interactive)
  (minicomp--goto (- minicomp--total 1)))

(defun minicomp-scroll-down ()
  "Go back by one page."
  (interactive)
  (minicomp--goto (max 0 (- minicomp--index minicomp-count))))

(defun minicomp-scroll-up ()
  "Go forward by one page."
  (interactive)
  (minicomp--goto (+ minicomp--index minicomp-count)))

(defun minicomp-next ()
  "Go to next candidate."
  (interactive)
  (minicomp--goto (1+ minicomp--index)))

(defun minicomp-previous ()
  "Go to previous candidate."
  (interactive)
  (minicomp--goto (- minicomp--index 1)))

(defun minicomp-exit (&optional arg)
  "Exit minibuffer with current candidate or input if prefix ARG is given."
  (interactive "P")
  (unless arg
    (minicomp-insert))
  (cond
   ((let ((input (minibuffer-contents-no-properties)))
      (or (not minibuffer--require-match)
          (eq minibuffer--require-match 'confirm-after-completion)
          (equal "" input)
          (test-completion input
                           minibuffer-completion-table
                           minibuffer-completion-predicate)))
    (exit-minibuffer))
   ((eq minibuffer--require-match 'confirm)
    (when (eq (read-char "Confirm") 13)
      (exit-minibuffer)))
   (t (message "Match required"))))

(defun minicomp-exit-input ()
  "Exit minibuffer with input."
  (interactive)
  (minicomp-exit t))

(defun minicomp-save ()
  "Save current candidate to kill ring."
  (interactive)
  (if (or (use-region-p) (not transient-mark-mode))
      (call-interactively #'kill-ring-save)
    (kill-new (minicomp--candidate))))

(defun minicomp-insert ()
  "Insert current candidate in minibuffer."
  (interactive)
  (let ((cand (minicomp--candidate)))
    (delete-minibuffer-contents)
    (insert cand)))

(defun minicomp--candidate ()
  "Return current candidate string."
  (let ((content (minibuffer-contents-no-properties)))
    (if (< minicomp--index 0)
        content
      (concat (substring content 0 minicomp--base)
              (nth minicomp--index minicomp--candidates)))))

(defun minicomp--setup ()
  "Setup completion system."
  (setq-local truncate-lines nil)
  (setq-local resize-mini-windows 'grow-only)
  (setq-local max-mini-window-height 1.0)
  ;; Optimize orderless filtering, skip highlighting
  (when (and (boundp 'orderless-skip-highlighting)
             (equal (default-value 'completion-styles) '(orderless)))
    (setq-local orderless-skip-highlighting t)
    (setq-local minicomp--highlight-function
                (lambda (input metadata candidates)
                  (let ((orderless-skip-highlighting nil))
                    (nconc
                     (completion-all-completions input
                                                 candidates
                                                 nil
                                                 (length input)
                                                 metadata)
                     nil)))))
  (setq minicomp--input t
        minicomp--candidates-ov (make-overlay (point-max) (point-max))
        minicomp--count-ov (make-overlay (point-min) (point-min)))
  (use-local-map minicomp-map)
  (add-hook 'post-command-hook #'minicomp--exhibit -99 'local))

(defun minicomp--advice (orig &rest args)
  "Advice for ORIG completion function, receiving ARGS."
  (minibuffer-with-setup-hook #'minicomp--setup (apply orig args)))

;;;###autoload
(define-minor-mode minicomp-mode
  "Minimal completion system."
  :global t
  (if minicomp-mode
      (progn
        (advice-add #'completing-read-default :around #'minicomp--advice)
        (advice-add #'completing-read-multiple :around #'minicomp--advice))
    (advice-remove #'completing-read-default #'minicomp--advice)
    (advice-remove #'completing-read-multiple #'minicomp--advice)))

(defun minicomp--consult-candidate ()
  "Current candidate."
  (when minicomp--input
    (minicomp--candidate)))

(defun minicomp--consult-refresh ()
  "Refresh ui."
  (when minicomp--input
    (setq minicomp--input t)
    (minicomp--exhibit)))

(defun minicomp--embark-target ()
  "Return embark target."
  (when minicomp--input
    (cons (completion-metadata-get (completion--field-metadata
                                    (minibuffer-prompt-end))
                                   'category)
	  (minicomp--candidate))))

(defun minicomp--embark-candidates ()
  "Return embark candidates."
  (when minicomp--input
    (cons (completion-metadata-get (completion--field-metadata
                                    (minibuffer-prompt-end))
                                   'category)
          ;; full candidates?
          minicomp--candidates)))

(with-eval-after-load 'consult
  (add-hook 'consult--completion-candidate-hook #'minicomp--consult-candidate)
  (add-hook 'consult--completion-refresh-hook #'minicomp--consult-refresh))

(with-eval-after-load 'embark
  (add-hook 'embark-target-finders #'minicomp--embark-target)
  (add-hook 'embark-candidate-collectors #'minicomp--embark-candidates))

(provide 'minicomp)
;;; minicomp.el ends here