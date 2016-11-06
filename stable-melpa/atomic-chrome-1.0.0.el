;;; atomic-chrome.el --- Edit Chrome text area with Emacs using Atomic Chrome

;; Copyright (C) 2016 alpha22jp <alpha22jp@gmail.com>

;; Author: alpha22jp <alpha22jp@gmail.com>
;; Package-Requires: ((emacs "24.3") (let-alist "1.0.4") (websocket "1.4"))
;; Package-Version: 1.0.0
;; Keywords: chrome edit textarea
;; URL: https://github.com/alpha22jp/atomic-chrome
;; Version: 1.0.0

;; This program is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation; either version 2 of the License, or (at your option) any later
;; version.

;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
;; details.

;; You should have received a copy of the GNU General Public License along with
;; this program; if not, write to the Free Software Foundation, Inc., 51
;; Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

;;; Commentary:

;; This is the Emacs version of Atomic Chrome which is an extension for Google
;; Chrome browser that allows you to edit text areas of the browser in Emacs.
;;
;; It's similar to Edit with Emacs, but has some advantages as below with the
;; help of websocket.
;;
;; * Live update
;;   The input on Emacs is reflected to the browser instantly and continuously.
;; * Bidirectional communication
;;   You can edit both on the browser and Emacs, they are synced to the same.

;;; Code:

