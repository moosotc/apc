open Format

let (|>) x f = f x
let (|<) f x = f x

let font = Glut.BITMAP_HELVETICA_12
let draw_string ?(font=font) x y s =
  GlPix.raster_pos ~x ~y ();
  String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c)) s

module NP = struct
  type sysinfo =
      { uptime: int64
      ; loads: int64 * int64 * int64
      ; totalram: int64
      ; freeram: int64
      ; sharedram: int64
      ; bufferram: int64
      ; totalswap: int64
      ; freeswap: int64
      ; procs: int64
      }

  external get_nprocs : unit -> int = "ml_get_nprocs"
  external idletimeofday : Unix.file_descr -> int -> float array
    = "ml_idletimeofday"
  external sysinfo : unit -> sysinfo = "ml_sysinfo"
  external waitalrm : unit -> unit = "ml_waitalrm"
  external get_hz : unit -> int = "ml_get_hz"
  external setnice : int -> unit = "ml_nice"
  external delay : float -> unit = "ml_delay"
  external is_winnt : unit -> bool = "ml_is_winnt"

  let winnt = is_winnt ()

  let user    = 0
  let nice    = 1
  let sys     = 2
  let idle    = 3
  let iowait  = 4
  let intr    = 5
  let softirq = 6

  let hz = get_hz () |> float

  let jiffies_to_sec j =
    float j /. hz

  let parse_uptime () =
    let ic = open_in "/proc/uptime" in
    let vals = Scanf.fscanf ic "%f %f" (fun u i -> (u, i)) in
      close_in ic;
      vals

  let nprocs = get_nprocs ()

  let rec parse_int_cont s pos =
    let slen = String.length s in
    let pos =
      let rec skipws pos =
        if pos = slen
        then pos
        else
          if String.get s pos = ' '
          then succ pos |> skipws
          else pos
      in skipws pos
    in
    let endpos =
      try String.index_from s pos ' '
      with Not_found -> slen
    in
    let i = endpos - pos |> String.sub s pos
                         |> int_of_string
                         |> jiffies_to_sec in
      if endpos = slen
      then
        `last i
      else
        `more (i, fun () -> succ endpos |> parse_int_cont s)

  let parse_cpul s =
    let rec tolist accu = function
      | `last i -> i :: accu
      | `more (i, f) -> f () |> tolist (i :: accu)
    in
    let index = String.index s ' ' in
    let cpuname = String.sub s 0 index in
    let vals = parse_int_cont s (succ index) |> tolist [] in
    let vals = List.rev |<
        if List.length vals < 7
        then
          0.0 :: 0.0 :: 0.0 :: 0.0 :: vals
        else
          vals
    in
      cpuname, Array.of_list vals

  let parse_stat () =
    if winnt
    then
      fun () ->
        let ia = idletimeofday Unix.stdin nprocs in
        let rec convert accu total n =
          if n = nprocs
          then
            let t = total in
            let a = "cpu", Array.make 7 t in
              a :: List.rev accu
          else
            let i = Array.get ia n in
            let total = total +. i in
            let v = "cpu" ^ string_of_int n, Array.make 7 i in
              convert |< v :: accu |< total |< succ n
        in
          convert [] 0.0 0
    else
      fun () ->
        let ic = open_in "/proc/stat" in
        let rec loop i accu =
          if i = -1
          then List.rev accu
          else (input_line ic |> parse_cpul) :: accu |> loop (pred i)
        in
        let ret = loop nprocs [] in
          close_in ic;
          ret

  let getselfdir () =
    try
      Filename.dirname |< Unix.readlink "/proc/self/exe"
    with exn ->
      "./"
end

