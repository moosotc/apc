#!/bin/sh

set -e

libs="unix.cma lablgl.cma lablglut.cma threads.cma"
flags="-custom -thread -I +lablGL"
test -z "$comp" && comp=ocamlc
$comp -o apc $flags $libs apc.ml ml_apc.c

(cd mod && make)
