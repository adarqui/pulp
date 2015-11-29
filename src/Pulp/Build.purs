
module Pulp.Build
  ( action
  , build
  , testBuild
  , getOutputStream
  ) where

import Prelude
import Control.Monad (when)
import Data.Maybe
import Data.Map (union)
import Data.String (split)
import Data.Set as Set
import Control.Monad.Eff.Class (liftEff)

import Pulp.System.FFI
import Pulp.System.Stream as Stream
import Pulp.System.Process as Process
import Pulp.System.Log as Log
import Pulp.System.Files as Files
import Pulp.Args
import Pulp.Args.Get
import Pulp.Exec (psc, pscBundle)
import Pulp.Files

data BuildType = NormalBuild | TestBuild

instance eqBuildType :: Eq BuildType where
  eq NormalBuild NormalBuild = true
  eq TestBuild TestBuild     = true
  eq _ _                     = false

action :: Action
action = go NormalBuild

build :: forall e. Args -> AffN e Unit
build = runAction action

testBuild :: forall e. Args -> AffN e Unit
testBuild = runAction (go TestBuild)

go :: BuildType -> Action
go buildType = Action \args -> do
  let opts = union args.globalOpts args.commandOpts

  cwd <- liftEff Process.cwd
  Log.log $ "Building project in" ++ cwd

  globs <- Set.union <$> defaultGlobs opts
                     <*> (if buildType == TestBuild
                            then testGlobs opts
                            else pure Set.empty)

  buildPath <- getOption' "buildPath" args.commandOpts

  psc (sources globs)
      (ffis globs)
      (["-o", buildPath] ++ args.remainder)
      Nothing
  Log.log "Build successful."

  shouldBundle <- (||) <$> getFlag "optimise" opts <*> hasOption "to" opts
  when shouldBundle (bundle args)

  -- TODO: rebuild

bundle :: forall e. Args -> AffN e Unit
bundle args = do
  let opts = union args.globalOpts args.commandOpts

  Log.log "Optimising JavaScript..."

  main      <- getOption' "main" opts
  modules   <- fromMaybe [] <<< map (split ",") <$> getOption "modules" opts
  buildPath <- getOption' "buildPath" opts

  bundledJs <- pscBundle (outputModules buildPath)
                         (["--module=" ++ main, "--main=" ++ main]
                           ++ map (\m -> "--module=" ++ m) modules
                           ++ args.remainder)
                          Nothing

  out <- getOutputStream opts
  Stream.write out bundledJs

  Log.log "Bundled."

-- | Get a writable stream which output should be written to, based on the
-- | value of the 'to' option.
getOutputStream :: forall e. Options -> AffN e (Stream.NodeStream String)
getOutputStream opts = do
  to <- getOption "to" opts
  case to of
    Just path -> liftEff $ Files.createWriteStream path
    Nothing   -> pure Process.stdout
