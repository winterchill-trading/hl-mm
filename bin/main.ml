open! Core
open! Async
open Hl_protocol
open Hl_mm
open Mm_core

(* "mm" in ASCII. *)
let default_address = "0x0000000000000000000000000000000000006d6d"
let default_base_url = "http://localhost:3000"

let address_arg =
  Command.Arg_type.create (fun s ->
    let hex = String.chop_prefix s ~prefix:"0x" in
    match hex with
    | Some hex when String.length hex = 40 && String.for_all hex ~f:Char.is_hex_digit ->
      Address.of_string s
    | _ -> raise_s [%message "expected 0x followed by 40 hex digits" s])
;;

module Live_hl = Mm_core.Live.Make (Hl_venue.Trading)

(* Per-coin defaults ([Params.for_instrument]): about $100 per order and 10 orders of
   position room, which for BTC at 100k reproduces [Params.btc] (0.001, 0.01 and 1500
   USD). *)
let params_for
  instrument
  ~mid
  ~levels
  ~size
  ~half_spread_bps
  ~skew_bps
  ~max_position
  ~requote_ms
  ~max_actions_per_sec
  ~soft_max_position
  ~params_file
  =
  Or_error.try_with_join (fun () ->
    let base =
      Params.for_instrument
        instrument
        ~mid
        ?order_size:(Option.map size ~f:Size.of_string)
        ?max_position:(Option.map max_position ~f:Size.of_string)
    in
    let flags : Params.t =
      { base with
        levels = Option.value levels ~default:base.levels
      ; base_half_spread_bps =
          Option.value half_spread_bps ~default:base.base_half_spread_bps
      ; skew_bps = Option.value skew_bps ~default:base.skew_bps
      ; requote_interval_ms = Option.value requote_ms ~default:base.requote_interval_ms
      ; max_actions_per_sec =
          Option.value max_actions_per_sec ~default:base.max_actions_per_sec
      ; soft_max_position =
          Option.first_some
            (Option.map soft_max_position ~f:Size.of_string)
            base.soft_max_position
      }
    in
    match params_file with
    | None -> Params.validate flags
    | Some path -> Params_file.load path ~base:flags)
;;

(* hl-sim (unsigned, the account from -address) or Hyperliquid's testnet (signed with
   HL_PRIVATE_KEY, the account is the key's). Mainnet is refused. *)
let trading_handle ~testnet ~base_url ~address =
  let module Client = Hl_client.Client in
  if testnet
  then (
    match base_url with
    | Some _ -> Or_error.error_string "-base-url and -testnet cannot be combined"
    | None ->
      Client.trading_of_env ~is_mainnet:false (Hl_client.Config.testnet ?address ()))
  else (
    let base_url = Uri.of_string (Option.value base_url ~default:default_base_url) in
    let config =
      Hl_client.Config.create
        ~address:(Option.value address ~default:(Address.of_string default_address))
        ~base_url
        ()
    in
    if Client.is_mainnet (Client.read_only config)
    then
      Or_error.error_s
        [%message "refusing to trade on mainnet" ~base_url:(Uri.to_string base_url)]
    else Ok (Client.trading config))
;;

(* [Live_hl.connect_and_run], keeping the loop's tick-to-order latency for the report. *)
let connect_and_run client ~symbol ~params ~summary_interval ~stop =
  let%bind.Deferred.Or_error venue = Hl_venue.Trading.connect client in
  let prepare =
    let open Deferred.Or_error.Let_syntax in
    let%bind instrument = Hl_venue.Trading.instrument venue symbol in
    let%bind mid = Live_hl.first_mid venue symbol in
    Deferred.return (params instrument ~mid)
  in
  match%bind prepare with
  | Error _ as error ->
    let%map () = Hl_venue.Trading.close venue in
    error
  | Ok params ->
    let%bind.Deferred.Or_error live =
      match%bind Live_hl.start venue { Live.Config.params; summary_interval } with
      | Ok _ as ok -> return ok
      | Error _ as error ->
        let%map () = Hl_venue.Trading.close venue in
        error
    in
    let%bind () = stop in
    let%map report = Live_hl.stop live in
    Ok (report, Live_hl.tick_to_order live)
;;

let command =
  Command.async_or_error
    ~summary:"Market maker for hl-sim (and Hyperliquid-compatible APIs)"
    ~readme:(fun () ->
      "Quotes a post-only ladder around the microprice of one coin, skewed by inventory, \
       and requotes as the book moves. Against hl-sim, exchange requests are unsigned \
       and carry the X-Address header (hl-sim's acting account). With -testnet they are \
       signed with the key in HL_PRIVATE_KEY and the account is the key's. Mainnet is \
       refused. On SIGINT/SIGTERM, or after -run-for seconds, it cancels every resting \
       order and prints a report (a second SIGINT exits at once).")
    (let%map_open.Command base_url =
       flag
         "-base-url"
         (optional string)
         ~doc:
           (sprintf
              "URL HTTP API root; the websocket is <url>/ws (default %s)"
              default_base_url)
     and testnet =
       flag
         "-testnet"
         no_arg
         ~doc:" trade on Hyperliquid's testnet, signing with the key in HL_PRIVATE_KEY"
     and address =
       flag
         "-address"
         (optional address_arg)
         ~doc:
           (sprintf
              "ADDRESS account to trade as (default %s, or the key's with -testnet)"
              default_address)
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
     and max_actions_per_sec =
       flag
         "-max-actions-per-sec"
         (optional int)
         ~doc:"N kill switch: more cancels and places than this in a second (default 100)"
     and soft_max_position =
       flag
         "-soft-max-position"
         (optional string)
         ~doc:
           "SIZE beyond this position stop quoting the side that grows it (default none)"
     and params_file =
       flag
         "-params"
         (optional string)
         ~doc:"FILE parameter overrides, a sexp of (field value) pairs (see README)"
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
       let%bind.Deferred.Or_error client =
         Deferred.return (trading_handle ~testnet ~base_url ~address)
       in
       Log.Global.info_s (List [ Atom "connecting"; Hl_client.Client.sexp_of_t client ]);
       let stop =
         Mm_core.Live.stop_signal ?run_for:(Option.map run_for ~f:Time_ns.Span.of_sec) ()
       in
       let%map.Deferred.Or_error report, tick_to_order =
         connect_and_run
           client
           ~symbol:(Coin.of_string coin)
           ~params:
             (params_for
                ~levels
                ~size
                ~half_spread_bps
                ~skew_bps
                ~max_position
                ~requote_ms
                ~max_actions_per_sec
                ~soft_max_position
                ~params_file)
           ~summary_interval:(Time_ns.Span.of_sec summary_secs)
           ~stop
       in
       print_endline "--- hl-mm report ---";
       print_endline (Mm_core.Live.Report.to_string_hum report);
       printf
         "tick to order    %s\n"
         (Option.value_map
            tick_to_order
            ~default:"-"
            ~f:Latency_histogram.Stats.to_string_hum))
;;

let () = Command_unix.run command
