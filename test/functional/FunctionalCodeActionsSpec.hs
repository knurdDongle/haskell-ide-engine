{-# LANGUAGE OverloadedStrings #-}

module FunctionalCodeActionsSpec where

import           Control.Applicative.Combinators
import           Control.Lens hiding (List)
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Default
import qualified Data.HashMap.Strict as HM
import           Data.Maybe
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Language.Haskell.LSP.Test as Test
import qualified Language.Haskell.LSP.Types as LSP
import           Language.Haskell.LSP.Types as LSP hiding (contents, error, message)
import qualified Language.Haskell.LSP.Types.Capabilities as C
import           Test.Hspec
import           TestUtils
import           Utils

spec :: Spec
spec = describe "code actions" $ do
  describe "hlint suggestions" $ do
    it "provides 3.8 code actions" $ runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata" $ do
      doc <- openDoc "ApplyRefact2.hs" "haskell"

      diags@(reduceDiag:_) <- waitForDiagnostics

      liftIO $ do
        length diags `shouldBe` 2
        reduceDiag ^. range `shouldBe` Range (Position 1 0) (Position 1 12)
        reduceDiag ^. severity `shouldBe` Just DsInfo
        reduceDiag ^. code `shouldBe` Just "Eta reduce"
        reduceDiag ^. source `shouldBe` Just "hlint"

      (CACodeAction ca:_) <- getAllCodeActions doc

      -- Evaluate became redundant id in later hlint versions
      liftIO $ ["Apply hint:Redundant id", "Apply hint:Evaluate"] `shouldContain` [ca ^. title]

      executeCodeAction ca

      contents <- getDocumentEdit doc
      liftIO $ contents `shouldBe` "main = undefined\nfoo x = x\n"

      noDiagnostics

    it "falls back to pre 3.8 code actions" $ runSessionWithConfig noLogConfig hieCommand noLiteralCaps "test/testdata" $ do
      doc <- openDoc "ApplyRefact2.hs" "haskell"

      _ <- waitForDiagnostics

      (CACommand cmd:_) <- getAllCodeActions doc

      -- Evaluate became redundant id in later hlint versions
      liftIO $ ["Apply hint:Redundant id", "Apply hint:Evaluate"] `shouldContain` [cmd ^. title ]

      executeCommand cmd

      contents <- skipManyTill publishDiagnosticsNotification $ getDocumentEdit doc
      liftIO $ contents `shouldBe` "main = undefined\nfoo x = x\n"

      noDiagnostics

  describe "rename suggestions" $ do
    it "works" $ runSessionWithConfig noLogConfig hieCommand noLiteralCaps "test/testdata" $ do
      doc <- openDoc "CodeActionRename.hs" "haskell"

      _ <- waitForDiagnosticsSource "ghcmod"

      CACommand cmd:_ <- getAllCodeActions doc
      executeCommand cmd

      x:_ <- T.lines <$> documentContents doc
      liftIO $ x `shouldBe` "main = putStrLn \"hello\""
    it "doesn't give both documentChanges and changes" $
      runSessionWithConfig noLogConfig hieCommand noLiteralCaps "test/testdata" $ do
        doc <- openDoc "CodeActionRename.hs" "haskell"

        _ <- waitForDiagnosticsSource "ghcmod"
        
        CACommand cmd <- (!! 2) <$> getAllCodeActions doc
        let Just (List [Object args]) = cmd ^. arguments
            Object editParams = args HM.! "fallbackWorkspaceEdit"
        liftIO $ do
          editParams `shouldSatisfy` HM.member "changes"
          editParams `shouldNotSatisfy` HM.member "documentChanges"

        executeCommand cmd

        _:x:_ <- T.lines <$> documentContents doc
        liftIO $ x `shouldBe` "foo = putStrLn \"world\""

  it "provides import suggestions and 3.8 code action kinds" $
    runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata" $ do
      doc <- openDoc "CodeActionImport.hs" "haskell"

      -- ignore the first empty hlint diagnostic publish
      [_,diag:_] <- count 2 waitForDiagnostics
      liftIO $ diag ^. LSP.message `shouldBe` "Variable not in scope: when :: Bool -> IO () -> IO ()"

      actionsOrCommands <- getAllCodeActions doc
      let actns = map fromAction actionsOrCommands

      liftIO $ do
        head actns ^. title `shouldBe` "Import module Control.Monad"
        forM_ actns $ \a -> do
          a ^. kind `shouldBe` Just CodeActionQuickFix
          a ^. command `shouldSatisfy` isJust
          a ^. edit `shouldBe` Nothing
          let hasOneDiag (Just (List [_])) = True
              hasOneDiag _ = False
          a ^. diagnostics `shouldSatisfy` hasOneDiag
        length actns `shouldBe` 5

      executeCodeAction (head actns)

      contents <- getDocumentEdit doc
      liftIO $ contents `shouldBe` "import Control.Monad\nmain :: IO ()\nmain = when True $ putStrLn \"hello\""


  describe "add package suggestions" $ do
    it "adds to .cabal files" $ runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata/addPackageTest/cabal" $ do
      doc <- openDoc "AddPackage.hs" "haskell"

      -- ignore the first empty hlint diagnostic publish
      [_,diag:_] <- count 2 waitForDiagnostics

      liftIO $ diag ^. LSP.message `shouldSatisfy` T.isPrefixOf "Could not find module ‘Data.Text’"

      (CACodeAction action:_) <- getAllCodeActions doc

      liftIO $ do
        action ^. title `shouldBe` "Add text as a dependency"
        action ^. kind `shouldBe` Just CodeActionQuickFix
        action ^. command . _Just . command `shouldSatisfy` T.isSuffixOf "package:add"

      executeCodeAction action

      contents <- getDocumentEdit . TextDocumentIdentifier =<< getDocUri "add-package-test.cabal"
      liftIO $ T.lines contents `shouldSatisfy` \x -> any (\l -> "text -any" `T.isSuffixOf` (x !! l)) [15, 16]

    it "adds to hpack package.yaml files" $
      runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata/addPackageTest/hpack" $ do
        doc <- openDoc "app/Asdf.hs" "haskell"

        -- ignore the first empty hlint diagnostic publish
        [_,diag:_] <- count 2 waitForDiagnostics

        liftIO $ diag ^. LSP.message `shouldSatisfy` T.isPrefixOf "Could not find module ‘Codec.Compression.GZip’"

        mActions <- getAllCodeActions doc
        let allActions = map fromAction mActions
            action = head allActions

        liftIO $ do
          action ^. title `shouldBe` "Add zlib as a dependency"
          forM_ allActions $ \a -> a ^. kind `shouldBe` Just CodeActionQuickFix
          forM_ allActions $ \a -> a ^. command . _Just . command `shouldSatisfy` T.isSuffixOf "package:add"

        executeCodeAction action

        contents <- getDocumentEdit . TextDocumentIdentifier =<< getDocUri "package.yaml"
        liftIO $ do
          T.lines contents !! 33 `shouldSatisfy` T.isSuffixOf "zlib"
          T.lines contents !! 12 `shouldNotSatisfy` T.isSuffixOf "zlib"
          T.lines contents !! 13 `shouldNotSatisfy` T.isSuffixOf "zlib"

  describe "redundant import code actions" $ do
    it "remove solitary redundant imports" $
      runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata/redundantImportTest/" $ do
        doc <- openDoc "src/CodeActionRedundant.hs" "haskell"

        -- ignore the first empty hlint diagnostic publish
        [_,diag:_] <- count 2 waitForDiagnostics

        liftIO $ diag ^. LSP.message `shouldSatisfy` T.isPrefixOf "The import of ‘Data.List’ is redundant"

        mActions <- getAllCodeActions doc

        let allActions@[removeAction, changeAction] = map fromAction mActions

        liftIO $ do
          removeAction ^. title `shouldBe` "Remove redundant import"
          changeAction ^. title `shouldBe` "Import instances"
          forM_ allActions $ \a -> a ^. kind `shouldBe` Just CodeActionQuickFix
          forM_ allActions $ \a -> a ^. command `shouldBe` Nothing
          forM_ allActions $ \a -> a ^. edit `shouldSatisfy` isJust

        executeCodeAction removeAction

        -- No command/applyworkspaceedit should be here, since action
        -- provides workspace edit property which skips round trip to
        -- the server
        contents <- documentContents doc
        liftIO $ contents `shouldBe` "main :: IO ()\nmain = putStrLn \"hello\""
    it "doesn't touch other imports" $ runSessionWithConfig noLogConfig hieCommand noLiteralCaps "test/testdata/redundantImportTest/" $ do
      doc <- openDoc "src/MultipleImports.hs" "haskell"

      _ <- count 2 waitForDiagnostics

      [CACommand cmd, _] <- getAllCodeActions doc

      executeCommand cmd

      contents <- documentContents doc

      liftIO $ contents `shouldBe`
        "module MultipleImports where\n\
        \import Data.Maybe\n\
        \foo :: Int\n\
        \foo = fromJust (Just 3)\n"

  describe "typed hole code actions" $ do
      it "works" $
        runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata" $ do
          doc <- openDoc "TypedHoles.hs" "haskell"
          _ <- waitForDiagnosticsSource "ghcmod"
          cas <- map (\(CACodeAction x)-> x) <$> getAllCodeActions doc

          suggestion <-
            if ghc84 then do
              liftIO $ map (^. title) cas `shouldMatchList`
                [ "Substitute hole (Int) with maxBound (forall a. Bounded a => a)"
                , "Substitute hole (Int) with minBound (forall a. Bounded a => a)"
                , "Substitute hole (Int) with undefined (forall (a :: TYPE r). GHC.Stack.Types.HasCallStack => a)"
                ]
              return "maxBound"
            else do
              liftIO $ map (^. title) cas `shouldMatchList`
                [ "Substitute hole (Int) with x ([Int])"
                , "Substitute hole (Int) with foo ([Int] -> Int)"
                ]
              return "x"

          executeCodeAction $ head cas

          contents <- documentContents doc

          liftIO $ contents `shouldBe`
            "module TypedHoles where\n\
            \foo :: [Int] -> Int\n\
            \foo x = " <> suggestion

      it "shows more suggestions" $
        runSessionWithConfig noLogConfig hieCommand fullCaps "test/testdata" $ do
          doc <- openDoc "TypedHoles2.hs" "haskell"
          _ <- waitForDiagnosticsSource "ghcmod"
          cas <- map (\(CACodeAction x)-> x) <$> getAllCodeActions doc

          suggestion <-
            if ghc84 then do
              liftIO $ map (^. title) cas `shouldMatchList`
                [ "Substitute hole (A) with undefined (forall (a :: TYPE r). GHC.Stack.Types.HasCallStack => a)"
                , "Substitute hole (A) with stuff (A -> A)"
                , "Substitute hole (A) with x ([A])"
                , "Substitute hole (A) with foo2 ([A] -> A)"
                ]
              return "undefined"
          else do
              liftIO $ map (^. title) cas `shouldMatchList`
                [ "Substitute hole (A) with stuff (A -> A)"
                , "Substitute hole (A) with x ([A])"
                , "Substitute hole (A) with foo2 ([A] -> A)"
                ]
              return "stuff"

          executeCodeAction $ head cas

          contents <- documentContents doc

          liftIO $ contents `shouldBe`
            "module TypedHoles2 (foo2) where\n\
            \newtype A = A Int\n\
            \foo2 :: [A] -> A\n\
            \foo2 x = " <> suggestion <> "\n\
            \  where\n\
            \    stuff (A a) = A (a + 1)\n"

fromAction :: CAResult -> CodeAction
fromAction (CACodeAction action) = action
fromAction _ = error "Not a code action"

noLiteralCaps :: C.ClientCapabilities
noLiteralCaps = def { C._textDocument = Just textDocumentCaps }
  where
    textDocumentCaps = def { C._codeAction = Just codeActionCaps }
    codeActionCaps = C.CodeActionClientCapabilities (Just True) Nothing
