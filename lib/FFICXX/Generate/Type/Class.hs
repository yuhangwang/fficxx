{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Type.Class
-- Copyright   : (c) 2011-2013 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Type.Class where

import Control.Applicative ((<$>),(<*>))
import Data.Char
import Data.List
import Data.Monoid
import qualified Data.Map as M
import System.FilePath
--
import FFICXX.Generate.Util

{-
  CPPType are represented by a base type (e.g., "int") and a collection of
  type operators applied to the base (e.g., pointers, arrays, etc...).

  Encoding:

  CPPType are encoded as strings of type constructors such as follows:

         String Encoding                 C Example
         ---------------                 ---------
         p.p.int                         int  *
         a(300).a(400).int               int [300][400]
         p.q(const).char                 char const  

  All type constructors are denoted by a trailing '.':

   'p.'                = Pointer (*)
   'r.'                = Reference (&)
   'a(n).'             = Array of size n  [n]
   'f(..,..).'         = Function with arguments  (args)
   'q(str).'           = Qualifier (such as const or volatile) (const, volatile)
   'm(qual).'          = Pointer to member (qual::*)

  The encoding follows the order that you might describe a type in words.
  For example "p.a(200).int" is "A pointer to array of int's" and
  "p.q(const).char" is "a pointer to a const char".

  This representation of types is fairly convenient because ordinary string
  operations can be used for type manipulation. For example, a type could be
  formed by combining two strings such as the following:

         "p.p." + "a(400).int" = "p.p.a(400).int"

  Similarly, one could strip a 'const' declaration from a type doing something
  like this:

         Replace(t,"q(const).","",DOH_REPLACE_ANY)

  For the most part, this module tries to minimize the use of special
  characters (*, [, <, etc...) in its type encoding.  One reason for this
  is that SWIG might be extended to encode data in formats such as XML
  where you might want to do this:

       <function>
          <type>p.p.int</type>
          ...
       </function>

  Or alternatively,

       <function type="p.p.int" ...>blah</function>

  In either case, it's probably best to avoid characters such as '&', '*', or '<'.
-}

data CPPType c = Ptr        (CPPType c) -- ^ Pointer to a type
               | Ref        (CPPType c) -- ^ Reference to a type
               | Arr        Int       (CPPType c) -- ^ Array of a type
               | Fun        [CPPType c] (CPPType c) -- ^ A function
               | QConst     (CPPType c) -- ^ const type
               | QVolatile  (CPPType c) -- ^ volatile type
               | QRestrict  (CPPType c) -- ^ restrict type, not supported, will give an error if passed such type
               | MPtr       c (PrimitiveTypes c) -- ^ Member pointer to class, the `CPPType` here should be a primitive type
             | PrimType  (PrimitiveTypes c) -- ^ Primitive c/c++ types
             deriving (Show, Eq)

data PrimitiveTypes c = CPTChar
                      | CPTInt
                      | CPTLong
                      | CPTUChar
                      | CPTUInt
                      | CPTULong
                      | CPTLongLong
                      | CPTULongLong
                      | CPTDouble
                      | CPTLongDouble
                      | CPTBool
                      | CPTVoid
                      | CPTClass c  -- ^ c denotes classes or templates
                    deriving (Show, Eq)

newtype ClassName = ClassName { unClassName :: String }

type SimpleCPPType = CPPType ClassName 

class CPPNameable c where -- ^ CPPType that can be identified by names
  cppname :: c -> String

instance CPPNameable ClassName where
  cppname = unClassName

instance (CPPNameable c) => CPPNameable (PrimitiveTypes c) where
  cppname CPTChar = "char"
  cppname CPTInt = "int"
  cppname CPTLong = "long int"
  cppname CPTLongLong = "long long"
  cppname CPTULong = "unsigned long"
  cppname CPTUChar = "unsigned char"
  cppname CPTUInt = "unsigned int"
  cppname CPTULongLong = "unsigned long long"
  cppname CPTDouble = "double"
  cppname CPTLongDouble = "long double"
  cppname CPTBool = "bool"
  cppname CPTVoid = "void"
  cppname (CPTClass c) = cppname c


instance (CPPNameable c) => CPPNameable (CPPType c) where
  cppname (Ptr fun@(Fun _ _)) = cppname fun
  cppname (Ptr t) = cppname t ++ "*"
  cppname (Ref t) = cppname t ++ "&"
  cppname (Arr n t) = cppname t ++ "[" ++ (show n) ++ "]"
  cppname (Fun ts t) = "(" ++ cppname t ++ ")" ++ " (*)(" ++ ((intercalate "," . map cppname) ts) ++ ")"
  cppname (QConst p@(Ptr _)) = cppname p ++ " const"
  cppname (QConst t) = "const " ++ cppname t
  cppname (QVolatile p@(Ptr _)) = cppname p ++ " volatile"
  cppname (QVolatile t) = "volatile " ++ cppname t
  cppname (QRestrict p@(Ptr _)) = cppname p ++ " restrict"
  cppname (QRestrict t) = "restrict " ++ cppname t
  cppname (MPtr s t) = cppname t ++ " " ++ cppname s ++ "::*"
  cppname (PrimType prim) = cppname prim
  
  
data StaticExtern = Static | Extern 
                  deriving Show 

type Args c = [(CPPType c,String)]

data TopLevelFunction c = TopLevelFunction { toplevelfunc_ret :: CPPType c
                                           , toplevelfunc_name :: String
                                           , toplevelfunc_args :: Args c
                                           , toplevelfunc_alias :: Maybe String
                                           , toplevelfunc_staticextern :: Maybe StaticExtern  
                                           }
                        deriving Show

cvarToStr :: (CPPNameable c) => CPPType c -> String -> String
cvarToStr t varname = (cppname t) `connspace` varname


-- | return type for haskell-C interface. special treatment to C++-only type
rettypeToString :: (CPPNameable c) => CPPType c -> String
rettypeToString (PrimType (CPTClass c)) = cppname c ++ "_p" 
rettypeToString (Ptr (PrimType (CPTClass c))) = cppname c ++ "_p"
rettypeToString (Ref (PrimType (CPTClass c))) = cppname c ++ "_p"
rettypeToString t = cppname t 
  

-- | Convert a function argument type to C syntax string
argToString :: (CPPNameable c) => (CPPType c,String) -> String
argToString (t, varname) = rettypeToString t `connspace` varname
                           
-- | function argument in C++ call
argToCallString :: (CPPNameable c) => (CPPType c,String) -> String
argToCallString (PrimType (CPTClass c),varname) =
    "to_nonconst<"++cppname c++","++cppname c++"_t>("++varname++")" 
argToCallString (Ptr (PrimType (CPTClass c)),varname) =
    "to_nonconstref<"++cppname c++","++cppname c++"_t>(*"++varname++")" 
argToCallString (_,varname) = varname


{-                           
argsToString :: (CPPNameable c) => Args c -> String
argsToString args =   
  let args' = (SelfType, "p") : args
  in  intercalateWith conncomma argToString args'
-}


{-
argsToCallString :: (CPPNameable c) => Args c -> String
argsToCallString = intercalateWith conncomma argToCallString
-}

{-                           
                           case isconst of
    Const   -> "const_" ++ cname ++ "_p " ++ varname
    NoConst -> cname ++ "_p " ++ varname
  where cname = class_name c
argToString (t, varname) = cvarToStr t varname
argToString (CPT (CPTClassRef c) isconst, varname) = case isconst of
    Const   -> "const_" ++ cname ++ "_p " ++ varname
    NoConst -> cname ++ "_p " ++ varname
  where cname = class_name c
argToString _ = error "undefined argToString"



argsToStringNoSelf :: (CPPNameable c) => Args c -> String
argsToStringNoSelf = intercalateWith conncomma argToString
 
-}





-- cvarToStr :: CPPType -> String -> String
-- cvarToStr t varname = (ctypToStr t) `connspace` varname




{-



-- | haskell representation of C++ types
hsCPPTypeName :: CPPType Class -> String
hsCPPTypeName (PrimType prim) =
  case prim of
    CPTChar -> "CChar"
    CPTInt -> "CInt"
    CPTLong -> "CLong"
    CPTUChar -> "CUChar"
    CPTUInt -> "CUInt"
    CPTULong -> "CULong"
    CPTLongLong -> "CLLong"
    CPTDouble -> "CDouble"
    CPTLongDouble -> "CDouble" -- not long double.. maybe problematic
    CPTBool -> "CInt"
    CPTVoid -> "()"
    CPTClass c -> "(Ptr "++rawname++")"  where rawname = snd (hsClassName c)

{-mkFullCPPType :: SomeGlobalNameMap -> CPPType String -> FFICXXMONAD (CPPType Class)-}

hsCppTypeName :: CPPType -> String
hsCppTypeName (Ref c) = "(Ptr "++rawname++")" where rawname = snd (hsClassName c)


{-
hsCTypeName CTString = "CString"
hsCTypeName CTChar   = "CChar"
hsCTypeName CTInt    = "CInt"
hsCTypeName CTUInt   = "CUInt"
hsCTypeName CTLong   = "CLong"
hsCTypeName CTULong  = "CULong"
hsCTypeName CTDouble = "CDouble"
hsCTypeName CTDoubleStar = "(Ptr CDouble)"
hsCTypeName CTBool   = "CInt"
hsCTypeName CTVoidStar = "(Ptr ())"
hsCTypeName CTIntStar = "(Ptr CInt)"
hsCTypeName CTCharStarStar = "(Ptr (CString))"
hsCTypeName (CPointer t) = "(Ptr " ++ hsCTypeName t ++ ")"
-}

-}

-------------
-------------
-------------
-- From here on, I haven't changed at all. 
-------------
-------------
                                                   
{-


-- | Member function 
data Function = Constructor { func_args :: Args
                            , func_alias :: Maybe String
                            }
              | Virtual { func_ret :: CPPType
                        , func_name :: String
                        , func_args :: Args
                        , func_alias :: Maybe String
                        }
              | NonVirtual { func_ret :: CPPType
                           , func_name :: String
                           , func_args :: Args
                           , func_alias :: Maybe String
                           }
              | Static     { func_ret :: CPPType
                           , func_name :: String
                           , func_args :: Args
                           , func_alias :: Maybe String
                           }
{-              | AliasVirtual { func_ret :: CPPType
                             , func_name :: String
                             , func_args :: Args
                             , func_alias :: String } -}
              | Destructor  { func_alias :: Maybe String }
              deriving Show



hsFrontNameForTopLevelFunction :: TopLevelFunction -> String
hsFrontNameForTopLevelFunction tfn =
    let (x:xs) = maybe (toplevelfunc_name tfn) id (toplevelfunc_alias tfn)
    in toLower x : xs


data TopLevelImportHeader = TopLevelImportHeader { tihHeaderFileName :: String
                                                 , tihClassDep :: [ClassImportHeader]
                                                 , tihFuncs :: [TopLevelFunction]
                                                 }



isNewFunc :: Function -> Bool
isNewFunc (Constructor _ _) = True
isNewFunc _ = False

isDeleteFunc :: Function -> Bool
isDeleteFunc (Destructor _) = True
isDeleteFunc _ = False

isVirtualFunc :: Function -> Bool
isVirtualFunc (Destructor _)           = True
isVirtualFunc (Virtual _ _ _ _)        = True
-- isVirtualFunc (AliasVirtual _ _ _ _) = True
isVirtualFunc _ = False

isStaticFunc :: Function -> Bool
isStaticFunc (Static _ _ _ _) = True
isStaticFunc _ = False

virtualFuncs :: [Function] -> [Function]
virtualFuncs = filter isVirtualFunc

constructorFuncs :: [Function] -> [Function]
constructorFuncs = filter isNewFunc

nonVirtualNotNewFuncs :: [Function] -> [Function]
nonVirtualNotNewFuncs =
  filter (\x -> (not.isVirtualFunc) x && (not.isNewFunc) x && (not.isDeleteFunc) x && (not.isStaticFunc) x )

staticFuncs :: [Function] -> [Function]
staticFuncs = filter isStaticFunc


--------

newtype ProtectedMethod = Protected { unProtected :: [String] }
    deriving (Monoid)

data Cabal = Cabal { cabal_pkgname :: String
                   , cabal_cheaderprefix :: String
                   , cabal_moduleprefix :: String }


data Class = Class { class_cabal :: Cabal
                   , class_name :: String
                   , class_parents :: [Class]
                   , class_protected :: ProtectedMethod
                   , class_alias :: Maybe String
                   , class_funcs :: [Function]
                   }
           | AbstractClass { class_cabal :: Cabal
                           , class_name :: String
                           , class_parents :: [Class]
                           , class_protected :: ProtectedMethod
                           , class_alias :: Maybe String
                           , class_funcs :: [Function]
                           }


newtype Namespace = NS { unNamespace :: String } deriving (Show)

data ClassImportHeader = ClassImportHeader
                       { cihClass :: Class
                       , cihSelfHeader :: String
                       , cihNamespace :: [Namespace]
                       , cihSelfCpp :: String
                       , cihIncludedHPkgHeadersInH :: [String]
                       , cihIncludedHPkgHeadersInCPP :: [String]
                       , cihIncludedCPkgHeaders :: [String]
                       } deriving (Show)

data ClassModule = ClassModule
                   { cmModule :: String
                   , cmClass :: [Class]
                   , cmCIH :: [ClassImportHeader]
                   , cmImportedModulesHighNonSource :: [String]
                   , cmImportedModulesRaw :: [String]
                   , cmImportedModulesHighSource :: [String]
                   , cmImportedModulesForFFI :: [String]
                   } deriving (Show)

data ClassGlobal = ClassGlobal
                   { cgDaughterSelfMap :: DaughterMap
                   , cgDaughterMap :: DaughterMap
                   }

-- | Check abstract class

isAbstractClass :: Class -> Bool
isAbstractClass (Class _ _ _ _ _ _) = False
isAbstractClass (AbstractClass _ _ _ _ _ _) = True

instance Show Class where
  show x = show (class_name x)

instance Eq Class where
  (==) x y = class_name x == class_name y

instance Ord Class where
  compare x y = compare (class_name x) (class_name y)

type DaughterMap = M.Map String [Class]

class_allparents :: Class -> [Class]
class_allparents c = let ps = class_parents c
                     in  if null ps
                           then []
                           else nub (ps ++ (concatMap class_allparents ps))


getClassModuleBase :: Class -> String
getClassModuleBase = (<.>) <$> (cabal_moduleprefix.class_cabal) <*> (fst.hsClassName)



-- | Daughter map not including itself
mkDaughterMap :: [Class] -> DaughterMap
mkDaughterMap = foldl mkDaughterMapWorker M.empty
  where mkDaughterMapWorker m c = let ps = map getClassModuleBase (class_allparents c)
                                  in  foldl (addmeToYourDaughterList c) m ps
        addmeToYourDaughterList c m p = let f Nothing = Just [c]
                                            f (Just cs)  = Just (c:cs)
                                        in  M.alter f p m



-- | Daughter Map including itself as a daughter
mkDaughterSelfMap :: [Class] -> DaughterMap
mkDaughterSelfMap = foldl worker M.empty
  where worker m c = let ps = map getClassModuleBase (c:class_allparents c)
                     in  foldl (addToList c) m ps
        addToList c m p = let f Nothing = Just [c]
                              f (Just cs)  = Just (c:cs)
                          in  M.alter f p m

-- | this function will be deprecated
ctypeToHsType :: Class -> CPPType -> String
ctypeToHsType _c Void = "()"
ctypeToHsType c SelfType = (fst.hsClassName) c
ctypeToHsType _c (CT CTString _) = "String"
ctypeToHsType _c (CT CTInt _) = "Int"
ctypeToHsType _c (CT CTUInt _) = "Word"
ctypeToHsType _c (CT CTChar _) = "Word8"
ctypeToHsType _c (CT CTLong _) = "CLong"
ctypeToHsType _c (CT CTULong _) = "CULong"
ctypeToHsType _c (CT CTDouble _) = "Double"
ctypeToHsType _c (CT CTBool _ ) = "Int"
ctypeToHsType _c (CT CTDoubleStar _) = "[Double]"
ctypeToHsType _c (CT CTVoidStar _) = "(Ptr ())"
ctypeToHsType _c (CT CTIntStar _) = "[Int]"
ctypeToHsType _c (CT CTCharStarStar _) = "[String]"
ctypeToHsType _c (CT (CPointer t) _) = hsCTypeName (CPointer t)
ctypeToHsType _c (CPT (CPTClass c') _) = class_name c'
ctypeToHsType _c (CPT (CPTClassRef c') _) = class_name c'

-- |
ctypToHsTyp :: Maybe Class -> CPPType -> String
ctypToHsTyp _c Void = "()"
ctypToHsTyp (Just c) SelfType = (fst.hsClassName) c
ctypToHsTyp Nothing SelfType = error "ctypToHsTyp : SelfType but no class "
ctypToHsTyp _c (CT CTString _) = "String"
ctypToHsTyp _c (CT CTInt _) = "Int"
ctypToHsTyp _c (CT CTUInt _) = "Word"
ctypToHsTyp _c (CT CTChar _) = "Word8"
ctypToHsTyp _c (CT CTLong _) = "CLong"
ctypToHsTyp _c (CT CTULong _) = "CULong"
ctypToHsTyp _c (CT CTDouble _) = "Double"
ctypToHsTyp _c (CT CTBool _ ) = "Int"
ctypToHsTyp _c (CT CTDoubleStar _) = "[Double]"
ctypToHsTyp _c (CT CTVoidStar _) = "(Ptr ())"
ctypToHsTyp _c (CT CTIntStar _) = "[Int]"
ctypToHsTyp _c (CT CTCharStarStar _) = "[String]"
ctypToHsTyp _c (CT (CPointer t) _) = hsCTypeName (CPointer t)
ctypToHsTyp _c (CPT (CPTClass c') _) = class_name c'
ctypToHsTyp _c (CPT (CPTClassRef c') _) = class_name c'


typeclassName :: Class -> String
typeclassName c = 'I' : fst (hsClassName c)

typeclassNameFromStr :: String -> String
typeclassNameFromStr = ('I':)

hsClassName :: Class -> (String, String)  -- ^ High-level, 'Raw'-level
hsClassName c =
  let cname = maybe (class_name c) id (class_alias c)
  in (cname, "Raw" ++ cname)

existConstructorName :: Class -> String
existConstructorName c = 'E' : (fst.hsClassName) c

-- | this is for FFI type.
hsFuncTyp :: Class -> Function -> String
hsFuncTyp c f = let args = genericFuncArgs f
                    ret  = genericFuncRet f
                in  selfstr ++ " -> " ++ concatMap ((++ " -> ") . hsargtype . fst) args ++ hsrettype ret

  where (_hcname,rcname) = hsClassName c
        selfstr = "(Ptr " ++ rcname ++ ")"

        hsargtype (CT ctype _) = hsCTypeName ctype
        hsargtype (CPT x _) = hsCppTypeName x
        hsargtype SelfType = selfstr
        hsargtype _ = error "undefined hsargtype"

        hsrettype Void = "IO ()"
        hsrettype SelfType = "IO " ++ selfstr
        hsrettype (CT ctype _) = "IO " ++ hsCTypeName ctype
        hsrettype (CPT x _ ) = "IO " ++ hsCppTypeName x

-- | this is for FFI
hsFuncTypNoSelf :: Class -> Function -> String
hsFuncTypNoSelf c f = let args = genericFuncArgs f
                          ret  = genericFuncRet f
                      in  intercalateWith connArrow id $ map (hsargtype . fst) args ++ [hsrettype ret]

  where (_hcname,rcname) = hsClassName c
        selfstr = "(Ptr " ++ rcname ++ ")"

        hsargtype (CT ctype _) = hsCTypeName ctype
        hsargtype (CPT x _) = hsCppTypeName x
        hsargtype SelfType = selfstr
        hsargtype _ = error "undefined hsargtype"

        hsrettype Void = "IO ()"
        hsrettype SelfType = "IO " ++ selfstr
        hsrettype (CT ctype _) = "IO " ++ hsCTypeName ctype
        hsrettype (CPT x _ ) = "IO " ++ hsCppTypeName x


hscFuncName :: Class -> Function -> String
hscFuncName c f = "c_" ++ toLowers (class_name c) ++ "_" ++ toLowers (aliasedFuncName c f)

hsFuncName :: Class -> Function -> String
hsFuncName c f = let (x:xs) = aliasedFuncName c f
                 in (toLower x) : xs

hsFuncXformer :: Function -> String
hsFuncXformer func@(Constructor _ _) = let len = length (genericFuncArgs func)
                                       in if len > 0
                                          then "xform" ++ show (len - 1)
                                          else "xformnull"
hsFuncXformer func@(Static _ _ _ _) =
  let len = length (genericFuncArgs func)
  in if len > 0
     then "xform" ++ show (len - 1)
     else "xformnull"
hsFuncXformer func = let len = length (genericFuncArgs func)
                     in "xform" ++ show len


genericFuncRet :: Function -> CPPType
genericFuncRet f =
  case f of
    Constructor _ _ -> self_
    Virtual t _ _ _ -> t
    NonVirtual t _ _ _-> t
    Static t _ _ _ -> t
    -- AliasVirtual t _ _ _ -> t
    Destructor _ -> void_

genericFuncArgs :: Function -> Args
genericFuncArgs (Destructor _) = []
genericFuncArgs f = func_args f

aliasedFuncName :: Class -> Function -> String
aliasedFuncName c f =
  case f of
    Constructor _ a -> maybe (constructorName c) id a
    Virtual _ str _ a -> maybe str id a
    NonVirtual _ str _ a-> maybe (nonvirtualName c str) id a
    Static _ str _ a -> maybe (nonvirtualName c str) id a
    -- AliasVirtual _ _  _ alias -> alias
    Destructor a -> maybe destructorName id a

cppStaticName :: Class -> Function -> String
cppStaticName c f = class_name c ++ "::" ++ func_name f

cppFuncName :: Class -> Function -> String
cppFuncName c f =   case f of
    Constructor _ _ -> "new"
    Virtual _ _  _ _ -> func_name f
    NonVirtual _ _ _ _-> func_name f
    Static _ _ _ _-> cppStaticName c f
    -- AliasVirtual _ _  _ _ _ -> func_name f
    Destructor _ -> destructorName

constructorName :: Class -> String
constructorName c = "new" ++ (fst.hsClassName) c

nonvirtualName :: Class -> String -> String
nonvirtualName c str = (firstLower.fst.hsClassName) c ++ str

destructorName :: String
destructorName = "delete"

-}


