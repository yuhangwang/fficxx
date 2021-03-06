{-# LANGUAGE ScopedTypeVariables #-}

import           FFICXX.Generate.Builder
import           FFICXX.Generate.Type.Class
import           FFICXX.Generate.Type.Module
import           FFICXX.Generate.Type.PackageInterface


mycabal = Cabal { cabal_pkgname = "MySample"
                , cabal_cheaderprefix = "MySample"
                , cabal_moduleprefix = "MySample"
                }

mycabalattr = 
    CabalAttr 
    { cabalattr_license = Just "BSD3"
    , cabalattr_licensefile = Just "LICENSE"
    , cabalattr_extraincludedirs = []
    , cabalattr_extralibdirs = []
    , cabalattr_extrafiles = []
    }


myclass = Class mycabal

a :: Class
a = myclass "A" [] mempty Nothing
    [ Constructor [] Nothing
    , Virtual void_ "method1" [ ] Nothing
    ]

b :: Class
b = myclass "B" [a] mempty Nothing
    [ Constructor [] Nothing
    , Virtual (cppclass_ a) "method2" [ cppclass a "x" ] Nothing
    ]

myclasses = [ a, b]

toplevelfunctions = [ ]


main :: IO ()
main = do 
  simpleBuilder "MySample" [] (mycabal,mycabalattr,myclasses,toplevelfunctions,[]) [ ] []

