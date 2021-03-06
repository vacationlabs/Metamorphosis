-- | Main functions to manipulate what's in Types.
-- and doesn't need Template Haskell
module Metamorphosis.Internal
( fieldsToTypes
, applyFieldMapping
, reverseTypeDescs
, module Metamorphosis.Types
, consCombinations
, bestConstructorFor
, typeSources
, converterBaseName
, filterSourceByTypes
)
where

import Lens.Micro
import Data.Function (on)
import Data.List (sort, nub, nubBy, group, groupBy, intercalate, minimum)
import Metamorphosis.Types
import qualified Data.Map as Map
import Data.Map(Map)
import Data.Set(Set)
import qualified Data.Set as Set
import Metamorphosis.Util
  
-- | Structure Field Descriptions to types
fieldsToTypes :: [FieldDesc] -> [TypeDesc]
fieldsToTypes fds = let
  sorted = nubBy ((==) `on` _fdKey) $ sort fds -- by type, constructor, pos
  groups = groupBy ((==) `on` _fdType) sorted
  mkType fields@(fd:_) = let typeD = TypeDesc (_fdTypeName fd)
                                 (_fdModuleName fd)
                                 (fieldsToConss typeD fields)
                         in typeD
  in map mkType groups


-- | Create ConsDesc from a list of FieldDesc belonging to the same type.
fieldsToConss :: TypeDesc -> [FieldDesc] -> [ConsDesc]
fieldsToConss typD fds = let
  sorted = nubBy ((==) `on` _fdKey) $ sort fds -- by type, constructor, pos
  groups = groupBy ((==) `on` _fdConsName) sorted
  mkCons fields@(fd:_) = let consD = ConsDesc (_fdConsName fd)
                                              typD
                                              ( zipWith3 FieldDescPlus (sort fields)
                                                                       (repeat consD)
                                                                       (repeat [])
                                              )
                         in consD
  in map mkCons groups

-- |
-- | Apply a field Mapping function to a list of TypeDesc.
applyFieldMapping :: (FieldDesc -> [FieldDesc]) -> [TypeDesc] -> [TypeDesc]
applyFieldMapping fieldMapping typDs = let
  fields =  typDs ^. each.tdCons.each.cdFields
  -- We need to create the new fields
  -- but also keep track of their sources
  newFields'Source = [ (_fdKey new , (new, [source]) )
                     |  source <- fields
                     , let field = source ^. fpField
                     , new <- fieldMapping  field
                     ]
  -- Group all sources
  newMap = Map.fromListWith (\(n, ss) (_, ss') -> (n, ss++ss')) newFields'Source
  setSources fp = fp { _fpSources = maybe []
                                          snd
                                          (Map.lookup (fp ^. to _fpKey) newMap)
                     }
  newTypes0 = fieldsToTypes (map fst (Map.elems newMap))
  -- We need to update the source
  in newTypes0 & mapped.tdCons.mapped.cdFields.mapped %~ setSources
  

-- | Extract the sources and recompute the source
-- so they point to the original target.
-- It should be equivalent to applying the inverse of a fieldMapping to types
-- (which where targets when calling applyingFieldMapping)
-- prop  rev.rev = id
reverseTypeDescs :: [TypeDesc] -> [TypeDesc]
reverseTypeDescs typDs = let
  sources = typeSources typDs
  targetFields = typDs ^. each.tdCons.each.cdFields

  sources'target = [(_fpKey source, (source, [originalTarget]))
                   | originalTarget <- targetFields
                   , source <- _fpSources originalTarget
                   ]

  sourcesMap = Map.fromListWith (\(n, ss) (_,ss') -> (n, ss++ss')) sources'target
  setSources fp = fp { _fpSources = maybe []
                                          ((mapped . fpSources .~ []) . snd)
                                          (Map.lookup (fp ^. to _fpKey) sourcesMap)
                     }
  in sources & mapped.tdCons.mapped.cdFields.mapped %~ setSources

  

  

-- | Find types needed to create a tuple of given types
-- Example if Data AB = AB A B and data XY = XY X Y
-- we can create (AB, X) from ()AB , XY
typeSources :: [TypeDesc] -> [TypeDesc]
typeSources tds = let
  sources = tds ^.. each . tdCons . each . cdFields . each .fpSources . each
  types = sources  ^.. each . fpCons . cdTypeDesc
  in nub . sort  $ types



-- | Only keep sources belonging to the list of types to keep
filterSourceByTypes :: [TypeDesc] -> [TypeDesc] -> [TypeDesc]
filterSourceByTypes  typesToKeep types =
  each . tdCons . each . cdFields . each . fpSources %~ (filter keep) $ types
  where keep  fd = fd ^. fpCons . cdTypeDesc `elem` typesToKeep

filterByTypes :: [TypeDesc] -> [TypeDesc] -> [TypeDesc]
filterByTypes typesToKeep types = filter (`elem` typesToKeep) types

-- | Keeps types having one of the given constructors.
filterByCons :: [ConsDesc] -> [TypeDesc] -> [TypeDesc]
filterByCons consToKeep types = filter (\t -> any (`elem` consToKeep) (_tdCons t)) types

-- * Hard bits
-- | Generates all the constructor combinations corresponding to the given type.
-- ex: for data AB = A a | B a ; data P = P x y ; data R = R 
-- [[A,P], [R]]  -- (A,P) R
-- [[B,P], [R]]   -- (B,P) R
consCombinations :: [[TypeDesc]] -> [[[ConsDesc]]]
consCombinations typs = go [] typs
  where go cs [] = [[reverse cs]]
        go cs ([]:[]) =  go cs []
        go cs ([]:typs) =  map (reverse cs:) (go [] typs)
        go cs ((typ:typs):typs') = [  comb
                           | con <- _tdCons typ
                           , comb <- go (con:cs) (typs:typs')
                           ]


-- | For the given type, find the constructor which is best buildable
-- from the given constructors (as function argument)
-- example: Converting from data B = B b to AB = ABA a | ABB b
-- the best suitable constructor given  (B b) would be ABB b
bestConstructorFor :: [TypeDesc] -> [[ConsDesc]] -> [ConsDesc]
bestConstructorFor typs sConss  = let
  sourceFields :: Set FieldDescPlus
  sourceFields = Set.fromList (sConss ^.. each . each . cdFields . each)
  weighted = [ (sum (map weight tCons), tCons)
             | tConss <- consCombinations [typs]
             , tCons <- tConss
             ] 
  -- weight = source variable not found (that will be converted to ())
  weight :: ConsDesc -> Int
  weight tCons = let
    used = [Set.member  fp sourceFields | fp <- tCons ^.. cdFields . each . fpSources . each ]
    in  length (filter (==False) used)

    
  in  snd $ minimum weighted


-- | Computes a converter name.
-- This is the base name to be used to filter converter to generates.
-- It is not a valid name and needs to be prefixed by something starting with lower case.
-- ex: (A) -> (B,C) -> (A,B,C) => AB'CToABC
converterBaseName  :: [[String]] -> [String] -> String
converterBaseName sourcess targets = let
  ss = map (intercalate "_") sourcess -- tuple separtor
  t = intercalate "'" targets
  in (intercalate "'" ss) ++ "To" ++ t
