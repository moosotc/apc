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
  cmo "-g -I +lablGL -thread" [srcdir] srcdir "apc";
  ocaml
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
        let build _ =
          let c = [Run ("cp " ^ Filename.quote src ^ " " ^ Filename.quote s)] in
          c, c, "COPY"
        in
        State.put_build_info s build;
        StrSet.add s deps
      else
        deps
    ) StrSet.empty modconts
    in
    let build _ =
      let c = [Run ("make")] in
      c, c, "KBUILD"
    in
    add_phony "mod" deps [];
    State.put_build_info "mod" build;
  in
  ()
;;

let () =
  let start = Unix.gettimeofday () in
  Scan.all targets;
  if dodeplist
  then
    List.iter State.print_deps targets
  else
    begin
      let build path =
        let built = Unix.handle_unix_error Build.path path in
        if not !Config.silent
        then
          if built
          then print_endline (path ^ " has been built")
          else print_endline ("nothing to be done for " ^ path)
        ;
      in
      if jobs = 1
      then
        iter build targets
      else
        let rec loop i tids = if i = jobs then tids else
            let tid = Thread.create (fun () -> iter build targets) () in
            loop (succ i) (tid :: tids)
        in
        let tids = loop 0 [] in
        iter Thread.join tids
    end
  ;
  Cache.save !State.Config.cache;
  let stop = Unix.gettimeofday () in
  Format.eprintf "build took %f seconds@." (stop -. start);
;;