module Args = struct
  let banner =
    [ "Amazing Piece of Code by insanely gifted programmer, Version 0.97a"
    ; "Motivation by: gzh and afs"
    ; "usage: "
    ] |> String.concat "\n"

  let freq     = ref 1.0
  let interval = ref 15.0
  let devpath  = NP.getselfdir () |> Filename.concat |< "itc" |> ref
  let pgrid    = ref 10
  let sgrid    = ref 10
  let w        = ref 400
  let h        = ref 200
  let verbose  = ref false
  let delay    = ref 0.04
  let ksampler = ref true
  let barw     = ref 100
  let bars     = ref 50
  let sigway   = ref true
  let niceval  = ref 0
  let gzh      = ref false
  let scalebar = ref false
  let timer    = ref 100
  let debug    = ref false
  let poly     = ref false
  let uptime   = ref false
  let icon     = ref false
  let labels   = ref true
  let mgrid    = ref false

  let pad n s =
    let l = String.length s in
      if l >= n
      then
        s
      else
        let d = String.make n ' ' in
          StringLabels.blit ~src:s ~dst:d
            ~src_pos:0 ~len:l
            ~dst_pos:0;
          d

  let sooo b = if b then "on" else "off"
  let dA tos s {contents=v} = s ^ " (" ^ tos v ^ ")"
  let dF = dA |< sprintf "%4.2f"
  let dB = dA sooo
  let dcB = dA sooo
  let dI = dA string_of_int
  let dS = dA (fun s -> "`" ^ String.escaped s ^ "'")

  let sF opt r doc =
    "-" ^ opt, Arg.Set_float r, pad 9 "<float> " ^ doc |> dF |< r

  let sI opt r doc =
    "-" ^ opt, Arg.Set_int r, pad 9 "<int> " ^ doc |> dI |< r

  let sB opt r doc =
    "-" ^ opt, Arg.Set r, pad 9 "" ^ doc |> dB |< r

  let sS opt r doc =
    "-" ^ opt, Arg.Set_string r, pad 9 "<string> " ^ doc |> dS |< r

  let fB opt r doc =
    if r.contents
    then
      "-" ^ opt, Arg.Clear r, pad 9 "" ^ doc |> dB |< r
    else
      "-" ^ opt, Arg.Clear r, pad 9 "" ^ doc |> dcB |< r

  let init () =
    let opts =
      [ sF "f" freq "sampling frequency in seconds"
      ; sF "D" delay "refresh delay in seconds"
      ; sF "i" interval "history interval in seconds"
      ; sI "p" pgrid "percent grid items"
      ; sI "s" sgrid "history grid items"
      ; sI "w" w "width"
      ; sI "h" h "height"
      ; sI "b" barw "bar width"
      ; sI "B" bars "number of CPU bars"
      ; sI "n" niceval "value to renice self on init"
      ; sI "t" timer "timer frequency in herz"
      ; sS "d" devpath "path to itc device"
      ; fB "k" ksampler |< "kernel sampler"
        ^ (if NP.winnt then "" else " (`/proc/[stat|uptime]')")
      ; fB "g" gzh "gzh way (does not quite work yet)"
      ; fB "u" uptime
        "`uptime' instead of `stat' as kernel sampler (UP only)"
      ; sB "v" verbose "verbose"
      ; fB "S" sigway "sigwait delay method"
      ; fB "c" scalebar "constant bar width"
      ; fB "P" poly "filled area instead of lines"
      ; fB "I" icon "icon (hack)"
      ; fB "l" labels "labels"
      ; fB "m" mgrid "moving grid"
      ]
    in
    let opts =
      if NP.winnt
      then
        begin
          let nixopts = ["-n"; "-u"; "-d"; "-I"; "-S"; "-g"] in
            prerr_endline "Only kernel sampler is available on Windows";
            List.filter (fun (s, _, _) -> List.mem s nixopts |> not) opts
        end
      else
        opts
    in
      Arg.parse opts
        (fun s ->
          "don't know what to do with " ^ s |> prerr_endline;
          exit 100
        )
        banner
end

