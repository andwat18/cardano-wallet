{ system
  , compiler
  , flags
  , pkgs
  , hsPkgs
  , pkgconfPkgs
  , errorHandler
  , config
  , ... }:
  {
    flags = { unexpected_thunks = false; };
    package = {
      specVersion = "1.10";
      identifier = { name = "cardano-cli"; version = "1.15.0"; };
      license = "Apache-2.0";
      copyright = "";
      maintainer = "operations@iohk.io";
      author = "IOHK";
      homepage = "";
      url = "";
      synopsis = "";
      description = "The Cardano command-line interface.";
      buildType = "Simple";
      isLocal = true;
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
          (hsPkgs."aeson-pretty" or (errorHandler.buildDepError "aeson-pretty"))
          (hsPkgs."attoparsec" or (errorHandler.buildDepError "attoparsec"))
          (hsPkgs."bech32" or (errorHandler.buildDepError "bech32"))
          (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
          (hsPkgs."base16-bytestring" or (errorHandler.buildDepError "base16-bytestring"))
          (hsPkgs."base58-bytestring" or (errorHandler.buildDepError "base58-bytestring"))
          (hsPkgs."canonical-json" or (errorHandler.buildDepError "canonical-json"))
          (hsPkgs."cardano-api" or (errorHandler.buildDepError "cardano-api"))
          (hsPkgs."cardano-binary" or (errorHandler.buildDepError "cardano-binary"))
          (hsPkgs."cardano-config" or (errorHandler.buildDepError "cardano-config"))
          (hsPkgs."cardano-crypto" or (errorHandler.buildDepError "cardano-crypto"))
          (hsPkgs."cardano-crypto-class" or (errorHandler.buildDepError "cardano-crypto-class"))
          (hsPkgs."cardano-crypto-wrapper" or (errorHandler.buildDepError "cardano-crypto-wrapper"))
          (hsPkgs."cardano-ledger" or (errorHandler.buildDepError "cardano-ledger"))
          (hsPkgs."cardano-prelude" or (errorHandler.buildDepError "cardano-prelude"))
          (hsPkgs."cardano-slotting" or (errorHandler.buildDepError "cardano-slotting"))
          (hsPkgs."contra-tracer" or (errorHandler.buildDepError "contra-tracer"))
          (hsPkgs."cborg" or (errorHandler.buildDepError "cborg"))
          (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
          (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
          (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
          (hsPkgs."formatting" or (errorHandler.buildDepError "formatting"))
          (hsPkgs."io-sim-classes" or (errorHandler.buildDepError "io-sim-classes"))
          (hsPkgs."iproute" or (errorHandler.buildDepError "iproute"))
          (hsPkgs."lens" or (errorHandler.buildDepError "lens"))
          (hsPkgs."memory" or (errorHandler.buildDepError "memory"))
          (hsPkgs."network" or (errorHandler.buildDepError "network"))
          (hsPkgs."network-mux" or (errorHandler.buildDepError "network-mux"))
          (hsPkgs."network-uri" or (errorHandler.buildDepError "network-uri"))
          (hsPkgs."optparse-applicative" or (errorHandler.buildDepError "optparse-applicative"))
          (hsPkgs."ouroboros-consensus" or (errorHandler.buildDepError "ouroboros-consensus"))
          (hsPkgs."ouroboros-consensus-byron" or (errorHandler.buildDepError "ouroboros-consensus-byron"))
          (hsPkgs."ouroboros-consensus-cardano" or (errorHandler.buildDepError "ouroboros-consensus-cardano"))
          (hsPkgs."ouroboros-consensus-shelley" or (errorHandler.buildDepError "ouroboros-consensus-shelley"))
          (hsPkgs."ouroboros-network" or (errorHandler.buildDepError "ouroboros-network"))
          (hsPkgs."scientific" or (errorHandler.buildDepError "scientific"))
          (hsPkgs."shelley-spec-ledger" or (errorHandler.buildDepError "shelley-spec-ledger"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."time" or (errorHandler.buildDepError "time"))
          (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
          (hsPkgs."transformers-except" or (errorHandler.buildDepError "transformers-except"))
          (hsPkgs."ouroboros-network-framework" or (errorHandler.buildDepError "ouroboros-network-framework"))
          (hsPkgs."utf8-string" or (errorHandler.buildDepError "utf8-string"))
          (hsPkgs."unordered-containers" or (errorHandler.buildDepError "unordered-containers"))
          (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
          ] ++ (if system.isWindows
          then [ (hsPkgs."Win32" or (errorHandler.buildDepError "Win32")) ]
          else [ (hsPkgs."unix" or (errorHandler.buildDepError "unix")) ]);
        buildable = true;
        };
      exes = {
        "cardano-cli" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cardano-cli" or (errorHandler.buildDepError "cardano-cli"))
            (hsPkgs."cardano-config" or (errorHandler.buildDepError "cardano-config"))
            (hsPkgs."cardano-prelude" or (errorHandler.buildDepError "cardano-prelude"))
            (hsPkgs."optparse-applicative" or (errorHandler.buildDepError "optparse-applicative"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."transformers-except" or (errorHandler.buildDepError "transformers-except"))
            ];
          buildable = true;
          };
        };
      tests = {
        "cardano-cli-test" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cardano-cli" or (errorHandler.buildDepError "cardano-cli"))
            (hsPkgs."cardano-prelude" or (errorHandler.buildDepError "cardano-prelude"))
            (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
            (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
            (hsPkgs."process" or (errorHandler.buildDepError "process"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."text-ansi" or (errorHandler.buildDepError "text-ansi"))
            (hsPkgs."unix" or (errorHandler.buildDepError "unix"))
            ];
          buildable = if system.isWindows then false else true;
          };
        "cardano-cli-pioneers" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."bech32" or (errorHandler.buildDepError "bech32"))
            (hsPkgs."cardano-api" or (errorHandler.buildDepError "cardano-api"))
            (hsPkgs."cardano-cli" or (errorHandler.buildDepError "cardano-cli"))
            (hsPkgs."cardano-prelude" or (errorHandler.buildDepError "cardano-prelude"))
            (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
            (hsPkgs."hedgehog" or (errorHandler.buildDepError "hedgehog"))
            (hsPkgs."optparse-applicative" or (errorHandler.buildDepError "optparse-applicative"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."transformers-except" or (errorHandler.buildDepError "transformers-except"))
            ];
          buildable = true;
          };
        };
      };
    } // {
    src = (pkgs.lib).mkDefault (pkgs.fetchgit {
      url = "https://github.com/input-output-hk/cardano-node";
      rev = "97b3e95c67940608f5acda929cf861e8ebfeddd1";
      sha256 = "1b50lv1lmc3qb5i4x9jry1nq88hqwavk857c1wp7v9666pq4nb9a";
      });
    postUnpack = "sourceRoot+=/cardano-cli; echo source root reset to \$sourceRoot";
    }