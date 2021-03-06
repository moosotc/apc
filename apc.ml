open Format

let (|>) x f = f x
let (|<) f x = f x

let font = Glut.BITMAP_HELVETICA_12
let draw_string ?(font=font) x y s =
  GlPix.raster_pos ~x ~y ();
  String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c)) s
;;

type stats =
    { all : float
    ; user : float
    ; nice : float
    ; sys : float
    ; idle : float
    ; iowait : float
    ; intr : float
    ; softirq : float
    }
;;

let zero_stat =
  { all = 0.0
  ; user = 0.0
  ; nice = 0.0
  ; sys = 0.0
  ; idle = 0.0
  ; iowait = 0.0
  ; intr = 0.0
  ; softirq = 0.0
  }
;;

let neg_stat a =
  { all = -.a.all
  ; user = -.a.user
  ; nice = -.a.nice
  ; sys = -.a.sys
  ; idle = -.a.idle
  ; iowait = -.a.iowait
  ; intr = -.a.intr
  ; softirq = -.a.softirq
  }
;;

let scale_stat a s =
  { all = a.all *. s
  ; user = a.user *. s
  ; nice = a.nice *. s
  ; sys = a.sys *. s
  ; idle = a.idle *. s
  ; iowait = a.iowait *. s
  ; intr = a.intr *. s
  ; softirq = a.softirq *. s
  }
;;

let add_stat a b =
  { all = a.all +. b.all
  ; user = a.user +. b.user
  ; nice = a.nice +. b.nice
  ; sys = a.sys +. b.sys
  ; idle = a.idle +. b.idle
  ; iowait = a.iowait +. b.iowait
  ; intr = a.intr +. b.intr
  ; softirq = a.softirq +. b.softirq
  }
;;