module Gzh = struct
  let lim = ref 0
  let stop = ref false
  let refdt = ref 0.0

  let rec furious_cycle i =
    if not !stop && i > 0
    then pred i |> furious_cycle
    else (i, Unix.gettimeofday ())

  let init verbose =
    let t = 0.5 in
    let it = { Unix.it_interval = t; it_value = t } in
    let tries = 1 in
    let handler =
      let n = ref tries in
        fun _ ->
          decr n;
          stop := !n = 0;
    in
    let sign = Sys.sigalrm in
    let oldh = Sys.signal sign |< Sys.Signal_handle handler in
    let oldi = Unix.setitimer Unix.ITIMER_REAL it in
    let oldbp = Unix.sigprocmask Unix.SIG_BLOCK [sign] in
    let () = NP.waitalrm () in
    let () = stop := false in
    let oldup = Unix.sigprocmask Unix.SIG_UNBLOCK [sign] in
    let t1 = Unix.gettimeofday () in
    let n, t2 = furious_cycle max_int in
    let () = refdt := t2 -. t1 in
    let () = lim := tries * (max_int - n) in
    let () = if verbose then
        begin
          printf "Completed %d iterations in %f seconds@." !lim !refdt
        end in
    let _ = Unix.sigprocmask Unix.SIG_UNBLOCK oldup in
    let _ = Unix.setitimer Unix.ITIMER_REAL oldi in
    let _ = Unix.sigprocmask Unix.SIG_BLOCK oldbp in
    let _ = Sys.signal sign oldh in
      ()
  ;;

  let gen f =
    let thf () =
      NP.setnice 20;
      stop := false;
      let l = ref 0 in
      let rec loop t1 =
        let _, t2 = furious_cycle !lim in
        let dt = t2 -. t1 in
          incr l;
          if !Args.debug && !l > 10
          then
            begin
              printf "Completed %d iterations in %f seconds load %f@."
                !lim dt |< !refdt /. dt;
              l := 0;
            end
          ;
          !refdt /. dt |> f;
          loop t2
      in
        Unix.gettimeofday () |> loop
    in
    let _ = Thread.create thf () in
      ()
  ;;
end

let oohz oohz fn =
  let prev = ref 0.0 in
    fun () ->
      let a = !prev in
      let b = Unix.gettimeofday () in
        if b -. a > oohz
        then
          begin
            prev := b;
            fn ()
          end

module Delay = struct
  let sighandler signr = ()

  let winfreq = ref 0.0

  let init freq gzh =
    if NP.winnt
    then
      winfreq := 1.0 /. float freq
    else
      let () =
        Sys.Signal_handle sighandler |> Sys.set_signal Sys.sigalrm;
        if !Args.sigway
        then
          let l = if gzh then [Sys.sigprof; Sys.sigvtalrm] else [] in
            Unix.sigprocmask Unix.SIG_BLOCK |< Sys.sigalrm :: l |> ignore;
      ;
      in
      let v = 1.0 /. float freq in
      let t = { Unix.it_interval = v; it_value = v } in
      let _ = Unix.setitimer Unix.ITIMER_REAL t in
        ()

  let delay () =
    if NP.winnt
    then
      NP.delay !winfreq
    else
      begin
        if !Args.sigway
        then
          NP.waitalrm ()
        else
          begin
            try let _ = Unix.select [] [] [] ~-.1.0 in ()
            with Unix.Unix_error (Unix.EINTR, _, _) -> ()
          end
      end
end

type sampler =
    { color : Gl.rgb;
      getyielder : unit -> unit -> float option;
      update : float -> float -> float -> float -> unit;
    }

module Sampler(T : sig val nsamples : int val freq : float end) =
struct
  let nsamples = T.nsamples + 1
  let samples = Array.create nsamples 0.0
  let head = ref 0
  let tail = ref 0
  let active = ref 0

  let update v n =
    let n = min nsamples n in
    let rec loop i j =
      if j = 0
      then ()
      else
        let i = if i = nsamples then 0 else i in
          Array.set samples i v;
          loop (succ i) (pred j)
    in
    let () = loop !head n in
    let () = head := (!head + n) mod nsamples in
    let () = active := min (!active + n) nsamples in
      ();
  ;;

  let getyielder () =
    let tail =
      let d = !head - !active in
        if d < 0
        then nsamples + d
        else d
    in
    let ry = ref (fun () -> assert false) in
    let rec yield i () =
      if i = !active
      then None
      else
        begin
          ry := succ i |> yield;
          Some ((i + tail) mod nsamples |> Array.get samples)
        end
    in
      ry := yield 0;
      (fun () -> !ry ());
  ;;

  let update t1 t2 i1 i2 =
    let d = t2 -. t1 in
    let i = i2 -. i1 in
    let isamples = d /. T.freq |> truncate in
    let l = 1.0 -. (i /. d) in
      update l isamples;
  ;;
