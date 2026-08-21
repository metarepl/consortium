(defsystem "metarepl.image.consortium"
  :description "inter-image coordination layer"
  :author "metarepl (https://github.com/metarepl)"
  :version "0.0.1"
  :license "MIT"
  :depends-on (:alexandria
               :serapeum

               :swank
               :swank-client
               :usocket
               :bordeaux-threads

               :journal
               :try)
  :serial t
  :components ((:file "package")
               (:static-file "README.org")
               (:module "src"
                 :components((:file "consortium")
                             (:file "consortium-minimal")))))