module NP =
struct
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
  ;;

  type os =
      | Linux
      | Windows
      | Solaris
      | MacOSX
  ;;

  external get_nprocs : unit -> int = "ml_get_nprocs"
  external idletimeofday : Unix.file_descr -> int -> float array
    = "ml_idletimeofday"
  external sysinfo : unit -> sysinfo = "ml_sysinfo"
  external waitalrm : unit -> unit = "ml_waitalrm"
  external get_hz : unit -> int = "ml_get_hz"
  external setnice : int -> unit = "ml_nice"
  external delay : float -> unit = "ml_delay"
  external os_type : unit -> os = "ml_os_type"
  external solaris_kstat : int -> float array = "ml_solaris_kstat"
  external macosx_host_processor_info : int -> float array =
      "ml_macosx_host_processor_info"
  external windows_processor_times : int -> float array =
      "ml_windows_processor_times"
  external fixwindow : int -> unit = "ml_fixwindow"
  external testpmc : unit -> bool = "ml_testpmc"

  let os_type = os_type ()

  let winnt   = os_type = Windows
  let solaris = os_type = Solaris
  let linux   = os_type = Linux
  let macosx  = os_type = MacOSX

  let user    = 0
  let nice    = 1
  let sys     = 2
  let idle    = 3
  let iowait  = 4
  let intr    = 5
  let softirq = 6

  let hz = get_hz () |> float

  let parse_uptime () =
    let ic = open_in "/proc/uptime" in
    let vals = Scanf.fscanf ic "%f %f" (fun u i -> (u, i)) in
      close_in ic;
      vals
  ;;

  let nprocs = get_nprocs ()

  let rec parse_int_cont s pos =
    let jiffies_to_sec j =
      float j /. hz
    in
    let slen = String.length s in
    let pos =
      let rec skipws pos =
        if pos = slen
        then
          pos
        else
          begin
            if String.get s pos = ' '
            then
              succ pos |> skipws
            else
              pos
          end
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
  ;;

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
  ;;

  let parse_stat () =
    match os_type with
      | Windows ->
          (fun () ->
            let iukw = windows_processor_times nprocs in
            let rec create n ai ak au ad ar accu =
              if n = nprocs
              then
                ("cpu", [| au; ad; ak; ai; 0.0; ar; 0.0 |]) :: List.rev accu
              else
                let hdr = "cpu" ^ string_of_int n in
                let o = n * 5 in
                let i = Array.get iukw (o + 0) in
                let k = Array.get iukw (o + 1) in
                let u = Array.get iukw (o + 2) in
                let d = Array.get iukw (o + 3) in
                let r = Array.get iukw (o + 4) in
                let ai = ai +. i in
                let au = au +. u in
                let ak = ak +. k in
                let ad = ad +. d in
                let ar = ar +. r in
                let accu = (hdr, [| u; d; k; i; 0.0; r; 0.0 |]) :: accu in
                  create (succ n) ai ak au ad ar accu
            in
              create 0 0.0 0.0 0.0 0.0 0.0 []
          )

      | Linux ->
          (fun () ->
            let ic = open_in "/proc/stat" in
            let rec loop i accu =
              if i = -1
              then
                List.rev accu
              else
                (input_line ic |> parse_cpul) :: accu |> loop (pred i)
            in
            let ret = loop nprocs [] in
              close_in ic;
              ret
          )

      | Solaris ->
          (fun () ->
            let iukw = solaris_kstat nprocs in
            let rec create n ai au ak aw accu =
              if n = nprocs
              then
                ("cpu", [| au; 0.0; ak; ai; aw; 0.0; 0.0 |]) :: List.rev accu
              else
                let hdr = "cpu" ^ string_of_int n in
                let o = n * 4 in
                let i = Array.get iukw (o + 0) /. hz in
                let u = Array.get iukw (o + 1) /. hz in
                let k = Array.get iukw (o + 2) /. hz in
                let w = Array.get iukw (o + 3) /. hz in
                let ai = ai +. i in
                let au = au +. u in
                let ak = ak +. k in
                let aw = aw +. w in
                let accu = (hdr, [| u; 0.0; k; i; w; 0.0; 0.0 |]) :: accu in
                  create (succ n) ai au ak aw accu
            in
              create 0 0.0 0.0 0.0 0.0 []
          )

      | MacOSX ->
          (fun () ->
            let iukn = macosx_host_processor_info nprocs in
            let rec create c ai au ak an accu =
              if c = nprocs
              then
                ("cpu", [| au; an; ak; ai; 0.0; 0.0; 0.0 |]) :: List.rev accu
              else
                let hdr = "cpu" ^ string_of_int c in
                let o = c * 4 in
                let i = Array.get iukn (o + 0) /. hz in
                let u = Array.get iukn (o + 1) /. hz in
                let k = Array.get iukn (o + 2) /. hz in
                let n = Array.get iukn (o + 3) /. hz in
                let ai = ai +. i in
                let au = au +. u in
                let ak = ak +. k in
                let an = an +. n in
                let accu = (hdr, [| u; n; k; i; 0.0; 0.0; 0.0 |]) :: accu in
                  create (succ c) ai au ak an accu
            in
              create 0 0.0 0.0 0.0 0.0 []
          )
  ;;
end

