{- git-annex assistant webapp configurators for Amazon AWS services
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP, QuasiQuotes, TemplateHaskell, OverloadedStrings #-}

module Assistant.WebApp.Configurators.AWS where

import Assistant.WebApp.Common
import Assistant.MakeRemote
import Assistant.Sync
#ifdef WITH_S3
import qualified Remote.S3 as S3
#endif
import qualified Remote.Glacier as Glacier
import qualified Remote.Helper.AWS as AWS
import Logs.Remote
import qualified Remote
import qualified Types.Remote as Remote
import Types.Remote (RemoteConfig)
import Types.StandardGroups
import Logs.PreferredContent
import Creds

import qualified Data.Text as T
import qualified Data.Map as M
import Data.Char

awsConfigurator :: Widget -> Handler Html
awsConfigurator = page "Add an Amazon repository" (Just Configuration)

glacierConfigurator :: Widget -> Handler Html
glacierConfigurator a = do
	ifM (liftIO $ inPath "glacier")
		( awsConfigurator a
		, awsConfigurator needglaciercli
		)
  where
	needglaciercli = $(widgetFile "configurators/needglaciercli")

data StorageClass = StandardRedundancy | ReducedRedundancy
	deriving (Eq, Enum, Bounded)

instance Show StorageClass where
	show StandardRedundancy = "STANDARD" 
	show ReducedRedundancy = "REDUCED_REDUNDANCY"

data AWSInput = AWSInput
	{ accessKeyID :: Text
	, secretAccessKey :: Text
	, datacenter :: Text
	-- Only used for S3, not Glacier.
	, storageClass :: StorageClass
	, repoName :: Text
	, enableEncryption :: EnableEncryption
	}

data AWSCreds = AWSCreds Text Text

extractCreds :: AWSInput -> AWSCreds
extractCreds i = AWSCreds (accessKeyID i) (secretAccessKey i)

s3InputAForm :: Maybe CredPair -> MkAForm AWSInput
s3InputAForm defcreds = AWSInput
	<$> accessKeyIDFieldWithHelp (T.pack . fst <$> defcreds)
	<*> secretAccessKeyField (T.pack . snd <$> defcreds)
	<*> datacenterField AWS.S3
	<*> areq (selectFieldList storageclasses) "Storage class" (Just StandardRedundancy)
	<*> areq textField "Repository name" (Just "S3")
	<*> enableEncryptionField
  where
	storageclasses :: [(Text, StorageClass)]
	storageclasses =
		[ ("Standard redundancy", StandardRedundancy)
		, ("Reduced redundancy (costs less)", ReducedRedundancy)
		]

glacierInputAForm :: Maybe CredPair -> MkAForm AWSInput
glacierInputAForm defcreds = AWSInput
	<$> accessKeyIDFieldWithHelp (T.pack . fst <$> defcreds)
	<*> secretAccessKeyField (T.pack . snd <$> defcreds)
	<*> datacenterField AWS.Glacier
	<*> pure StandardRedundancy
	<*> areq textField "Repository name" (Just "glacier")
	<*> enableEncryptionField

awsCredsAForm :: Maybe CredPair -> MkAForm AWSCreds
awsCredsAForm defcreds = AWSCreds
	<$> accessKeyIDFieldWithHelp (T.pack . fst <$> defcreds)
	<*> secretAccessKeyField (T.pack . snd <$> defcreds)

accessKeyIDField :: Widget -> Maybe Text -> MkAForm Text
accessKeyIDField help def = areq (textField `withNote` help) "Access Key ID" def

accessKeyIDFieldWithHelp :: Maybe Text -> MkAForm Text
accessKeyIDFieldWithHelp def = accessKeyIDField help def
  where
	help = [whamlet|
<a href="https://portal.aws.amazon.com/gp/aws/securityCredentials#id_block">
  Get Amazon access keys
|]

secretAccessKeyField :: Maybe Text -> MkAForm Text
secretAccessKeyField def = areq passwordField "Secret Access Key" def

datacenterField :: AWS.Service -> MkAForm Text
datacenterField service = areq (selectFieldList list) "Datacenter" defregion
  where
	list = M.toList $ AWS.regionMap service
	defregion = Just $ AWS.defaultRegion service

getAddS3R :: Handler Html
getAddS3R = postAddS3R

postAddS3R :: Handler Html
#ifdef WITH_S3
postAddS3R = awsConfigurator $ do
	defcreds <- liftAnnex previouslyUsedAWSCreds
	((result, form), enctype) <- liftH $
		runFormPost $ renderBootstrap $ s3InputAForm defcreds
	case result of
		FormSuccess input -> liftH $ do
			let name = T.unpack $ repoName input
			makeAWSRemote S3.remote (extractCreds input) name setgroup $ M.fromList
				[ configureEncryption $ enableEncryption input
				, ("type", "S3")
				, ("datacenter", T.unpack $ datacenter input)
				, ("storageclass", show $ storageClass input)
				]
		_ -> $(widgetFile "configurators/adds3")
  where
	setgroup r = liftAnnex $
		setStandardGroup (Remote.uuid r) TransferGroup
#else
postAddS3R = error "S3 not supported by this build"
#endif

getAddGlacierR :: Handler Html
getAddGlacierR = postAddGlacierR

postAddGlacierR :: Handler Html
#ifdef WITH_S3
postAddGlacierR = glacierConfigurator $ do
	defcreds <- liftAnnex previouslyUsedAWSCreds
	((result, form), enctype) <- liftH $
		runFormPost $ renderBootstrap $ glacierInputAForm defcreds
	case result of
		FormSuccess input -> liftH $ do
			let name = T.unpack $ repoName input
			makeAWSRemote Glacier.remote (extractCreds input) name setgroup $ M.fromList
				[ configureEncryption $ enableEncryption input
				, ("type", "glacier")
				, ("datacenter", T.unpack $ datacenter input)
				]
		_ -> $(widgetFile "configurators/addglacier")
  where
	setgroup r = liftAnnex $ 
		setStandardGroup (Remote.uuid r) SmallArchiveGroup
#else
postAddGlacierR = error "S3 not supported by this build"
#endif

getEnableS3R :: UUID -> Handler Html
#ifdef WITH_S3
getEnableS3R uuid = do
	m <- liftAnnex readRemoteLog
	if isIARemoteConfig $ fromJust $ M.lookup uuid m
		then redirect $ EnableIAR uuid
		else postEnableS3R uuid
#else
getEnableS3R = postEnableS3R
#endif

postEnableS3R :: UUID -> Handler Html
#ifdef WITH_S3
postEnableS3R uuid = awsConfigurator $ enableAWSRemote S3.remote uuid
#else
postEnableS3R _ = error "S3 not supported by this build"
#endif

getEnableGlacierR :: UUID -> Handler Html
getEnableGlacierR = postEnableGlacierR

postEnableGlacierR :: UUID -> Handler Html
postEnableGlacierR = glacierConfigurator . enableAWSRemote Glacier.remote

enableAWSRemote :: RemoteType -> UUID -> Widget
#ifdef WITH_S3
enableAWSRemote remotetype uuid = do
	defcreds <- liftAnnex previouslyUsedAWSCreds
	((result, form), enctype) <- liftH $
		runFormPost $ renderBootstrap $ awsCredsAForm defcreds
	case result of
		FormSuccess creds -> liftH $ do
			m <- liftAnnex readRemoteLog
			let name = fromJust $ M.lookup "name" $
				fromJust $ M.lookup uuid m
			makeAWSRemote remotetype creds name (const noop) M.empty
		_ -> do
			description <- liftAnnex $
				T.pack <$> Remote.prettyUUID uuid
			$(widgetFile "configurators/enableaws")
#else
enableAWSRemote _ _ = error "S3 not supported by this build"
#endif

makeAWSRemote :: RemoteType -> AWSCreds -> String -> (Remote -> Handler ()) -> RemoteConfig -> Handler ()
makeAWSRemote remotetype (AWSCreds ak sk) name setup config = do
	remotename <- liftAnnex $ fromRepo $ uniqueRemoteName name 0
	liftIO $ AWS.setCredsEnv (T.unpack ak, T.unpack sk)
	r <- liftAnnex $ addRemote $ do
		makeSpecialRemote hostname remotetype config
		return remotename
	setup r
	liftAssistant $ syncRemote r
	redirect $ EditNewCloudRepositoryR $ Remote.uuid r
  where
	{- AWS services use the remote name as the basis for a host
	 - name, so filter it to contain valid characters. -}
	hostname = case filter isAlphaNum name of
		[] -> "aws"
		n -> n

getRepoInfo :: RemoteConfig -> Widget
getRepoInfo c = [whamlet|S3 remote using bucket: #{bucket}|]
  where
	bucket = fromMaybe "" $ M.lookup "bucket" c

#ifdef WITH_S3
isIARemoteConfig :: RemoteConfig -> Bool
isIARemoteConfig = S3.isIAHost . fromMaybe "" . M.lookup "host"

previouslyUsedAWSCreds :: Annex (Maybe CredPair)
previouslyUsedAWSCreds = getM gettype [S3.remote, Glacier.remote]
  where
	gettype t = previouslyUsedCredPair AWS.creds t $
		not . isIARemoteConfig . Remote.config
#endif
