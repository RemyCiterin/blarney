{-|
Module      : Namer
Description : Namer plugin for Blarney
Copyright   : (c) Alexandre Joannou, 2019
                  Matthew Naylor, 2019
License     : MIT
Maintainer  : alexandre.joannou@gmail.com
Stability   : experimental

This module defines a ghc plugin for Blarney to preserve names from
Blarney source code down to netlists (and hence, for example,
generated Verilog code).  We look for monadic bindings of the form

  x <- m

where m has type

  Module a

for any a, and we rewrite the binding as

  x <- withName "x" m

Where withName is a standard Blarney function.  In this way, module
instances (including registers and wires, which are modules in
Blarney) will often be augmented with name information.  This is the
simplest useful approach we could think of.  In future, we might do
something similar with other binding forms too, for introducing names
into pure/combinatorial code.

This module was developed using Ollie Charle's assert-explainer
plugin as a guiding example:

  https://github.com/ocharles/assert-explainer

-}

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}

module BlarneyPlugins.Namer (plugin) where

import Control.Monad.IO.Class ( liftIO )

-- ghc
import qualified GHC
import qualified GHC.Plugins as GHC
import qualified GHC.Tc.Types as GHC
import qualified GHC.Tc.Plugin as GHC
import qualified GHC.HsToCore as GHC
import qualified GHC.Tc.Types.Evidence as GHC
import qualified GHC.Types.TyThing as GHC
import qualified GHC.Types.SourceText as GHC
import qualified GHC.Hs.Pat as Pat
import qualified GHC.Hs.Expr as Expr
import qualified GHC.Core.Utils as CoreUtils
import qualified GHC.Parser.Annotation as GHC
import qualified GHC.Tc.Utils.Monad
import qualified GHC.Unit.Finder
import qualified GHC.Iface.Env
import qualified Data.Generics as SYB
import Data.IORef
import Control.Monad

-- | Printing helpers
msg :: String -> GHC.TcM ()
msg = liftIO . putStrLn
ppr :: GHC.Outputable a => a -> String
ppr = GHC.showPprUnsafe
pprMsg :: GHC.Outputable a => a -> GHC.TcM ()
pprMsg = msg . ppr

-- | SYB sadly doesn't define this
everywhereButM :: forall m. Monad m => SYB.GenericQ Bool
               -> SYB.GenericM m -> SYB.GenericM m
everywhereButM q f = go
  where
    go :: SYB.GenericM m
    go x
      | q x       = return x
      | otherwise = SYB.gmapM go x >>= f

-- | The exported 'GHC.Plugin'. Defines a custom type checker pass.
plugin :: GHC.Plugin
plugin = GHC.defaultPlugin {
           GHC.typeCheckResultAction = tcPass
         , GHC.pluginRecompile = \_ -> return GHC.NoForceRecompile
         }

-- | The type checker pass.
tcPass :: [GHC.CommandLineOption] -> GHC.ModSummary -> GHC.TcGblEnv
       -> GHC.TcM GHC.TcGblEnv
tcPass _ modS env = do
  count  <- liftIO $ newIORef 0
  hs_env <- GHC.Tc.Utils.Monad.getTopEnv
  blMod  <- liftIO $ GHC.Unit.Finder.findImportedModule hs_env
                    (GHC.mkModuleName "Blarney.Core.Module") Nothing
  case blMod of
    GHC.Found _ m -> do
      blNoNameVar <- GHC.Iface.Env.lookupOrig m (GHC.mkVarOcc "noName")
      tcg_binds <- everywhereButM (SYB.mkQ False (dontName blNoNameVar))
                     (SYB.mkM (nameModule count blMod)) (GHC.tcg_binds env)
      n <- liftIO $ readIORef count
      when (n > 0) $
        msg $ "\tBlarney's Namer plugin preserved "
            ++ show n ++ " instance name"
            ++ if n > 1 then "s" else ""
      return $ env { GHC.tcg_binds = tcg_binds }
    _ -> return env

-- | Avoid traversing into applications of function with given name
dontName :: GHC.Name -> Expr.HsExpr GHC.GhcTc -> Bool
dontName x (GHC.HsApp _ (GHC.L _
             (GHC.XExpr (GHC.WrapExpr
               (GHC.HsWrap _ (GHC.HsVar _ (GHC.L _ y)))))) e)
  | x == GHC.varName y = True
dontName x other = False

-- | Helper function to preserve Blarney modules' instance name.
nameModule :: IORef Int ->  GHC.FindResult -> Expr.ExprLStmt GHC.GhcTc
           -> GHC.TcM (Expr.ExprLStmt GHC.GhcTc)
nameModule count (GHC.Found _ m)
           e@(GHC.L loc (Expr.BindStmt xbind pat body)) = do
  hs_env <- GHC.Tc.Utils.Monad.getTopEnv
  blModuleTy <- GHC.Iface.Env.lookupOrig m (GHC.mkTcOcc "Module")
  (_, mbe) <- liftIO (GHC.deSugarExpr hs_env body)
  case CoreUtils.exprType <$> mbe of
    Nothing -> return e
    Just t  -> case GHC.splitTyConApp_maybe t of
      Just (tyC, [tyArg]) | GHC.tyConName tyC == blModuleTy -> do
        namer <- GHC.lookupId =<<
                 GHC.Iface.Env.lookupOrig m (GHC.mkVarOcc "withName")
        let isVarPat :: Pat.Pat GHC.GhcTc -> Bool
            isVarPat (Pat.VarPat _ _) = True
            isVarPat _ = False
        let vs     = SYB.listify isVarPat pat
        let name   = concatMap GHC.showPprUnsafe vs
        let bLoc   = GHC.L (GHC.getLoc body)
        let noExt  = GHC.noExtField
        let namerE = bLoc $ GHC.mkHsWrap (GHC.WpTyApp tyArg)
                          $ GHC.HsVar noExt
                              (GHC.L (GHC.l2l $ GHC.getLoc body) namer)
        let nameE  = bLoc $ GHC.HsLit GHC.noAnn
                          $ GHC.HsString GHC.NoSourceText (GHC.fsLit name)
        let namedE = bLoc $ GHC.HsApp GHC.noAnn namerE nameE
        let body'  = bLoc $ GHC.HsApp GHC.noAnn namedE body
        liftIO $ modifyIORef' count (+1)
        return $ GHC.L loc (Expr.BindStmt xbind pat body')
      _ -> return e
nameModule _ _ e = return e