module Args =
struct
  let banner =
    [ "Amazing Piece of Code by insanely gifted programmer, Version 1.03"
    ; "Motivation by: gzh and afs"
    ; "usage: "
    ] |> String.concat "\n"

  let freq     = ref 1.0
  let interval = ref 15.0
  let devpath  = ref "/dev/itc"
  let pgrid    = ref 10
  let sgrid    = ref 15
  let w        = ref 400
  let h        = ref 200
  let verbose  = ref false
  let delay    = ref 0.04
  let ksampler = ref true
  let isampler = ref true
  let barw     = ref 100
  let bars     = ref 50
  let sigway   = ref (NP.os_type != NP.MacOSX)
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
  let sepstat  = ref true
  let grid_green = ref 0.75

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
  ;;

  let sooo b = if b then "on" else "off"
  let dA tos s {contents=v} = s ^ " (" ^ tos v ^ ")"
  let dF = dA |< sprintf "%4.2f"
  let dB = dA sooo
  let dcB = dA sooo
  let dI = dA string_of_int
  let dS = dA (fun s -> "`" ^ String.escaped s ^ "'")

  let sF opt r doc =
    "-" ^ opt, Arg.Set_float r, pad 9 "<float> " ^ doc |> dF |< r
  ;;

  let sI opt r doc =
    "-" ^ opt, Arg.Set_int r, pad 9 "<int> " ^ doc |> dI |< r
  ;;

  let sB opt r doc =
    "-" ^ opt, Arg.Set r, pad 9 "" ^ doc |> dB |< r
  ;;

  let sS opt r doc =
    "-" ^ opt, Arg.Set_string r, pad 9 "<string> " ^ doc |> dS |< r
  ;;

  let fB opt r doc =
    if r.contents
    then
      "-" ^ opt, Arg.Clear r, pad 9 "" ^ doc |> dB |< r
    else
      "-" ^ opt, Arg.Set r, pad 9 "" ^ doc |> dcB |< r
  ;;

  let commonopts =
    [ sF "f" freq "sampling frequency in seconds"
    ; sF "D" delay "refresh delay in seconds"
    ; sF "i" interval "history interval in seconds"
    ; sI "p" pgrid "percent grid items"
    ; sI "s" sgrid "history grid items"
    ; sI "w" w "width"
    ; sI "h" h "height"
    ; sI "b" barw "bar width"
    ; sI "B" bars "number of CPU bars"
    ; sB "v" verbose "verbose"
    ; fB "C" sepstat "separate sys/nice/intr/iowait values (kernel sampler)"
    ; fB "c" scalebar "constant bar width"
    ; fB "P" poly "filled area instead of lines"
    ; fB "l" labels "labels"
    ; fB "m" mgrid "moving grid"
    ]
  ;;

  let add_opts tail =
    let add_linux opts =
      sI "t" timer "timer frequency in herz"
      :: fB "I" icon "icon (hack)"
      :: sS "d" devpath "path to itc device"
      :: (fB "k" ksampler |< "kernel sampler (`/proc/[stat|uptime]')")
      :: (fB "M" isampler |< "idle sampler")
      :: (fB "u" uptime
             "`uptime' instead of `stat' as kernel sampler (UP only)")
      :: sI "n" niceval "value to renice self on init"
      :: fB "g" gzh "gzh way (does not quite work yet)"
      :: fB "S" sigway "sigwait delay method"
      :: opts
    in
    let add_solaris opts =
      isampler := false;
      fB "I" icon "icon (hack)"
      :: opts
    in
    let add_windows opts =
      isampler := false;
      (fB "k" ksampler |< "kernel sampler (ZwQuerySystemInformation)")
      :: (fB "M" isampler |< "idle sampler (PMC based)")
      :: opts
    in
    let add_macosx opts =
      isampler := false;
      fB "g" gzh "gzh way (does not quite work yet)"
      :: opts
    in
      match NP.os_type with
        | NP.Linux -> add_linux tail
        | NP.Windows -> add_windows tail
        | NP.Solaris -> add_solaris tail
        | NP.MacOSX -> add_macosx tail
  ;;

  let init () =
    let opts = add_opts commonopts in
      Arg.parse opts
        (fun s ->
          raise (Arg.Bad
                    ("Invocation error: Don't know what to do with " ^ s));
        )
        banner
      ;
      let cp {contents=v} s =
        if v <= 0
        then (prerr_string s; prerr_endline " must be positive"; exit 1)
      in
      let cpf {contents=v} s =
        if v <= 0.0
        then (prerr_string s; prerr_endline " must be positive"; exit 1)
      in
        cp w "Width";
        cp h "Height";
        cp pgrid "Number of percent grid items";
        cp sgrid "Number of history grid items";
        cp bars "Number of CPU bars";
        cp timer "Timer frequency";
        cpf freq "Frequency";
        cpf delay "Delay";
        cpf interval "Interval";
        if not (!isampler || !ksampler)
        then
          barw := 0
        ;
        if NP.winnt && !isampler
        then
          isampler := NP.testpmc ()
        ;
  ;;
end

module Gzh =
struct
  let lim = ref 0
  let stop = ref false
  let refdt = ref 0.0

  let rec furious_cycle i =
    if not !stop && i > 0
    then
      pred i |> furious_cycle
    else
      (i, Unix.gettimeofday ())
  ;;

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
    let () =
      if verbose
      then
        printf "Completed %d iterations in %f seconds@." !lim !refdt
    in
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
;;