end

module type ViewSampler =
sig
  val getyielder : unit -> unit -> float option
  val update : float -> float -> float -> float -> unit
end

module type View =
sig
  val x : int
  val y : int
  val w : int
  val h : int
  val sgrid : int
  val pgrid : int
  val freq : float
  val interval : float
  val samplers : sampler list
end

module View(V: sig val w : int val h : int end) = struct
  let ww = ref 0
  let wh = ref 0
  let funcs = ref []

  let keyboard ~key ~x ~y =
    if key = 27 || key = Char.code 'q'
    then exit 0

  let add dri =
    funcs := dri :: !funcs

  let display () =
    GlClear.clear [`color];
    List.iter (fun (display, _, _) -> display ()) !funcs;
    Glut.swapBuffers ()

  let reshape ~w ~h =
    ww := w;
    wh := h;
    List.iter (fun (_, reshape, _) -> reshape w h) !funcs;
    GlClear.clear [`color];
    GlMat.mode `modelview;
    GlMat.load_identity ();
    GlMat.mode `projection;
    GlMat.load_identity ();
    GlMat.rotate ~y:1.0 ~angle:180.0 ();
    GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
    GlMat.scale ~x:2.0 ~y:2.0 ();
    Glut.postRedisplay ()

  let init () =
    let () =
      Glut.initDisplayMode ~double_buffer:true ();
      Glut.initWindowSize V.w V.h
    in
    let winid = Glut.createWindow "APC" in
      Glut.displayFunc display;
      Glut.reshapeFunc reshape;
      Glut.keyboardFunc keyboard;
      GlDraw.color (1.0, 1.0, 0.0);
      winid;
  ;;

  let inc () = List.iter (fun (_, _, inc) -> inc ()) !funcs
  let update = Glut.postRedisplay
  let func = Glut.idleFunc
  let run = Glut.mainLoop
end

