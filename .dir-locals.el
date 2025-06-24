((nil . ((eval . (progn
                   (unless (bound-and-true-p my/lsp-crystal-client-registered)
                     (add-to-list 'lsp-language-id-configuration
                                  '(crystal-mode . "crystal"))
                     (lsp-register-client
                      (make-lsp-client
                       :new-connection (lsp-stdio-connection '("crystalline"))
                       :activation-fn (lsp-activate-on "crystal")
                       :priority 1
                       :server-id 'crystalline))
                     (setq my/lsp-crystal-client-registered t)))))))
