{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Code.HsFrontEnd
-- Copyright   : (c) 2011-2016 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Code.HsFrontEnd where

import           Control.Monad.State
import           Control.Monad.Reader
import           Data.List
import           Data.Monoid                             ( (<>) )
import           Language.Haskell.Exts.Syntax            ( Asst(..), Binds(..), Boxed(..), Bracket(..)
                                                         , ClassDecl(..), DataOrNew(..), Decl(..)
                                                         , Exp(..), ExportSpec(..)
                                                         , ImportDecl(..), InstDecl(..), Literal(..)
                                                         , Name(..), Namespace(..), Pat(..)
                                                         , QualConDecl(..), Stmt(..)
                                                         , Type(..), TyVarBind (..)
                                                         )
import           Language.Haskell.Exts.SrcLoc            ( noLoc )
import           System.FilePath                         ((<.>))
-- 
import           FFICXX.Generate.Type.Class
import           FFICXX.Generate.Type.Annotate
import           FFICXX.Generate.Type.Module
import           FFICXX.Generate.Util
import           FFICXX.Generate.Util.HaskellSrcExts



mkComment :: Int -> String -> String
mkComment indent str 
  | (not.null) str = 
    let str_lines = lines str
        indentspace = replicate indent ' ' 
        commented_lines = 
          (indentspace <> "-- | "<>head str_lines) : map (\x->indentspace <> "--   "<>x) (tail str_lines)
     in unlines commented_lines 
  | otherwise = str                

mkPostComment :: String -> String
mkPostComment str 
  | (not.null) str = 
    let str_lines = lines str 
        commented_lines = 
          ("-- ^ "<>head str_lines) : map (\x->"--   "<>x) (tail str_lines)
     in unlines commented_lines 
  | otherwise = str                


genHsFrontDecl :: Class -> Reader AnnotateMap Decl
genHsFrontDecl c = do
  -- for the time being, let's ignore annotation.
  -- amap <- ask  
  -- let cann = maybe "" id $ M.lookup (PkgClass,class_name c) amap 
  let cdecl = mkClass (classConstraints c) (typeclassName c) [mkTBind "a"] body
      sigdecl f = mkFunSig (hsFuncName c f) (functionSignature c f)
      body = map (ClsDecl . sigdecl) . virtualFuncs . class_funcs $ c 
  return cdecl

-------------------

genHsFrontInst :: Class -> Class -> [Decl]
genHsFrontInst parent child  
  | (not.isAbstractClass) child = 
    let idecl = mkInstance [] (typeclassName parent) [convertCpp2HS (Just child) SelfType] body
        defn f = mkBind1 (hsFuncName child f) [] rhs Nothing 
          where rhs = App (mkVar (hsFuncXformer f)) (mkVar (hscFuncName child f))
        body = map (InsDecl . defn) . virtualFuncs . class_funcs $ parent
    in [idecl]
  | otherwise = []
        

      

---------------------

genHsFrontInstNew :: Class         -- ^ only concrete class 
                  -> Reader AnnotateMap [Decl]
genHsFrontInstNew c = do 
  -- amap <- ask
  let fs = filter isNewFunc (class_funcs c)
  return . flip concatMap fs $ \f ->
    let
        -- for the time being, let's ignore annotation.
        -- cann = maybe "" id $ M.lookup (PkgMethod, constructorName c) amap
        -- newfuncann = mkComment 0 cann
        rhs = App (mkVar (hsFuncXformer f)) (mkVar (hscFuncName c f))
    in mkFun (constructorName c) (functionSignature c f) [] rhs Nothing

genHsFrontInstNonVirtual :: Class -> [Decl]
genHsFrontInstNonVirtual c =
  flip concatMap nonvirtualFuncs $ \f -> 
    let rhs = App (mkVar (hsFuncXformer f)) (mkVar (hscFuncName c f))
    in mkFun (aliasedFuncName c f) (functionSignature c f) [] rhs Nothing
 where nonvirtualFuncs = nonVirtualNotNewFuncs (class_funcs c)

-----

genHsFrontInstStatic :: Class -> [Decl]
genHsFrontInstStatic c =
  flip concatMap (staticFuncs (class_funcs c)) $ \f ->
    let rhs = App (mkVar (hsFuncXformer f)) (mkVar (hscFuncName c f))
    in mkFun (aliasedFuncName c f) (functionSignature c f) [] rhs Nothing

-----

castBody :: [InstDecl]
castBody =
  [ InsDecl (mkBind1 "cast" [mkPVar "x",mkPVar "f"] (App (mkVar "f") (App (mkVar "castPtr") (App (mkVar "get_fptr") (mkVar "x")))) Nothing)
  , InsDecl (mkBind1 "uncast" [mkPVar "x",mkPVar "f"] (App (mkVar "f") (App (mkVar "cast_fptr_to_obj") (App (mkVar "castPtr") (mkVar "x")))) Nothing)
  ]

genHsFrontInstCastable :: Class -> Maybe Decl
genHsFrontInstCastable c 
  | (not.isAbstractClass) c = 
    let iname = typeclassName c
        (_,rname) = hsClassName c
        a = mkTVar "a"
        ctxt = [ ClassA (unqual iname) [a], ClassA (unqual "FPtr") [a] ]
    in Just (mkInstance ctxt "Castable" [a,TyApp tyPtr (tycon rname)] castBody)
  | otherwise = Nothing

genHsFrontInstCastableSelf :: Class -> Maybe Decl
genHsFrontInstCastableSelf c 
  | (not.isAbstractClass) c = 
    let (cname,rname) = hsClassName c
    in Just (mkInstance [] "Castable" [tycon cname, TyApp tyPtr (tycon rname)] castBody)
  | otherwise = Nothing


--------------------------

hsClassRawType :: Class -> [Decl]
hsClassRawType c =
  [ mkData    rawname [] [] []
  , mkNewtype highname []
      [ QualConDecl noLoc [] []
          (conDecl highname [TyApp tyPtr rawtype])
      ]
      derivs
  , mkInstance [] "FPtr" [hightype]
      [ InsType noLoc (TyApp (tycon "Raw") hightype) rawtype
      , InsDecl (mkBind1 "get_fptr" [PApp (unqual highname) [mkPVar "ptr"]] (mkVar "ptr") Nothing)
      , InsDecl (mkBind1 "cast_fptr_to_obj" [] (con highname) Nothing)
      ]
      
  ]
 where (highname,rawname) = hsClassName c
       hightype = tycon highname
       rawtype = tycon rawname
       derivs = [(unqual "Eq",[]),(unqual "Ord",[]),(unqual "Show",[])]


------------
-- upcast --
------------

genHsFrontUpcastClass :: Class -> [Decl]
genHsFrontUpcastClass c = mkFun ("upcast"<>highname) typ [mkPVar "h"] rhs Nothing
  where (highname,rawname) = hsClassName c
        hightype = tycon highname
        rawtype = tycon rawname
        iname = typeclassName c
        a_bind = UnkindedVar (Ident "a")
        a_tvar = mkTVar "a"
        typ = TyForall (Just [a_bind])
                [ClassA (unqual "FPtr") [a_tvar], ClassA (unqual iname) [a_tvar]]
                (TyFun a_tvar hightype)
        rhs = Let (BDecls
                    [ pbind (mkPVar "fh") (App (mkVar "get_fptr") (mkVar "h")) Nothing
                    , pbind (mkPVarSig "fh2" (TyApp tyPtr rawtype))
                        (App (mkVar "castPtr") (mkVar "fh")) Nothing
                    ]
                  )
                  (mkVar "cast_fptr_to_obj" `App` mkVar "fh2")


--------------
-- downcast --
--------------

genHsFrontDowncastClass :: Class -> [Decl]
genHsFrontDowncastClass c = mkFun ("downcast"<>highname) typ [mkPVar "h"] rhs Nothing
  where (highname,_rawname) = hsClassName c
        hightype = tycon highname
        iname = typeclassName c
        a_bind = UnkindedVar (Ident "a")
        a_tvar = mkTVar "a"
        typ = TyForall (Just [a_bind])
                [ClassA (unqual "FPtr") [a_tvar], ClassA (unqual iname) [a_tvar]]
                (TyFun hightype a_tvar)
        rhs = Let (BDecls
                    [ pbind (mkPVar "fh") (App (mkVar "get_fptr") (mkVar "h")) Nothing
                    , pbind (mkPVar "fh2") (App (mkVar "castPtr") (mkVar "fh")) Nothing
                    ] 
                  ) 
                  (mkVar "cast_fptr_to_obj" `App` mkVar "fh2")


------------------------
-- Top Level Function --
------------------------

genTopLevelFuncDef :: TopLevelFunction -> [Decl]
genTopLevelFuncDef f@TopLevelFunction {..} = 
    let fname = hsFrontNameForTopLevelFunction f
        (typs,ctxts) = extractArgRetTypes Nothing False (toplevelfunc_args,toplevelfunc_ret)
        -- rtyp = (tycon . ctypToHsTyp Nothing) toplevelfunc_ret
        sig = TyForall Nothing ctxts (foldr1 TyFun typs)
        xformerstr = let len = length toplevelfunc_args in if len > 0 then "xform" <> show (len-1) else "xformnull"
        cfname = "c_" <> toLowers fname 
        rhs = App (mkVar xformerstr) (mkVar cfname)
        
    in mkFun fname sig [] rhs Nothing 
genTopLevelFuncDef v@TopLevelVariable {..} = 
    let fname = hsFrontNameForTopLevelFunction v
        cfname = "c_" <> toLowers fname 
        rtyp = (tycon . ctypToHsTyp Nothing) toplevelvar_ret
        sig = TyApp (tycon "IO") rtyp
        rhs = App (mkVar "xformnull") (mkVar cfname)
        
    in mkFun fname sig [] rhs Nothing 


------------
-- Export --
------------

genExport :: Class -> [ExportSpec]
genExport c =
    let espec n = if null . (filter isVirtualFunc) $ (class_funcs c) 
                    then EAbs NoNamespace (unqual n)
                    else EThingAll (unqual n)
    in if isAbstractClass c 
       then [ espec (typeclassName c) ]
       else [ EThingAll (unqual ((fst.hsClassName) c))
            , espec (typeclassName c)
            , EVar (unqual ("upcast" <> (fst.hsClassName) c))
            , EVar (unqual ("downcast" <> (fst.hsClassName) c)) ]
            <> genExportConstructorAndNonvirtual c 
            <> genExportStatic c 

-- | constructor and non-virtual function 
genExportConstructorAndNonvirtual :: Class -> [ExportSpec]
genExportConstructorAndNonvirtual c = map (EVar . unqual) fns
  where fs = class_funcs c
        fns = map (aliasedFuncName c) (constructorFuncs fs 
                                       <> nonVirtualNotNewFuncs fs)

-- | staic function export list 
genExportStatic :: Class -> [ExportSpec]
genExportStatic c = map (EVar . unqual) fns
  where fs = class_funcs c
        fns = map (aliasedFuncName c) (staticFuncs fs) 


genExtraImport :: ClassModule -> [ImportDecl]
genExtraImport cm = map mkImport (cmExtraImport cm)


genImportInModule :: [Class] -> [ImportDecl]
genImportInModule = concatMap (\x -> map (\y -> mkImport (getClassModuleBase x<.>y)) ["RawType","Interface","Implementation"])

genImportInFFI :: ClassModule -> [ImportDecl]
genImportInFFI = map (\x->mkImport (x <.> "RawType")) . cmImportedModulesForFFI

genImportInInterface :: ClassModule -> [ImportDecl]
genImportInInterface m = 
  let modlstraw = cmImportedModulesRaw m
      modlstparent = cmImportedModulesHighNonSource m 
      modlsthigh = cmImportedModulesHighSource m
  in  [mkImport (cmModule m <.> "RawType")]
      <> map (\x -> mkImport (x<.>"RawType")) modlstraw
      <> map (\x -> mkImport (x<.>"Interface")) modlstparent 
      <> map (\x -> mkImportSrc (x<.>"Interface")) modlsthigh

-- |
genImportInCast :: ClassModule -> [ImportDecl]
genImportInCast m = [ mkImport (cmModule m <.> "RawType")
                   ,  mkImport (cmModule m <.> "Interface") ]

-- | 
genImportInImplementation :: ClassModule -> [ImportDecl]
genImportInImplementation m = 
  let modlstraw' = cmImportedModulesForFFI m
      modlsthigh = nub $ map getClassModuleBase $ concatMap class_allparents (cmClass m)
      modlstraw = filter (not.(flip elem modlsthigh)) modlstraw' 
  in  [ mkImport (cmModule m <.> "RawType")
      , mkImport (cmModule m <.> "FFI")
      , mkImport (cmModule m <.> "Interface")
      , mkImport (cmModule m <.> "Cast") ]
      <> concatMap (\x -> map (\y -> mkImport (x<.>y)) ["RawType","Cast","Interface"]) modlstraw
      <> concatMap (\x -> map (\y -> mkImport (x<.>y)) ["RawType","Cast","Interface"]) modlsthigh

        
genTmplInterface :: TemplateClass -> [Decl]
genTmplInterface t =
  [ mkData rname [mkTBind tp] [] []
  , mkNewtype hname [mkTBind tp]
      [ QualConDecl noLoc [] [] (conDecl hname [TyApp tyPtr rawtype]) ] []
  , mkClass [] (typeclassNameT t) [mkTBind tp] methods
  , mkInstance [] "FPtr" [ hightype ] fptrbody
  , mkInstance [] "Castable" [ hightype, TyApp tyPtr rawtype ] castBody
  ]
 where (hname,rname) = hsTemplateClassName t
       tp = tclass_param t
       fs = tclass_funcs t
       rawtype = TyApp (tycon rname) (mkTVar tp)
       hightype = TyApp (tycon hname) (mkTVar tp)
       sigdecl f@TFun {..}    = mkFunSig tfun_name (functionSignatureT t f)
       sigdecl f@TFunNew {..} = mkFunSig ("new"<>tclass_name t) (functionSignatureT t f)
       sigdecl f@TFunDelete = mkFunSig ("delete"<>tclass_name t) (functionSignatureT t f)
       methods = map (ClsDecl . sigdecl) fs
       fptrbody = [ InsType noLoc (TyApp (tycon "Raw") hightype) rawtype
                  , InsDecl (mkBind1 "get_fptr" [PApp (unqual hname) [mkPVar "ptr"]] (mkVar "ptr") Nothing)
                  , InsDecl (mkBind1 "cast_fptr_to_obj" [] (con hname) Nothing)
                  ]


genTmplImplementation :: TemplateClass -> [Decl]
genTmplImplementation t = concatMap gen (tclass_funcs t)
  where
    gen f = mkFun nh sig [p "nty", p "ncty"] rhs (Just binds)
      where nh = case f of
                   TFun {..}    -> "t_" <> tfun_name
                   TFunNew {..} -> "t_" <> "new" <> tclass_name t
                   TFunDelete   -> "t_" <> "delete" <> tclass_name t                   
            nc = case f of
                   TFun {..}    -> tfun_name
                   TFunNew {..} -> "new"
                   TFunDelete   -> "delete"                   
            sig = tycon "Name" `TyFun` (tycon "String" `TyFun` tycon "ExpQ")
            v = mkVar
            p = mkPVar
            tp = tclass_param t
            prefix = tclass_name t
            lit = Lit (String (prefix<>"_"<>nc<>"_"))
            lam = Lambda noLoc [p "n"] ( lit `App` v "<>" `App` v "n") 
            rhs = App (v "mkTFunc") (Tuple Boxed [v "nty", v "ncty", lam, v "tyf"])
            sig' = functionSignatureTT t f
            binds = BDecls [ mkBind1 "tyf" [mkPVar "n"]
                               (Let (BDecls [ pbind (p tp) (v "return" `App` (con "ConT" `App` v "n")) Nothing ])
                                 (BracketExp (TypeBracket sig')))
                               Nothing 
                           ]


genTmplInstance :: TemplateClass -> [TemplateFunction] -> [Decl]
genTmplInstance t fs = mkFun fname sig [p "n", p "ctyp"] rhs Nothing
  where tname = tclass_name t 
        fname = "gen" <> tname <> "InstanceFor"
        p = mkPVar
        v = mkVar
        l = Lit . String
        sig = tycon "Name" `TyFun` (tycon "String" `TyFun` (TyApp (tycon "Q") (TyList (tycon "Dec"))))

        nfs = zip ([1..] :: [Int]) fs
        rhs = Do (map genstmt nfs <> [LetStmt (lststmt nfs), Qualifier retstmt])

        genstmt (n,TFun    {..}) = Generator noLoc (p ("f"<>show n))
                                   (v "mkMember" `App` l tfun_name
                                                 `App` v ("t_" <> tfun_name)
                                                 `App` v "n"
                                                 `App` v "ctyp"
                                   )
        genstmt (n,TFunNew {..}) = Generator noLoc (p ("f"<>show n)) 
                                   (v "mkNew"    `App` l ("new" <> tname)
                                                 `App` v ("t_new" <> tname)
                                                 `App` v "n"
                                                 `App` v "ctyp"
                                   )
        genstmt (n,TFunDelete)   = Generator noLoc (p ("f"<>show n)) 
                                   (v "mkDelete" `App` l ("delete"<>tname)
                                                 `App` v ("t_delete" <> tname)
                                                 `App` v "n"
                                                 `App` v "ctyp"
                                   )                                   
        lststmt lst = BDecls [ pbind (p "lst") (List (map (v . (\n -> "f" <> show n) . fst) lst)) Nothing ]
        retstmt = v "return"
                  `App` List [ v "mkInstance"
                               `App` List []
                               `App` (con "AppT"
                                      `App` (v "con" `App` l (typeclassNameT t))
                                      `App` (con "ConT" `App` (v "n"))
                                     )
                               `App` (v "lst")
                             ] 

