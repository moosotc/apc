set libs=unix.cma lablgl.cma lablglut.cma threads.cma
set flags=-custom -thread -I +lablGL
ocamlc -o apc.exe %flags% %libs% apc.ml ml_apc.c -cclib user32.lib
REM link /edit /subsystem:windows apc.exe