(eval-when-compile (require 'cl))
(require 'json)
(require 'let-alist)
(require 'websocket)

(defgroup atomic-chrome nil
  "Edit Chrome text area with Emacs using Atomic Chrome."
  :prefix "atomic-chrome-"
  :group 'applications)

(defcustom atomic-chrome-buffer-open-style 'split
  "Specify the style to open new buffer for editing."
  :type '(choice (const :tag "Open buffer with full window" full)
                 (const :tag "Open buffer with splitted window" split)
                 (const :tag "Open buffer with new frame" frame))
  :group 'atomic-chrome)

(defcustom atomic-chrome-buffer-frame-width 80
  "Width of editing buffer frame."
  :type 'integer
  :group 'atomic-chrome)

(defcustom atomic-chrome-buffer-frame-height 25
  "Height of editing buffer frame."
  :type 'integer
  :group 'atomic-chrome)

(defcustom atomic-chrome-enable-auto-update t
  "If non-nil, edit on Emacs is reflected to Chrome instantly, \
otherwise you need to type \"C-xC-s\" manually."
  :type 'boolean
  :group 'atomic-chrome)

(defcustom atomic-chrome-enable-bidirectional-edit t
  "If non-nil, you can edit both on Chrome text area and Emacs, \
otherwise edit on Chrome is ignored while editing on Emacs."
  :type 'boolean
  :group 'atomic-chrome)

(defcustom atomic-chrome-default-major-mode 'text-mode
  "Default major mode for editing buffer."
  :type 'function
  :group 'atomic-chrome)

(defcustom atomic-chrome-url-major-mode-alist nil
  "Association list of URL regexp and corresponding major mode \
which is used to select major mode for specified website."
  :type '(alist :key-type (string :tag "regexp")
                :value-type (function :tag "major mode"))
  :group 'atomic-chrome)

(defcustom atomic-chrome-edit-mode-hook nil
  "Customizable hook which run when the editing buffer is created."
  :type 'hook
  :group 'atomic-chrome)

(defcustom atomic-chrome-edit-done-hook nil
  "Customizable hook which run when the editing buffer is closed."
  :type 'hook
  :group 'atomic-chrome)

(defvar atomic-chrome-server-conn nil)

(defvar atomic-chrome-buffer-table (make-hash-table :test 'equal)
  "Hash table of editing buffer and its assciated data.
Each element has a list consisting of (websocket, frame).")

(defun atomic-chrome-get-websocket (buffer)
  "Lookup websocket associated with buffer BUFFER \
from `atomic-chrome-buffer-table'."
  (nth 0 (gethash buffer atomic-chrome-buffer-table)))

(defun atomic-chrome-get-frame (buffer)
  "Lookup frame associated with buffer BUFFER \
from `atomic-chrome-buffer-table'."
  (nth 1 (gethash buffer atomic-chrome-buffer-table)))

(defun atomic-chrome-get-buffer-by-socket (socket)
  "Lookup buffer which is associated to the websocket SOCKET \
from `atomic-chrome-buffer-table'."
  (let (buffer)
    (cl-loop for key being the hash-keys of atomic-chrome-buffer-table
             using (hash-values val)
             do (when (equal (nth 0 val) socket) (setq buffer key)))
    buffer))

(defun atomic-chrome-close-connection ()
  "Close client connection associated with current buffer."
  (let ((socket (atomic-chrome-get-websocket (current-buffer))))
    (when socket
      (remhash (current-buffer) atomic-chrome-buffer-table)
      (websocket-close socket))))

(defun atomic-chrome-send-buffer-text ()
  "Send request to update text with current buffer content."
  (interactive)
  (let ((socket (atomic-chrome-get-websocket (current-buffer)))
        (text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and socket text)
      (websocket-send-text socket
                           (json-encode
                            (list '("type" . "updateText")
                                  (cons "payload" (list (cons "text" text)))))))))

(defun atomic-chrome-set-major-mode (url)
  "Set major mode for editing buffer depending on URL.
`atomic-chrome-url-major-mode-alist' can be used to select major mode.
The specified major mode is used if URL matches to one of the alist,
otherwise fallback to `atomic-chrome-default-major-mode'"
  (funcall (or (and url (assoc-default url
                                       atomic-chrome-url-major-mode-alist
                                       'string-match))
               atomic-chrome-default-major-mode)))

(defun atomic-chrome-show-edit-buffer (buffer title)
  "Show editing buffer BUFFER by creating a frame with title TITLE, \
or raising the selected frame depending on `atomic-chrome-buffer-open-style'."
  (let ((edit-frame nil)
        (frame-params (list (cons 'name (format "Atomic Chrome: %s" title))
                            (cons 'width atomic-chrome-buffer-frame-width)
                            (cons 'height atomic-chrome-buffer-frame-height))))
    (when (eq atomic-chrome-buffer-open-style 'frame)
      (setq edit-frame
            (if (memq window-system '(ns mac))
                ;; Avoid using make-frame-on-display for Mac OS.
                (make-frame frame-params)
              (make-frame-on-display (getenv "DISPLAY") frame-params)))
      (select-frame edit-frame))
    (if (eq atomic-chrome-buffer-open-style 'split)
        (pop-to-buffer buffer)
      (switch-to-buffer buffer))
    (raise-frame edit-frame)
    (select-frame-set-input-focus (window-frame (selected-window)))
    edit-frame))

(defun atomic-chrome-create-buffer (ws url title text)
  "Create buffer associated with websocket specified by WS.
URL is used to determine the major mode of the buffer created,
TITLE is used for the buffer name and TEXT is inserted to the buffer."
  (let ((buffer (generate-new-buffer title)))
    (with-current-buffer buffer
      (puthash buffer
             (list ws (atomic-chrome-show-edit-buffer buffer title))
             atomic-chrome-buffer-table)
      (atomic-chrome-set-major-mode url)
      (insert text))))

(defun atomic-chrome-close-edit-buffer (buffer)
  "Close buffer BUFFER if it's one of Atomic Chrome edit buffers."
  (let ((frame (atomic-chrome-get-frame buffer)))
    (with-current-buffer buffer
      (save-restriction
        (run-hooks 'atomic-chrome-edit-done-hook)
        (when frame (delete-frame frame))
        (kill-buffer buffer)))))

(defun atomic-chrome-close-current-buffer ()
  "Close current buffer and connection from client."
  (interactive)
  (atomic-chrome-close-edit-buffer (current-buffer)))

(defun atomic-chrome-update-buffer (ws text)
  "Update text on buffer associated with WS to TEXT."
  (let* ((buffer-name (gethash (websocket-conn ws) atomic-chrome-buffer-table))
         (buffer (if buffer-name (get-buffer buffer-name) nil)))
    (when buffer
      (with-current-buffer buffer
        (erase-buffer)
        (insert text)))))

(defun atomic-chrome-on-message (ws frame)
  "Function to handle data received from websocket client specified by WS, \
where FRAME show raw data received."
  (let ((msg (json-read-from-string
              (decode-coding-string
               (string-make-unibyte (websocket-frame-payload frame)) 'utf-8))))
    (let-alist msg
      (cond ((string= .type "register")
             (atomic-chrome-create-buffer ws .payload.url .payload.title .payload.text))
            ((string= .type "updateText")
             (when atomic-chrome-enable-bidirectional-edit
               (atomic-chrome-update-buffer ws .payload.text)))))))

(defun atomic-chrome-on-close (socket)
  "Function to handle request from client to close websocket SOCKET."
  (let ((buffer (atomic-chrome-get-buffer-by-socket socket)))
    (when buffer (atomic-chrome-close-edit-buffer buffer))))

(defvar atomic-chrome-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-s") 'atomic-chrome-send-buffer-text)
    (define-key map (kbd "C-c C-c") 'atomic-chrome-close-current-buffer)
    map)
  "Keymap for minor mode `atomic-chrome-edit-mode'.")

(define-minor-mode atomic-chrome-edit-mode
  "Minor mode enabled on buffers opened by Emacs Chrome server."
  :group 'atomic-chrome
  :lighter " AtomicChrome"
  :init-value nil
  :keymap atomic-chrome-edit-mode-map
  (when atomic-chrome-edit-mode
    (add-hook 'kill-buffer-hook 'atomic-chrome-close-connection nil t)
    (when atomic-chrome-enable-auto-update
      (add-hook 'post-command-hook 'atomic-chrome-send-buffer-text nil t))))

(defun atomic-chrome-turn-on-edit-mode ()
  "Turn on `atomic-chrome-edit-mode' if the buffer is an editing buffer."
  (when (gethash (current-buffer) atomic-chrome-buffer-table)
    (atomic-chrome-edit-mode t)))

(define-global-minor-mode global-atomic-chrome-edit-mode
  atomic-chrome-edit-mode atomic-chrome-turn-on-edit-mode)

(defadvice save-buffers-kill-emacs
      (before atomic-chrome-server-stop-before-kill-emacs)
      "Call `atomic-chrome-close-server' before closing Emacs to avoid users \
being prompted to kill the websocket server process."
      (atomic-chrome-stop-server))

;;;###autoload
(defun atomic-chrome-start-server ()
  "Start websocket server for atomic-chrome."
  (interactive)
  (unless atomic-chrome-server-conn
    (global-atomic-chrome-edit-mode 1)
    (ad-activate 'save-buffers-kill-emacs)
    (setq atomic-chrome-server-conn
          (websocket-server
           64292
           :host 'local
           :on-message #'atomic-chrome-on-message
           :on-open nil
           :on-close #'atomic-chrome-on-close))))

;;;###autoload
(defun atomic-chrome-stop-server nil
  "Stop websocket server for atomic-chrome."
  (interactive)
  (when atomic-chrome-server-conn
    (websocket-server-close atomic-chrome-server-conn)
    (setq atomic-chrome-server-conn nil))
  (ad-disable-advice 'save-buffers-kill-emacs
                     'before 'atomic-chrome-server-stop-before-kill-emacs)
  ;; Disabling advice doesn't take effect until you (re-)activate
  ;; all advice for the function.
  (ad-activate 'save-buffers-kill-emacs)
  (global-atomic-chrome-edit-mode 0))

(provide 'atomic-chrome)

;;; atomic-chrome.el ends here