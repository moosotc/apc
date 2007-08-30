#!/bin/sh

#set -x
set -e

h=$(readlink -f $(dirname $0))
r=$(readlink -f $h/..)
t=$r/tbs
d=MD5

export OCAMLRUNPARAM=b

if test $h = $PWD; then
    mkdir -p build
    cd build
fi

if ! md5sum --status -c $d; then
    cp $h/build.ml build1.ml
    md5sum $h/build.ml $h/build.sh $t/tbs.cma >$d.tmp
    ocamlc.opt -g -thread -I $t unix.cma threads.cma tbs.cma build1.ml -o b
    mv $d.tmp $d
fi

targets="apc"
./b -O src:$h $* $targets
