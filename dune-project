(lang dune 3.17)

(name hl-mm)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/hl-mm))

(package
 (name hl-mm)
 (synopsis "Market maker for hl-sim")
 (depends ocaml dune core hl-protocol fixed-decimal ppx_jane))