module Bar(T: sig val barw : int val bars : int end) = struct
  let nbars = T.bars
  let kload = ref 0.0
  let iload = ref 0.0
  let vw = ref 0
  let vh = ref 0
  let sw = float T.barw /. float !Args.w
  let bw = ref 0
  let m = 1
  let fw = 3 * Glut.bitmapWidth font (Char.code 'W')
  let ksepsl, isepsl =
    let base = GlList.gen_lists ~len:2 in
      GlList.nth base ~pos:0,
      GlList.nth base ~pos:1

  let getlr = function
    | `k -> 0.01, 0.49
    | `i -> 0.51, 0.99

  let seps ki =
    let xl, xr = getlr ki in
    let y = 18 in
    let h = !vh - 15 - y in
    let () = GlDraw.viewport m y !bw h in
    let () =
      GlMat.push ();
      GlMat.load_identity ();
      GlMat.rotate ~y:1.0 ~angle:180.0 ();
      GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
      GlMat.scale ~x:2.0 ~y:(2.0 /. float h) ()
    in
    let barm = 1 in
    let mspace = barm * nbars in
    let barh = (h + 66 - mspace / 2) / nbars |> float in
    let barm = float barm in
    let rec loop i yb =
      if i = T.bars
      then ()
      else
        let yt = yb +. barm in
        let yn = yt +. barh in
          GlDraw.vertex2 (xl, yb);
          GlDraw.vertex2 (xl, yt);
          GlDraw.vertex2 (xr, yt);
          GlDraw.vertex2 (xr, yb);
          succ i |> loop |< yn
    in
      GlDraw.color (0.0, 0.0, 0.0);
      GlDraw.begins `quads;
      loop 0 barh;
      GlDraw.ends ();
      GlMat.pop ();
  ;;

  let reshape w h =
    vw := w;
    vh := h;
    bw :=
      if !Args.scalebar
      then
        (float w *. sw |> truncate) - m
      else
        T.barw - m
    ;

    GlList.begins ksepsl `compile;
    seps `k;
    GlList.ends ();

    GlList.begins isepsl `compile;
    seps `i;
    GlList.ends ();
  ;;

  let drawseps = function
    | `k -> GlList.call ksepsl
    | `i -> GlList.call isepsl
  ;;

  let display () =
    let kload = min !kload 1.0 |> max 0.0 in
    let iload = min !iload 1.0 |> max 0.0 in
    let () = GlDraw.viewport m 0 !bw 15 in
    let () =
      GlDraw.color (1.0, 1.0, 1.0);
      let kload = 100.0 *. kload in
      let iload = 100.0 *. iload in
      let () =
        GlMat.push ();
        GlMat.load_identity ();
        GlMat.scale ~x:(1.0/.float !bw) ~y:(1.0/.30.0) ()
      in
      let ix = !bw / 2 - fw |> float in
      let kx = - (fw + !bw / 2) |> float in
      let () = sprintf "%5.2f" iload |> draw_string ix 0.0 in
      let () = sprintf "%5.2f" kload |> draw_string kx 0.0 in
      let () = GlMat.pop () in ()
    in

    let y = 18 in
    let h = !vh - 15 - y in
    let () = GlDraw.viewport m y !bw h in
    let () =
      GlMat.push ();
      GlMat.load_identity ();
      GlMat.rotate ~y:1.0 ~angle:180.0 ();
      GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
      GlMat.scale ~x:2.0 ~y:(2.0 /. float h) ()
    in
    let drawbar load ki =
      let xl, xr = getlr ki in
      let drawquad yb yt =
        GlDraw.begins `quads;
        GlDraw.vertex2 (xl, yb);
        GlDraw.vertex2 (xl, yt);
        GlDraw.vertex2 (xr, yt);
        GlDraw.vertex2 (xr, yb);
        GlDraw.ends ()
      in
      let yt = float h *. load in
      let yb = 0.0 in
      let () = drawquad yb yt in
      let () = GlDraw.color (0.5, 0.5, 0.5) in
      let yb = yt in
      let yt = float h in
      let () = drawquad yb yt in
        drawseps ki
    in
      GlDraw.color (1.0, 1.0, 0.0);
      drawbar iload `k;
      GlDraw.color (1.0, 0.0, 0.0);
      drawbar kload `i;
      GlMat.pop ();
  ;;

  let update kload' iload' =
    kload := kload' /. float NP.nprocs;
    iload := iload' /. float NP.nprocs;
  ;;
end

