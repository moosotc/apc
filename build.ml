let start = Unix.gettimeofday ();;
open List;;
open Typs;;
open Utils;;
open State;;
open Helpers;;

let jobs, targets, dodeplist, dotarlist = getopt ();;

let srcdir =
  match getval "src" with
  | None -> failwith "no source dir"
  | Some s -> s
;;

let _ =
  cmopp ~flags:"-g -I +lablGL -thread" ~dirname:srcdir "apc";
  ocaml
    "ocamlc.opt"
    "-ccopt '-Wall -o ml_apc.o'"
    "ml_apc.o"
    (StrSet.singleton "ml_apc.o")
    [Filename.concat srcdir "ml_apc.c"]
    StrSet.empty
  ;
  let prog base =
    gcc "gcc" true
      "-Wall -Werror -g -c" ""
      (base ^ ".o")
      [Filename.concat srcdir (base ^ ".c")]
    ;
    gcc "gcc" false
      "" ""
      base
      [base ^ ".o"]
    ;
  in
  prog "hog";
  prog "idlestat";
  ocaml
    "ocamlc.opt"
    "-custom -thread -g -I +lablGL lablgl.cma lablglut.cma unix.cma threads.cma"
    "apc"
    (StrSet.singleton "apc")
    ["ml_apc.o"; "apc.cmo"]
    StrSet.empty
  ;
  let _ =
    let moddir = Filename.concat srcdir "mod" in
    let modconts = Sys.readdir moddir in
    let deps = Array.fold_left (fun deps s ->
      if String.length s > 0 && s.[0] != '.'
      then
        let src = Filename.concat moddir s in
        add_target s (StrSet.singleton src) (StrSet.singleton s) (StrSet.singleton src);
        let build =
          let commands _ =
            [Run ("cp " ^ Filename.quote src ^ " " ^ Filename.quote s)]
          and cookie _ = "cp"
          and presentation _ =
            "COPY"
          in
          { get_commands = commands
          ; get_cookie = cookie
          ; get_presentation = presentation
          }
        in
        State.put_build_info s build;
        StrSet.add s deps
      else
        deps
    ) StrSet.empty modconts
    in
    let build =
      let commands _ =  [Run ("make")]
      and cookie _ = "make"
      and presentation _ = "KBUILD" in
      { get_commands = commands
      ; get_cookie = cookie
      ; get_presentation = presentation
      }
    in
    add_phony "mod" deps "";
    State.put_build_info "mod" build;
  in
  ()
;;

let () =
  Helpers.run start jobs targets dodeplist dotarlist
;;
