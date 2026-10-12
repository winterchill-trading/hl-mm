open! Core
open! Async
open Hl_protocol
open Hl_mm
open Sim_helpers
module Live = Mm_core.Live
module Live_hl = Live.Make (Hl_venue)

let%expect_test "tick_of_mid" =
  List.iter
    [ "100000", 5; "99876.5", 5; "3500.25", 4; "150.123", 2; "0.5123", 0 ]
    ~f:(fun (mid, sz_decimals) ->
      printf
        "%s (szDecimals %d): %s\n"
        mid
        sz_decimals
        (Price.to_string (Hl_venue.tick_of_mid ~sz_decimals (Price.of_string mid))));
  [%expect
    {|
    100000 (szDecimals 5): 1
    99876.5 (szDecimals 5): 1
    3500.25 (szDecimals 4): 0.1
    150.123 (szDecimals 2): 0.01
    0.5123 (szDecimals 0): 0.00001
    |}];
  return ()
;;

let%expect_test "live loop quotes, fills and cancels against hl-sim" =
  let%bind sim = start_sim () in
  let client = sim.client in
  let%bind venue = Hl_venue.connect (client mm) >>| ok_exn in
  let%bind instrument = Hl_venue.instrument venue (Coin.of_string "BTC") >>| ok_exn in
  print_s [%sexp (instrument : Exchange_core.Instrument.t)];
  [%expect
    {|
    ((symbol BTC) (size_decimals 5) (price_tick 1) (max_significant_figures (5))
     (max_leverage 40) (fees ((taker_bps 3.5) (maker_bps 1))))
    |}];
  let%bind live =
    Live_hl.start
      venue
      { params =
          { Mm_core.Params.btc with requote_interval_ms = Time_ns.Span.of_int_ms 200 }
      ; summary_interval = Time_ns.Span.of_int_sec 60
      }
    >>| ok_exn
  in
  let%bind () =
    wait_until ~what:"quotes" (fun () -> (Live_hl.report live).orders_placed >= 6)
  in
  (* 3 bps around the microprice, then 2 bps per level, on the hl-mm account. *)
  let%bind () = print_open_orders (client mm) in
  [%expect
    {|
    A 0.001@100070
    A 0.001@100050
    A 0.001@100030
    B 0.001@99970
    B 0.001@99950
    B 0.001@99930
    |}];
  (* A taker sells into the best bid: hl-mm gets a maker fill over the websocket. *)
  let%bind response =
    Hl_client.Exchange.place_orders
      (client taker)
      [ order ~is_buy:false ~px:"99970" ~sz:"0.001" ~tif:Ioc ]
  in
  print_s [%sexp (ok_exn response : Exchange_response.t)];
  [%expect
    {| (Ok (Order ((Filled (oid 9) (total_sz 0.001) (avg_px 99970) (cloid ()))))) |}];
  let%bind () = wait_until ~what:"fill" (fun () -> (Live_hl.report live).fills >= 1) in
  let%bind report = Live_hl.stop live in
  print_s
    [%message
      ""
        ~fills:(report.fills : int)
        ~maker_fills:(report.maker_fills : int)
        ~position:(report.position : Size.t)
        ~volume:(report.volume : Usd.t)
        ~fees:(report.fees : Usd.t)
        ~placed_at_least_6:(report.orders_placed >= 6 : bool)
        ~cancelled_at_least_5:(report.orders_cancelled >= 5 : bool)
        ~mode:(report.mode : Mm_core.Strategy.Mode.t)
        ~tick_to_order_measured:
          (Option.exists (Live_hl.tick_to_order live) ~f:(fun stats -> stats.count >= 1)
           : bool)];
  [%expect
    {|
    ((fills 1) (maker_fills 1) (position 0.001) (volume 99.97) (fees 0.009997)
     (placed_at_least_6 true) (cancelled_at_least_5 true) (mode Running)
     (tick_to_order_measured true))
    |}];
  (* Shutdown cancelled everything. *)
  let%bind () = print_open_orders (client mm) in
  [%expect {| |}];
  stop_sim sim
;;

let%expect_test "slow acks: no order is placed twice" =
  (* Every /exchange ack arrives 500ms late, longer than the 200ms requote interval; the
     orders themselves rest at once and their updates reach the websocket first. *)
  let%bind sim =
    start_sim
      ~config:
        { Hl_sim.Server.Config.default with response_delay = Time_ns.Span.of_int_ms 500 }
      ()
  in
  let client = sim.client in
  let%bind venue = Hl_venue.connect (client mm) >>| ok_exn in
  let%bind live =
    Live_hl.start
      venue
      { params =
          { Mm_core.Params.btc with requote_interval_ms = Time_ns.Span.of_int_ms 200 }
      ; summary_interval = Time_ns.Span.of_int_sec 60
      }
    >>| ok_exn
  in
  let%bind () =
    wait_until ~what:"quotes" (fun () -> (Live_hl.report live).orders_placed >= 6)
  in
  (* Ten requote intervals with nothing changing: the ladder must stay as it is. *)
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_sec 2) in
  let%bind () = print_open_orders (client mm) in
  [%expect
    {|
    A 0.001@100070
    A 0.001@100050
    A 0.001@100030
    B 0.001@99970
    B 0.001@99950
    B 0.001@99930
    |}];
  (* A better bid moves the microprice: the requote cancels and places with slow acks. *)
  let%bind (_ : Exchange_response.t Or_error.t) =
    Hl_client.Exchange.place_orders
      (client maker)
      [ order ~is_buy:true ~px:"99990" ~sz:"0.01" ~tif:Gtc ]
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_sec 3) in
  let%bind () = print_open_orders (client mm) in
  [%expect
    {|
    A 0.001@100097
    A 0.001@100070
    A 0.001@100050
    B 0.001@99996
    B 0.001@99970
    B 0.001@99950
    |}];
  let%bind report = Live_hl.stop live in
  print_s
    [%message
      ""
        ~plans:(report.plans : int)
        ~placed:(report.orders_placed : int)
        ~rejected:(report.orders_rejected : int)
        ~cancelled:(report.orders_cancelled : int)];
  [%expect {| ((plans 2) (placed 8) (rejected 0) (cancelled 8)) |}];
  let%bind () = print_open_orders (client mm) in
  [%expect {| |}];
  stop_sim sim
;;
