open! Core
open! Async
open Hl_mm
open Sim_helpers
module Bugged = Bugged_venue.Make (Hl_venue)
module Live_bugged = Mm_core.Live.Make (Bugged)

let config =
  { Mm_core.Live.Config.params = { Mm_core.Params.btc with requote_interval_ms = 200 }
  ; summary_interval = Time_ns.Span.of_int_sec 60
  }
;;

let with_delay ms =
  { Hl_sim.Server.Config.default with response_delay = Time_ns.Span.of_int_ms ms }
;;

let print_report (report : Mm_core.Live.Report.t) venue =
  print_s
    [%message
      ""
        ~plans:(report.plans : int)
        ~placed:(report.orders_placed : int)
        ~rejected:(report.orders_rejected : int)
        ~cancelled:(report.orders_cancelled : int)
        ~injected:(Bugged.injected venue : Bugged_venue.Injected.t)]
;;

let%expect_test "seeded rejects with slow acks: rejected levels are retried, never \
                 doubled"
  =
  let%bind sim = start_sim ~config:(with_delay 200) () in
  let%bind venue =
    Bugged.connect
      ({ Bugged_venue.Bugs.none with seed = 7; reject_percent = 30 }, sim.client mm)
    >>| ok_exn
  in
  let%bind live = Live_bugged.start venue config >>| ok_exn in
  let%bind () =
    wait_until ~what:"full ladder" (fun () ->
      List.length (Mm_core.Strategy.open_orders (Live_bugged.strategy live)) = 6)
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_sec 2) in
  let%bind () = print_open_orders (sim.client mm) in
  [%expect
    {|
    A 0.001@100070
    A 0.001@100050
    A 0.001@100030
    B 0.001@99970
    B 0.001@99950
    B 0.001@99930
    |}];
  let%bind report = Live_bugged.stop live in
  print_report report venue;
  [%expect
    {|
    ((plans 2) (placed 6) (rejected 1) (cancelled 6)
     (injected ((rejects 1) (timeouts 0))))
    |}];
  let%bind () = print_open_orders (sim.client mm) in
  [%expect {| |}];
  stop_sim sim
;;

let%expect_test "a place that times out but rests is adopted, not placed again" =
  let%bind sim = start_sim ~config:(with_delay 500) () in
  let%bind venue =
    Bugged.connect
      ( { Bugged_venue.Bugs.none with
          timeout_places = 1
        ; place_timeout = Time_ns.Span.of_int_ms 100
        }
      , sim.client mm )
    >>| ok_exn
  in
  let%bind live = Live_bugged.start venue config >>| ok_exn in
  let%bind () =
    wait_until ~what:"timeout" (fun () -> (Bugged.injected venue).timeouts = 1)
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_sec 3) in
  let%bind () = print_open_orders (sim.client mm) in
  [%expect
    {|
    A 0.001@100070
    A 0.001@100050
    A 0.001@100030
    B 0.001@99970
    B 0.001@99950
    B 0.001@99930
    |}];
  let%bind report = Live_bugged.stop live in
  print_report report venue;
  [%expect
    {|
    ((plans 1) (placed 0) (rejected 0) (cancelled 6)
     (injected ((rejects 0) (timeouts 1))))
    |}];
  let%bind () = print_open_orders (sim.client mm) in
  [%expect {| |}];
  stop_sim sim
;;
