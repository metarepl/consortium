(in-package :consortium/minimal)

;; Filesystem coordination because images are in separate OS processes.
(defvar *registry* (merge-pathnames ".consortium-minimal/" (user-homedir-pathname)))

(defun make-name (name)
  "converts string or keyword or symbol to string"
  (format nil "~(~A~)" name))

(defun register (name &optional (port (+ 40000 (random 100))))
  "Register this image and start server."
  (ensure-directories-exist *registry*)
  (micros:create-server :port port :dont-close t)
  (setf micros:*use-dedicated-output-stream* t)
  (with-open-file (s (merge-pathnames (concatenate 'string (make-name name) ".node")
                                      *registry*)
                     :direction :output
                     :if-exists :supersede)
    (prin1 (list :name (make-name name) :port port) s))
  (format t "~&[consortium] registered ~A on port ~A~%" (make-name name) port))

(defun nodes ()
  "List all registered nodes."
  (loop for f in (directory (merge-pathnames "*.node" *registry*))
        collect (with-open-file (s f) (read s))))

(defun eval-in (name form)
  "Evaluate FORM at NAME."
  (let* ((info (find (make-name name) (nodes)
                     :key (lambda (i) (getf i :name))
                     :test #'string-equal))
         (port (getf info :port)))
    (swank-client:with-slime-connection (c "localhost" port)
      (swank-client:slime-eval form c))))
