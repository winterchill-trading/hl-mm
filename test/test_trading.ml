open! Core
open! Async
open Hl_protocol
open Hl_mm
open Sim_helpers
module Client = Hl_client.Client
module Signing = Hl_client.Signing
module Live_trading = Mm_core.Live.Make (Hl_venue.Trading)

(* A throwaway key (the secp256k1 secret 1); its address is well known. *)
let key = Signing.Private_key.of_hex (String.make 63 '0' ^ "1") |> ok_exn

let signer (entry : Hl_sim.Journal.Entry.t) =
  match entry.request.signature with
  | None -> "unsigned"
  | Some json ->
    let signature = Signing.Signature.t_of_yojson json in
    let connection_id =
      Signing.action_hash
        ~vault_address:entry.request.vault_address
        ~nonce:entry.request.nonce
        (Exchange_action.yojson_of_t entry.request.action)
    in
    let digest = Signing.l1_digest ~is_mainnet:false ~connection_id in
    "signed by " ^ Address.to_string (ok_exn (Signing.recover ~digest signature))
;;

let%expect_test "a signed trading handle quotes on hl-sim as the key's account" =
  let journal_dir = Filename_unix.temp_dir "hl-mm" "" in
  let journal_path = Filename.concat journal_dir "journal" in
  let%bind journal_writer = Writer.open_file journal_path in
  let%bind sim = start_sim ~journal:(Hl_sim.Journal.of_writer journal_writer) () in
  let handle =
    Client.trading ~key (Hl_client.Config.create ~base_url:(sim.client mm).base_url ())
  in
  print_s
    [%message
      ""
        ~account:((Client.config handle).address : Address.t option)
        ~mainnet:(Client.is_mainnet handle : bool)];
  [%expect {| ((account (0x7e5f4552091a69125d5dfcb7b8c2659029395bdf)) (mainnet false)) |}];
  let%bind venue = Hl_venue.Trading.connect handle >>| ok_exn in
  let%bind live =
    Live_trading.start
      venue
      { params =
          { Mm_core.Params.btc with requote_interval_ms = Time_ns.Span.of_int_ms 200 }
      ; summary_interval = Time_ns.Span.of_int_sec 60
      }
    >>| ok_exn
  in
  let%bind () =
    wait_until ~what:"quotes" (fun () -> (Live_trading.report live).orders_placed >= 6)
  in
  let account = Signing.Private_key.address key in
  let%bind () = print_open_orders (sim.client account) in
  [%expect
    {|
    A 0.001@100070
    A 0.001@100050
    A 0.001@100030
    B 0.001@99970
    B 0.001@99950
    B 0.001@99930
    |}];
  let%bind (_ : Mm_core.Live.Report.t) = Live_trading.stop live in
  let%bind () = Writer.close journal_writer in
  let%bind lines = Reader.file_lines journal_path in
  let%bind () = Unix.unlink journal_path in
  let%bind () = Unix.rmdir journal_dir in
  List.map lines ~f:(fun line ->
    let entry = Hl_sim.Journal.Entry.of_line line in
    Exchange_action.type_tag entry.request.action, signer entry)
  |> List.dedup_and_sort ~compare:[%compare: string * string]
  |> List.iter ~f:(fun (action, signer) -> printf "%s %s\n" action signer);
  (* The unsigned order is the static book, placed through a bare config. *)
  [%expect
    {|
    cancel signed by 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
    order signed by 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
    order unsigned
    |}];
  stop_sim sim
;;
