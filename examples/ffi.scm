;(load-ffi "Language.Scheme.Plugins.Examples" "test" "test")
;(load-ffi "Language.Scheme.Plugins.Examples" "test2" "test2")
;(load-ffi "hs-src/Language/Scheme/Plugins/Examples.hs" "Language.Scheme.Plugins.Examples" "test" "test3")
(load-ffi "Language.Scheme.Plugins.CPUTime" "precision" "cpu-time:precision")
(load-ffi "Language.Scheme.Plugins.CPUTime" "elapsed" "cpu-time:elapsed")

;(write (test 1))
;(write (test "1"))
;(write (test2 1))
;(write (test3 "1"))
(write (cpu-time:precision))
(write (cpu-time:elapsed))
(display "elapsed (secs): ")
(display (exact->inexact (/ (cpu-time:elapsed) (cpu-time:precision))))
(newline)
