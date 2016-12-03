;;; edictc.el --- DICT client for Emacs (Work In Progress) -*- lexical-binding: t; -*-

;; Copyright (C) 2016 Jambunathan K <kjambunathan at gmail dot com>

;; Author: Jambunathan K <kjambunathan at gmail dot com>
;; Maintainer: Jambunathan K <kjambunahtan at gmail dot com>
;; URL: https://github.com/kjambunathan/edictc
;; Version: 0.0

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
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

(require 'cl-lib)
(require 'rx)

(require 'hl-line)
(require 'goto-addr)

;;; Code:

;;; Constants

(defconst edictc-version "0.5")

;;; Variables

(defvar edictc-cookie nil)
(put 'edictc-cookie 'permanent-local t)

(defvar edictc-pipeline-commands t)

;;; User variables

(defgroup edictc nil
  "DICT client for Emacs."
  :tag "Edictc"
  :group 'applications)

(defcustom edictc-process-default-configuration
  `(:client-text ,(format "edictc-%s (GNU Emacs %s)" edictc-version emacs-version)
		 :port 2628 :database "*" :strategy "prefix"
		 :hello-timeout 3 :command-timeout 7 :idle-timeout 60)
  "DICT servers."
  :type `(plist :options
		((:client-text (string :tag "Identifier"))
		 (:port (integer :tag "TCP Port Number"))
		 (:database (choice :tag "Database"
				    (const :tag "All" "*")
				    (const :tag "Any" "!")))
		 (:strategy (choice :tag "Match Strategy"
				    (const :tag "prefix" "prefix")
				    (const :tag "exact" "exact")
				    (const :tag "Server Preferred" ".")))
		 (:hello-timeout  (integer :tag "Hello Timeout (secs)" :value 3))
		 (:idle-timeout  (integer :tag "Hello Timeout (secs)" :value 60))
		 (:command-timeout (integer :tag "Hello Timeout (secs)" :value 7))))
  :group 'edictc)

(defcustom edictc-servers nil
  "DICT servers."
  :type `(alist :key-type (string :tag "Nickname")
		:value-type (plist :options
                                   ((:hostname (string :tag "Hostname or IP address"))
                                    (:port (integer :tag "TCP port number"
						    :value ,(plist-get edictc-process-default-configuration :port)))
				    (:database (choice :tag "Database"
						       (const :tag "All" "*")
						       (const :tag "Any" "!")
						       (const :tag "All" nil)
						       (string :tag "Custom"))
					       :value ,(plist-get edictc-process-default-configuration :database))
				    (:strategy (choice :tag "Match Strategy"
						       (const :tag "prefix" "prefix")
						       (const :tag "exact" "exact")
						       (const :tag "Server Preferred" ".")
						       (string :tag "Custom"))
					       :value ,(plist-get edictc-process-default-configuration :strategy))
                                    (:remarks (string :tag "Remarks")))))
  :group 'edictc)

(defcustom edictc-server nil
  "Preferred DICT server."
  :type '(choice (const :tag "None" nil)
		 (string :tag "Nickname"))
  :group 'edictc)

(defcustom edictc-debug nil
  "Enable debugging."
  :type 'boolean
  :group 'edictc)

(defgroup edictc-faces nil
  "Faces for hi-lock."
  :group 'edictc
  :group 'faces)

(defface edictc-highlight-face
  '((((min-colors 88) (background dark))
     (:background "yellow1" :foreground "black"))
    (((background dark)) (:background "yellow" :foreground "black"))
    (((min-colors 88)) (:background "yellow1"))
    (t (:background "yellow")))
  "Default face for hi-lock mode."
  :group 'edictc-faces)

;;; Datastructures

;;;; DICT Protocol Related

(defstruct (edictc-match (:constructor edictc-create-match)
			 (:copier nil))
  database word)

(defstruct (edictc-database (:constructor edictc-create-database)
			    (:copier nil))
  handle description)

(defstruct (edictc-strategy (:constructor edictc-create-strategy)
			    (:copier nil))
  handle description)

;;;; EDICTC Related

(defstruct (edictc-request (:constructor edictc-create-request)
			   (:copier nil))
  process command callback)

(defstruct (edictc-process
	    (:constructor nil)
	    (:constructor edictc-process-from-server
			  (&key
			   server-nick
			   hostname
			   (port (plist-get edictc-process-default-configuration :port))
			   (database (plist-get edictc-process-default-configuration :database))
			   (strategy (plist-get edictc-process-default-configuration :strategy))
			   (hello-ticks (plist-get edictc-process-default-configuration
						   :hello-timeout))
			   (idle-ticks (plist-get edictc-process-default-configuration
						  :idle-timeout))
			   (command-ticks (plist-get edictc-process-default-configuration
						     :command-timeout))
			   (state 'DEAD)
			   (display-buffer (generate-new-buffer "edictc-display"))
			   (log-buffer (generate-new-buffer "edictc-log"))
			   (output-buffer (generate-new-buffer "edictc-output"))))

	    (:constructor edictc-process-from-edictc-process
			  (&key edictc-process
				&aux (output-buffer (generate-new-buffer "edictc-output"))
				(log-buffer (generate-new-buffer "edictc-log"))
				(display-buffer (edictc-process-display-buffer edictc-process))
				(server-nick (edictc-process-server-nick edictc-process))
				(hostname (edictc-process-hostname edictc-process))
				(port (edictc-process-port edictc-process))
				(database (edictc-process-database edictc-process))
				(state 'DEAD)
				(strategy (edictc-process-strategy edictc-process))
				(hello-ticks (edictc-process-hello-ticks edictc-process))
				(idle-ticks (edictc-process-idle-ticks edictc-process))
				(command-ticks (edictc-process-command-ticks edictc-process))))

	    (:copier nil))

  ;; Buffers
  ;;; Buffers that are invisible to the user.
  output-buffer log-buffer

  ;;; Buffers that are visible to the user.
  display-buffer

  ;; Fields set up based on user configuration.
  server-nick hostname port
  database strategy
  ;;; Timeouts
  hello-ticks idle-ticks command-ticks

  ;; Fields dependent on DICT server configuration.
  databases strategies

  ;; Fields for connection maintenance.
  process
  state handshake

  ;;; Command Queue
  request-qhead request-qtail

  ;;; Response
  status-code
  response

  ;;; Timer and Timeouts
  timer ticks
  )

(defun edictc-server--connect (nick)
  "Connect to DICT server."
  (interactive)
  (let* ((ep (apply 'edictc-process-from-server
		    (nconc (list :allow-other-keys t)
			   (cons :server-nick (assoc nick edictc-servers))))))
    (edictc-open-network-stream ep 'explore)))

(defun edictc-server-connect (&optional button)
  "Connect to DICT server."
  (interactive)
  (let* ((nick (if (derived-mode-p 'edictc-servers-menu-mode) (tabulated-list-get-id)
		 (button-get 'edictc-server button))))
    (edictc-server--connect nick)))

(defun edictc-show-database ()
  (interactive)
  (when (derived-mode-p 'edictc-server-databases-menu-mode)
    (let* ((database (tabulated-list-get-id)))
      (edictc-command-show-info database edictc-cookie))))

;;; Manage Process

(defun edictc-process-sentinel (process sentinel)
  "Called when PROCESS receives SENTINEL."

  (let* ((sentinel (string-trim sentinel))
	 (ep (process-get process :edictc-process)))
    (message "Received sentinel:%s status: %s" sentinel (process-status process))
    (case (process-status process)
      (open (ignore))
      ((failed closed)
       (let* ((output-buffer (edictc-process-output-buffer ep))
	      (log-buffer (edictc-process-log-buffer ep)))

	 (setf (edictc-process-process ep) nil)
	 (process-put process :edictc-process nil)

	 (kill-buffer output-buffer)
	 (setf (edictc-process-output-buffer ep) nil)

	 (unless edictc-debug
	   (kill-buffer log-buffer)
	   (setf (edictc-process-log-buffer ep) nil))

	 (cancel-timer (edictc-process-timer ep))
	 (setf  (edictc-process-timer ep) nil)

	 (setf (edictc-process-state ep) 'DEAD)

	 (when (eq ep (default-value 'edictc-cookie))
	   (set-default 'edictc-cookie nil)))

       )
      (otherwise
       (user-error "Edictc process status \"%s\" not handled" (process-status process))))))

;;; DICT Protocol Handling

;;;; Debugging

(defun edictc-process-log (ep tag fmt &rest args)
  (when edictc-debug
    (let* ((log-buffer (edictc-process-log-buffer ep))
	   (log-buffer (if (buffer-live-p log-buffer) log-buffer
			 (setf (edictc-process-log-buffer ep) (generate-new-buffer "edictc-log")))))
      (with-current-buffer log-buffer
	(goto-char (point-max))
	(insert (format "\n[%s] %s %s" (format-time-string "%H:%M:%S:%3N")
			tag (apply 'format fmt args)))))))

;;;; SEND side

(defun edictc-process-quit (ep reason)
  (edictc-process-log ep "QUIT" "%s" reason)
  (delete-process (edictc-process-process ep)))

(defun edictc-set-process-state (ep new-state)
  (let* ((current-state (edictc-process-state ep)))
    (edictc-process-log ep "STATE" "%s → %s" current-state new-state)
    (cond
     ((eq new-state 'INIT)
      (setf (edictc-process-ticks ep) (edictc-process-hello-ticks ep))
      (setf (edictc-process-timer ep)
	    (run-at-time 1 nil 'edictc-timer ep)))
     ((eq new-state 'IDLE)
      (setf (edictc-process-ticks ep) (edictc-process-idle-ticks ep))
      (edictc-process-log ep "TIMER" "START IDLE: %d" (edictc-process-ticks ep)))
     ((eq current-state 'IDLE)
      (setf (edictc-process-ticks ep) (edictc-process-command-ticks ep))
      (edictc-process-log ep "TIMER" "START REQUEST: %d" (edictc-process-ticks ep))))
    (setf (edictc-process-state ep) new-state)))

(defun edictc-timer (ep)
  (decf (edictc-process-ticks ep))
  (let ((ticks (edictc-process-ticks ep)))
    (edictc-process-log ep "TIMER EVENT" "%s" ticks)
    (if (zerop ticks)
	(edictc-process-quit ep
			     (case (edictc-process-state ep)
			       (INIT "HELLO TIMER")
			       (IDLE "IDLE TIMER")
			       (t "REQUEST TIMER")))
      (setf (edictc-process-timer ep) (run-at-time 1 nil 'edictc-timer ep)))))

(defun edictc-open-network-stream (ep &optional explore)
  (let* ((hostname (edictc-process-hostname ep))
	 (port (edictc-process-port ep))
	 process)

    (message "Connecting to %s: %s" hostname port)
    (setq process (open-network-stream "edictc" nil hostname port :nowait t))

    (edictc-set-process-state ep 'INIT)

    (set-process-coding-system process 'no-conversion 'no-conversion)
    (set-process-sentinel process 'edictc-process-sentinel)
    (set-process-filter process 'edictc-process-filter)

    (process-put process :edictc-process ep)
    (setf (edictc-process-process ep) process)

    (with-current-buffer (edictc-process-output-buffer ep)
      (setq-local edictc-cookie ep))

    (with-current-buffer (edictc-process-display-buffer ep)
      (setq-local edictc-cookie ep))

    (with-current-buffer (edictc-process-log-buffer ep)
      (edictc-minor-mode 1)
      (setq-local edictc-cookie ep))

    ;; Identify us to the server.
    (edictc-command-client ep (plist-get edictc-process-default-configuration :client-text))

    ;; Download Strategies, if needed.
    (unless (edictc-process-strategies ep)
      (edictc-command--send ep 'SHOW 'STRATEGIES 'ignore))

    ;; Download Databases, if needed.
    (unless (edictc-process-databases ep)
      (edictc-command--send ep 'SHOW 'DATABASES
			    (if explore 'edictc-list-server-databases 'ignore)))

    ;; Return process
    process))

;;;; RECEIVE side

(defun edictc-summarize-status-code (code)
  (let ((status-alist '((1 . positive-preliminary)
			(2 . positive-completion)
			(3 . positive-intermediate)
			(4 . transient-negative)
			(5 . permanent-negative)))
	(first-digit (/ code 100)))
    (assoc-default first-digit status-alist)))

(defconst edictc-status-codes
  '((110  . "n databases present - text follows")
    (111  . "n strategies available - text follows")
    (112  . "database information follows")
    (113  . "help text follows")
    (114  . "server information follows")
    (130  . "challenge follows")
    (150  . "n definitions retrieved - definitions follow")
    (151  . "word database name - text follows")
    (152  . "n matches found - text follows")
    (210  . "(optional timing and statistical information here)")
    (220  . "text msg-id")
    (221  . "Closing Connection")
    (230  . "Authentication successful")
    (250  . "ok (optional timing information here)")
    (330  . "send response")
    (420  . "Server temporarily unavailable")
    (421  . "Server shutting down at operator request")
    (500  . "Syntax error, command not recognized")
    (501  . "Syntax error, illegal parameters")
    (502  . "Command not implemented")
    (503  . "Command parameter not implemented")
    (530  . "Access denied")
    (531  . "Access denied, use \"SHOW INFO\" for server information")
    (532  . "Access denied, unknown mechanism")
    (550  . "Invalid database, use \"SHOW DB\" for list of databases")
    (551  . "Invalid strategy, use \"SHOW STRAT\" for a list of strategies")
    (552  . "No match")
    (554  . "No databases present")
    (555  . "No strategies available")))

(defconst edictc-status-code-with-follow-text
  '(
    110 				; "n databases present - text follows"
    111 				; "n strategies available - text follows"
    112 				; "database information follows"
    113 				; "help text follows"
    114 				; "server information follows"
    130 				; "challenge follows"
    ;; 150 				; "n definitions retrieved - definitions follow"
    151 				; "word database name - text follows"
    152 				; "n matches found - text follows"
    ))

(defun edictc-process-filter (process string)
  (let* ((ep (process-get process :edictc-process))
	 (buffer (edictc-process-output-buffer ep)))
    ;; (edictc-process-log ep "<-" "%s" string)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
	(goto-char (point-max))
	(insert string)
	(goto-char (point-min))
	(while (and (not (eq  (edictc-process-state ep) 'IDLE))
		    (not (eobp)))
	  ;; (message "\n\n--- response --\n\n %S\n\n" (edictc-process-response ep))
	  (cl-case (edictc-process-state ep)
	    ((INIT WAITING-FOR-STATUS)
	     (when (re-search-forward (rx-to-string '(and bol
							  (group-n 1 (one-or-more digit))
							  (one-or-more space)
							  (group-n 2 (zero-or-more any))
							  "\r" "\n"))
				      nil 'move)
	       (let* ((status (match-string 1))
		      (status-text (match-string 2))
		      (status-code (string-to-number status)))
		 (delete-region (point-min) (point))
		 ;; (edictc-process-log ep "DEBUG" "%d: %s" status-code status-text)

		 (setf (edictc-process-response ep)
		       (cons
			(cons status-code status-text)
			(edictc-process-response ep)))

		 (cond
		  ((= status-code 220)
		   ;; (setf (edictc-process-handshake ep) status-text)
		   )
		  ((= status-code 110)
		   ))
		 (cond
		  ((memq (edictc-summarize-status-code status-code)
			 '(positive-completion permanent-negative))

		   (setf (edictc-process-response ep) (nreverse (edictc-process-response ep)))
		   (setf (edictc-process-status-code ep) status-code)
		   (edictc-command-done ep))

		  ((member status-code edictc-status-code-with-follow-text)
		   (edictc-set-process-state ep 'WAITING-FOR-TEXT))))))
	    (WAITING-FOR-TEXT
	     (when (re-search-forward "\r\n\\.\r\n" nil 'move)
	       (let* ((response-text (buffer-substring (point-min) (match-beginning 0)))
		      (response-text (decode-coding-string response-text 'utf-8 t)))
		 (setf (edictc-process-response ep)
		       (cons
			(cons 'text response-text)
			(edictc-process-response ep)))
		 (delete-region (point-min) (point))
		 (edictc-set-process-state ep 'WAITING-FOR-STATUS))))))))))

;;;; Handle DICT Commands

(defun edictc-command-id (command)
  (intern (mapconcat (lambda (w) (if (symbolp w) (symbol-name w) "")) command "")))

(defun edictc-command-string (command)
  (mapconcat (lambda (w) (format "%s" w)) command " "))

(defun edictc-command--send-one (ep request)
  (let* ((command (edictc-request-command request))
	 (command-string (edictc-command-string command)))
    (edictc-process-log ep "->" "%s" command-string)
    (process-send-string (edictc-process-process ep) (format "%s\r\n" command-string))))

(defun edictc-command--send (ep &rest command-and-callback)
  (let* ((command (butlast command-and-callback))
	 (callback (car (last command-and-callback)))
	 (head (edictc-process-request-qhead ep))
	 (tail (edictc-process-request-qtail ep)))
    (when command
      (message "%s" (edictc-command-string command))
      (let* ((request (list (edictc-create-request :process ep :command command
						   :callback callback))))

	(cond
	 ;; There are outstanding commands.
	 (head
	  ;; Add user request to the tail.
	  (setcdr tail request)
	  (setf (edictc-process-request-qtail ep) request))
	 ;; There are no commands.
	 (t
	  ;; Queue user request
	  (setf (edictc-process-request-qhead ep) request)
	  (setf (edictc-process-request-qtail ep) request)))

	(edictc-process-log ep "ENQ" "%s" (edictc-command-string command))
	)
      )

    (when (eq (edictc-process-state ep) 'IDLE)
      ;; A command has just finished or the handshake is done.  Send a
      ;; pending command over the network.
      (let* ((head (edictc-process-request-qhead ep)))
	(when head
	  (edictc-command--send-one ep (car head))
	  (edictc-set-process-state ep 'WAITING-FOR-STATUS))))))

;;; Handle DICT Response

(defun edictc-command-done (ep)
  ;; (edictc-process-log ep "DONE" "%d" status-code)
  (unless (eq (edictc-process-state ep) 'INIT)
    (let* ((request (car (edictc-process-request-qhead ep)))
	   (command (edictc-request-command request))
	   (callback (edictc-request-callback request))
	   (pending-requests (cdr (edictc-process-request-qhead ep))))

      ;; Remove the just completed request
      (setf (edictc-process-request-qhead ep) pending-requests)
      (unless pending-requests
	(setf (edictc-process-request-qtail ep) nil))

      ;; (edictc-process-log ep "DONE" "%d: %S %s" status-code
      ;; 			  (edictc-command-id command)
      ;; 			  (edictc-command-string command))

      ;; (edictc-process-log ep "DONE" "\n\n-- %s --\n\n%S"
      ;; 			  (edictc-command-string command)
      ;; 			  (edictc-process-response ep))

      ;; Store response
      (case (edictc-command-id command)
	((CLIENT DEFINE HELP SHOWINFO SHOWSERVER STATUS QUIT)
	 ;; Serialize Response
	 (setf (edictc-process-response ep)
	       (mapconcat
		(lambda (response)
		  (let* ((type  (car response))
			 (text (cdr response)))
		    (cond
		     ((symbolp type)
		      (replace-regexp-in-string
		       "\r\n" "\n" (replace-regexp-in-string (rx-to-string 'bol) " " text nil t)
		       nil t))
		     ((string= (number-to-string type) "250") "")
		     ((numberp type) (format "* %s" text)))))
		(edictc-process-response ep) "\n\n")))
	(MATCH
	 (let* ((text (assoc-default 'text (edictc-process-response ep)) )
		(lines (split-string text "[\r\n]")))
	   (setf (edictc-process-response ep)
		 (mapcar (lambda (line)
			   (when (string-match (rx-to-string '(and (group (one-or-more (not (any " "))))
								   (one-or-more (in space))
								   (group (one-or-more any))))
					       line)
			     (edictc-create-match :database (match-string 1 line)
						  :word (match-string 2 line))))
			 lines))))
	(SHOWDATABASES
	 (let* ((text (assoc-default 'text (edictc-process-response ep)) )
		(lines (split-string text "[\r\n]")))
	   (setf (edictc-process-databases ep)
		 (mapcar (lambda (line)
			   (when (string-match (rx-to-string '(and (group (one-or-more (not (any " "))))
								   (one-or-more (in space))
								   (group (one-or-more any))))
					       line)
			     (edictc-create-database :handle (match-string 1 line)
						     :description (match-string 2 line))))
			 lines))))
	(SHOWSTRATEGIES
	 (let* ((text (assoc-default 'text (edictc-process-response ep)) )
		(lines (split-string text "[\r\n]")))
	   (setf (edictc-process-strategies ep)
		 (mapcar (lambda (line)
			   (when (string-match (rx-to-string '(and (group (one-or-more (not (in " "))))
								   (one-or-more (any space))
								   (group (one-or-more any))))
					       line)
			     (edictc-create-strategy :handle (match-string 1 line)
						     :description (match-string 2 line))))
			 lines))))
	(t
	 (error "Response to Command \"(%s)\" not handled" (edictc-command-string command))
	 ))


      (funcall callback ep command)

      ;; Clear out the response.
      (setf (edictc-process-status-code ep) nil)
      (setf (edictc-process-response ep) nil)))

  (edictc-set-process-state ep 'IDLE)
  (edictc-process-log ep "STATE" "%s" "IDLE")

  ;; Send a command, if there is one.
  (edictc-command--send ep)

  )

;;; DICT Client Commands

;;;; Misc.

(defun edictc-read-word (prompt)
  (let* ((word (or (if (region-active-p)
		       (buffer-substring (region-beginning) (region-end))
		     (word-at-point)))))
    (read-string (format "%s (%s): " prompt (or word "")) word nil word)))

;;;; CLIENT

(defun edictc-command-client (ep text)
  (edictc-command--send ep 'CLIENT text 'ignore))

;;;; DEFINE

(defun edictc-command-define (ep database word)
  (interactive
   (let* ((word (edictc-read-word "Define"))
	  (ep (edictc-infer-edictc-process))
	  (database (edictc-process-database ep)))
     (list ep database word)))
  (edictc-command--send ep 'DEFINE database word 'edictc-display-response))

;;;; HELP

(defun edictc-command-help (ep)
  (interactive (list (edictc-infer-edictc-process)))
  (edictc-command--send ep 'HELP 'edictc-display-response))

;;;; MATCH

(defun edictc-command-match (ep database strategy word)
  (interactive
   (let* ((word (edictc-read-word "Match"))
	  (ep (edictc-infer-edictc-process))
	  (strategy (or (edictc-process-strategy ep)
			(plist-get edictc-process-default-configuration :strategy)))
	  (database (edictc-process-database ep)))
     (list ep database strategy word)))
  (edictc-command--send ep 'MATCH database strategy word 'edictc-list-server-matches))

;;;; SHOW DATABASES

(defun edictc-command-show-databases (ep)
  (interactive (list (edictc-infer-edictc-process)))
  (edictc-command--send ep 'SHOW 'DATABASES 'edictc-list-server-databases))

;;;; SHOW INFO

(defun edictc-command-show-info (ep database)
  (interactive
   (let* ((ep (edictc-infer-edictc-process))
	  (database (if (derived-mode-p 'edictc-server-databases-menu-mode)
			(tabulated-list-get-id))))
     (list ep database)))
  (edictc-command--send ep 'SHOW 'INFO database 'edictc-display-response))

;;;; SHOW SERVER

(defun edictc-command-show-server (ep)
  (interactive (list (edictc-infer-edictc-process)))
  (edictc-command--send ep 'SHOW 'SERVER 'edictc-display-response))

;;;; SHOW STRATEGIES

(defun edictc-command-show-strategies (ep)
  (interactive (list (edictc-infer-edictc-process)))
  (edictc-command--send ep 'SHOW 'STRATEGIES 'edictc-list-server-strategies))

;;;; STATUS

(defun edictc-command-status (ep)
  (interactive (list (edictc-infer-edictc-process)))
  (edictc-command--send ep 'STATUS 'edictc-display-response))

;;;; QUIT

(defun edictc-command-quit (ep)
  (interactive (list (edictc-infer-edictc-process)))
  (edictc-command--send ep 'QUIT 'ignore))

;;; User Display

(defvar edictc-minor-mode-map
  (let ((map (make-sparse-keymap)))
    ;; (define-key map "\C-m" 'edictc-server-connect)
    ;; (define-key map "c" 'edictc-command-client)
    (define-key map "*" 'edictc-command-define-or-match)
    (define-key map "h" 'edictc-command-help)
    ;; (define-key map "*" 'edictc-command-match)
    (define-key map "d" 'edictc-command-show-databases)
    (define-key map "si" 'edictc-command-show-info)
    (define-key map "ss" 'edictc-command-show-server)
    (define-key map "s" 'edictc-command-show-strategies)
    ;; (define-key map "s\\?" 'edictc-command-show-status)
    (define-key map "q" 'edictc-command-quit)
    map)
  "Local keymap for `edictc-server-databases-menu-mode' buffers.")

(defvar-local edictc-minor-mode-lighter "")

(define-minor-mode edictc-minor-mode
  "EDICTC Minor mode."
  :lighter (" " edictc-minor-mode-lighter)
  (when edictc-cookie
    (setq edictc-minor-mode-lighter
	  (format "%s: %s / %s"
		  (edictc-process-server-nick edictc-cookie)
		  (edictc-process-database edictc-cookie)
		  (edictc-process-strategy edictc-cookie))))
  (goto-address-mode 1))

;;;; DEFAULT

(defun edictc-display-response (ep _command)
  (let* ((display-buffer (edictc-process-display-buffer ep)))
    (with-current-buffer display-buffer
      (let ((inhibit-read-only t))
	(erase-buffer)
	(insert (edictc-process-response ep)))
      (outline-mode)
      (edictc-minor-mode 1)
      (read-only-mode 1)
      (define-key (current-local-map) (kbd "<backtab>") 'org-global-cycle)
      (define-key (current-local-map) (kbd "<tab>") 'org-cycle)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

;;;; SHOW DATABASES

(defvar edictc-server-databases-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "\C-m" 'edictc-set-as-default-database)
    (define-key map "\C-x\C-s" 'edictc-save-configuration)
    map)
  "Local keymap for `edictc-server-databases-menu-mode' buffers.")

(define-derived-mode edictc-server-databases-menu-mode tabulated-list-mode "DICT Servers Menu"
  "Display the string in `edictc-server-databases-menu-text' in all available fonts."
  (setq tabulated-list-format
        `[("Database" 20 t)
          ("Description" 50 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Database" nil))
  (add-hook 'tabulated-list-revert-hook 'edictc-server-databases-menu--refresh nil t)
  (edictc-server-databases-menu--refresh)
  (setq tabulated-list-use-header-line nil)
  (tabulated-list-init-header)
  (tabulated-list-print)

  (setq  header-line-format
	 (concat
	  (make-text-button "Servers" nil 'type 'edictc-button-servers)
	  " "
	  (make-text-button "Strategies" nil 'type 'edictc-button-strategies 'edictc-cookie edictc-cookie)))
  (edictc-minor-mode)
  (hl-line-mode 1)
  )

(defun edictc-list-server-databases (ep _command)
  "Examine how a text is rendered in all available font families.
Use `edictc-server-databases-menu-set-text' to change the sample text.  Use
`edictc-server-databases-menu-set-script' to change the script.  Use
`edictc-server-databases-menu-set-frame-font' to change the frame font to the font in
the current line."
  (interactive)
  (let ((display-buffer (edictc-process-display-buffer ep)))
    (with-current-buffer display-buffer
      (edictc-server-databases-menu-mode))
    (switch-to-buffer display-buffer)))

(defun edictc-server-databases-menu--refresh ()
  "Re-populate `tabulated-list-entries'."
  (let ()
    (assert edictc-cookie)
    (setq tabulated-list-entries
	  (edictc-highlight-entry-with-id
	   (mapcar
	    (lambda (db)
	      (let* ((handle (edictc-database-handle db))
		     (description (edictc-database-description db)))
		(list handle (vector
			      (cons handle
				    `(database ,handle
					       action
					       (lambda (button)
						 (let* ((database (button-get button 'database))
							(ep (edictc-infer-edictc-process)))
						   (message "%s" (current-buffer))
						   (edictc-command--send ep 'SHOW 'INFO database
									 'edictc-display-response)))))
			      handle
			      description))))
	    (edictc-process-databases edictc-cookie))
	   (edictc-process-database edictc-cookie)))))

;;;; SHOW STRATEGIES

(defvar edictc-server-strategies-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "\C-m" 'edictc-set-as-default-strategy)
    (define-key map "\C-x\C-s" 'edictc-save-configuration)
    map)
  "Local keymap for `edictc-server-strategies-menu-mode' buffers.")

(define-derived-mode edictc-server-strategies-menu-mode tabulated-list-mode "DICT Servers Menu"
  "Display the string in `edictc-server-strategies-menu-text' in all available fonts."
  (setq tabulated-list-format
        `[("Strategy" 20 t)
          ("Description" 50 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Strategy" nil))
  (add-hook 'tabulated-list-revert-hook 'edictc-server-strategies-menu--refresh nil t)
  (edictc-server-strategies-menu--refresh)
  (setq  header-line-format (make-text-button "Databases" nil 'type 'edictc-button-databases))
  (setq tabulated-list-use-header-line nil)
  (tabulated-list-init-header)
  (tabulated-list-print)

  (setq  header-line-format
	 (concat
	  (make-text-button "Servers" nil 'type 'edictc-button-servers)
	  " "
	  (make-text-button "Databases" nil 'type 'edictc-button-databases 'edictc-cookie edictc-cookie)))

  (edictc-minor-mode)
  (hl-line-mode 1))

(defun edictc-list-server-strategies (ep _command)
  "Examine how a text is rendered in all available font families.
Use `edictc-server-strategies-menu-set-text' to change the sample text.  Use
`edictc-server-strategies-menu-set-script' to change the script.  Use
`edictc-server-strategies-menu-set-frame-font' to change the frame font to the font in
the current line."
  (interactive (list edictc-cookie))
  (let ((display-buffer (edictc-process-display-buffer ep)))
    (with-current-buffer display-buffer
      (edictc-server-strategies-menu-mode))
    (switch-to-buffer display-buffer)))

(defun edictc-server-strategies-menu--refresh ()
  "Re-populate `tabulated-list-entries'."
  (let ()
    (assert edictc-cookie)
    (setq tabulated-list-entries
	  (edictc-highlight-entry-with-id
	   (mapcar
	    (lambda (db)
	      (let* ((handle (edictc-strategy-handle db))
		     (description (edictc-strategy-description db)))
		(list handle (vector
			      handle
			      description))))
	    (edictc-process-strategies edictc-cookie))
	   (edictc-process-strategy edictc-cookie)))))

;;;; DICT Servers

(defun edictc-set-as-default-server ()
  "Connect to DICT server."
  (interactive)
  (when (derived-mode-p 'edictc-servers-menu-mode)
    (let* ((server-nick (tabulated-list-get-id)))
      (unless (string= server-nick edictc-server)
	(when (y-or-n-p (format "Use %s?" server-nick))
	  (setq edictc-server server-nick)
	  (call-interactively 'revert-buffer)
	  (edictc-minor-mode 1))))))

(defun edictc-set-as-default-strategy ()
  "Connect to DICT server."
  (interactive)
  (when (derived-mode-p 'edictc-server-strategies-menu-mode)
    (let* ((strategy (tabulated-list-get-id))
	   (ep edictc-cookie))
      (unless (string= strategy (edictc-process-strategy ep))
	(when (y-or-n-p (format "Switch strategy from \"%s\" to \"%s\"?"
				(edictc-process-strategy ep)
				strategy))
	  (setf (edictc-process-strategy ep) strategy)
	  (call-interactively 'revert-buffer)
	  (edictc-minor-mode 1))))))

(defun edictc-set-as-default-database ()
  "Connect to DICT server."
  (interactive)
  (when (derived-mode-p 'edictc-server-databases-menu-mode)
    (let* ((database (tabulated-list-get-id))
	   (ep edictc-cookie))
      (unless (string= database (edictc-process-database ep))
	(when (y-or-n-p (format "Switch database from \"%s\" to \"%s\"?"
				(edictc-process-database ep)
				database))
	  (setf (edictc-process-database ep) database)
	  (call-interactively 'revert-buffer)
	  (edictc-minor-mode 1))))))

(defun edictc-save-configuration ()
  (interactive)
  (cond
   ;; Save Default Server
   ((derived-mode-p 'edictc-servers-menu-mode)
    (let* ((server-saved (eval (car (get 'edictc-server 'saved-value)))))
      (when (and (not (string= server-saved edictc-server))
		 (y-or-n-p (format "Change DICT server (%s -> %s)"
				   server-saved
				   edictc-server)))
	(customize-save-variable 'edictc-server edictc-server))))
   ;; Save Default Database
   ((derived-mode-p 'edictc-server-databases-menu-mode)
    (let* ((ep edictc-cookie)
	   (server-nick (edictc-process-server-nick ep))
	   (database (edictc-process-database ep))
	   (server-props (assoc server-nick edictc-servers))
	   (database-saved (or (plist-get (cdr server-props) :database)
			       (plist-get edictc-process-default-configuration :database))))
      (when (and (not  (string= database-saved database))
		 (y-or-n-p (format "Change Database for \"%s\": %s -> %s? "
				   server-nick database-saved database)))
	(setcdr server-props (plist-put (cdr server-props) :database database))
	(customize-save-variable 'edictc-servers edictc-servers))))
   ((derived-mode-p 'edictc-server-strategies-menu-mode)
    (let* ((ep edictc-cookie)
	   (server-nick (edictc-process-server-nick ep))
	   (strategy (edictc-process-strategy ep))
	   (server-props (assoc server-nick edictc-servers))
	   (strategy-saved (or (plist-get (cdr server-props) :strategy)
			       (plist-get edictc-process-default-configuration :strategy))))
      (when (and (not (string= strategy-saved strategy))
		 (y-or-n-p (format "Change Match Strategy for \"%s\": %s -> %s? "
				   server-nick strategy-saved strategy)))
	(setcdr server-props (plist-put (cdr server-props) :strategy strategy))
	(customize-save-variable 'edictc-servers edictc-servers))))))

(defvar edictc-servers-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "\C-m" 'edictc-set-as-default-server)
    (define-key map "\C-x\C-s" 'edictc-save-configuration)
    map)
  "Local keymap for `edictc-servers-menu-mode' buffers.")

(easy-menu-define edictc-servers-mode-menu edictc-servers-menu-mode-map
  "Menu for `edictc-menu-mode'."
  `("Dictionary"
    ["Define word" edictc-command-define-or-match]
    ["Match word" edictc-command-match]
    "--"
    ["Show DICT Servers" edictc-list-servers]
    ["Set this Server as default" edictc-set-as-default-server
     :visible (derived-mode-p 'edictc-servers-menu-mode)
     ]
    ["Explore this Server" edictc-server-connect
     :visible (derived-mode-p 'edictc-servers-menu-mode)]))

(easy-menu-define edictc-minor-mode-menu-bar-map edictc-minor-mode-map
  "Menu for `edictc-menu-mode'."
  `("Dictionary"
    ["Define word" edictc-command-define-or-match]
    ["Match word" edictc-command-match]
    "--"
    ;; ("Show"
     ["DICT Servers" edictc-list-servers]
     ["Databases" edictc-command-show-databases]
     ["Strategies" edictc-command-show-strategies]
     ["Show Database Info" edictc-command-show-info
      :visible (derived-mode-p 'edictc-server-databases-menu-mode)]
     ;; )
    "--"
    ;; ("Server"
     ;; ["Set CLIENT string" edictc-command-client]
     ["Help" edictc-command-help]
     ["Show Server" edictc-command-show-server]
     ["Show Status" edictc-command-status]
     ["Quit" edictc-command-quit]
     ;; )
    "--"
    ;; ("Configure"
     ["Set this Server as default" edictc-set-as-default-server
      :visible (derived-mode-p 'edictc-servers-menu-mode)]
     ["Set this Database as default" edictc-set-as-default-database
      :visible (derived-mode-p 'edictc-server-databases-menu-mode)]
     ["Set this Strategy as default" edictc-set-as-default-strategy
      :visible (derived-mode-p 'edictc-server-strategies-menu-mode)]
     ["Save Configuration" edictc-save-configuration]
     ;; )
    ))

(easy-menu-add-item (current-global-map) '("menu-bar" "tools") edictc-servers-mode-menu "spell")

(define-derived-mode edictc-servers-menu-mode tabulated-list-mode "DICT Servers Menu"
  "Display the string in `edictc-servers-menu-text' in all available fonts."
  (setq tabulated-list-format
        `[("Nick" 12 t)
          ("Server" 30 nil)
	  ("Port" 5 nil)
	  ("Remarks" 30 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Nick" nil))
  (add-hook 'tabulated-list-revert-hook 'edictc-servers-menu--refresh nil t)
  (edictc-servers-menu--refresh)
  (tabulated-list-init-header)
  (tabulated-list-print))

(defun edictc-list-servers ()
  "Examine how a text is rendered in all available font families.
Use `edictc-servers-menu-set-text' to change the sample text.  Use
`edictc-servers-menu-set-script' to change the script.  Use
`edictc-servers-menu-set-frame-font' to change the frame font to the font in
the current line."
  (interactive)
  (let ((buf (get-buffer-create "*EDICTC Servers Menu*")))
    (with-current-buffer buf
      (edictc-servers-menu-mode))
    (switch-to-buffer buf)))

(defun edictc-highlight-entry-with-id (entries id)
  (mapcar
   (lambda (e)
     (if (string= (car e) id)
	 (list (car e)
	       (apply 'vector
		      (mapcar (lambda (c)
				(if (stringp c)
				    (propertize c 'face 'edictc-highlight-face)
				  (append c '(face edictc-highlight-face))))
			      (cadr e))))

       e))
   entries))

(defun edictc-servers-menu--refresh ()
  "Re-populate `tabulated-list-entries'."
  (setq tabulated-list-entries
	(edictc-highlight-entry-with-id
	 (mapcar
	  (lambda (s)
	    (let* ((nick (car s))
		   (settings (cdr s))
		   (hostname (plist-get settings :hostname))
		   (port (or (plist-get settings :port)
			     (plist-get edictc-process-default-configuration :port)))
		   (remarks (or (plist-get settings :remarks) "")))
	      (list nick (vector
			  (cons nick `(edictc-server ,nick action edictc-server-connect))
			  hostname
			  (number-to-string port)
			  remarks))))
	  edictc-servers)
	 edictc-server)))

;;; Emacs Bugs

;; tabulated-list.el → https://lists.gnu.org/archive/html/bug-gnu-emacs/2015-07/msg00311.html
;; https://lists.gnu.org/archive/html/bug-gnu-emacs/2015-07/msg00310.html

(define-button-type 'edictc-button-servers
  :supertype 'help-xref
  'help-function (lambda nil (call-interactively 'edictc-list-servers)))

(define-button-type 'edictc-button-databases
  :supertype 'help-xref
  'action (lambda (button)
	    (let ((ep (button-get button 'edictc-cookie)))
	      (edictc-command-show-databases ep))))

(define-button-type 'edictc-button-strategies
  :supertype 'help-xref
  'action (lambda (button)
	    (let ((ep (button-get button 'edictc-cookie)))
	      (edictc-command-show-strategies ep))))

(define-button-type 'edictc-button-database-info
  :supertype 'help-xref
  'help-function (lambda nil (call-interactively 'edictc-command-show-info)))

(defun edictc-infer-edictc-process ()
  (cond
   (edictc-cookie
    (let* ((process (edictc-process-process edictc-cookie)))
      (cond
       ((process-live-p process) edictc-cookie)
       (t
	(let* ((ep (edictc-process-from-edictc-process :edictc-process edictc-cookie)))
	  (edictc-open-network-stream ep)
	  ep)))))
   (t

    (let* ((ep (apply 'edictc-process-from-server (cons :server-nick (assoc edictc-server edictc-servers)))))
      (edictc-open-network-stream ep)
      (setq edictc-cookie ep)))))

(defun edictc-command-define-or-match (prefix)
  (interactive "P")
  (if prefix
      (call-interactively 'edictc-command-match)
    (call-interactively 'edictc-command-define)))

(define-key esc-map "*" 'edictc-command-define-or-match)

;;;; SHOW MATCHES

(defvar edictc-server-matches-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "\C-m" 'edictc-set-as-default-match)
    (define-key map "\C-x\C-s" 'edictc-save-configuration)
    map)
  "Local keymap for `edictc-server-matches-menu-mode' buffers.")

(define-derived-mode edictc-server-matches-menu-mode tabulated-list-mode "DICT Servers Menu"
  "Display the string in `edictc-server-matches-menu-text' in all available fonts."
  (setq tabulated-list-format
        `[("Match" 50 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Match" nil))
  (add-hook 'tabulated-list-revert-hook 'edictc-server-matches-menu--refresh nil t)
  (edictc-server-matches-menu--refresh)
  (setq tabulated-list-use-header-line nil)
  (tabulated-list-init-header)
  (tabulated-list-print)

  (setq  header-line-format
	 (concat
	  (make-text-button "Servers" nil 'type 'edictc-button-servers)
	  " "
	  (make-text-button "Strategies" nil 'type 'edictc-button-strategies 'edictc-cookie edictc-cookie)))
  (edictc-minor-mode)
  (hl-line-mode 1)
  )

(defun edictc-list-server-matches (ep _command)
  "Examine how a text is rendered in all available font families.
Use `edictc-server-matches-menu-set-text' to change the sample text.  Use
`edictc-server-matches-menu-set-script' to change the script.  Use
`edictc-server-matches-menu-set-frame-font' to change the frame font to the font in
the current line."
  (interactive)
  (let ((display-buffer (edictc-process-display-buffer ep)))
    (with-current-buffer display-buffer
      (edictc-server-matches-menu-mode))
    (switch-to-buffer display-buffer)))

(defun edictc-server-matches-menu--refresh ()
  "Re-populate `tabulated-list-entries'."
  (let ()
    (assert edictc-cookie)
    (setq tabulated-list-entries
	  (mapcar
	   (lambda (match)
	     (let* ((database (edictc-match-database match))
		    (word (edictc-match-word match)))
	       (list (concat database word)
		     (vector
		      (cons word
			    `(database ,database word ,word
				       action
				       (lambda (button)
					 (let* ((database (button-get button 'database))
						(word (button-get button 'word))
						(ep (edictc-infer-edictc-process)))
					   (edictc-command--send ep 'DEFINE database word
								 'edictc-display-response)))))))))
	   (edictc-process-response edictc-cookie)))))

(provide 'edictc)

;;; edictc.el ends here