module Graph (V: View) = struct
  let ox = if !Args.scalebar then 0 else !Args.barw
  let sw = float V.w /. float (!Args.w - ox)
  let sh = float V.h /. float !Args.h
  let sx = float (V.x - ox)  /. float V.w
  let sy = float V.y /. float V.h
  let vw = ref 0
  let vh = ref 0
  let vx = ref 0
  let vy = ref 0
  let scale = V.freq /. V.interval
  let gscale = 1.0 /. float V.sgrid
  let nsamples = ref 0

  let fw, fh =
    if !Args.labels
    then 3 * Glut.bitmapWidth font (Char.code '%'), 20
    else 0, 10

  let gridlist =
    let base = GlList.gen_lists ~len:1 in
      GlList.nth base ~pos:0

  let viewport typ =
    let ox = if !Args.scalebar then 0 else !Args.barw in
    let x, y, w, h =
      match typ with
        | `labels -> (!vx + ox, !vy + 5, fw, !vh - fh)
        | `graph  -> (!vx + fw + 5 + ox, !vy + 5, !vw - fw - 10, !vh - fh)
    in
      GlDraw.viewport x y w h;
  ;;

  let sgrid () =
    for i = 0 to V.sgrid
    do
      let x = if i = 0 then 0.0009 else float i *. gscale in
        GlDraw.vertex ~x ~y:0.0 ();
        GlDraw.vertex ~x ~y:1.0 ();
    done;
  ;;

  let grid () =
    viewport `graph;
    GlDraw.line_width 1.0;
    GlDraw.color (0.0, 1.0, 0.0);
    GlDraw.begins `lines;
    if !Args.mgrid
    then
      begin
        GlDraw.vertex2 (0.0009, 0.0);
        GlDraw.vertex2 (0.0009, 1.0);
        GlDraw.vertex2 (1.0000, 0.0);
        GlDraw.vertex2 (1.0000, 1.0);
      end
    else
      sgrid ()
    ;
    let () =
      let lim = 100 / V.pgrid in
        for i = 0 to lim
        do
          let y = (i * V.pgrid |> float) /. 100.0 in
          let y = if i = lim then y -. 0.0009 else y in
            GlDraw.vertex ~x:0.0 ~y ();
            GlDraw.vertex ~x:1.0 ~y ();
        done;
    in
    let () = GlDraw.ends () in
      if !Args.labels
      then
        begin
          viewport `labels;
          GlDraw.color (1.0, 1.0, 1.0);
          let ohp = 100.0 in
            for i = 0 to 100 / V.pgrid
            do
              let p = i * V.pgrid in
              let y = float p /. ohp in
              let s = Printf.sprintf "%3d%%" p in
                draw_string 1.0 y s
            done
        end
  ;;

  let reshape w h =
    let wxsw = float (w - ox) *. sw
    and hxsh = float h *. sh in
      vw := wxsw |> truncate;
      vh := hxsh |> truncate;
      vx := wxsw *. sx |> truncate;
      vy := hxsh *. sy |> truncate;
      GlList.begins gridlist `compile;
      grid ();
      GlList.ends ();
  ;;

  let swap =
    Glut.swapBuffers |> oohz !Args.delay;
  ;;

  let inc () = incr nsamples

  let mgrid () =
    GlDraw.line_width 1.0;
    GlDraw.color (0.0, 1.0, 0.0);
    GlDraw.begins `lines;
    let offset =
      ((pred !nsamples |> float) *. scale /. gscale |> modf |> fst) *. gscale
    in
      for i = 0 to pred V.sgrid
      do
        let x = offset +. float i *. gscale in
          GlDraw.vertex ~x ~y:0.0 ();
          GlDraw.vertex ~x ~y:1.0 ();
      done;
      GlDraw.ends ();
  ;;

  let display () =
    GlList.call gridlist;
    viewport `graph;
    if !Args.mgrid then mgrid ();
    GlDraw.line_width 1.5;

    let sample sampler =
      GlDraw.color sampler.color;
      let () =
        if not !Args.poly
        then GlDraw.begins `line_strip
        else
          begin
            GlDraw.begins `polygon;
            GlDraw.vertex2 (0.0, 0.0);
          end
      in
      let yield = sampler.getyielder () in
      let rec loop last i =
        match yield () with
          | Some y as opty ->
              let x = float i *. scale in
                GlDraw.vertex ~x ~y ();
                loop opty (succ i)
          | None ->
              if !Args.poly
              then
                match last with
                  | None -> ()
                  | Some y ->
                      let x = float (pred i) *. scale in
                        GlDraw.vertex ~x ~y:0.0 ()
      in
        loop None 0;
        GlDraw.ends ();
    in
      List.iter sample V.samplers;
  ;;

  let funcs = display, reshape, inc
end

let getplacements w h n barw =
  let sr = float n |> sqrt |> ceil |> truncate in
  let d = n / sr in
  let r = if n mod sr = 0 then 0 else 1 in
  let x, y =
    if w - barw > h
    then
      sr + r, d
    else
      d, sr + r
  in
  let w' = w - barw in
  let h' = h in
  let vw = w' / x in
  let vh = h' / y in
  let rec loop accu i =
    if i = n
    then accu
    else
      let yc = i / x in
      let xc = i mod x in
      let xc = xc * vw + barw in
      let yc = yc * vh in
        (i, xc, yc) :: accu |> loop |< succ i
  in
    loop [] 0, vw, vh