module Delay =
struct
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
          let l =
            if gzh
            then
              [Sys.sigprof; Sys.sigvtalrm]
            else
              []
          in
            Unix.sigprocmask Unix.SIG_BLOCK |< Sys.sigalrm :: l |> ignore;
      ;
      in
      let v = 1.0 /. float freq in
      let t = { Unix.it_interval = v; it_value = v } in
      let _ = Unix.setitimer Unix.ITIMER_REAL t in
        ()
  ;;

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
  ;;
end

type sampler =
    { color : Gl.rgb;
      getyielder : unit -> unit -> float option;
      update : float -> float -> unit;
    }
;;

module Sampler (T : sig val nsamples : int val freq : float end) =
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
      then
        ()
      else
        let i =
          if i = nsamples
          then
            0
          else
            i
        in
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
        then
          nsamples + d
        else
          d
    in
    let ry = ref (fun () -> assert false) in
    let rec yield i () =
      if i = !active
      then
        None
      else
        begin
          ry := succ i |> yield;
          Some ((i + tail) mod nsamples |> Array.get samples)
        end
    in
      ry := yield 0;
      (fun () -> !ry ());
  ;;

  let update dt di =
    let isamples = dt /. T.freq |> truncate in
    let l = 1.0 -. (di /. dt) in
    let l = max 0.0 l in
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

