(defsystem "metarepl.image.lisp-mash"
  :description "inter-image coordination layer"
  :author "metarepl (https://github.com/metarepl)"
  :version "0.0.1"
  :license "MIT"
  :depends-on (:alexandria
               :serapeum

               :micros
               :swank-client
               :usocket
               :find-port
               :bordeaux-threads

               :journal
               :try)
  :serial t
  :components ((:file "package")
               (:static-file "README.org")
               (:module "src"
                 :components((:file "consortium")
                             (:file "consortium-minimal")))))
