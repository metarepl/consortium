(in-package :consortium)

;;;; =========================================================================
;;;; Configuration
;;;; =========================================================================

;; Filesystem is the coordination backbone because our images are separate
;; OS processes that can't share memory. A simple directory of files is
;; more robust than a central server that could become a single point of failure.
(defvar *registry-path*
  (merge-pathnames ".config/consortium/registry/"
                   (user-homedir-pathname)))

;; Local cache avoids hitting the filesystem on every operation.
;; We refresh it periodically and on-demand.
(defvar *nodes-cache* (make-hash-table :test 'equal))

;; Track our own identity so we can update our registration when things change.
(defvar *self* nil)

;; Used to detect when our exported symbols change, triggering re-registration.
(defvar *symbol-hash* nil)

;; Background threads for monitoring — stored so we can clean them up.
(defvar *heartbeat-thread* nil)
(defvar *self-monitor-thread* nil)

;; Tuning parameters. Heartbeat is less frequent because checking liveness
;; requires network round-trips to every node.
(defvar *heartbeat-interval* 30)
(defvar *self-monitor-interval* 10)

;;;; =========================================================================
;;;; Filesystem Registry
;;;; =========================================================================

(defun ensure-registry-dir ()
  (ensure-directories-exist *registry-path*))

(defun node-file (name)
  ;; Each node gets one file. The filename is the node name, making it
  ;; trivial to find, update, or remove a specific node's registration.
  (merge-pathnames (format nil "~(~A~).sexp" name)
                   *registry-path*))

(defun write-node-file (name info)
  (ensure-registry-dir)
  ;; Overwrites atomically. If we crash mid-write, the old file remains.
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
  (ensure-registry-dir)
  (loop for file in (directory (merge-pathnames "*.sexp" *registry-path*))
        for info = (ignore-errors (read-node-file file))
        when info collect info))

;;;; =========================================================================
;;;; Port Management
;;;; =========================================================================

(defun find-free-port (&optional (start 40000) (end 40100))
  ;; We try to bind and immediately release. This has a small race condition
  ;; but it's acceptable — the alternative is managing a port registry, which
  ;; adds complexity for minimal benefit.
  (loop for port from start below end
        when (ignore-errors
               (let ((socket (usocket:socket-listen "127.0.0.1" port)))
                 (usocket:socket-close socket)
                 t))
          return port
        finally (error "No free port found between ~A and ~A" start end)))

;;;; =========================================================================
;;;; Micros Server
;;;; =========================================================================

(defun start-micros (port)
  ;; dont-close keeps the server running after the first client disconnects,
  ;; which is essential since we expect multiple connections over time.
  (micros:create-server :port port :dont-close t)
  port)

;;;; =========================================================================
;;;; Background Monitors
;;;; =========================================================================

(defun node-alive-p (info)
  ;; A simple arithmetic eval is the cheapest possible liveness check.
  ;; If this fails, the node is definitely unreachable.
  (ignore-errors
    (eql 2 (eval-at (getf info :name) '(+ 1 1)))))

(defun prune-dead-nodes ()
  ;; Iterate a snapshot of the registry to avoid issues with concurrent modification.
  ;; Pruning is best-effort; if we fail to delete a file, we'll try again next cycle.
  (dolist (info (scan-registry))
    (unless (node-alive-p info)
      (let ((name (getf info :name)))
        ;; Don't prune ourselves even if the check fails.
        (unless (and *self* (string= name (getf *self* :name)))
          (format t "~&[consortium] Pruning dead node: ~A~%" name)
          (delete-node-file name))))))

(defun start-heartbeat ()
  ;; Clean up existing thread to allow re-registration without leaking threads.
  (when (and *heartbeat-thread* (bt:thread-alive-p *heartbeat-thread*))
    (bt:destroy-thread *heartbeat-thread*))
  (setf *heartbeat-thread*
        (bt:make-thread
         (lambda ()
           (loop
             (sleep *heartbeat-interval*)
             (ignore-errors (prune-dead-nodes))))
         :name "consortium-heartbeat")))

(defun compute-symbol-hash (package)
  ;; Sorting ensures deterministic hashing regardless of internal symbol order.
  (sxhash
   (sort (loop for s being the external-symbols of package
               collect (symbol-name s))
         #'string<)))

(defun update-registration ()
  ;; Only re-write the file if something actually changed, avoiding
  ;; unnecessary I/O and timestamp churn.
  (when *self*
    (let* ((pkg (find-package (getf *self* :package)))
           (new-hash (compute-symbol-hash pkg)))
      (unless (eql new-hash *symbol-hash*)
        (setf *symbol-hash* new-hash)
        (setf (getf *self* :symbol-hash) new-hash
              (getf *self* :updated-at) (get-universal-time))
        (write-node-file (getf *self* :name) *self*)
        (format t "~&[consortium] Exports changed, registration updated~%")))))

(defun start-self-monitor ()
  ;; Clean up existing thread to allow re-registration.
  (when (and *self-monitor-thread* (bt:thread-alive-p *self-monitor-thread*))
    (bt:destroy-thread *self-monitor-thread*))
  (setf *self-monitor-thread*
        (bt:make-thread
         (lambda ()
           (loop
             (sleep *self-monitor-interval*)
             (ignore-errors (update-registration))))
         :name "consortium-self-monitor")))

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

(defun register-exit-hook (name)
  ;; Different implementations have different hook mechanisms.
  ;; We want to clean up our registry file on graceful exit so other
  ;; nodes don't waste time trying to contact us.
  (let ((cleanup (lambda ()
                   (ignore-errors (delete-node-file name))
                   (ignore-errors (stop-monitors)))))
    #+sbcl (push cleanup sb-ext:*exit-hooks*)
    #+ccl (push cleanup ccl:*lisp-cleanup-functions*)
    #+ecl (push cleanup si:*exit-hooks*)
    #-(or sbcl ccl ecl)
    (warn "No exit hook mechanism known for this implementation")))

(defun register-source (source-package &key name)
  "Register this Lisp image as a node in the consortium network.
   Call this from your application's config file."
  (let* ((pkg (find-package source-package))
         (node-name (or name (package-name pkg)))
         (port (find-free-port))
         (info (list :name node-name
                     :package (package-name pkg)
                     :port port
                     :hostname "localhost"
                     ;; PID helps distinguish between restarts of the same app.
                     :pid #+sbcl (sb-posix:getpid)
                          #+ccl (ccl::getpid)
                          #-(or sbcl ccl) 0
                     :registered-at (get-universal-time)
                     :symbol-hash nil)))
    (unless pkg
      (error "Package ~A not found" source-package))

    (start-micros port)

    ;; Compute initial symbol hash for change detection.
    (setf *symbol-hash* (compute-symbol-hash pkg))
    (setf (getf info :symbol-hash) *symbol-hash*)

    (write-node-file node-name info)
    (setf *self* info)

    (register-exit-hook node-name)

    ;; Background monitors make the network self-healing.
    (start-heartbeat)
    (start-self-monitor)

    (format t "~&[consortium] ~A registered on port ~A~%" node-name port)
    info))

(defun unregister ()
  "Remove this node from the network."
  (when *self*
    (stop-monitors)
    (delete-node-file (getf *self* :name))
    (format t "~&[consortium] ~A unregistered~%" (getf *self* :name))
    (setf *self* nil
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
  (or (gethash (string name) *nodes-cache*)
      (error "Unknown node: ~A" name)))

;;;; =========================================================================
;;;; Remote Evaluation
;;;; =========================================================================

(defun eval-at (node form)
  "Evaluate FORM in another node's image."
  (let* ((info (get-node (string node)))
         (port (getf info :port))
         (host (getf info :hostname)))
    (handler-case
        (micros-client:with-slime-connection (conn host port)
          (micros-client:slime-eval form conn))
      (error (e)
        ;; If we can't reach a node, remove it from the registry so others
        ;; don't waste time on it. The node will re-register if it comes back.
        (delete-node-file (string node))
        (remhash (string node) *nodes-cache*)
        (error "Node ~A unreachable (pruned): ~A" node e)))))

(defun broadcast (form)
  "Evaluate FORM in all registered nodes."
  ;; Collect results even if some nodes fail, so partial results are still useful.
  (loop for info in (nodes)
        for name = (getf info :name)
        collect (cons name (ignore-errors (eval-at name form)))))

;;;; =========================================================================
;;;; Symbol Sharing
;;;; =========================================================================

(defun import-remote-symbols (node)
  "Create local stubs that proxy calls to a remote node's exports."
  (let* ((info (get-node (string node)))
         (remote-pkg (getf info :package))
         (node-name (getf info :name))
         ;; Fetch the list of exported symbol names from the remote.
         (symbols (eval-at node
                    `(loop for s being the external-symbols of ,remote-pkg
                           collect (symbol-name s)))))
    (dolist (sym-name symbols)
      (let ((local-sym (intern sym-name :consortium)))
        ;; Each stub captures the node name and symbol name, then delegates.
        ;; This creates transparent remote procedure calls.
        (let ((captured-name node-name)
              (captured-sym sym-name)
              (captured-pkg remote-pkg))
          (setf (symbol-function local-sym)
                (lambda (&rest args)
                  (eval-at captured-name
                    `(apply (find-symbol ,captured-sym ,captured-pkg)
                            ',args)))))
        (export local-sym :consortium)))
    (format t "~&[consortium] Imported ~A symbols from ~A~%"
            (length symbols) node-name)
    symbols))

(defun sync-all ()
  "Import exported symbols from all registered nodes."
  ;; Skip ourselves to avoid circular stubs.
  (dolist (info (nodes))
    (let ((name (getf info :name)))
      (unless (and *self* (string= name (getf *self* :name)))
        (ignore-errors (import-remote-symbols name))))))