let create fd w h =
  let module S =
      struct
        let freq = !Args.freq
        let nsamples = !Args.interval /. freq |> ceil |> truncate
      end
  in
  let placements, vw, vh = getplacements w h NP.nprocs !Args.barw in

  let iget () = NP.idletimeofday fd NP.nprocs in
  let is = iget () in

  let kget () =
    let gks = NP.parse_stat () in
      gks () |> Array.of_list
  in
  let ks = kget () in

  let crgraph (kaccu, iaccu, gaccu) (i, x, y) =
    let module Si = Sampler (S) in
    let isampler =
      { getyielder = Si.getyielder
      ; color = (1.0, 1.0, 0.0)
      ; update = Si.update
      }
    in
    let (kcalc, ksampler) =
      let module Sc = Sampler (S) in
      let sampler =
        { getyielder = Sc.getyielder
        ; color = (1.0, 0.0, 0.0)
        ; update = Sc.update
        }
      in
      let calc =
        if !Args.gzh
        then
          let d = ref 0.0 in
          let f d' = d := d' in
          let () = Gzh.gen f in
            fun _ _ _ -> (0.0, !d)
        else
          if !Args.uptime
          then
            let (u1, i1) = NP.parse_uptime () in
            let u1 = ref u1
            and i1 = ref i1 in
              fun _ _ _ ->
                let (u2, i2) = NP.parse_uptime () in
                let du = u2 -. !u1
                and di = i2 -. !i1 in
                  u1 := u2;
                  i1 := i2;
                  (0.0, di /. du)
          else
            let i' = if i = NP.nprocs then 0 else succ i in
            let n = NP.idle in
            let g ks = Array.get ks i' |> snd |> Array.get |< n in
            let i1 = g ks |> ref in
              fun ks t1 t2 ->
                let i2 = g ks in
                let i1' = !i1
                and i2' = i2 in
                  i1 := i2;
                  (i1', i2')
      in
        calc, sampler
    in
    let module V =
        struct
          let x = x
          let y = y
          let w = vw
          let h = vh
          let freq = S.freq
          let interval = !Args.interval
          let pgrid = !Args.pgrid
          let sgrid = !Args.sgrid
          let samplers =
            if !Args.ksampler
            then [isampler; ksampler]
            else [isampler]
        end
    in
    let module Graph = Graph (V) in
    let icalc =
      let i1 = Array.get is i |> ref in
        fun is t1 t2 ->
          let i2 = Array.get is i in
            if classify_float i2 = FP_infinite
            then
              (t1, t2)
            else
              let i1' = !i1 in
                i1 := i2;
                (i1', i2)
    in
    let kaccu =
      if !Args.ksampler
      then (i, kcalc, ksampler) :: kaccu
      else kaccu
    in
      kaccu, (i, icalc, isampler) :: iaccu, Graph.funcs :: gaccu
  in
  let kl, il, gl = List.fold_left crgraph ([], [], []) placements in
    ((if kl == [] then (fun () -> [||]) else kget), kl), (iget, il), gl

let opendev path =
  if NP.winnt
  then
    Unix.stdout
  else
    try
      Unix.openfile path [Unix.O_RDONLY] 0
    with
      | Unix.Unix_error (Unix.ENODEV, s1, s2) ->
          eprintf "Could not open ITC device %S:\n%s(%s): %s)\n"
            path s1 s2 |< Unix.error_message Unix.ENODEV;
          eprintf "(perhaps the module is not loaded?)@.";
          exit 100

      | Unix.Unix_error (Unix.ENOENT, s1, s2) ->
          eprintf "Could not open ITC device %S:\n%s(%s): %s\n"
            path s1 s2 |< Unix.error_message Unix.ENOENT;
          exit 100

      | exn ->
          eprintf "Could not open ITC device %S:\n%s\n"
            path |< Printexc.to_string exn;
          exit 100

let seticon () =
  let module X = struct external seticon : string -> unit = "ml_seticon" end in
  let len = 32*4 in
  let data = String.create |< 32*len + 2*4 in
  let line r g b a =
    let r = Char.chr r
    and g = Char.chr g
    and b = Char.chr b
    and a = Char.chr a in
    let s = String.create len in
    let rec fill x =
      if x = len
      then s
      else
        begin
          x + 0 |> String.set s |< b;
          x + 1 |> String.set s |< g;
          x + 2 |> String.set s |< r;
          x + 3 |> String.set s |< a;
          x + 4 |> fill
        end
    in
      fill 0
  in
  let el = line 0x00 0x00 0x00 0xff
  and kl = line 0xff 0x00 0x00 0xff
  and il = line 0xff 0xff 0x00 0xff in
  let fill l sy ey =
    let src = l and dst = data and src_pos = 0 in
    let rec loop n dst_pos =
      if n > 0
      then
        begin
          StringLabels.blit ~src ~src_pos ~dst ~dst_pos ~len;
          pred n |> loop |< dst_pos + len
        end
    in
      (ey - sy) |> loop |< (32 - ey) * len + 4*2
  in
    fun ~iload ~kload ->
      let iy = iload *. 32.0 |> ceil |> truncate |> max 0 |> min 32
      and ky = kload *. 32.0 |> ceil |> truncate |> max 0 |> min 32 in
      let ey =
        if ky < iy
        then (fill kl 0 ky; fill il ky iy; iy)
        else (fill kl 0 ky; ky)
      in
        fill el ey 32;
        X.seticon data;
;;

let main () =
  let _ = Glut.init [|""|] in
  let () = Args.init () in
  let () =
    if !Args.verbose
    then
      "detected " ^ string_of_int NP.nprocs ^ " CPUs" |> print_endline
  in
  let () = if !Args.gzh then Gzh.init !Args.verbose in
  let () = Delay.init !Args.timer !Args.gzh in
  let () = if !Args.niceval != 0 then NP.setnice !Args.niceval in
  let w = !Args.w
  and h = !Args.h in
  let fd = opendev !Args.devpath in
  let module FullV = View (struct let w = w let h = h end) in
  let _winid = FullV.init () in
  let (kget, kfuncs), (iget, ifuncs), gl = create fd w h in
  let bar_update =
    List.iter FullV.add gl;
    if !Args.barw > 0
    then
      let module Bar =
        Bar (struct let barw = !Args.barw let bars = !Args.bars end)
      in
        FullV.add (Bar.display, Bar.reshape, fun _ -> ());
        Bar.update
    else
      fun _ _ -> ()
  in
  let seticon = if !Args.icon then seticon () else fun ~iload ~kload -> () in
  let rec loop t1 () =
    let t2 = Unix.gettimeofday () in
    let dt = t2 -. t1 in
      if dt >= !Args.freq
      then
        let is = iget () in
        let ks = kget () in
        let rec loop2 load s = function
          | [] -> load
          | (nr, calc, sampler) :: rest ->
              let i1, i2 = calc s t1 t2 in
              let thisload = 1.0 -. ((i2 -. i1) /. dt) in
              let thisload = max 0.0 thisload in
              let () =
                if !Args.verbose
                then
                  ("cpu load(" ^ string_of_int nr ^ "): "
                    ^ (thisload *. 100.0 |> string_of_float)
                  |> print_endline)
              in
              let load = load +. thisload in
                sampler.update t1 t2 i1 i2;
                loop2 load s rest
        in
        let iload = loop2 0.0 is ifuncs in
        let kload = loop2 0.0 ks kfuncs in
          if !Args.debug
          then
            begin
              iload |> string_of_float |> prerr_endline;
              kload |> string_of_float |> prerr_endline;
            end
          ;
          seticon ~iload ~kload;
          bar_update kload iload;
          FullV.inc ();
          FullV.update ();
          FullV.func (Some (loop t2))
      else
        Delay.delay ()
  in
    FullV.func (Some (Unix.gettimeofday () |> loop));
    FullV.run ()

let _ =
  try main ()
  with
    | Unix.Unix_error (e, s1, s2) ->
        eprintf "%s(%s): %s@." s1 s2 |< Unix.error_message e

    | exn ->
        Printexc.to_string exn |> eprintf "Exception: %s@."
