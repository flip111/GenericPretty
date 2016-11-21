{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

{-|
  GenericPretty is a Haskell library that supports automatic
  derivation of pretty printing functions on user defined data
  types.

        The output provided is a pretty printed version of that provided by
  'Prelude.show'.  That is, rendering the document provided by this pretty
  printer yields an output identical to that of 'Prelude.show', except
  for extra whitespace.

        For examples of usage please see the README file included in the package.

  For more information see the HackageDB project page: <http://hackage.haskell.org/package/GenericPretty>
-}
module Text.PrettyPrint.GenericPretty
  ( Pretty(..)
  , pp
  , ppLen
  , ppStyle
  , displayPretty
  , displayPrettyL
  ) where

import           Data.Char
import           Data.List                    (last)
import qualified Data.Monoid                  as Monoid
import           Data.String.Conversions      (cs)
import qualified Data.Text                    as T
import           Data.Text.Lazy               (Text)
import qualified Data.Text.Lazy               as LT
import qualified Data.Text.Lazy.IO            as LT
import           GHC.Generics
import           Protolude                    hiding (Text, Type,
                                               empty, (<>))
import           Text.PrettyPrint.Leijen.Text hiding (Pretty)
import           Data.IxSet.Typed             (Indexable)
import qualified Data.Map
import           Data.Time
import qualified Data.HashMap.Strict
import qualified Data.IntMap
import qualified Data.IxSet.Typed

-- | The class 'Pretty' is the equivalent of 'Prelude.Show'
--
-- It provides conversion of values to pretty printable Pretty.Doc's.
--
-- Minimal complete definition: 'docPrec' or 'doc'.
--
-- Derived instances of 'Pretty' have the following properties
--
-- * The result of 'docPrec' is a syntactically correct Haskell
--   expression containing only constants, given the fixity
--   declarations in force at the point where the type is declared.
--   It contains only the constructor names defined in the data type,
--   parentheses, and spaces.  When labelled constructor fields are
--   used, braces, commas, field names, and equal signs are also used.
--
-- * If the constructor is defined to be an infix operator, then
--   'docPrec' will produce infix applications of the constructor.
--
-- * the representation will be enclosed in parentheses if the
--   precedence of the top-level constructor in @x@ is less than @d@
--   (associativity is ignored).  Thus, if @d@ is @0@ then the result
--   is never surrounded in parentheses; if @d@ is @11@ it is always
--   surrounded in parentheses, unless it is an atomic expression.
--
-- * If the constructor is defined using record syntax, then 'docPrec'
--   will produce the record-syntax form, with the fields given in the
--   same order as the original declaration.
--
-- For example, given the declarations
--
--
-- > data Tree a =  Leaf a  |  Node (Tree a) (Tree a) deriving (Generic)
--
-- The derived instance of 'Pretty' is equivalent to:
--
-- > instance (Pretty a) => Pretty (Tree a) where
-- >
-- >         docPrec d (Leaf m) = Pretty.sep $ wrapParens (d > appPrec) $
-- >              text "Leaf" : [nest (constrLen + parenLen) (docPrec (appPrec+1) m)]
-- >           where appPrec = 10
-- >                 constrLen = 5;
-- >                 parenLen = if(d > appPrec) then 1 else 0
-- >
-- >         docPrec d (Node u v) = Pretty.sep $ wrapParens (d > appPrec) $
-- >              text "Node" :
-- >              nest (constrLen + parenLen) (docPrec (appPrec+1) u) :
-- >              [nest (constrLen + parenLen) (docPrec (appPrec+1) v)]
-- >           where appPrec = 10
-- >                 constrLen = 5
-- >                 parenLen = if(d > appPrec) then 1 else 0
class Pretty a
      -- | 'docPrec' is the equivalent of 'Prelude.showsPrec'.
      --
      -- Convert a value to a pretty printable 'Pretty.Doc'.
                                                             where
  docPrec
    :: Int -- ^ the operator precedence of the enclosing
       -- context (a number from @0@ to @11@).
       -- Function application has precedence @10@.
    -> a -- ^ the value to be converted to a 'String'
    -> Doc -- ^ the resulting Doc
  default docPrec :: (Generic a, GPretty (Rep a)) =>
    Int -> a -> Doc
  docPrec n x = sep $ gpretty (from x) Pref n False
  -- | 'doc' is the equivalent of 'Prelude.show'
  --
  -- This is a specialised variant of 'docPrec', using precedence context zero.
  doc :: a -> Doc
  default doc :: (Generic a, GPretty (Rep a)) =>
    a -> Doc
  doc x = sep $ gpretty (from x) Pref 0 False
  -- | 'docList' is the equivalent of 'Prelude.showList'.
  --
  -- The method 'docList' is provided to allow the programmer to
  -- give a specialised way of showing lists of values.
  -- For example, this is used by the predefined 'Pretty' instance of
  -- the 'Char' type, where values of type 'String' should be shown
  -- in double quotes, rather than between square brackets.
  docList :: [a] -> Doc
  docList = docListWith doc

-- used to define docList, creates output identical to that of show for general list types
docListWith :: (a -> Doc) -> [a] -> Doc
docListWith f = brackets . fillCat . punctuate comma . map f

-- returns a list without it's first and last elements
-- except if the list has a single element, in which case it returns the list unchanged
middle :: [a] -> [a]
middle []     = []
middle [x]    = [x]
middle (_:xs) = initDef [] xs

-- |Utility function used to wrap the passed value in parens if the bool is true.
wrapParens :: Bool -> [Doc] -> [Doc]
wrapParens _ [] = []
wrapParens False s = s
wrapParens True s
  | length s == 1 = [lparen <> (fromMaybe empty . head) s <> rparen]
  | otherwise =
    [lparen <> (fromMaybe empty . head) s] ++ middle s ++ [last s <> rparen]

-- show the whole document in one line
showDocOneLine :: Doc -> Text
showDocOneLine = displayT . renderOneLine

-- The types of data we need to consider for product operator. Record, Prefix and Infix.
-- Tuples aren't considered since they're already instances of 'Pretty' and thus won't pass through that code.
data Type
  = Rec
  | Pref
  | Inf Text

--'GPretty' is a helper class used to output the Sum-of-Products type, since it has kind *->*,
-- so can't be an instance of 'Pretty'
class GPretty f
      -- |'gpretty' is the (*->*) kind equivalent of 'docPrec'
                                                            where
  gpretty
    :: f x -- The sum of products representation of the user's custom type
    -> Type -- The type of multiplication. Record, Prefix or Infix.
    -> Int -- The operator precedence, determines wether to wrap stuff in parens.
    -> Bool -- A flag, marks wether the constructor directly above was wrapped in parens.
       -- Used to determine correct indentation
    -> [Doc] -- The result. Each Doc could be on a newline, depending on available space.
  -- |'isNullary' marks nullary constructors, so that we don't put parens around them
  isNullary :: f x -> Bool

-- if empty, output nothing, this is a null constructor
instance GPretty U1 where
  gpretty _ _ _ _ = [empty]
  isNullary _ = True

-- ignore datatype meta-information
instance (GPretty f) =>
         GPretty (M1 D c f) where
  gpretty (M1 a) = gpretty a
  isNullary (M1 a) = isNullary a

-- if there is a selector, display it and it's value + appropriate white space
instance (GPretty f, Selector c) =>
         GPretty (M1 S c f) where
  gpretty s@(M1 a) t d p
    | LT.null selector = gpretty a t d p
    | otherwise =
      (string selector <+> char '=') :
      map (nest $ (fromIntegral . LT.length) selector + 3) (gpretty a t 0 p)
    where
      selector = (cs . selName) s
  isNullary (M1 a) = isNullary a

-- constructor
-- here the real type and parens flag is set and propagated forward via t and n, the precedence factor is updated
instance (GPretty f, Constructor c) =>
         GPretty (M1 C c f) where
  gpretty c@(M1 a) _ d _ =
    case fixity
         -- if prefix add the constructor name, nest the result and possibly put it in parens
          of
      Prefix ->
        wrapParens boolParens $
        text name : makeMargins t boolParens (gpretty a t 11 boolParens)
      -- if infix possibly put in parens
      Infix _ m -> wrapParens (d > m) $ gpretty a t (m + 1) (d > m)
    where
      boolParens = d > 10 && (not $ isNullary a)
      name = checkInfix . cs $ conName c
      fixity = conFixity c
      -- get the type of the data, Record, Infix or Prefix.
      t =
        if conIsRecord c
          then Rec
          else case fixity of
                 Prefix    -> Pref
                 Infix _ _ -> (Inf . cs . conName) c
      --add whitespace and possible braces for records
      makeMargins :: Type -> Bool -> [Doc] -> [Doc]
      makeMargins _ _ [] = []
      makeMargins Rec _ s
        | length s == 1 =
          [ nest
              ((fromIntegral . LT.length) name + 1)
              (lbrace <> (fromMaybe empty . head) s <> rbrace)
          ]
        | otherwise =
          nest
            ((fromIntegral . LT.length) name + 1)
            (lbrace <> (fromMaybe empty (head s))) :
          map
            (nest $ (fromIntegral . LT.length) name + 2)
            (middle s ++ [last s <> rbrace])
      makeMargins _ b s =
        map
          (nest $
           ((fromIntegral . LT.length) name) +
           if b
             then 2
             else 1)
          s
      -- check for infix operators that are acting like prefix ones due to records, put them in parens
      checkInfix :: Text -> Text
      checkInfix xs
        | xs == LT.empty = LT.empty
        | otherwise =
          let x = LT.head xs
          in if fixity == Prefix && (isAlphaNum x || x == '_')
               then xs
               else "(" Monoid.<> xs Monoid.<> ")"
  isNullary (M1 a) = isNullary a

-- ignore tagging, call docPrec since these are concrete types
instance (Pretty f) =>
         GPretty (K1 t f) where
  gpretty (K1 a) _ d _ = [docPrec d a]
  isNullary _ = False

-- just continue to the corresponding side of the OR
instance (GPretty f, GPretty g) =>
         GPretty (f :+: g) where
  gpretty (L1 a) t d p = gpretty a t d p
  gpretty (R1 a) t d p = gpretty a t d p
  isNullary (L1 a) = isNullary a
  isNullary (R1 a) = isNullary a

-- output both sides of the product, possible separated by a comma or an infix operator
instance (GPretty f, GPretty g) =>
         GPretty (f :*: g) where
  gpretty (f :*: g) t@Rec d p = initDef [] pfn ++ [last pfn <> comma] ++ pgn
    where
      pfn = gpretty f t d p
      pgn = gpretty g t d p
  -- if infix, nest the second value since it isn't nested in the constructor
  gpretty (f :*: g) t@(Inf s) d p =
    initDef [] pfn ++ [last pfn <+> text s] ++ checkIndent pgn
    where
      pfn = gpretty f t d p
      pgn = gpretty g t d p
      -- if the second value of the :*: is in parens, nest it, otherwise just check for an extra paren space
      -- needs to get the string representation of the first elements in the left and right Doc lists
      -- to be able to determine the correct indentation
      checkIndent :: [Doc] -> [Doc]
      checkIndent [] = []
      checkIndent m@(x:_)
        | parensLength == 0 =
          if p
            then map (nest 1) m
            else m
        | otherwise = map (nest $ fromIntegral cons + 1 + parenSpace) m
        where
          parenSpace =
            if p
              then 1
              else 0
          strG = showDocOneLine x
          cons =
            maybe
              0
              (LT.length .
               LT.takeWhile (/= ' ') . LT.dropWhile (== '(') . showDocOneLine)
              (head pfn)
          parensLength = LT.length $ LT.takeWhile (== '(') strG
  gpretty (f :*: g) t@Pref n p = gpretty f t n p ++ gpretty g t n p
  isNullary _ = False

-- | 'fullPP' is a fully customizable Pretty Printer
--
-- Every other pretty printer just gives some default values to 'fullPP'
-- fullPP
--   :: (Pretty a)
--   => (TextDetails -> b -> b) -- ^Function that handles the text conversion /(eg: 'outputIO')/
--   -> b -- ^The end element of the result /( eg: "" or putChar('\n') )/
--   -> Style -- ^The pretty printing 'Text.PrettyPrint.MyPretty.Style' to use
--   -> a -- ^The value to pretty print
--   -> b -- ^The pretty printed result
-- fullPP td end s a =
--   fullRender (mode s) (lineLength s) (ribbonsPerLine s) td end doc
--   where
--     doc = docPrec 0 a
-- | Utility function that handles the text conversion for 'fullPP'.
--
-- 'outputIO' transforms the text into 'String's and outputs it directly.
-- outputIO :: TextDetails -> IO () -> IO ()
-- outputIO td act = do
--   putStr $ decode td
--   act
--   where
--     decode :: TextDetails -> String
--     decode (Str s)   = s
--     decode (PStr s1) = s1
--     decode (Chr c)   = [c]
-- | Utility function that handles the text conversion for 'fullPP'.
--
--'outputStr' just leaves the text as a 'String' which is usefull if you want
-- to further process the pretty printed result.
-- outputStr :: TextDetails -> String -> String
-- outputStr td str = decode td ++ str
--   where
--     decode :: TextDetails -> String
--     decode (Str s)   = s
--     decode (PStr s1) = s1
--     decode (Chr c)   = [c]
-- | Customizable pretty printer
--
-- Takes a user defined 'Text.PrettyPrint.MyPretty.Style' as a parameter and uses 'outputStr' to obtain the result
-- Equivalent to:
--
-- > fullPP outputStr ""
prettyStyle
  :: (Pretty a)
  => Float -> Int -> a -> Text
prettyStyle r l = displayT . renderPretty r l . doc

-- | Semi-customizable pretty printer.
--
-- Equivalent to:
--
-- > prettyStyle customStyle
--
-- Where customStyle uses the specified line length, mode = PageMode and ribbonsPerLine = 1.
prettyLen
  :: (Pretty a)
  => Int -> a -> Text
prettyLen l = displayT . renderPretty 1.0 l . doc

-- | The default pretty printer returning 'String's
--
--  Equivalent to
--
-- > prettyStyle defaultStyle
--
-- Where defaultStyle = (mode=PageMode, lineLength=80, ribbonsPerLine=1.5)
-- pretty
--   :: (Pretty a)
--   => a -> Text
-- pretty = displayT . renderPretty 1.0 80 . doc
displayPrettyL
  :: Pretty a
  => a -> Text
displayPrettyL = displayT . renderPretty 1.0 70 . doc -- pretty

displayPretty
  :: Pretty a
  => a -> T.Text
displayPretty = toStrict . displayPrettyL

-- | Customizable pretty printer.
--
-- Takes a user defined 'Text.PrettyPrint.MyPretty.Style' as a parameter and uses 'outputIO' to obtain the result
-- Equivalent to:
--
-- > fullPP outputIO (putChar '\n')
ppStyle
  :: (Pretty a)
  => Float -> Int -> a -> IO ()
ppStyle r l = LT.putStrLn . prettyStyle r l

-- | Semi-customizable pretty printer.
--
-- Equivalent to:
--
-- > ppStyle customStyle
--
-- Where customStyle uses the specified line length, mode = PageMode and ribbonsPerLine = 1.
ppLen
  :: (Pretty a)
  => Int -> a -> IO ()
ppLen l = LT.putStrLn . prettyLen l

-- | The default Pretty Printer,
--
--  Equivalent to:
--
-- > ppStyle defaultStyle
--
-- Where defaultStyle = (mode=PageMode, lineLength=80, ribbonsPerLine=1.5)
pp
  :: (Pretty a)
  => a -> IO ()
pp = putDoc . doc

-- define some instances of Pretty making sure to generate output identical to 'show' modulo the extra whitespace
instance Pretty () where
  doc _ = text "()"
  docPrec _ = doc

instance Pretty Char where
  doc a = char '\'' <> (text . LT.singleton $ a) <> char '\''
  docPrec _ = doc
  docList = text . cs

instance Pretty Int where
  docPrec n x
    | n /= 0 && x < 0 = parens $ int x
    | otherwise = int x
  doc = docPrec 0

instance Pretty Integer where
  docPrec n x
    | n /= 0 && x < 0 = parens $ integer x
    | otherwise = integer x
  doc = docPrec 0

instance Pretty Float where
  docPrec n x
    | n /= 0 && x < 0 = parens $ float x
    | otherwise = float x
  doc = docPrec 0

instance Pretty Double where
  docPrec n x
    | n /= 0 && x < 0 = parens $ double x
    | otherwise = double x
  doc = docPrec 0

instance Pretty Rational where
  docPrec n x
    | n /= 0 && x < 0 = parens $ rational x
    | otherwise = rational x
  doc = docPrec 0

instance Pretty a =>
         Pretty [a] where
  doc = docList
  docPrec _ = doc

instance Pretty Bool where
  doc True  = text "True"
  doc False = text "False"
  docPrec _ = doc

instance Pretty a =>
         Pretty (Maybe a) where
  docPrec _ Nothing = text "Nothing"
  docPrec n (Just x)
    | n /= 0 = parens result
    | otherwise = result
    where
      result = text "Just" <+> docPrec 10 x
  doc = docPrec 0

instance (Pretty a, Pretty b) =>
         Pretty (Either a b) where
  docPrec n (Left x)
    | n /= 0 = parens result
    | otherwise = result
    where
      result = string "Left" <+> docPrec 10 x
  docPrec n (Right y)
    | n /= 0 = parens result
    | otherwise = result
    where
      result = string "Right" <+> docPrec 10 y
  doc = docPrec 0

instance (Pretty a, Pretty b) =>
         Pretty (a, b) where
  doc (a, b) = parens (sep [doc a <> comma, doc b])
  docPrec _ = doc

instance (Pretty a, Pretty b, Pretty c) =>
         Pretty (a, b, c) where
  doc (a, b, c) = parens (sep [doc a <> comma, doc b <> comma, doc c])
  docPrec _ = doc

instance (Pretty a, Pretty b, Pretty c, Pretty d) =>
         Pretty (a, b, c, d) where
  doc (a, b, c, d) =
    parens (sep [doc a <> comma, doc b <> comma, doc c <> comma, doc d])
  docPrec _ = doc

instance (Pretty a, Pretty b, Pretty c, Pretty d, Pretty e) =>
         Pretty (a, b, c, d, e) where
  doc (a, b, c, d, e) =
    parens
      (sep
         [doc a <> comma, doc b <> comma, doc c <> comma, doc d <> comma, doc e])
  docPrec _ = doc

instance (Pretty a, Pretty b, Pretty c, Pretty d, Pretty e, Pretty f) =>
         Pretty (a, b, c, d, e, f) where
  doc (a, b, c, d, e, f) =
    parens
      (sep
         [ doc a <> comma
         , doc b <> comma
         , doc c <> comma
         , doc d <> comma
         , doc e <> comma
         , doc f
         ])
  docPrec _ = doc

instance (Pretty a, Pretty b, Pretty c, Pretty d, Pretty e, Pretty f, Pretty g) =>
         Pretty (a, b, c, d, e, f, g) where
  doc (a, b, c, d, e, f, g) =
    parens
      (sep
         [ doc a <> comma
         , doc b <> comma
         , doc c <> comma
         , doc d <> comma
         , doc e <> comma
         , doc f <> comma
         , doc g
         ])
  docPrec _ = doc

instance Pretty LT.Text where
  doc = string
  docPrec _ = doc
  docList = doc

instance (Pretty a, Pretty b) =>
         Pretty (Data.Map.Map a b) where
  doc v = text "fromList " <+> doc v
  docPrec _ = doc

instance (Pretty a) =>
         Pretty (Data.IntMap.IntMap a) where
  doc v = text "fromList " <+> doc v
  docPrec _ = doc

instance (Pretty a, Pretty b) =>
         Pretty (Data.HashMap.Strict.HashMap a b) where
  doc v = text "fromList " <+> doc v
  docPrec _ = doc

instance Pretty UTCTime where
  doc = text . cs . formatTime defaultTimeLocale rfc822DateFormat
  docPrec _ = doc

instance (Show a, Indexable ixs a) =>
         Pretty (Data.IxSet.Typed.IxSet ixs a) where
  doc = text . show
  docPrec _ = doc

instance Pretty Word where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Word8 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Word16 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Word32 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Word64 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Int8 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Int16 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Int32 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc

instance Pretty Int64 where
  doc = (doc :: Integer -> Doc) . fromIntegral
  docPrec _ = doc
