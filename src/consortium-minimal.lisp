(in-package :target-pak/minimal)

;; Filesystem coordination because images are in separate OS processes.
(defvar *registry* (merge-pathnames ".target-pak/" (user-homedir-pathname)))

(defun register (name &optional (port (+ 40000 (random 100))))
  "Register this image and start swank."
  (ensure-directories-exist *registry*)
  (swank:create-server :port port :dont-close t)
  (with-open-file (s (merge-pathnames (format nil "~(~A~)" name) *registry*)
                     :direction :output :if-exists :supersede)
    (prin1 (list :name name :port port) s))
  (format t "~&[target-pak] ~A on port ~A~%" name port))

(defun nodes ()
  "List all registered nodes."
  (loop for f in (directory (merge-pathnames "*" *registry*))
        collect (with-open-file (s f) (read s))))

(defun eval-at (name form)
  "Evaluate FORM at NAME."
  (let* ((info (find name (nodes) :key (lambda (i) (getf i :name)) :test #'string-equal))
         (port (getf info :port)))
    (swank-client:with-slime-connection (c "localhost" port)
      (swank-client:slime-eval form c))))