module View (V: sig val w : int val h : int end) =
struct
  let ww = ref 0
  let wh = ref 0
  let oldwidth = ref !Args.w
  let barmode = ref false
  let funcs = ref []

  let keyboard ~key ~x ~y =
    if key = 27 || key = Char.code 'q'
    then
      exit 0
    ;
    if key = Char.code 'b' && not !barmode
    then
      begin
        let h = Glut.get Glut.WINDOW_HEIGHT in
          oldwidth := Glut.get Glut.WINDOW_WIDTH;
          Glut.reshapeWindow ~w:(!Args.barw + 4) ~h;
          barmode := true;
      end
    ;
    if key = Char.code 'a' && !barmode
    then
      begin
        let h = Glut.get Glut.WINDOW_HEIGHT in
          Glut.reshapeWindow ~w:!oldwidth ~h;
          barmode := false;
      end
    ;
  ;;

  let add dri =
    funcs := dri :: !funcs
  ;;

  let display () =
    GlClear.clear [`color];
    List.iter (fun (display, _, _) -> display ()) !funcs;
    Glut.swapBuffers ();
  ;;

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
    Glut.postRedisplay ();
  ;;

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

module type BarInfo =
sig
  val x : int
  val y : int
  val w : int
  val h : int
  val getl : stats -> ((float * float * float) * float) list
end

module Bar (I: BarInfo) =
struct
  let w = ref I.w
  let dontdraw = ref false
  let h = ref I.h
  let xoffset = ref I.x
  let xratio = float I.x /. float !Args.w
  let wratio = float I.w /. float !Args.w
  let load = ref zero_stat
  let nrcpuscale = 1.0 /. float NP.nprocs
  let fh = 12
  let strw = Glut.bitmapLength ~font ~str:"55.55"
  let sepsl =
    let base = GlList.gen_lists ~len:1 in
      GlList.nth base ~pos:0
  ;;

  let seps () =
    let hh = !h - 26 in
    let () =
      GlDraw.viewport !xoffset (I.y + 15) !w hh;
      GlMat.push ();
      GlMat.load_identity ();
      GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
      GlMat.scale ~y:(2.0 /. (float hh)) ~x:1.0 ();
    in
    let seph = 1 in
    let barh = float (hh - (!Args.bars - 1) * seph) /. float !Args.bars in
    let barh = ceil barh |> truncate in
    let rec loop i yb =
      if yb > hh
      then
        ()
      else
        let yt = yb + seph in
        let yn = yt + barh in
        let yb = float yb
        and yt = float yt in
          GlDraw.vertex2 (0.0, yb);
          GlDraw.vertex2 (0.0, yt);
          GlDraw.vertex2 (2.0, yt);
          GlDraw.vertex2 (2.0, yb);
          succ i |> loop |< yn
    in
      GlDraw.color (0.0, 0.0, 0.0);
      GlDraw.begins `quads;
      loop 0 barh;
      GlDraw.ends ();
      GlMat.pop ();
  ;;

  let reshape w' h' =
    if !Args.scalebar
    then
      begin
        w := float w' *. wratio |> truncate;
        xoffset := float w' *. xratio |> truncate;
      end
    else
      begin
        w := I.w;
        xoffset := I.x;
      end
    ;
    h := h';
    GlList.begins sepsl `compile;
    seps ();
    GlList.ends ();
    dontdraw :=
      !h < 20 || !w < 20 || !xoffset < 0
    ;
  ;;

  let display_aux () =
    let load = scale_stat !load nrcpuscale in
    let load_all = min (1.0 -. load.all) 1.0 |> max 0.0 in
    let () = GlMat.push () in
    let () =
      GlDraw.viewport !xoffset (I.y + 2) !w !h;
      GlDraw.color (1.0, 1.0, 1.0);
      let load_all = 100.0 *. load_all in
      let str = sprintf "%5.2f" load_all in
      let () =
        GlMat.load_identity ();
        let strw =
          if false
          then
            Glut.bitmapLength ~font ~str:str
          else
            strw
        in
        let x = -. (float strw /. float !w) in
          GlMat.translate ~y:~-.1.0 ~x ();
      in
      let () = draw_string 0.0 0.0 str in
        ()
    in
      GlDraw.viewport !xoffset (I.y + 15) !w (!h - 26);
      GlMat.load_identity ();
      GlMat.translate ~x:~-.1. ~y:~-.1.();
      let drawquad yb yt =
        GlDraw.begins `quads;
        GlDraw.vertex2 (0.0, yb);
        GlDraw.vertex2 (0.0, yt);
        GlDraw.vertex2 (2.0, yt);
        GlDraw.vertex2 (2.0, yb);
        GlDraw.ends ()
      in
      let fold yb (color, load) =
        if load > 0.0
        then
          let () = GlDraw.color color in
          let yt = yb +. 2.0*.load in
          let () = drawquad yb yt in
            yt
        else
          yb
      in
      let cl = I.getl load in
      let yb = List.fold_left fold 0.0 cl in
      let () = GlDraw.color (0.5, 0.5, 0.5) in
      let () = drawquad yb 2.0 in
      let () = GlList.call sepsl in
        GlMat.pop ();
        GlList.call sepsl;
  ;;

  let display () =
    if !dontdraw
    then
      ()
    else
      display_aux ()
    ;
  ;;

  let update delta' load' =
    let delta = 1.0 /. delta' in
      load := scale_stat load' delta;
  ;;
end

module Graph (V: View) =
struct
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
  let dontdraw = ref false

  let fw, fh =
    if !Args.labels
    then
      3 * Glut.bitmapWidth font (Char.code '%'), 20
    else
      0, 10
  ;;

  let gridlist =
    let base = GlList.gen_lists ~len:1 in
      GlList.nth base ~pos:0
  ;;

  let getviewport typ =
    let ox = if !Args.scalebar then 0 else !Args.barw in
      match typ with
        | `labels -> (!vx + ox, !vy + 5, fw, !vh - fh)
        | `graph  -> (!vx + fw + 5 + ox, !vy + 5, !vw - fw - 10, !vh - fh)
  ;;

  let viewport typ =
    let x, y, w, h = getviewport typ in
      GlDraw.viewport x y w h;
  ;;

  let sgrid () =
    for i = 0 to V.sgrid
    do
      let x = if i = 0 then 0.00009 else float i *. gscale in
      let x = if i = V.sgrid then x -. 0.0009 else x in
        GlDraw.vertex ~x ~y:0.0 ();
        GlDraw.vertex ~x ~y:1.0 ();
    done;
  ;;

  let grid () =
    viewport `graph;
    GlDraw.line_width 1.0;
    GlDraw.color (0.0, !Args.grid_green, 0.0);
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
          let y = if i = 0 then 0.0009 else y in
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
              let s = sprintf "%3d%%" p in
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
      dontdraw :=
        (
          let x0, y0, w0, h0 = getviewport `labels in
          let x1, y1, w1, h1 = getviewport `graph in
            (!Args.labels && (w0 < 20 || h0 < 20 || x0 < 0 || y0 < 0))
            || (w1 < 20 || h1 < 20 || x1 < 0 || y1 < 0)
        )
      ;
      if not !dontdraw
      then
        begin
          GlList.begins gridlist `compile;
          grid ();
          GlList.ends ();
        end
  ;;

  let swap =
    Glut.swapBuffers |> oohz !Args.delay;
  ;;

  let inc () = incr nsamples

  let mgrid () =
    GlDraw.line_width 1.0;
    GlDraw.color (0.0, !Args.grid_green, 0.0);
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

  let display_aux () =
    GlList.call gridlist;
    viewport `graph;
    if !Args.mgrid then mgrid ();
    GlDraw.line_width 2.0;
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
              let x = scale *. float i in
                GlDraw.vertex ~x ~y ();
                loop opty (succ i)

          | None ->
              if !Args.poly
              then
                match last with
                  | None -> ()
                  | Some y ->
                      let x = scale *. float (pred i) in
                        GlDraw.vertex ~x ~y:0.0 ()
      in
        loop None 0;
        GlDraw.ends ();
    in
      List.iter sample V.samplers;
  ;;

  let display () =
    if not !dontdraw
    then
      display_aux ()
    else
      ()
    ;
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
    then
      accu
    else
      let yc = i / x in
      let xc = i mod x in
      let xc = xc * vw + barw in
      let yc = yc * vh in
        (i, xc, yc) :: accu |> loop |< succ i
  in
    loop [] 0, vw, vh
;;

let create fd w h =
  let module S =
      struct
        let freq = !Args.freq
        let nsamples = !Args.interval /. freq |> ceil |> truncate
      end
  in
  let placements, vw, vh = getplacements w h NP.nprocs !Args.barw in

  let iget () =
    if !Args.isampler then NP.idletimeofday fd NP.nprocs else [||]
  in
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
    let module Sk = Sampler (S) in
    let ksampler =
      { getyielder = Sk.getyielder
      ; color = (1.0, 0.0, 0.0)
      ; update = Sk.update
      }
    in
    let module Sk2 = Sampler (S) in
    let ksampler2 =
      { getyielder = Sk2.getyielder
      ; color = (1.0, 1.0, 1.0)
      ; update = Sk2.update
      }
    in
    let module V = struct
      let x = x
      let y = y
      let w = vw
      let h = vh
      let freq = S.freq
      let interval = !Args.interval
      let pgrid = !Args.pgrid
      let sgrid = !Args.sgrid
      let samplers =
        ksampler2 ::
        if !Args.isampler
        then
          isampler :: (if !Args.ksampler then [ksampler] else [])
        else
          if !Args.ksampler then [ksampler] else []
    end
    in
    let module Graph = Graph (V) in
    let kaccu =
      if !Args.ksampler
      then
        let calc =
          if !Args.gzh
          then
            let d = ref 0.0 in
            let f d' = d := d' in
            let () = Gzh.gen f in
              fun _ _ _ ->
                let d = !d in
                  { zero_stat with
                    all = d; iowait = d; user = 1.0 -. d; idle = d }
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
                  let d = di /. du in
                    u1 := u2;
                    i1 := i2;
                    { zero_stat with
                      all = d; iowait = d; user = 1.0 -. d; idle = d }
          else
            let i' = if i = NP.nprocs then 0 else succ i in
            let g ks n = Array.get ks i' |> snd |> Array.get |< n in
            let gall ks =
              let user = g ks NP.user
              and nice = g ks NP.nice
              and sys = g ks NP.sys
              and idle = g ks NP.idle
              and iowait = g ks NP.idle
              and intr = g ks NP.intr
              and softirq = g ks NP.softirq in
              let () =
                if !Args.debug
                then
                  eprintf
                    "user=%f nice=%f sys=%f iowait=%f intr=%f softirq=%f@."
                    user
                    nice
                    sys
                    iowait
                    intr
                    softirq
                ;
              in
                { all = user +. nice +. sys
                ; user = user
                ; nice = nice
                ; sys = sys
                ; idle = idle
                ; iowait = iowait
                ; intr = intr
                ; softirq = softirq
                }
            in
            let i1 = ref (gall ks) in
              fun ks t1 t2 ->
                let i2 = gall ks in
                let diff = add_stat i2 (neg_stat !i1) in
                let diff = { diff with all = t2 -. t1 -. diff.all } in
                  i1 := i2;
                  diff
        in
        let calc2 =
          let idle1 = ref 0.0 in
          fun ks (t1 : float) (t2 : float) ->
            let i' = if i = NP.nprocs then 0 else succ i in
            let g ks n = Array.get ks i' |> snd |> Array.get |< n in
            let idle2 = g ks NP.idle in
            let diff = idle2 -. !idle1 in
            let diff = { zero_stat with all = diff } in
            idle1 := idle2;
            diff
        in
        (i, calc, ksampler)
        (* :: (i, calc2, ksampler2) *)
        :: kaccu
      else
        kaccu
    in
    let iaccu =
      if !Args.isampler
      then
        let calc =
          let i1 = Array.get is i |> ref in
            fun is t1 t2 ->
              let i2 = Array.get is i in
                if classify_float i2 = FP_infinite
                then
                  { zero_stat with all = t2 -. t1 }
                else
                  let i1' = !i1 in
                    i1 := i2;
                    { zero_stat with all = i2 -. i1' }
        in
          (i, calc, isampler) :: iaccu
      else
        iaccu
    in
      kaccu, iaccu, Graph.funcs :: gaccu
  in
  let kl, il, gl = List.fold_left crgraph ([], [], []) placements in
    ((if kl == [] then (fun () -> [||]) else kget), kl), (iget, il), gl
;;

let opendev path =
  if not NP.linux
  then
    (* gross hack but we are not particularly picky today *)
    Unix.stdout
  else
    try
      if (Unix.stat path).Unix.st_kind != Unix.S_CHR
      then
        begin
          eprintf "File %S is not an ITC device@." path;
          exit 100
        end
      ;
      Unix.openfile path [Unix.O_RDONLY] 0
    with
      | Unix.Unix_error ((Unix.ENODEV | Unix.ENXIO) as err , s1, s2) ->
          eprintf "Could not open ITC device %S:\n%s(%s): %s@."
            path s1 s2 |< Unix.error_message err;
          eprintf "(perhaps the module is not loaded?)@.";
          exit 100

      | Unix.Unix_error (Unix.EALREADY, s1, s2) ->
          eprintf "Could not open ITC device %S:\n%s(%s): %s@."
            path s1 s2 |< Unix.error_message Unix.EALREADY;
          eprintf "(perhaps modules is already in use?)@.";
          exit 100

      | Unix.Unix_error (error, s1, s2) ->
          eprintf "Could not open ITC device %S:\n%s(%s): %s@."
            path s1 s2 |< Unix.error_message error;
          exit 100

      | exn ->
          eprintf "Could not open ITC device %S:\n%s@."
            path |< Printexc.to_string exn;
          exit 100
;;

let seticon () =
  let module X =
      struct
        external seticon : string -> unit = "ml_seticon"
      end
  in
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
      then
        s
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
        then
          (fill kl 0 ky; fill il ky iy; iy)
        else
          (fill kl 0 ky; ky)
      in
        fill el ey 32;
        X.seticon data;
;;

let create_bars h kactive iactive =
  let getlk kload =
    if !Args.sepstat
    then
      let sum = kload.user +. kload.nice +. kload.sys
        +. kload.intr +. kload.softirq
      in
        [ (1.0, 1.0, 0.0), kload.user
        ; (0.0, 0.0, 1.0), kload.nice
        ; (1.0, 0.0, 0.0), kload.sys
        ; (1.0, 1.0, 1.0), kload.intr
        ; (0.5, 0.8, 1.0), kload.softirq
        ; (0.75, 0.5, 0.5), (1.0 -. kload.iowait) -. sum
        (* ; (0.0, 1.0, 0.0), kload.all -. kload.iowait -. kload.softirq *)
        ]
    else
      [ (1.0, 0.0, 0.0), 1.0 -. kload.idle ]
  in
  let getli iload =
    [ (1.0, 1.0, 0.0), 1.0 -. iload.all ]
  in
  let barw = !Args.barw in
  let nfuncs =
    (fun () -> ()), (fun _ _ -> ()), (fun _ _ -> ())
  in
  let kd, kr, ku =
    if kactive
    then
      let module Bar =
        Bar (struct
          let x = 3
          let y = 0
          let w = (if iactive then barw / 2 else barw) - 3
          let h = h
          let getl = getlk
        end)
      in
        Bar.display, Bar.reshape, Bar.update
    else
      nfuncs
  in
  let id, ir, iu =
    if iactive
    then
      let module Bar =
        Bar (struct
          let x = (if kactive then barw / 2 else 0) + 3
          let y = 0
          let w = (if kactive then barw / 2 else barw) - 3
          let h = h
          let getl = getli
        end)
      in
        Bar.display, Bar.reshape, Bar.update
    else
      nfuncs
  in
    if kactive
    then
      begin
      if iactive
      then
        let d () = kd (); id () in
        let r w h = kr w h; ir w h in
        let u d k i = ku d k; iu d i in
          d, r, u
      else
        kd, kr, (fun d k _ -> ku d k)
      end
    else
      begin
        if iactive
        then
          id, ir, (fun d _ i -> iu d i)
        else
          (fun () -> ()), (fun _ _ -> ()), (fun _ _ _ -> ())
      end
;;

let main () =
  let _ = Glut.init [|""|] in
  let () = Args.init () in
  let () =
    if !Args.verbose
    then
      "detected " ^ string_of_int NP.nprocs ^ " CPUs" |> print_endline
  in
  let () = if !Args.gzh then Gzh.init !Args.verbose else () in
  let () = Delay.init !Args.timer !Args.gzh in
  let () = if !Args.niceval != 0 then NP.setnice !Args.niceval else () in
  let w = !Args.w
  and h = !Args.h in
  let fd = opendev !Args.devpath in
  let module FullV = View (struct let w = w let h = h end) in
  let winid = FullV.init () in
  let () = NP.fixwindow winid in
  let (kget, kfuncs), (iget, ifuncs), gl = create fd w h in
  let bar_update =
    List.iter FullV.add gl;
    if !Args.barw > 0
    then
      let (display, reshape, update) =
        create_bars h !Args.ksampler !Args.isampler
      in
        FullV.add (display, reshape, fun _ -> ());
        update
    else
      fun _ _ _ -> ()
  in
  let seticon = if !Args.icon then seticon () else fun ~iload ~kload -> () in
  let rec loop t1 () =
    let t2 = Unix.gettimeofday () in
    let dt = t2 -. t1 in
      if dt >= !Args.freq
      then
        let is = iget () in
        let ks = kget () in
        let rec loop2 load sample = function
          | [] -> load
          | (nr, calc, sampler) :: rest ->
              let cpuload = calc sample t1 t2 in
              let () =
                let thisload = 1.0 -. (cpuload.all /. dt) in
                let thisload = max 0.0 thisload in
                if !Args.verbose
                then
                  ("cpu load(" ^ string_of_int nr ^ "): "
                    ^ (thisload *. 100.0 |> string_of_float)
                  |> print_endline)
              in
              let load = add_stat load cpuload in
                sampler.update dt cpuload.all;
                loop2 load sample rest
        in
        let iload = loop2 zero_stat is ifuncs in
        let kload = loop2 zero_stat ks kfuncs in
          if !Args.debug
          then
            begin
              iload.all |> string_of_float |> prerr_endline;
              kload.all |> string_of_float |> prerr_endline;
            end
          ;
          seticon ~iload:iload.all ~kload:kload.all;
          bar_update dt kload iload;
          FullV.inc ();
          FullV.update ();
          FullV.func (Some (loop t2))
      else
        Delay.delay ()
  in
    FullV.func (Some (Unix.gettimeofday () |> loop));
    FullV.run ()
;;

let _ =
  try
    main ()
  with
    | Unix.Unix_error (e, s1, s2) ->
        Unix.error_message e |> eprintf "main failure: %s(%s): %s@." s1 s2

    | exn ->
        Printexc.to_string exn |> eprintf "main failure: %s@."
;;
