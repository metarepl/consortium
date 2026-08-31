(in-package :lisp-mash)

;; &&& use https://github.com/kanru/cl-isolated to sandbox inter image calls?
;; &&& or secure incoming connections to a repl by password?

;;;; =========================================================================
;;;; Configuration
;;;; =========================================================================

;; Filesystem is the coordination backbone because our images are separate
;; OS processes that can't share memory. A simple directory of files is
;; more robust than a central server that could become a single point of failure.
(defvar *registry-path*
  (merge-pathnames ".config/lisp-mash/registry/"
                   (user-homedir-pathname)))

;; Local cache avoids hitting the filesystem on every operation.
;; We refresh it periodically and on-demand.
(defvar *nodes-cache* (make-hash-table :test 'equal))

;; Track our own identity so we can update our registration when things change.
(defvar *this-node* nil)

;; Used to detect when our exported symbols change, triggering re-registration.
(defvar *symbol-hash* nil)

;; Background threads for monitoring
(defvar *heartbeat-thread* nil)
(defvar *self-monitor-thread* nil)

;; Tuning parameters. Heartbeat is less frequent because checking liveness
;; requires network round-trips to every node.
(defvar *heartbeat-interval* 37)
(defvar *self-monitor-interval* 11)

;;;; =========================================================================
;;;; Filesystem Registry
;;;; =========================================================================

(defun make-name (name)
  "converts string or keyword or symbol to downcased string"
  (format nil "~(~A~)" name))

(defun node-file (name)
  ;; Each node gets one file. The filename is the node name, making it
  ;; trivial to find, update, or remove a specific node's registration.
  (merge-pathnames (format nil "~A.node" (make-name name))
                   *registry-path*))

(defun write-node-file (name info)
  (ensure-directories-exist *registry-path*)
  (with-open-file (s (node-file name)
                     :direction :output
                     :if-exists :supersede)
    (prin1 info s)))

(defun read-node-file (path)
  (with-open-file (s path :direction :input)
    (read s)))

(defun delete-node-file (name)
  (let ((path (node-file name)))
    (when (probe-file path)
      (delete-file path))))

(defun scan-registry ()
  ;; Returns all registered nodes. We read everything because we don't know
  ;; which nodes exist until we look.
  (ensure-directories-exist *registry-path*)
  (loop for file in (directory (merge-pathnames "*.node" *registry-path*))
        for info = (ignore-errors (read-node-file file))
        when info collect info))

;;;; =========================================================================
;;;; Server
;;;; =========================================================================

(defun find-free-port (&optional (start 40000) (end 41000))
  (let ((port (find-port:find-port :min start :max end)))
    (if (null port)
        (error "No free port found between ~A and ~A" start end)
        port)))

(defun start-server (port)
  (micros:create-server :port port :dont-close t)
  port)

;;;; =========================================================================
;;;; Background Monitors
;;;; =========================================================================

(defun node-alive-p (info)
  ;; simple arithmetic eval as a liveness check.
  ;; If this fails, the node is definitely unreachable.

  ;; TODO at the end of a call micros barks about disconnnection, stop the print
  (ignore-errors
    (eql 42 (eval-in (getf info :name) '(+ 40 2)))))

(defun prune-dead-nodes ()
  ;; Iterate a snapshot of the registry to avoid issues with concurrent modification.
  ;; Pruning is best-effort; if we fail to delete a file, we'll try again next cycle.
  (dolist (info (scan-registry))
    (unless (node-alive-p info)
      (let ((name (getf info :name)))
        ;; Don't prune ourselves even if the check fails.
        (unless (and *this-node*
                     (string= name (getf *this-node* :name)))
          (format t "~&[lisp-mash] Pruning dead node: ~A~%" name)
          (delete-node-file name))))))

(defun heartbeat-tasks ()
  (ignore-errors (prune-dead-nodes)))

(defun start-heartbeat ()
  ;; Clean up existing thread to allow re-registration
  (when (and *heartbeat-thread* (bt:thread-alive-p *heartbeat-thread*))
    (bt:destroy-thread *heartbeat-thread*))
  (setf *heartbeat-thread*
        (bt:make-thread
         (lambda ()
           (loop
             (sleep *heartbeat-interval*)
             (heartbeat-tasks)))
         :name "lisp-mash-heartbeat")))

(defun compute-symbol-hash (package)
  ;; Sorting ensures deterministic hashing regardless of internal symbol order.
  (sxhash
   (sort (loop for s being the external-symbols of package
               collect (symbol-name s))
         #'string<)))

(defun ensure-registration ()
  ;; registration file exists
  (when *this-node*
    (let* ((name (getf *this-node* :name))
           (node-file (node-file name)))
      (unless (probe-file node-file)
        (write-node-file name *this-node*)))))

(defun update-registration ()
  ;; Only re-write the file if something actually changed, avoiding
  ;; unnecessary I/O and timestamp churn.
  (when *this-node*
    (let* ((pkg (find-package (getf *this-node* :package)))
           (new-hash (compute-symbol-hash pkg)))
      (unless (eql new-hash *symbol-hash*)
        (setf *symbol-hash* new-hash)
        (setf (getf *this-node* :symbol-hash) new-hash
              (getf *this-node* :updated-at) (get-universal-time))
        (write-node-file (getf *this-node* :name) *this-node*)
        (format t "~&[lisp-mash] Exports changed, registration updated~%")))))

(defun self-monitor-tasks ()
  (ensure-registration)
  (ignore-errors (update-registration)))

(defun start-self-monitor ()
  ;; Clean up existing thread to allow re-registration.
  (when (and *self-monitor-thread* (bt:thread-alive-p *self-monitor-thread*))
    (bt:destroy-thread *self-monitor-thread*))
  (setf *self-monitor-thread*
        (bt:make-thread
         (lambda ()
           (loop
             (sleep *self-monitor-interval*)
             (self-monitor-tasks)))
         :name "lisp-mash-self-monitor")))

(defun stop-monitors ()
  ;; Clean shutdown for both threads.
  (when (and *heartbeat-thread* (bt:thread-alive-p *heartbeat-thread*))
    (bt:destroy-thread *heartbeat-thread*)
    (setf *heartbeat-thread* nil))
  (when (and *self-monitor-thread* (bt:thread-alive-p *self-monitor-thread*))
    (bt:destroy-thread *self-monitor-thread*)
    (setf *self-monitor-thread* nil)))

;;;; =========================================================================
;;;; Registration
;;;; =========================================================================

(defun stop-node (name port)
  (delete-node-file name)
  (stop-monitors)
  (micros:stop-server port))

(defun register-exit-hook (name port)
  ;; Different implementations have different hook mechanisms.
  ;; We want to clean up our registry file on graceful exit so other
  ;; nodes don't waste time trying to contact us.
  (let* ((cleanup (lambda () (stop-node name port))))
    #+sbcl (push cleanup sb-ext:*exit-hooks*)
    #+ccl (push cleanup ccl:*lisp-cleanup-functions*)
    #+ecl (push cleanup si:*exit-hooks*)
    #-(or sbcl ccl ecl)
    (warn "No exit hook mechanism known for this implementation")))

(defun register-image (node-name)
  "Register this Lisp image as a node in the lisp-mash network.
   Call this from a lisp application's config file."
  (let* ((pkg-name (package-name *package*))
         (name (make-name node-name))
         (pid #+sbcl (sb-posix:getpid)
              #+ccl (ccl::getpid)
              #-(or sbcl ccl) 0)
         (port (find-free-port))
         (info (list :name name
                     :package pkg-name
                     :port port
                     :hostname "localhost"
                     ;; PID helps distinguish between restarts of the same app.
                     :pid pid
                     :registered-at (get-universal-time)
                     :symbol-hash nil)))

    (start-server port)

    ;; Compute initial symbol hash for change detection.
    (setf *symbol-hash* (compute-symbol-hash *package*))
    (setf (getf info :symbol-hash) *symbol-hash*)

    (write-node-file name info)
    (setf *this-node* info)

    (register-exit-hook name port)

    ;; Background monitors make the network self-healing.
    ;; (start-heartbeat)
    ;; (start-self-monitor)

    (format t "~&[lisp-mash] registered ~A on port ~A~%" name port)
    info))

(defun unregister-image ()
  "Remove this node from the network."
  (when *this-node*
    (stop-node (getf *this-node* :name)
               (getf *this-node* :port))
    (format t "~&[lisp-mash] ~A unregistered~%" (getf *this-node* :name))
    (setf *this-node* nil
          *symbol-hash* nil)))

;;;; =========================================================================
;;;; Node Discovery
;;;; =========================================================================

(defun refresh-nodes ()
  "Reload node info from registry files."
  (clrhash *nodes-cache*)
  (loop for info in (scan-registry)
        do (setf (gethash (getf info :name) *nodes-cache*) info))
  *nodes-cache*)

(defun nodes ()
  "List all registered nodes."
  ;; Always refresh to ensure we see recent registrations/unregistrations.
  (refresh-nodes)
  (loop for info being the hash-values of *nodes-cache*
        collect info))

(defun get-node (name)
  (refresh-nodes)
  (or (gethash (make-name name) *nodes-cache*)
      (error "Unknown node: ~A" name)))

;;;; =========================================================================
;;;; Remote Evaluation
;;;; =========================================================================

(defun eval-in (node form)
  "Evaluate FORM in the image of another node."
  (let* ((info (get-node node))
         (name (getf info :name))
         (port (getf info :port))
         (host (getf info :hostname)))
    (handler-case
        (swank-client:with-slime-connection (conn host port)
          (swank-client:slime-eval form conn))
      (error (e)
        ;; If we can't reach a node, remove it from the registry so others
        ;; don't waste time on it. The node will re-register if it comes back.
        (delete-node-file name)
        (remhash name *nodes-cache*)
        (error "Node ~A unreachable (pruned): ~A" node e)))))

(defun broadcast (form)
  "Evaluate FORM in all registered nodes."
  ;; Collect results even if some nodes fail, so partial results are still useful.
  (loop for info in (nodes)
        for name = (getf info :name)
        collect (cons name (ignore-errors (eval-in name form)))))

;;;; =========================================================================
;;;; Symbol Sharing
;;;; =========================================================================

;; TODO choose package to import from
(defun sync-remote-symbols (node)
  "Create local stubs that proxy calls to a remote node's exports."
  (let* ((info (get-node node))
         (remote-pkg (getf info :package))
         (node-name (getf info :name))
         ;; Fetch the list of exported symbol names from the remote.
         (symbols (eval-in node
                    `(loop for s being the external-symbols of ,remote-pkg
                           collect (symbol-name s)))))
    (dolist (sym-name symbols)
      (let ((local-sym (intern sym-name :lisp-mash/mash)))
        ;; Each stub captures the node name and symbol name, then delegates.
        ;; This creates transparent remote procedure calls.
        (let ((captured-name node-name)
              (captured-sym sym-name)
              (captured-pkg remote-pkg))
          (setf (symbol-function local-sym)
                (lambda (&rest args)
                  (eval-in captured-name
                    `(apply (find-symbol ,captured-sym ,captured-pkg)
                            ',args)))))
        (export local-sym :lisp-mash/mash)))
    (format t "~&[lisp-mash] Imported ~A symbols from ~A~%"
            (length symbols) node-name)
    symbols))

(defun sync-all ()
  "Import exported symbols from all registered nodes."
  ;; Skip ourselves to avoid circular stubs.
  (dolist (info (nodes))
    (let ((name (getf info :name)))
      (unless (and *this-node* (string= name (getf *this-node* :name)))
        (ignore-errors (sync-remote-symbols name))))))
