--| Shared review records: mori://shinzui/okf-profiles/profiles/reviews.
-- Upstream release tag v0.21.0 verified before adoption.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.21.0/package.dhall
        sha256:4be32588d55c74282ceab54b06b22f552cdbf4215788e3eb5256ee8744cb92a2

in  Profiles.assurance.reviews
