(* A read-only hl-client handle cannot reach /exchange, so it must not type-check as the
   config of a trading venue. *)
let connect (handle : Hl_client.Client.read_only Hl_client.Client.t) =
  Hl_mm.Hl_venue.Trading.connect handle
;;
