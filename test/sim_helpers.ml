open! Core
open! Async
open Hl_protocol

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

type sim =
  { server : Hl_sim.Server.t
  ; http : (Socket.Address.Inet.t, int) Cohttp_async.Server.t
  ; client : Address.t -> Hl_client.Config.t
  }

let start_sim ?config ?journal () =
  Log.Global.set_output [];
  let server = Hl_sim.Server.create ?config ?journal (Hl_sim.Adapt.create_exchange ()) in
  let%bind http = Hl_sim.Server.listen server ~port:0 in
  let base_url =
    Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Hl_sim.Server.port http) ()
  in
  let client address = Hl_client.Config.create ~address ~base_url () in
  let%map response =
    Hl_client.Exchange.place_orders
      (client maker)
      [ order ~is_buy:true ~px:"99900" ~sz:"0.01" ~tif:Gtc
      ; order ~is_buy:false ~px:"100100" ~sz:"0.01" ~tif:Gtc
      ]
  in
  (match ok_exn response with
   | Ok (Order [ Resting _; Resting _ ]) -> ()
   | response -> raise_s [%message "static book" (response : Exchange_response.t)]);
  { server; http; client }
;;

let stop_sim sim = Cohttp_async.Server.close sim.http
