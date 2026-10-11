open! Core
open! Async
open Hl_protocol
open Hl_mm

(* "mm" in ASCII. *)
let default_address = "0x0000000000000000000000000000000000006d6d"

let address_arg =
  Command.Arg_type.create (fun s ->
    let hex = String.chop_prefix s ~prefix:"0x" in
    match hex with
    | Some hex when String.length hex = 40 && String.for_all hex ~f:Char.is_hex_digit ->
      Address.of_string s
    | _ -> raise_s [%message "expected 0x followed by 40 hex digits" s])
;;

(* Per-coin defaults: about $100 per order and 10 orders of position room, which for BTC
   at 100k reproduces [Params.btc] (0.001, 0.01 and 1500 USD). *)
let params_for
  (instrument : Live.Instrument.t)
  ~levels
  ~size
  ~half_spread_bps
  ~skew_bps
  ~max_position
  ~requote_ms
  =
  let base = Params.btc in
  let order_size =
    match size with
    | Some size -> Size.of_string size
    | None ->
      let size = Fx.size_of_notional (Usd.of_int 100) instrument.mid in
      Size.of_units (Fx.ceil_to (Size.to_units size) ~step:(Size.to_units instrument.lot))
  in
  let max_position =
    match max_position with
    | Some max_position -> Size.of_string max_position
    | None -> Size.scale order_size ~by:10
  in
  let max_notional =
    Usd.of_float (1.5 *. Size.to_float max_position *. Price.to_float instrument.mid)
  in
  { base with
    coin = instrument.coin
  ; asset = instrument.asset
  ; tick = instrument.tick
  ; lot = instrument.lot
  ; order_size
  ; levels = Option.value levels ~default:base.levels
  ; base_half_spread_bps = Option.value half_spread_bps ~default:base.base_half_spread_bps
  ; skew_bps = Option.value skew_bps ~default:base.skew_bps
  ; max_position
  ; max_notional
  ; requote_interval_ms = Option.value requote_ms ~default:base.requote_interval_ms
  }
;;

let command =
  Command.async_or_error
    ~summary:"Market maker for hl-sim (and Hyperliquid-compatible APIs)"
    ~readme:(fun () ->
      "Quotes a post-only ladder around the microprice of one coin, skewed by inventory, \
       and requotes as the book moves. Exchange requests carry the X-Address header \
       (hl-sim's acting account). On SIGINT/SIGTERM, or after -run-for seconds, it \
       cancels every resting order and prints a report (a second SIGINT exits at once).")
    (let%map_open.Command base_url =
       flag
         "-base-url"
         (optional_with_default "http://localhost:3000" string)
         ~doc:
           "URL HTTP API root; the websocket is <url>/ws (default http://localhost:3000)"
     and address =
       flag
         "-address"
         (optional_with_default (Address.of_string default_address) address_arg)
         ~doc:(sprintf "ADDRESS account to trade as (default %s)" default_address)
     and coin =
       flag
         "-coin"
         (optional_with_default "BTC" string)
         ~doc:"COIN coin to quote (default BTC)"
     and levels = flag "-levels" (optional int) ~doc:"N quote levels per side (default 3)"
     and size =
       flag
         "-size"
         (optional string)
         ~doc:"SIZE order size per level (default: about 100 USD, 0.001 for BTC)"
     and half_spread_bps =
       flag
         "-half-spread-bps"
         (optional float)
         ~doc:"BPS distance of the first level from the reservation price (default 3)"
     and skew_bps =
       flag
         "-skew-bps"
         (optional float)
         ~doc:"BPS reservation price shift at full inventory (default 4)"
     and max_position =
       flag
         "-max-position"
         (optional string)
         ~doc:"SIZE absolute position limit (default 10 x size)"
     and requote_ms =
       flag
         "-requote-ms"
         (optional int)
         ~doc:"MS requote and open-orders poll interval (default 1000)"
     and run_for =
       flag
         "-run-for"
         (optional float)
         ~doc:"SECONDS stop after this long, cancel all and print a report"
     and summary_secs =
       flag
         "-summary-secs"
         (optional_with_default 10. float)
         ~doc:"SECONDS interval of the position and quotes summary log (default 10)"
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info, warn or error (default info)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let open Deferred.Or_error.Let_syntax in
       let client =
         Hl_client.Config.create ~address ~base_url:(Uri.of_string base_url) ()
       in
       let%bind instrument = Live.Instrument.fetch client (Coin.of_string coin) in
       let%bind params =
         Deferred.return
           (Or_error.try_with_join (fun () ->
              params_for
                instrument
                ~levels
                ~size
                ~half_spread_bps
                ~skew_bps
                ~max_position
                ~requote_ms
              |> Params.validate))
       in
       let stop = Ivar.create () in
       Signal.handle [ Signal.int; Signal.term ] ~f:(fun signal ->
         if Ivar.is_full stop
         then (
           Log.Global.error_s [%message "second signal, exiting" (signal : Signal.t)];
           Shutdown.shutdown 130)
         else (
           Log.Global.info_s
             [%message "signal received, shutting down" (signal : Signal.t)];
           Ivar.fill_if_empty stop ()));
       Option.iter run_for ~f:(fun seconds ->
         upon (Clock_ns.after (Time_ns.Span.of_sec seconds)) (Ivar.fill_if_empty stop));
       let%map report =
         Live.run
           { client; params; summary_interval = Time_ns.Span.of_sec summary_secs }
           ~stop:(Ivar.read stop)
       in
       print_endline "--- hl-mm report ---";
       print_endline (Live.Report.to_string_hum report))
;;

let () = Command_unix.run command
