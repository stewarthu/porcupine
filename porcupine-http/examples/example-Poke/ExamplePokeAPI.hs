{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE Arrows #-}

-- Don't forget to map locations to http urls in the 'exampleHTTP.yaml'
-- generated by calling 'exampleHTTP write-config-template'.

import           Control.Monad
import           Data.Aeson
import           Data.DocRecord
import qualified Data.Text                     as T
import           GHC.Generics
import           Porcupine.Run
import           Porcupine.Serials
import           Porcupine.Tasks
import           Prelude                       hiding (id, (.))
import           Graphics.Vega.VegaLite        as VL

import           Data.Locations.Accessors.HTTP


data Pokemon = Pokemon { pkName  :: !T.Text
                       , pkMoves :: ![T.Text]
                       , pkTypes :: ![T.Text] }

instance FromJSON Pokemon where
  parseJSON = withObject "Pokemon" $ \o -> Pokemon
    <$> o .: "name"
    <*> (o .: "moves" >>= mapM ((.: "move") >=> (.: "name")))
    <*> (o .: "types" >>= mapM ((.: "type") >=> (.: "name")))

-- | How to load pokemons.
pokemonFile :: DataSource Pokemon
pokemonFile = dataSource ["Inputs", "Pokemon"]
                         (somePureDeserial JSONSerial)
-- See https://pokeapi.co/api/v2/pokemon/25 for instance

newtype Analysis = Analysis { moveCount :: Int }
  deriving (Generic, ToJSON)

-- | How to write analysis
analysisFile :: DataSink Analysis
analysisFile = dataSink ["Outputs", "Analysis"]
                        (somePureSerial JSONSerial)

vlSummarySink :: DataSink VegaLite
vlSummarySink = dataSink ["Outputs", "Summary"]
              (lmap VL.toHtml (somePureSerial $ PlainTextSerial $ Just "html")
               <>
               lmap VL.fromVL (somePureSerial JSONSerial))

analyzePokemon :: Pokemon -> Analysis
analyzePokemon = Analysis . length . pkMoves

writeSummary :: (LogThrow m) => PTask m [Pokemon] ()
writeSummary = proc pkmn -> do
  let dat = dataFromColumns []
          . dataColumn "name" (Strings $ map pkName pkmn)
          . dataColumn "numMoves" (Numbers $ map (fromIntegral . length . pkMoves) pkmn)

      enc = encoding
          . position X [ PName "name", PmType Nominal ]
          . position Y [ PName "numMoves", PmType Quantitative ] -- , PAggregate Mean ]

      spec = toVegaLite [ dat [], mark Bar [], enc [] ]
  writeData vlSummarySink -< spec

-- | The task combining the three previous operations.
--
-- This task may look very opaque from the outside, having no parameters and no
-- return value. But we will be able to ppreuse it over different users without
-- having to change it at all.
analyzeOnePokemon :: (LogThrow m) => PTask m a Pokemon
analyzeOnePokemon =
  loadData pokemonFile >>> (arr analyzePokemon >>> writeData analysisFile) &&& id >>> arr snd

mainTask :: (LogThrow m) => PTask m () ()
mainTask =
  -- First we get the ids of the users that we want to analyse. We need only one
  -- field that will contain a range of values, see IndexRange. By default, this
  -- range contains just one value, zero.
  getOption ["Settings"] (docField @"pokemonIds" (oneIndex (1::Int)) "The indices of the pokemon to load")
  -- We turn the range we read into a full lazy list:
  >>> arr enumTRIndices
  -- Then we just map over these ids and call analyseOnePokemon each time:
  >>> parMapTask (repIndex "pokemonId") analyzeOnePokemon
  >>> writeSummary

main :: IO ()
main = runPipelineTask (FullConfig "example-pokeapi"
                                   "porcupine-http/examples/example-Poke/example-pokeapi.yaml"
                                   "example-pokeapi_files")
                       (  #http <-- useHTTP
                            -- We just add #http on top of the baseContexts.
                       :& baseContexts "")
                       mainTask ()
