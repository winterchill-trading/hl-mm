(lang dune 3.0)
(name hl-mm)
(generate_opam_files true)
(license MIT)
(source (github winterchill-trading/hl-mm))
(package
 (name hl-mm)
 (synopsis "Market maker for hl-sim")
 (depends ocaml dune core async ppx_jane ppx_yojson_conv yojson))
