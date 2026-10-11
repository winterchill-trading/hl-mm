open! Core
open! Async
open Hl_protocol
open Hl_mm

let%expect_test "tick_of_mid" =
  List.iter
    [ "100000", 5; "99876.5", 5; "3500.25", 4; "150.123", 2; "0.5123", 0 ]
    ~f:(fun (mid, sz_decimals) ->
      printf
        "%s (szDecimals %d): %s\n"
        mid
        sz_decimals
        (Price.to_string (Live.Instrument.tick_of_mid ~sz_decimals (Price.of_string mid))));
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

let mm = Address.of_string "0x0000000000000000000000000000000000006d6d"
let maker = Address.of_string "0x00000000000000000000000000000000000000b0"
let taker = Address.of_string "0x00000000000000000000000000000000000000c0"

let order ~is_buy ~px ~sz ~tif =
  { Order_request.asset = Asset.of_int 0
  ; is_buy
  ; limit_px = Price.of_string px
  ; sz = Size.of_string sz
  ; reduce_only = false
  ; order_type = Limit { tif }
  ; cloid = None
  }
;;

let rec wait_until ?(timeout = Time_ns.Span.of_int_sec 10) ~what f =
  if f ()
  then return ()
  else if Time_ns.Span.(timeout <= zero)
  then raise_s [%message "timed out waiting" what]
  else (
    let step = Time_ns.Span.of_int_ms 20 in
    let%bind () = Clock_ns.after step in
    wait_until ~timeout:Time_ns.Span.(timeout - step) ~what f)
;;

let print_open_orders config =
  let%map orders = Hl_client.Info.open_orders config >>| ok_exn in
  List.sort orders ~compare:(fun (a : Open_order.t) b ->
    Price.descending a.limit_px b.limit_px)
  |> List.iter ~f:(fun (o : Open_order.t) ->
    printf
      "%s %s@%s\n"
      (Side.to_wire o.side)
      (Size.to_string o.sz)
      (Price.to_string o.limit_px))
;;

let%expect_test "live loop quotes, fills and cancels against hl-sim" =
  Log.Global.set_output [];
  let server = Hl_sim.Server.create (Hl_sim.Exchange.create ()) in
  let%bind http = Hl_sim.Server.listen server ~port:0 in
  let base_url =
    Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Hl_sim.Server.port http) ()
  in
  let client address = Hl_client.Config.create ~address ~base_url () in
  (* A static two-sided book, 20 bps wide around 100000. *)
  let%bind response =
    Hl_client.Exchange.place_orders
      (client maker)
      [ order ~is_buy:true ~px:"99900" ~sz:"0.01" ~tif:Gtc
      ; order ~is_buy:false ~px:"100100" ~sz:"0.01" ~tif:Gtc
      ]
  in
  print_s [%sexp (ok_exn response : Exchange_response.t)];
  [%expect {| (Ok (Order ((Resting (oid 1) (cloid ())) (Resting (oid 2) (cloid ()))))) |}];
  let%bind live =
    Live.start
      { client = client mm
      ; params = { Params.btc with requote_interval_ms = 200 }
      ; summary_interval = Time_ns.Span.of_int_sec 60
      }
    >>| ok_exn
  in
  let%bind () =
    wait_until ~what:"quotes" (fun () -> (Live.report live).orders_placed >= 6)
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
  let%bind () = wait_until ~what:"fill" (fun () -> (Live.report live).fills >= 1) in
  let%bind report = Live.stop live in
  print_s
    [%message
      ""
        ~fills:(report.fills : int)
        ~maker_fills:(report.maker_fills : int)
        ~position:(report.position : Size.t)
        ~volume:(report.volume : Usd.t)
        ~fees:(report.fees : Usd.t)
        ~placed_at_least_6:(report.orders_placed >= 6 : bool)
        ~mode:(report.mode : Strategy.Mode.t)];
  [%expect
    {|
    ((fills 1) (maker_fills 1) (position 0.001) (volume 99.97) (fees 0.009997)
     (placed_at_least_6 true) (mode Running))
    |}];
  (* Shutdown cancelled everything. *)
  let%bind () = print_open_orders (client mm) in
  [%expect {| |}];
  Cohttp_async.Server.close http
;;
