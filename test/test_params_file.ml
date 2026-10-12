open! Core
open Exchange_core
open Hl_mm

let base = Mm_core.Params.btc

let show overrides =
  match Params_file.apply base ~overrides:(Sexp.of_string overrides) with
  | Error error -> print_s [%message "error" (error : Error.t)]
  | Ok (p : Mm_core.Params.t) ->
    print_s
      [%message
        ""
          ~levels:(p.levels : int)
          ~max_actions_per_sec:(p.max_actions_per_sec : int)
          ~soft_max_position:(p.soft_max_position : Size.t option)
          ~max_position:(p.max_position : Size.t)]
;;

let%expect_test "fields left out keep the base values" =
  show "()";
  [%expect
    {|
    ((levels 3) (max_actions_per_sec 100) (soft_max_position ())
     (max_position 0.01))
    |}]
;;

let%expect_test "action cap and soft position limit" =
  show "((max_actions_per_sec 20) (soft_max_position (0.005)) (levels 2))";
  [%expect
    {|
    ((levels 2) (max_actions_per_sec 20) (soft_max_position (0.005))
     (max_position 0.01))
    |}];
  show "((soft_max_position ()))";
  [%expect
    {|
    ((levels 3) (max_actions_per_sec 100) (soft_max_position ())
     (max_position 0.01))
    |}]
;;

let%expect_test "validation" =
  show "((max_actions_per_sec 0))";
  [%expect
    {|
    (error
     (error ("invalid params" (errors ("max_actions_per_sec must be positive")))))
    |}];
  show "((soft_max_position (0.02)))";
  [%expect
    {|
    (error
     (error
      ("invalid params"
       (errors ("soft_max_position must be in (0, max_position]")))))
    |}];
  show "((soft_max_position (-0.001)))";
  [%expect
    {|
    (error
     (error
      ("invalid params"
       (errors ("soft_max_position must be in (0, max_position]")))))
    |}];
  show "((soft_max_position 0.005))";
  [%expect
    {|
    (error
     (error
      ("bad parameter value"
       (Of_sexp_error "option_of_sexp: only none can be atom"
        (invalid_sexp 0.005)))))
    |}];
  show "((max_action_per_sec 20))";
  [%expect {| (error (error ("unknown parameters" (max_action_per_sec)))) |}];
  show "((levels 2) (levels 3))";
  [%expect {| (error (error ("field set twice" levels))) |}];
  show "((symbol ETH))";
  [%expect {| (error (error ("the symbol cannot change" (from BTC) (to_ ETH)))) |}]
;;
