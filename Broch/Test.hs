{-# LANGUAGE OverloadedStrings #-}

module Broch.Test where

import           Control.Applicative
import           Control.Monad.IO.Class
import qualified Crypto.BCrypt as BCrypt
import qualified Data.ByteString.Base64 as B64
import qualified Data.Default.Generics as DD
import           Data.Time.Clock
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.UUID (toString)
import           Data.UUID.V4
import           Database.Persist.Sql (ConnectionPool, runMigrationSilent, runSqlPersistMPool)
import           Web.Routing.TextRouting

import           Broch.Model
import           Broch.Persist (persistBackend)
import qualified Broch.Persist.Internal as BP
import           Broch.Random (randomBytes)
import           Broch.Scim
import           Broch.Server (brochServer, defaultLoginPage,  defaultApprovalPage, authenticatedSubject, passwordLoginHandler)
import           Broch.Server.Internal
import           Broch.Server.Config

testClients :: [Client]
testClients =
    [ DD.def { clientId = "admin", clientSecret = Just "adminsecret", authorizedGrantTypes = [ClientCredentials, AuthorizationCode], redirectURIs = ["http://admin"], tokenEndpointAuthMethod = ClientSecretBasic }
    , DD.def { clientId = "cf", authorizedGrantTypes = [ResourceOwner], redirectURIs = ["http://cf.client"], tokenEndpointAuthMethod = ClientAuthNone }
    , DD.def { clientId = "app", clientSecret = Just "appsecret", authorizedGrantTypes = [AuthorizationCode, Implicit, RefreshToken], redirectURIs = ["http://localhost:8080/app"], tokenEndpointAuthMethod = ClientSecretBasic, allowedScope = [OpenID, CustomScope "scope1", CustomScope "scope2"] }
    ]

testUsers :: [ScimUser]
testUsers =
    [ DD.def
        { scimUserName = "cat"
        , scimPassword = Just "cat"
        , scimName     = Just $ DD.def {nameFormatted = Just "Tom Cat", nameFamilyName = Just "Cat", nameGivenName = Just "Tom"}
        , scimEmails = Just [DD.def {emailValue = "cat@example.com"}]
        }
    , DD.def { scimUserName = "dog", scimPassword = Just "dog" }
    ]

testBroch :: Text -> ConnectionPool -> IO (RoutingTree (Handler ()))
testBroch issuer pool = do
    _ <- runSqlPersistMPool (runMigrationSilent BP.migrateAll) pool
    mapM_ (\c -> runSqlPersistMPool (BP.createClient c) pool) testClients
    mapM_ createUser testUsers
    kr <- defaultKeyRing
    rotateKeys kr True
    config <- persistBackend pool <$> inMemoryConfig issuer kr
    let extraRoutes =
            [ ("/home",   text "Hello, I'm the home page")
            , ("/login",  passwordLoginHandler defaultLoginPage (authenticateResourceOwner config))
            , ("/logout", invalidateSession >> complete)
            ]
        routingTable = foldl (\tree (r, h) -> addToRoutingTree r h tree) (brochServer config defaultApprovalPage authenticatedSubject) extraRoutes
    return routingTable
  where
    createUser scimData = do
        now <- Just <$> liftIO getCurrentTime
        uid <- (T.pack . toString) <$> liftIO nextRandom
        password <- hashPassword =<< maybe randomPassword return (scimPassword scimData)
        let meta = Meta now now Nothing Nothing
        flip runSqlPersistMPool pool $ BP.createUser uid password scimData { scimId = Just uid, scimMeta = Just meta }

    randomPassword = (TE.decodeUtf8 . B64.encode) <$> randomBytes 12

    hashPassword p = do
        hash <- liftIO $ BCrypt.hashPasswordUsingPolicy BCrypt.fastBcryptHashingPolicy (TE.encodeUtf8 p)
        maybe (error "Hash failed") (return . TE.decodeUtf8) hash
