#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'

action, source_argument, output_argument = ARGV
abort 'usage: generate-chatwoot-active-ja-overrides.rb generate|verify SOURCE_ROOT OVERLAY_APP_ROOT' unless
  %w[generate verify].include?(action) && source_argument && output_argument

SOURCE_ROOT = Pathname.new(source_argument).realpath
OUTPUT_ROOT = Pathname.new(output_argument).expand_path

SOURCE_SHA256 = {
  'app/javascript/dashboard/components-next/Contacts/EmptyState/contactEmptyStateContent.js' =>
    '4542ea4bca42064b84ae10928432a67fb3a9ea288090cd2c0008cdbf1ee6aa2f',
  'app/javascript/dashboard/components/auth/SessionLimitOverlay.vue' =>
    '72bdcde41b8cf5d86465e2abac639cf160a62b12c7f14fac9e2478ec653ae3e3',
  'app/javascript/dashboard/components/auth/MfaVerification.vue' =>
    'efb1719110cf16406d18df3b2757e2418f011ad25f223fd94da9655318b95a2d',
  'app/javascript/dashboard/components/ModalHeader.vue' =>
    '41e7a94ade49ea50b02f46a10e753bc46575ca263a91247ae5dc6d6eef067abe',
  'app/javascript/dashboard/components/widgets/conversation/EmptyState/EmptyStateMessage.vue' =>
    '6b055decd0c9b40424d54801d4c36b6ee68c37786397848be09b675f8ebfbe56',
  'app/javascript/dashboard/components/widgets/conversation/MessagesView.vue' =>
    '511ba24496b380f8b713e1e25b7079c611a4f0e6768bffc8c0c49b71dd687a7a',
  'app/javascript/dashboard/components/widgets/conversation/OnboardingView.vue' =>
    'c44813b643f4490a18ecb4bc46ae835ff3ebdace1ed42a6b1e813277c3bec355',
  'app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue' =>
    'b3a6593fea16bee0728f8bf5690ace93ea121f5774b6c5331f40ed0e8be3002d',
  'app/javascript/dashboard/components/widgets/conversation/ContentTemplates/ContentTemplatesPicker.vue' =>
    'b7d9c12d56403d8aee53abf9eec928aae1d6245149b3c457f25c814fdffb5d05',
  'app/javascript/dashboard/components/widgets/conversation/ShopifyOrderItem.vue' =>
    '7729c787c4ccd025ca25a06dec5fc2721153eb24e871b92b4a5ee3f51478167e',
  'app/javascript/dashboard/components/widgets/conversation/components/GalleryView.vue' =>
    '298470bc20a59c63f63b57c97391cc3dd50d18e696bcb44952caf7749205e386',
  'app/javascript/dashboard/components/widgets/conversation/contextMenu/Index.vue' =>
    '07c1db02546d0ae4b7e61c50df8abd9d23b8fbf0fcbd4828788c7663a7d9bdfd',
  'app/javascript/dashboard/components/widgets/conversation/ConversationCallButton.vue' =>
    '081b9d3539d05ffc71d3eb4704b7df1bd794c0272929ec35348e0383d3d815b5',
  'app/javascript/dashboard/components/widgets/conversation/advancedFilterItems/languages.js' =>
    '8695e0a87471076c7873ee7924a3f13cc610d389d3e1905ce7ed8c5879d4875f',
  'app/javascript/dashboard/components-next/Contacts/ContactsHeader/ContactListHeaderWrapper.vue' =>
    '8b8d8245616a23754bf32b77d6a7039fa9edf2d29cf44da59b95653510c9d7a3',
  'app/javascript/dashboard/components-next/Contacts/Pages/ContactDetails.vue' =>
    '8b58422d744f96438d12418d022cf9ef9ebe103c78dd9507b4339c3cc0ecf44c',
  'app/javascript/dashboard/components-next/Contacts/Pages/ContactsList.vue' =>
    'fa688afc3d4686d9ebc4f38e223906c3aceeef213a67e3bad3b2c8033f9c1b26',
  'app/javascript/dashboard/components-next/Contacts/VoiceCallButton.vue' =>
    '0d0db17e4752f310dec8403dee5f0407d02b2e17fae2bdff9b4f5f653818e489',
  'app/javascript/dashboard/components-next/NewConversation/ComposeConversation.vue' =>
    '4aab987306e10909f38b624e7c1414c709003a0eed17c0d412ebd3a1b34b8122',
  'app/javascript/dashboard/components/widgets/FilterInput/FilterOperatorTypes.js' =>
    '31824898130c00c0ccc656471d3d6b17d405d362903fb70d75b98f9d9f6cdf0a',
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactNotes.vue' =>
    '548a2301bf714e160f19425aebc2a719435fb3df4a19a8ab84e7b9a5384a3013',
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/components/ContactNoteItem.vue' =>
    '24e0dff75eaeb806296605869d938766d31bf283db967ca2c0844aee65033ed8',
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactCustomAttributeItem.vue' =>
    '4932c386fde253abb90d760bb5b185b793db2d237c4f0e704af97b18098e7e16',
  'app/javascript/dashboard/components-next/Campaigns/EmptyState/CampaignEmptyStateContent.js' =>
    'b892b8e202815faf09ce9e41d268ffa0518a404c3a485073fce6595a79d3a6e9',
  'app/javascript/dashboard/components-next/HelpCenter/CategoryCard/CategoryCard.vue' =>
    'a354feaf2ed88c44b7c250b1817e1093773c39655ca791108bc878076db13741',
  'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Category/categoryEmptyStateContent.js' =>
    'f112b0985dcbb89338c1224a95d9110ccd31043ff00c7c44c5c28c7891d1346d',
  'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Portal/portalEmptyStateContent.js' =>
    'ef086037cc6ea4de189e8d1f556d54172aa0762a528a1c3607c5073f5ccf21cf',
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoriesPage.vue' =>
    '539d2db4f1748cd376461a80a10174f1e0adb5d5accb905ee096d7f881d48aa2',
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoryDialog.vue' =>
    '433ce1b806a688d1a9b7c3f409ad9d769a53f5e4f2e79092cf9e04e664357e2e',
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/EditCategoryDialog.vue' =>
    'c1a50ccb495ece7978390a5056d91e52f99bd1977f5605bdb159fad3d0585948',
  'app/javascript/dashboard/components-next/HelpCenter/PortalSwitcher/CreatePortalDialog.vue' =>
    '75592bcb2f3fe3a86fbc203714466f73433a69d4395c15616ec01cbb40432756',
  'app/javascript/dashboard/modules/conversations/components/MessageContextMenu.vue' =>
    'cd598606d926e92d8147fc6d2d8d297a2035ceb83ac713506c3d3c64cdd037d5',
  'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactInfo.vue' =>
    'bb7c4b1efa93aed6ce7f45c235ef5bf439a9539e710e342d51d276ce3669acf7',
  'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactForm.vue' =>
    'b9368a71b7c8165f2c1622a21d69999f4bd4aa8d9efef5e3f485ed78f0986f2a',
  'app/javascript/dashboard/routes/dashboard/conversation/customAttributes/CustomAttributes.vue' =>
    'defc23890660a318771437a2043fb72394357c664b0ba7a78e94e7ef04cdd8b1',
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxChannelForm.vue' =>
    'eb9e667cd5844a5a81047f129dbb5ab974fbd05bd558172d9e3e2b29389708d3',
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxFacebookForm.vue' =>
    'f7444f54b1196d1ba41bb888d274c7973482691ce6fb55077deb0781da8180b2',
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/useChannelConnect.js' =>
    '6c0a32c657f44468085e8fdd3edea863c215b05e31313468803b071dd89b4b6a',
  'app/javascript/dashboard/routes/dashboard/onboarding/shared/constants.js' =>
    'c6d8cfefdcbc39ee16645913da7804a351a0e4a1ce5008992221082eeea51576',
  'app/javascript/dashboard/routes/dashboard/settings/data/importSources.js' =>
    '0d12e4a8a3bf82a76ae13d6553e7ebe408ea7cdd39f09d43aae8b2d8854ef23b',
  'app/javascript/dashboard/routes/dashboard/helpcenter/pages/PortalsSettingsIndexPage.vue' =>
    '84970c8b1058f2769f00c923fe36b7972f278fec98cf2c10eff8dae271eb9a0c',
  'app/javascript/dashboard/routes/dashboard/settings/automation/Index.vue' =>
    '055e786a867a04a03e6beeb13938e5c4580d5c1c2e0699d84d3cbef898c35d7a',
  'app/javascript/dashboard/routes/dashboard/settings/automation/operators.js' =>
    'f6b263af8575fc558180b6450dc7b4221daffe21bfd149268d5d310f0fda7c90',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/AddAgents.vue' =>
    'ab356610b811a468b729670ad68b334edaeadc88f4b62f5e0b8cbef84183bf6d',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/FinishSetup.vue' =>
    '53fdda9764a12b67b70cf5461e30bd6e39a965b046abb21a818afb1931c9cb93',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue' =>
    '4de6dd47c70682fb826f3a02c04adcff47f05315415504a487abe8051691a743',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Twitter.vue' =>
    'c8363f001343329368f3c9fbad5b39374331ebf7e980b5bcde6100e28f3bd56f',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Facebook.vue' =>
    '823b29271997735d3f8f5e81e557d4a79426a859ae141bea35a9aa5ffedf7b3f',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Website.vue' =>
    'fd44dc04267ed542d0cf4fbdb589e75a18b5e46e983954acde1846eebb582c2d',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/ImapSettings.vue' =>
    '7e95bd5b0ea6ba00d44471a8ad3a518e4e657559f15903eea8001eb13c271f35',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/SmtpSettings.vue' =>
    '2a7b4e88abfff768a89304950653764ea470977b89447afd52df2402c2b22c17',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/components/BusinessDay.vue' =>
    'c8496212bd9faffca3941c7a5ebd8547375aadc1ddc3696488a6de0547350eca',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/components/WeeklyAvailability.vue' =>
    '00a626ed8de48cf1c39e23503d3da6150f6334c3c83b229c6acc6c8cd190cb7e',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/businessHour.js' =>
    'e47bbfe7cc99e321fd19dc1aab728ddb61b8378ead6b4ac9728b4c83decb5ae1',
  'app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/CustomerSatisfactionPage.vue' =>
    '826de74ae2be850469de9d5ac2bbecb65df604941745353a96260c6cb62c9bb0',
  'app/javascript/dashboard/routes/dashboard/settings/profile/ActiveSessions.vue' =>
    '4ce8cfba39c4a82d0f0e0003e4cd86bd179644f73370bfd1441fee3b6368352d',
  'app/javascript/dashboard/routes/dashboard/settings/profile/AudioAlertTone.vue' =>
    '825fd61c613ba1b232edc677bed3bd724725d20621b692a42cfe82035d58f831',
  'app/javascript/dashboard/routes/dashboard/settings/profile/Index.vue' =>
    'a3f3dbd89a7a470965276345da3b851d12b091c0ac0610d0c36debff78b05ce1',
  'app/javascript/dashboard/routes/dashboard/settings/profile/MfaSetupWizard.vue' =>
    '8d5fcf7f8295fe28f3cf5843da44a627d1f7be6eb2de8b31498e644f033e8d5f',
  'app/javascript/dashboard/routes/dashboard/settings/labels/AddLabel.vue' =>
    'a61bb2e6630b511f8030593a8c761e5f8b7430c1d8b1bfc61a580dd61a77cf3c',
  'app/javascript/dashboard/routes/dashboard/settings/teams/Create/AddAgents.vue' =>
    'a268772057b5d6ef8bd9db1f58c586545951f470ae49f3eaeb4369046ce0deb7',
  'app/javascript/dashboard/routes/dashboard/settings/teams/Edit/EditAgents.vue' =>
    'bc5dd60dd3b847243b592c7a111e2519decda1438bce71f3b78cb46681802de3',
  'app/javascript/shared/constants/messages.js' =>
    'af1015c33e804debf49670ccb08ee6cb0727cdb35d580307532a50c2bcaf012f',
  'app/javascript/shared/constants/countries.js' =>
    '21da2763b74d7f4984d2dd4f5cf2ab14f9a70031a0fb872621ff381d8d81ef2c',
  'app/javascript/shared/helpers/timeHelper.js' =>
    '20b51ab98163fc5d2134ac74b4ba13948008b6b129f26fed7340649190ae4e96',
  'app/javascript/dashboard/helper/preChat.js' =>
    '977df3b3b75a5588323f82faed3ccb758aeeb4bf4ce7f688435bd1748d08270c',
  'app/javascript/dashboard/helper/snoozeHelpers.js' =>
    '6541ad70444aca4af7390e9c79f07cdac0fcd97fe79ebfb8ca599f48ed83a1f3',
  'app/javascript/v3/api/auth.js' =>
    '9b5e208f7c90503f11c75bad0574109f8b8c8a9280d0e42f3b16f34fb9fdb5d6',
  'app/javascript/v3/views/auth/password/Edit.vue' =>
    '909f351a4a31f9b00fd637bd6963fd726990ad84a11bd67a3e430058bb85d653',
  'app/javascript/v3/views/auth/reset/password/Index.vue' =>
    'b8b231e22b5fb848dd66b4ee8620887bc69658b628656102595a438fa4361637',
  'app/javascript/v3/views/auth/signup/components/Signup/Form.vue' =>
    '808918cea4c075e9804c85687930a446366bb4849ba94938651bafab928a2448',
  'app/javascript/v3/components/Form/Input.vue' =>
    '1cc3610b9b55ccb8cf9013d6449a2d4acebee29f7df38513365c90dc84c170bd',
  'public/assets/images/dashboard/profile/hot-key-enter.svg' =>
    'a055a3e930aad122c642b16f527c9ec55b222763650eb09f9605afc6ab5b156f',
  'public/assets/images/dashboard/profile/hot-key-enter-dark.svg' =>
    '8add5619c43775a5616daf8b7e5c6788771712ac8ca590b698f01a2c0226540c',
  'public/assets/images/dashboard/profile/hot-key-ctrl-enter.svg' =>
    '0c2da9504ec8221005360e13a26c5e0db68ab2268c906fac08c5c19267f3027d',
  'public/assets/images/dashboard/profile/hot-key-ctrl-enter-dark.svg' =>
    '76cdb8e7d0a7b1642fa93c6f0b9d783c0ed24346c534a9d474c8e8c3af1c4a9a'
}.freeze

# Keep this as a small, explicit data contract. It confirms that every major
# user-facing surface still has its pinned route seam and declares only the
# active Japanese overrides that the surface needs. It intentionally does not
# attempt to parse JavaScript imports or build a dependency graph.
MAJOR_ROUTE_ANCHORS = {
  'auth' => {
    route_source: 'app/javascript/v3/views/routes.js',
    anchors: ["path: frontendURL('login')", "path: frontendURL('auth/reset/password')"],
    required_overlays: [
      'app/javascript/dashboard/components/auth/SessionLimitOverlay.vue',
      'app/javascript/dashboard/components/auth/MfaVerification.vue',
      'app/javascript/v3/api/auth.js',
      'app/javascript/v3/views/auth/password/Edit.vue',
      'app/javascript/v3/views/auth/reset/password/Index.vue',
      'app/javascript/v3/views/auth/signup/components/Signup/Form.vue'
    ]
  },
  'onboarding' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/dashboard.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/onboarding')",
              "path: frontendURL('accounts/:accountId/onboarding/inbox-setup')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxChannelForm.vue',
      'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxFacebookForm.vue',
      'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/useChannelConnect.js',
      'app/javascript/dashboard/routes/dashboard/onboarding/shared/constants.js'
    ]
  },
  'conversations' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/conversation/conversation.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/conversations/:conversation_id')"],
    required_overlays: [
      'app/javascript/dashboard/components-next/NewConversation/ComposeConversation.vue',
      'app/javascript/dashboard/components/widgets/conversation/EmptyState/EmptyStateMessage.vue',
      'app/javascript/dashboard/components/widgets/conversation/MessagesView.vue',
      'app/javascript/dashboard/components/widgets/conversation/OnboardingView.vue',
      'app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue',
      'app/javascript/dashboard/components/widgets/conversation/ContentTemplates/ContentTemplatesPicker.vue',
      'app/javascript/dashboard/components/widgets/conversation/ShopifyOrderItem.vue',
      'app/javascript/dashboard/components/widgets/conversation/components/GalleryView.vue',
      'app/javascript/dashboard/components/widgets/conversation/contextMenu/Index.vue',
      'app/javascript/dashboard/components/widgets/conversation/ConversationCallButton.vue',
      'app/javascript/dashboard/components/widgets/conversation/advancedFilterItems/languages.js',
      'app/javascript/dashboard/modules/conversations/components/MessageContextMenu.vue',
      'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactInfo.vue',
      'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactForm.vue',
      'app/javascript/dashboard/routes/dashboard/conversation/customAttributes/CustomAttributes.vue'
    ]
  },
  'contacts' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/contacts/routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/contacts')"],
    required_overlays: [
      'app/javascript/dashboard/components-next/Contacts/EmptyState/contactEmptyStateContent.js',
      'app/javascript/dashboard/components-next/Contacts/ContactsHeader/ContactListHeaderWrapper.vue',
      'app/javascript/dashboard/components-next/Contacts/Pages/ContactDetails.vue',
      'app/javascript/dashboard/components-next/Contacts/Pages/ContactsList.vue',
      'app/javascript/dashboard/components-next/Contacts/VoiceCallButton.vue',
      'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactCustomAttributeItem.vue',
      'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactNotes.vue',
      'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/components/ContactNoteItem.vue',
      'app/javascript/dashboard/components/widgets/FilterInput/FilterOperatorTypes.js'
    ]
  },
  'inbox' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/settings/inbox/inbox.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/settings/inboxes')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/settings/inbox/AddAgents.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/FinishSetup.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Twitter.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Facebook.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Website.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/ImapSettings.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/SmtpSettings.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/components/BusinessDay.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/components/WeeklyAvailability.vue',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/businessHour.js',
      'app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/CustomerSatisfactionPage.vue'
    ]
  },
  'automation' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/settings/automation/automation.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/settings/automation')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/settings/automation/Index.vue',
      'app/javascript/dashboard/routes/dashboard/settings/automation/operators.js'
    ]
  },
  'campaigns' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/campaigns/campaigns.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/campaigns')"],
    required_overlays: [
      'app/javascript/dashboard/components-next/Campaigns/EmptyState/CampaignEmptyStateContent.js'
    ]
  },
  'helpcenter' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/helpcenter/helpcenter.routes.js',
    anchors: ["path: getPortalRoute(':portalSlug/:locale/:categorySlug?/articles/:tab?')"],
    required_overlays: [
      'app/javascript/dashboard/components-next/HelpCenter/CategoryCard/CategoryCard.vue',
      'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Category/categoryEmptyStateContent.js',
      'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Portal/portalEmptyStateContent.js',
      'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoriesPage.vue',
      'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoryDialog.vue',
      'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/EditCategoryDialog.vue',
      'app/javascript/dashboard/components-next/HelpCenter/PortalSwitcher/CreatePortalDialog.vue',
      'app/javascript/dashboard/routes/dashboard/helpcenter/pages/PortalsSettingsIndexPage.vue'
    ]
  },
  'captain' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/captain/captain.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/captain')"],
    release_state: 'parked_pending_staging_feature_confirmation',
    required_overlays: []
  },
  'profile' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/settings/profile/profile.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/profile')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/settings/profile/ActiveSessions.vue',
      'app/javascript/dashboard/routes/dashboard/settings/profile/AudioAlertTone.vue',
      'app/javascript/dashboard/routes/dashboard/settings/profile/Index.vue',
      'app/javascript/dashboard/routes/dashboard/settings/profile/MfaSetupWizard.vue',
      'public/assets/images/dashboard/profile/hot-key-enter.svg',
      'public/assets/images/dashboard/profile/hot-key-enter-dark.svg',
      'public/assets/images/dashboard/profile/hot-key-ctrl-enter.svg',
      'public/assets/images/dashboard/profile/hot-key-ctrl-enter-dark.svg'
    ]
  },
  'data' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/settings/data/data.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/settings/data')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/settings/data/importSources.js'
    ]
  },
  'labels' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/settings/labels/labels.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/settings/labels')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/settings/labels/AddLabel.vue'
    ]
  },
  'teams' => {
    route_source: 'app/javascript/dashboard/routes/dashboard/settings/teams/teams.routes.js',
    anchors: ["path: frontendURL('accounts/:accountId/settings/teams')"],
    required_overlays: [
      'app/javascript/dashboard/routes/dashboard/settings/teams/Create/AddAgents.vue',
      'app/javascript/dashboard/routes/dashboard/settings/teams/Edit/EditAgents.vue'
    ]
  }
}.freeze

SHARED_OVERRIDES = [
  'app/javascript/dashboard/components/ModalHeader.vue',
  'app/javascript/dashboard/helper/preChat.js',
  'app/javascript/dashboard/helper/snoozeHelpers.js',
  'app/javascript/shared/constants/messages.js',
  'app/javascript/shared/constants/countries.js',
  'app/javascript/shared/helpers/timeHelper.js',
  'app/javascript/v3/components/Form/Input.vue'
].freeze

def replacement(before, after, count = 1)
  [before, after, count]
end

REPLACEMENTS = {
  'app/javascript/dashboard/components/ModalHeader.vue' => [
    replacement('alt="No image"', 'alt=""')
  ],
  'app/javascript/dashboard/components/auth/MfaVerification.vue' => [
    replacement("  parseAPIErrorResponse,\n", ''),
    replacement("  } catch (error) {\n    errorMessage.value =\n      parseAPIErrorResponse(error) || t('MFA_VERIFICATION.VERIFICATION_FAILED');",
                "  } catch {\n    errorMessage.value = t('MFA_VERIFICATION.VERIFICATION_FAILED');")
  ],
  'app/javascript/dashboard/components/widgets/conversation/EmptyState/EmptyStateMessage.vue' => [
    replacement('alt="No Chat dark"', 'alt="チャットはありません"'),
    replacement('alt="No Chat"', 'alt="チャットはありません"')
  ],
  'app/javascript/dashboard/components/widgets/conversation/OnboardingView.vue' => [
    replacement('image-alt="Omnichannel"', 'image-alt="オムニチャネル受信箱"'),
    replacement('image-alt="Teams"', 'image-alt="チーム"'),
    replacement('image-alt="Canned responses"', 'image-alt="定型文"'),
    replacement('image-alt="Labels"', 'image-alt="ラベル"')
  ],
  'app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue' => [
    replacement("        Enter: {\n          action: e => {\n            if (this.isAValidEvent('enter')) {",
                "        Enter: {\n          action: e => {\n            // Safari may report isComposing=false on the IME confirmation key.\n            if (e.isComposing || e.keyCode === 229) return;\n            if (this.isAValidEvent('enter')) {"),
    replacement("        '$mod+Enter': {\n          action: () => {\n            if (this.copilot.isActive.value && this.isFocused) {",
                "        '$mod+Enter': {\n          action: e => {\n            if (e.isComposing || e.keyCode === 229) return;\n            if (this.copilot.isActive.value && this.isFocused) {"),
    replacement("      } catch (error) {\n        const errorMessage =\n          error?.response?.data?.error || this.$t('CONVERSATION.MESSAGE_ERROR');\n        useAlert(errorMessage);",
                "      } catch {\n        useAlert(this.$t('CONVERSATION.MESSAGE_ERROR'));")
  ],
  'app/javascript/dashboard/components/widgets/conversation/ContentTemplates/ContentTemplatesPicker.vue' => [
    replacement("{{ template.category || 'utility' }}", "{{ template.category || 'ユーティリティ' }}"),
    replacement('new Date(template.created_at).toLocaleDateString()',
                "new Date(template.created_at).toLocaleDateString('ja-JP')")
  ],
  'app/javascript/dashboard/components/widgets/conversation/components/GalleryView.vue' => [
    replacement("return messageTimestamp(createdAt, 'LLL d yyyy, h:mm a') || '';",
                "return messageTimestamp(createdAt, 'yyyy年M月d日 H:mm') || '';"),
    replacement("currentUser.value?.id === id ? 'You' : name || availableName || ''",
                "currentUser.value?.id === id ? 'あなた' : name || availableName || ''")
  ],
  'app/javascript/dashboard/components/widgets/conversation/ShopifyOrderItem.vue' => [
    replacement("import { format } from 'date-fns';\n", ''),
    replacement("const formatDate = dateString => {\n  return format(new Date(dateString), 'MMM d, yyyy');\n};",
                "const formatDate = dateString => {\n  return new Intl.DateTimeFormat('ja-JP', { dateStyle: 'medium' }).format(\n    new Date(dateString)\n  );\n};"),
    replacement("return new Intl.NumberFormat('en', {", "return new Intl.NumberFormat('ja-JP', {")
  ],
  'app/javascript/dashboard/components/widgets/conversation/contextMenu/Index.vue' => [
    replacement("          name: 'None'", "          name: '未割り当て'"),
    replacement("          email: 'None'", "          email: '未割り当て'")
  ],
  'app/javascript/dashboard/components/widgets/conversation/ConversationCallButton.vue' => [
    replacement("  } catch (error) {\n    useAlert(error?.message || t('CONVERSATION.HEADER.WHATSAPP_CALL_FAILED'));\n  }",
                "  } catch {\n    useAlert(t('CONVERSATION.HEADER.WHATSAPP_CALL_FAILED'));\n  }"),
    replacement("  } catch (error) {\n    useAlert(error?.message || t('CONVERSATION.HEADER.VOICE_CALL_FAILED'));\n  }",
                "  } catch {\n    useAlert(t('CONVERSATION.HEADER.VOICE_CALL_FAILED'));\n  }")
  ],
  'app/javascript/dashboard/components-next/Contacts/Pages/ContactsList.vue' => [
    replacement("    } else if (error instanceof ExceptionWithMessage) {\n      useAlert(error.data);",
                "    } else if (error instanceof ExceptionWithMessage) {\n      useAlert(t(`${i18nPrefix}.ERROR_MESSAGE`));")
  ],
  'app/javascript/dashboard/components-next/Contacts/ContactsHeader/ContactListHeaderWrapper.vue' => [
    replacement("    } else if (error instanceof ExceptionWithMessage) {\n      useAlert(error.data);",
                "    } else if (error instanceof ExceptionWithMessage) {\n      useAlert(t(`${i18nPrefix}.ERROR_MESSAGE`));"),
    replacement("  } catch (error) {\n    useAlert(\n      error.message ??\n        t('CONTACTS_LAYOUT.HEADER.ACTIONS.IMPORT_CONTACT.ERROR_MESSAGE')\n    );",
                "  } catch {\n    useAlert(t('CONTACTS_LAYOUT.HEADER.ACTIONS.IMPORT_CONTACT.ERROR_MESSAGE'));"),
    replacement("  } catch (error) {\n    useAlert(\n      error.message ||\n        t('CONTACTS_LAYOUT.HEADER.ACTIONS.EXPORT_CONTACT.ERROR_MESSAGE')\n    );",
                "  } catch {\n    useAlert(t('CONTACTS_LAYOUT.HEADER.ACTIONS.EXPORT_CONTACT.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/components-next/Contacts/Pages/ContactDetails.vue' => [
    replacement("  } catch (error) {\n    useAlert(\n      error.message\n        ? error.message\n        : t('CONTACTS_LAYOUT.DETAILS.AVATAR.DELETE.ERROR_MESSAGE')\n    );",
                "  } catch {\n    useAlert(t('CONTACTS_LAYOUT.DETAILS.AVATAR.DELETE.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/components-next/Contacts/VoiceCallButton.vue' => [
    replacement("    } catch (error) {\n      useAlert(error?.message || t('CONTACT_PANEL.CALL_FAILED'));\n    }",
                "    } catch {\n      useAlert(t('CONTACT_PANEL.CALL_FAILED'));\n    }"),
    replacement("  } catch (error) {\n    const apiError = error?.message;\n    useAlert(apiError || t('CONTACT_PANEL.CALL_FAILED'));\n  }",
                "  } catch {\n    useAlert(t('CONTACT_PANEL.CALL_FAILED'));\n  }")
  ],
  'app/javascript/dashboard/components-next/NewConversation/ComposeConversation.vue' => [
    replacement("import { parseAPIErrorResponse } from 'dashboard/store/utils/api';\n", ''),
    replacement("import { ExceptionWithMessage } from 'shared/helpers/CustomErrors';\n", ''),
    replacement("    } catch (error) {\n      isCreatingContact.value = false;\n      const message = parseAPIErrorResponse(error);\n      useAlert(\n        typeof message === 'string'\n          ? message\n          : t('COMPOSE_NEW_CONVERSATION.CONTACT_CREATE.ERROR_MESSAGE')\n      );",
                "    } catch {\n      isCreatingContact.value = false;\n      useAlert(t('COMPOSE_NEW_CONVERSATION.CONTACT_CREATE.ERROR_MESSAGE'));"),
    replacement("  } catch (error) {\n    useAlert(\n      error instanceof ExceptionWithMessage\n        ? error.data\n        : t('COMPOSE_NEW_CONVERSATION.FORM.ERROR_MESSAGE')\n    );",
                "  } catch {\n    useAlert(t('COMPOSE_NEW_CONVERSATION.FORM.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/modules/conversations/components/MessageContextMenu.vue' => [
    replacement("import { parseAPIErrorResponse } from 'dashboard/store/utils/api';\n", ''),
    replacement("const targetLanguage = agentLocale || accountLocale || 'en';",
                "const targetLanguage = agentLocale || accountLocale || 'ja';"),
    replacement("      } catch (error) {\n        useAlert(parseAPIErrorResponse(error));",
                "      } catch {\n        useAlert('メッセージを翻訳できませんでした。もう一度お試しください。');")
  ],
  'app/javascript/dashboard/components/widgets/FilterInput/FilterOperatorTypes.js' => [
    replacement("label: 'Equal to'", "label: '等しい'", 4),
    replacement("label: 'Not equal to'", "label: '等しくない'", 4),
    replacement("label: 'Contains'", "label: '含む'"),
    replacement("label: 'Does not contain'", "label: '含まない'"),
    replacement("label: 'Is present'", "label: '値がある'", 2),
    replacement("label: 'Is not present'", "label: '値がない'", 2),
    replacement("label: 'Is greater than'", "label: 'より大きい'", 2),
    replacement("label: 'Is less than'", "label: 'より小さい'", 2),
    replacement("label: 'Is x days before'", "label: '指定日数より前'")
  ],
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactNotes.vue' => [
    replacement("    : note?.user?.name || 'Bot';", "    : note?.user?.name || 'ボット';")
  ],
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/components/ContactNoteItem.vue' => [
    replacement(":name=\"note?.user?.name || 'Bot'\"", ":name=\"note?.user?.name || 'ボット'\"")
  ],
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactCustomAttributeItem.vue' => [
    replacement("  } catch (error) {\n    useAlert(\n      error?.response?.message ||\n        t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.DELETE_ERROR')\n    );",
                "  } catch {\n    useAlert(t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.DELETE_ERROR'));"),
    replacement("  } catch (error) {\n    useAlert(\n      error?.response?.message ||\n        t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.UPDATE_ERROR')\n    );",
                "  } catch {\n    useAlert(t('CONTACTS_LAYOUT.SIDEBAR.ATTRIBUTES.API.UPDATE_ERROR'));")
  ],
  'app/javascript/dashboard/components-next/Campaigns/EmptyState/CampaignEmptyStateContent.js' => [
    replacement("title: 'Chatbot Assistance'", "title: 'チャットボットのご案内'"),
    replacement("title: 'Pricing Information Support'", "title: '料金に関するご案内'"),
    replacement("title: 'Product Setup Assistance'", "title: '初期設定のサポート'"),
    replacement("title: 'General Assistance Campaign'", "title: '総合お問い合わせ'"),
    replacement("title: 'Customer Feedback Request'", "title: 'ご意見のお願い'"),
    replacement("title: 'Welcome New Customer'", "title: '新しいお客様へのご案内'"),
    replacement("title: 'New Business Welcome'", "title: '新規お取引のご案内'"),
    replacement("title: 'New Member Onboarding'", "title: '新しいメンバーへのご案内'"),
    replacement("name: 'PaperLayer Website'", "name: 'トイバコ Webサイト'", 4),
    replacement("name: 'PaperLayer Mobile'", "name: 'トイバコ モバイル'", 4),
    replacement("name: 'Alexa Rivera'", "name: '佐藤 花子'"),
    replacement("name: 'Jamie Lee'", "name: '鈴木 健太'"),
    replacement("name: 'Chatwoot'", "name: 'トイバコ'"),
    replacement("name: 'Chris Barlow'", "name: '田中 美咲'"),
    replacement("message: 'Hello! 👋 Need help with our chatbot features? Feel free to ask!'",
                "message: 'こんにちは！👋 チャットボット機能について、お気軽にご相談ください。'"),
    replacement("message: 'Hello! 👋 Any questions on pricing? I’m here to help!'",
                "message: 'こんにちは！👋 料金についてのご質問にお答えします。'"),
    replacement("message: 'Hi! Chatwoot here. Need help setting up? Let me know!'",
                "message: 'こんにちは！トイバコの初期設定をお手伝いします。'"),
    replacement("      'Hi there! 👋 I’m here for any questions you may have. Let’s chat!'",
                "      'こんにちは！👋 ご不明な点があれば、いつでもご相談ください。'"),
    replacement("      'Hello! Enjoying our product? Share your feedback on G2 and earn a $25 Amazon coupon: https://chwt.app/g2-review'",
                "      'いつもご利用ありがとうございます。サービスについてのご意見をお聞かせください。'"),
    replacement("message: 'Welcome aboard! 🎉 Let us know if you have any questions.'",
                "message: 'ご利用ありがとうございます！🎉 ご不明な点があればお知らせください。'"),
    replacement("message: 'Hello! We’re excited to have your business with us!'",
                "message: 'このたびはお取引いただき、ありがとうございます！'"),
    replacement("message: 'Welcome to the team! Reach out if you have questions.'",
                "message: 'チームへようこそ！ご質問があればお気軽にご連絡ください。'")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Category/categoryEmptyStateContent.js' => [
    replacement("name: 'Getting Started'", "name: 'はじめに'"),
    replacement("description: 'Quick guides to help new users onboard.'",
                "description: '初めて利用する方向けのクイックガイドです。'"),
    replacement("name: 'Advanced Features'", "name: '高度な機能'"),
    replacement("description: 'Explore advanced features for power users.'",
                "description: 'より便利に使うための高度な機能を紹介します。'"),
    replacement("name: 'FAQs'", "name: 'よくある質問'"),
    replacement("description: 'Commonly asked questions and helpful answers.'",
                "description: 'よくある質問と回答をまとめています。'"),
    replacement("name: 'Troubleshooting'", "name: 'トラブルシューティング'"),
    replacement("description: 'Resolve common issues with step-by-step guidance.'",
                "description: 'よくある問題の解決手順を案内します。'"),
    replacement("name: 'Community Guidelines'", "name: 'コミュニティガイドライン'"),
    replacement("description: 'Rules and practices for community engagement.'",
                "description: 'コミュニティ利用時のルールと推奨事項です。'"),
    replacement("name: 'Account Management'", "name: 'アカウント管理'"),
    replacement("description: 'Manage your account and settings efficiently.'",
                "description: 'アカウントと各種設定の管理方法を紹介します。'"),
    replacement("name: 'Security Tips'", "name: 'セキュリティのヒント'"),
    replacement("description: 'Best practices for securing your account.'",
                "description: 'アカウントを安全に保つための推奨事項です。'"),
    replacement("name: 'Integrations'", "name: '外部サービス連携'"),
    replacement("description: 'Connect to third-party services and tools easily.'",
                "description: '外部サービスやツールとの連携方法を紹介します。'"),
    replacement("name: 'Billing & Payments'", "name: '請求・支払い'"),
    replacement("description: 'Manage your billing and payment details seamlessly.'",
                "description: '請求情報と支払い方法を管理します。'"),
    replacement("name: 'Customization'", "name: 'カスタマイズ'"),
    replacement("description: 'Personalize and customize your user experience.'",
                "description: '使い方に合わせたカスタマイズ方法を紹介します。'"),
    replacement("name: 'Notifications'", "name: '通知'"),
    replacement("description: 'Adjust your notification settings and preferences.'",
                "description: '通知設定と受信方法を変更します。'"),
    replacement("name: 'Privacy'", "name: 'プライバシー'"),
    replacement("description: 'Understand how your data is collected and used.'",
                "description: 'データの収集方法と利用目的を説明します。'"),
    replacement("name: 'Mobile App'", "name: 'モバイルアプリ'"),
    replacement("description: 'Guides for using the mobile app effectively.'",
                "description: 'モバイルアプリの便利な使い方を紹介します。'"),
    replacement("name: 'Beta Features'", "name: 'ベータ機能'"),
    replacement("description: 'Learn about new experimental features in beta.'",
                "description: '試験提供中の新機能を紹介します。'")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/CategoryCard/CategoryCard.vue' => [
    replacement("label: 'Edit'", "label: '編集'"),
    replacement("label: 'Delete'", "label: '削除'"),
    replacement("props.description ? props.description : 'No description added'",
                "props.description ? props.description : '説明はありません'")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Portal/portalEmptyStateContent.js' => [
    replacement('title: "How to get an SSL certificate for your Help Center\'s custom domain"',
                "title: 'カスタムドメイン用SSL証明書を取得する方法'"),
    replacement("title: 'Setting up your first Help Center portal'",
                "title: '最初のヘルプセンターポータルを設定する'"),
    replacement("title: 'Best practices for organizing your Help Center content'",
                "title: 'ヘルプセンターコンテンツ整理のベストプラクティス'"),
    replacement("title: 'Customizing the appearance of your Help Center'",
                "title: 'ヘルプセンターの外観をカスタマイズする'"),
    replacement("title: 'Integrating your Help Center with third-party tools'",
                "title: 'ヘルプセンターを外部ツールと連携する'"),
    replacement("title: 'Managing user permissions in your Help Center'",
                "title: 'ヘルプセンターのユーザー権限を管理する'"),
    replacement("title: 'Creating and managing FAQ sections'",
                "title: 'FAQセクションを作成・管理する'"),
    replacement("title: 'Implementing search functionality in your Help Center'",
                "title: 'ヘルプセンターに検索機能を導入する'"),
    replacement("title: 'Analyzing Help Center usage metrics'",
                "title: 'ヘルプセンターの利用状況を分析する'"),
    replacement("title: 'Setting up multilingual support in your Help Center'",
                "title: 'ヘルプセンターを多言語対応にする'"),
    replacement("title: 'Creating interactive tutorials for your products'",
                "title: '製品向けインタラクティブチュートリアルを作成する'"),
    replacement("title: 'Implementing a feedback system in your Help Center'",
                "title: 'ヘルプセンターにフィードバック機能を導入する'"),
    replacement("title: 'Optimizing Help Center content for SEO'",
                "title: 'ヘルプセンターコンテンツをSEO最適化する'"),
    replacement("title: 'Creating a knowledge base for internal teams'",
                "title: '社内チーム向けナレッジベースを作成する'"),
    replacement("availableName: 'Michael'", "availableName: '佐藤'"),
    replacement("availableName: 'John'", "availableName: '鈴木'"),
    replacement("availableName: 'Fernando'", "availableName: '高橋'"),
    replacement("availableName: 'Jane'", "availableName: '田中'"),
    replacement("availableName: 'Sarah'", "availableName: '伊藤'"),
    replacement("availableName: 'Alex'", "availableName: '渡辺'"),
    replacement("availableName: 'Emily'", "availableName: '山本'"),
    replacement("availableName: 'David'", "availableName: '中村'"),
    replacement("availableName: 'Rachel'", "availableName: '小林'"),
    replacement("availableName: 'Carlos'", "availableName: '加藤'"),
    replacement("availableName: 'Olivia'", "availableName: '吉田'"),
    replacement("availableName: 'Nathan'", "availableName: '山田'"),
    replacement("availableName: 'Sophia'", "availableName: '佐々木'"),
    replacement("availableName: 'Daniel'", "availableName: '山口'"),
    replacement("name: 'Setup & Configuration'", "name: '設定・構成'"),
    replacement("name: 'Onboarding'", "name: '導入ガイド'"),
    replacement("name: 'Best Practices'", "name: 'ベストプラクティス'"),
    replacement("name: 'Design'", "name: 'デザイン'"),
    replacement("name: 'Integrations'", "name: '連携'"),
    replacement("name: 'Administration'", "name: '管理'"),
    replacement("name: 'Content Management'", "name: 'コンテンツ管理'"),
    replacement("name: 'Features'", "name: '機能'"),
    replacement("name: 'Analytics'", "name: '分析'"),
    replacement("name: 'Localization'", "name: '多言語対応'"),
    replacement("name: 'Education'", "name: '学習ガイド'"),
    replacement("name: 'User Engagement'", "name: 'ユーザーエンゲージメント'"),
    replacement("name: 'SEO'", "name: 'SEO対策'"),
    replacement("name: 'Internal Resources'", "name: '社内資料'")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/PortalSwitcher/CreatePortalDialog.vue' => [
    replacement("emit('create', { slug: portal.slug, locale: 'en' });",
                "emit('create', { slug: portal.slug, locale: 'ja' });"),
    replacement("  } catch (error) {\n    dialogRef.value.close();\n\n    useAlert(\n      error?.message ||\n        t('HELP_CENTER.PORTAL_SETTINGS.API.CREATE_PORTAL.ERROR_MESSAGE')\n    );",
                "  } catch {\n    dialogRef.value.close();\n\n    useAlert(t('HELP_CENTER.PORTAL_SETTINGS.API.CREATE_PORTAL.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoriesPage.vue' => [
    replacement("  } catch (error) {\n    useAlert(\n      error.message ||\n        t('HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.DELETE.API.ERROR_MESSAGE')\n    );",
                "  } catch {\n    useAlert(\n      t('HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.DELETE.API.ERROR_MESSAGE')\n    );")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoryDialog.vue' => [
    replacement("  } catch (error) {\n    const errorMessage =\n      error?.message ||\n      t(\n        `HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.${props.mode.toUpperCase()}.API.ERROR_MESSAGE`\n      );\n    useAlert(errorMessage);",
                "  } catch {\n    useAlert(\n      t(\n        `HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.${props.mode.toUpperCase()}.API.ERROR_MESSAGE`\n      )\n    );")
  ],
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/EditCategoryDialog.vue' => [
    replacement("  } catch (error) {\n    const errorMessage =\n      error?.message ||\n      t(`HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.EDIT.API.ERROR_MESSAGE`);\n    useAlert(errorMessage);",
                "  } catch {\n    useAlert(\n      t(`HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.EDIT.API.ERROR_MESSAGE`)\n    );")
  ],
  'app/javascript/dashboard/routes/dashboard/helpcenter/pages/PortalsSettingsIndexPage.vue' => [
    replacement("  } catch (error) {\n    useAlert(\n      error?.message ||\n        t('HELP_CENTER.PORTAL_SETTINGS.API.UPDATE_PORTAL.ERROR_MESSAGE')\n    );",
                "  } catch {\n    useAlert(t('HELP_CENTER.PORTAL_SETTINGS.API.UPDATE_PORTAL.ERROR_MESSAGE'));"),
    replacement("  } catch (error) {\n    useAlert(\n      error?.message ||\n        t('HELP_CENTER.PORTAL.PORTAL_SETTINGS.DELETE_PORTAL.API.DELETE_ERROR')\n    );",
                "  } catch {\n    useAlert(\n      t('HELP_CENTER.PORTAL.PORTAL_SETTINGS.DELETE_PORTAL.API.DELETE_ERROR')\n    );"),
    replacement("  } catch (error) {\n    useAlert(\n      error?.message ||\n        t(\n          'HELP_CENTER.PORTAL.PORTAL_SETTINGS.SEND_CNAME_INSTRUCTIONS.API.ERROR_MESSAGE'\n        )\n    );",
                "  } catch {\n    useAlert(\n      t(\n        'HELP_CENTER.PORTAL.PORTAL_SETTINGS.SEND_CNAME_INSTRUCTIONS.API.ERROR_MESSAGE'\n      )\n    );")
  ],
  'app/javascript/shared/constants/messages.js' => [
    replacement("label: 'Conversation Id'", "label: '会話ID'"),
    replacement("label: 'Contact Id'", "label: '連絡先ID'"),
    replacement("label: 'Contact name'", "label: '連絡先名'"),
    replacement("label: 'Contact first name'", "label: '連絡先の名'"),
    replacement("label: 'Contact last name'", "label: '連絡先の姓'"),
    replacement("label: 'Contact email'", "label: '連絡先のメールアドレス'"),
    replacement("label: 'Contact phone'", "label: '連絡先の電話番号'"),
    replacement("label: 'Agent name'", "label: '担当者名'"),
    replacement("label: 'Agent first name'", "label: '担当者の名'"),
    replacement("label: 'Agent last name'", "label: '担当者の姓'"),
    replacement("label: 'Agent email'", "label: '担当者のメールアドレス'"),
    replacement("label: 'Inbox name'", "label: '受信トレイ名'"),
    replacement("label: 'Inbox id'", "label: '受信トレイID'")
  ],
  'app/javascript/shared/constants/countries.js' => [
    replacement('export default countries;',
                "const regionDisplayNames = new Intl.DisplayNames(['ja'], { type: 'region' });\nconst localizedCountries = countries.map(country => ({\n  ...country,\n  name: regionDisplayNames.of(country.id) || country.name,\n}));\n\nexport default localizedCountries;")
  ],
  'app/javascript/shared/helpers/timeHelper.js' => [
    replacement("} from 'date-fns';", "} from 'date-fns';\nimport { ja } from 'date-fns/locale';"),
    replacement("export const messageStamp = (time, dateFormat = 'h:mm a') => {",
                "export const messageStamp = (time, dateFormat = 'H:mm') => {"),
    replacement('return format(unixTime, dateFormat);', 'return format(unixTime, dateFormat, { locale: ja });'),
    replacement("export const messageTimestamp = (time, dateFormat = 'MMM d, yyyy') => {",
                "export const messageTimestamp = (time, dateFormat = 'yyyy年M月d日') => {"),
    replacement('const messageDate = format(messageTime, dateFormat);',
                'const messageDate = format(messageTime, dateFormat, { locale: ja });'),
    replacement("return format(messageTime, 'LLL d y, h:mm a');",
                "return format(messageTime, 'yyyy年M月d日 H:mm', { locale: ja });"),
    replacement("if (isToday(date)) return format(date, 'h:mm a');",
                "if (isToday(date)) return format(date, 'H:mm', { locale: ja });"),
    replacement("if (isThisYear(date)) return format(date, 'MMM d');",
                "if (isThisYear(date)) return format(date, 'M月d日', { locale: ja });"),
    replacement("return format(date, 'MMM d, yyyy');",
                "return format(date, 'yyyy年M月d日', { locale: ja });"),
    replacement('return formatDistanceToNow(unixTime, { addSuffix: true });',
                'return formatDistanceToNow(unixTime, { addSuffix: true, locale: ja });'),
    replacement("export const dateFormat = (time, df = 'MMM d, yyyy') => {",
                "export const dateFormat = (time, df = 'yyyy年M月d日') => {"),
    replacement('return format(unixTime, df);', 'return format(unixTime, df, { locale: ja });'),
    replacement("export const shortTimestamp = (time, withAgo = false) => {",
                "export const shortTimestamp = (time, withAgo = false) => {\n  const japaneseTime = time.match(/^(?:約)?(\\d+)(分|時間|日|か月|年)前$/);\n  if (japaneseTime) {\n    return `${japaneseTime[1]}${japaneseTime[2]}${withAgo ? '前' : ''}`;\n  }")
  ],
  'app/javascript/dashboard/helper/preChat.js' => [
    replacement("const defaultTranslations = Object.fromEntries(\n  Object.entries(i18n).filter(([key]) => key.includes('en'))\n).en;",
                'const defaultTranslations = i18n.ja;'),
    replacement("label: 'Email Id'", "label: 'メールアドレス'"),
    replacement("placeholder: 'Please enter your email address'", "placeholder: 'メールアドレスを入力してください'"),
    replacement("label: 'Full Name'", "label: '氏名'"),
    replacement("placeholder: 'Please enter your full name'", "placeholder: '氏名を入力してください'"),
    replacement("label: 'Phone Number'", "label: '電話番号'"),
    replacement("placeholder: 'Please enter your phone number'", "placeholder: '電話番号を入力してください'")
  ],
  'app/javascript/dashboard/helper/snoozeHelpers.js' => [
    replacement("} from 'date-fns';", "} from 'date-fns';\nimport { ja } from 'date-fns/locale';"),
    replacement("if (isToday(date)) return format(date, 'h.mmaaa');",
                "if (isToday(date)) return format(date, 'H:mm', { locale: ja });"),
    replacement("if (!isSameYear(date, new Date())) return format(date, 'd MMM yyyy, h.mmaaa');",
                "if (!isSameYear(date, new Date()))\n    return format(date, 'yyyy年M月d日 H:mm', { locale: ja });"),
    replacement("return format(date, 'd MMM, h.mmaaa');",
                "return format(date, 'M月d日 H:mm', { locale: ja });"),
    replacement("const formatSnoozeDate = (snoozeDate, currentDate, locale = 'en') => {",
                "const formatSnoozeDate = (snoozeDate, currentDate, locale = 'ja-JP') => {"),
    replacement('hour12: true,', 'hour12: false,'),
    replacement("? format(snoozeDate, 'EEE, d MMM, h:mm a')\n      : format(snoozeDate, 'EEE, d MMM yyyy, h:mm a');",
                "? format(snoozeDate, 'M月d日（EEE）H:mm', { locale: ja })\n      : format(snoozeDate, 'yyyy年M月d日（EEE）H:mm', { locale: ja });")
  ],
  'app/javascript/dashboard/components-next/Contacts/EmptyState/contactEmptyStateContent.js' => [
    replacement("city: 'Los Angeles'", "city: '東京'"),
    replacement("city: 'San Francisco'", "city: '大阪'"),
    replacement("city: 'Austin'", "city: '名古屋'"),
    replacement("city: 'Seattle'", "city: '札幌'"),
    replacement("city: 'Chicago'", "city: '福岡'"),
    replacement("city: 'Boston'", "city: '仙台'"),
    replacement("city: 'Denver'", "city: '広島'"),
    replacement("city: 'Miami'", "city: '那覇'"),
    replacement("country: 'United States'", "country: '日本'", 8),
    replacement("countryCode: 'US'", "countryCode: 'JP'", 8),
    replacement('"I\'m Candice, a developer focusing on building web solutions. Currently, I’m working as a Product Developer at Lumora."',
                "'Webサービスの開発と運用を担当しています。'"),
    replacement("description: 'Passionate about design and user experience.'", "description: '使いやすいデザインを大切にしています。'"),
    replacement("description: 'Avid coder and tech enthusiast.'", "description: '業務システムの改善に取り組んでいます。'"),
    replacement("description: 'Product manager with a love for innovation.'", "description: '新しいサービスの企画を担当しています。'"),
    replacement("description: 'Marketing specialist and content creator.'", "description: '広報とコンテンツ制作を担当しています。'"),
    replacement("description: 'SEO expert and analytics enthusiast.'", "description: '検索とアクセス分析を担当しています。'"),
    replacement("description: 'UI/UX designer with a flair for minimalist designs.'", "description: '画面設計と利用体験の改善を担当しています。'"),
    replacement("description: 'Entrepreneur with a background in e-commerce.'", "description: 'オンライン販売事業を運営しています。'"),
    replacement("companyName: 'Lumora'", "companyName: '株式会社サンプル'"),
    replacement("companyName: 'Designify'", "companyName: 'デザイン商事'"),
    replacement("companyName: 'CodeHub'", "companyName: 'コード企画'"),
    replacement("companyName: 'InnovaTech'", "companyName: 'イノベーション合同会社'"),
    replacement("companyName: 'Contently'", "companyName: 'コンテンツ制作所'"),
    replacement("companyName: 'OptiSearch'", "companyName: '検索研究所'"),
    replacement("companyName: 'Minimal Designs'", "companyName: 'ミニマルデザイン'"),
    replacement("companyName: 'Ecom Solutions'", "companyName: 'ECソリューションズ'"),
    replacement("name: 'Candice Matherson'", "name: '佐藤 花子'"),
    replacement("name: 'Ophelia Folkard'", "name: '鈴木 美咲'"),
    replacement("name: 'Willy Castelot'", "name: '田中 健太'"),
    replacement("name: 'Elisabeth Derington'", "name: '高橋 さくら'"),
    replacement("name: 'Olia Olenchenko'", "name: '伊藤 葵'"),
    replacement("name: 'Nathaniel Vannuchi'", "name: '渡辺 翔'"),
    replacement("name: 'Merrile Petruk'", "name: '山本 結衣'"),
    replacement("name: 'Cordell Dalinder'", "name: '中村 大輔'"),
    replacement("listContact: 'Follow-Up'", "listContact: '要フォロー'"),
    replacement("listContact: 'Prospects'", "listContact: '見込み顧客'"),
    replacement("textContact: 'Hi there!'", "textContact: 'お問い合わせありがとうございます。'"),
    replacement("textContact: 'Looking forward to connecting!'", "textContact: 'ご連絡をお待ちしています。'"),
    replacement("textContact: 'Let’s collaborate!'", "textContact: 'ぜひご一緒しましょう。'"),
    replacement("textContact: 'Let’s schedule a call.'", "textContact: '打ち合わせ日程を調整しましょう。'")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/components/WeeklyAvailability.vue' => [
    replacement("label: 'Pacific Time (US & Canada) (GMT-07:00)'", "label: '日本標準時（Asia/Tokyo）'"),
    replacement("value: 'America/Los_Angeles'", "value: 'Asia/Tokyo'"),
    replacement("0: 'Sunday'", "0: '日曜日'"),
    replacement("1: 'Monday'", "1: '月曜日'"),
    replacement("2: 'Tuesday'", "2: '火曜日'"),
    replacement("3: 'Wednesday'", "3: '水曜日'"),
    replacement("4: 'Thursday'", "4: '木曜日'"),
    replacement("5: 'Friday'", "5: '金曜日'"),
    replacement("6: 'Saturday'", "6: '土曜日'"),
    replacement("      } catch (error) {\n        useAlert(error.message || this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));\n      }",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/components/BusinessDay.vue' => [
    replacement("const groupByPeriod = slots =>\n  ['AM', 'PM']\n    .map(period => ({\n      label: period,\n      options: slots\n        .filter(s => s.endsWith(period))\n        .map(s => ({ value: s, label: s })),\n    }))",
                "const groupByPeriod = slots =>\n  ['AM', 'PM']\n    .map(period => ({\n      label: period === 'AM' ? '午前' : '午後',\n      options: slots\n        .filter(s => s.endsWith(period))\n        .map(s => ({\n          value: s,\n          label: s.replace('AM', '午前').replace('PM', '午後'),\n        })),\n    }))"),
    replacement("if (this.timeSlot.openAllDay) return '24h';", "if (this.timeSlot.openAllDay) return '24時間';"),
    replacement("return [h && `${h}h`, m && `${m}m`].filter(Boolean).join(' ') || '0m';",
                "return [h && `${h}時間`, m && `${m}分`].filter(Boolean).join(' ') || '0分';")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/businessHour.js' => [
    replacement("  /* \n", "  /*\n"),
    replacement("export const timeZoneOptions = () => {\n  return Object.keys(timeZoneData).map(key => ({\n    label: key,\n    value: timeZoneData[key],\n  }));\n};",
                "const localizedTimeZoneName = timeZone =>\n  new Intl.DateTimeFormat('ja-JP', {\n    timeZone,\n    timeZoneName: 'longGeneric',\n  })\n    .formatToParts(new Date())\n    .find(part => part.type === 'timeZoneName')?.value || timeZone;\n\nexport const timeZoneOptions = () => {\n  return Object.values(timeZoneData).map(timeZone => ({\n    label: `${localizedTimeZoneName(timeZone)}（${timeZone}）`,\n    value: timeZone,\n  }));\n};")
  ],
  'app/javascript/v3/components/Form/Input.vue' => [
    replacement(":aria-label=\"isPasswordVisible ? 'Hide password' : 'Show password'\"",
                ":aria-label=\"isPasswordVisible ? 'パスワードを隠す' : 'パスワードを表示する'\"")
  ],
  'app/javascript/dashboard/components/widgets/conversation/MessagesView.vue' => [
    replacement('alt="Someone is typing"', 'alt="入力中"')
  ],
  'app/javascript/v3/api/auth.js' => [
    replacement("  throwErrorMessage,\n", ''),
    replacement('const loginError = new Error(parseAPIErrorResponse(error));',
                "const parsedError = parseAPIErrorResponse(error);\n    const loginError = new Error(\n      typeof parsedError === 'string' && /[ぁ-んァ-ヶ一-龠々ー]/.test(parsedError)\n        ? parsedError\n        : 'ログインできませんでした。入力内容を確認して、もう一度お試しください。'\n    );"),
    replacement('throwErrorMessage(error);', "throw new Error('操作を完了できませんでした。もう一度お試しください。');", 3)
  ],
  'app/javascript/v3/views/auth/password/Edit.vue' => [
    replacement("        .catch(error => {\n          this.showAlertMessage(\n            error?.message || this.$t('SET_NEW_PASSWORD.API.ERROR_MESSAGE')\n          );\n        });",
                "        .catch(() => {\n          this.showAlertMessage(this.$t('SET_NEW_PASSWORD.API.ERROR_MESSAGE'));\n        });")
  ],
  'app/javascript/v3/views/auth/reset/password/Index.vue' => [
    replacement("        .then(res => {\n          let successMessage = this.$t('RESET_PASSWORD.API.SUCCESS_MESSAGE');\n          if (res.data && res.data.message) {\n            successMessage = res.data.message;\n          }\n          this.showAlertMessage(successMessage);\n        })\n        .catch(error => {\n          let errorMessage = this.$t('RESET_PASSWORD.API.ERROR_MESSAGE');\n          if (error?.response?.data?.message) {\n            errorMessage = error.response.data.message;\n          }\n          this.showAlertMessage(errorMessage);\n        });",
                "        .then(() => {\n          this.showAlertMessage(this.$t('RESET_PASSWORD.API.SUCCESS_MESSAGE'));\n        })\n        .catch(() => {\n          this.showAlertMessage(this.$t('RESET_PASSWORD.API.ERROR_MESSAGE'));\n        });")
  ],
  'app/javascript/v3/views/auth/signup/components/Signup/Form.vue' => [
    replacement("  } catch (error) {\n    const errorMessage = error?.message || t('REGISTER.API.ERROR_MESSAGE');",
                "  } catch {\n    const errorMessage = t('REGISTER.API.ERROR_MESSAGE');")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Twitter.vue' => [
    replacement('label="Sign in with Twitter"', 'label="X（旧Twitter）で接続"')
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Facebook.vue' => [
    replacement('alt="Facebook-logo"', 'alt="Facebookロゴ"')
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Website.vue' => [
    replacement("      } catch (error) {\n        useAlert(\n          error.message ||\n            this.$t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.API.ERROR_MESSAGE')\n        );",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.API.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/profile/AudioAlertTone.vue' => [
    replacement("label: 'Ding'", "label: 'ディン'"),
    replacement("label: 'Bell'", "label: 'ベル'"),
    replacement("label: 'Chime'", "label: 'チャイム'"),
    replacement("label: 'Magic'", "label: 'マジック'"),
    replacement("label: 'Ping'", "label: 'ピング'")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/data/importSources.js' => [
    replacement("label: 'File import'", "label: 'ファイルからインポート'")
  ],
  'app/javascript/dashboard/components/auth/SessionLimitOverlay.vue' => [
    replacement("import { format, parseISO } from 'date-fns';", "import { format, parseISO } from 'date-fns';\nimport { ja } from 'date-fns/locale';"),
    replacement("return format(parseISO(dateStr), 'MMMM d, yyyy');", "return format(parseISO(dateStr), 'yyyy年M月d日', { locale: ja });"),
    replacement("return format(parseISO(dateStr), 'hh:mma');", "return format(parseISO(dateStr), 'HH:mm', { locale: ja });"),
    replacement("return parts.join(' on ') || t('SESSION_LIMIT.UNKNOWN_DEVICE');", "return parts.join(' / ') || t('SESSION_LIMIT.UNKNOWN_DEVICE');")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/profile/ActiveSessions.vue' => [
    replacement("import { formatDistanceToNow, parseISO } from 'date-fns';", "import { formatDistanceToNow, parseISO } from 'date-fns';\nimport { ja } from 'date-fns/locale';"),
    replacement("return formatDistanceToNow(parseISO(dateStr), { addSuffix: true });", "return formatDistanceToNow(parseISO(dateStr), { addSuffix: true, locale: ja });"),
    replacement("parts.join(' on ')", "parts.join(' / ')")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/profile/Index.vue' => [
    replacement("title: this.$t(\n            'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.ENTER_KEY.HEADING'\n          ),",
                "titleKey: 'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.ENTER_KEY.HEADING',"),
    replacement("description: this.$t(\n            'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.ENTER_KEY.CONTENT'\n          ),",
                "descriptionKey: 'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.ENTER_KEY.CONTENT',"),
    replacement("title: this.$t(\n            'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.CMD_ENTER_KEY.HEADING'\n          ),",
                "titleKey: 'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.CMD_ENTER_KEY.HEADING',"),
    replacement("description: this.$t(\n            'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.CMD_ENTER_KEY.CONTENT'\n          ),",
                "descriptionKey: 'PROFILE_SETTINGS.FORM.SEND_MESSAGE.CARD.CMD_ENTER_KEY.CONTENT',"),
    replacement("'/assets/images/dashboard/profile/hot-key-enter.svg'",
                "'/assets/images/dashboard/profile/hot-key-enter.svg?v=54f1dbcfeda0'"),
    replacement("'/assets/images/dashboard/profile/hot-key-enter-dark.svg'",
                "'/assets/images/dashboard/profile/hot-key-enter-dark.svg?v=17b3f666561c'"),
    replacement("'/assets/images/dashboard/profile/hot-key-ctrl-enter.svg'",
                "'/assets/images/dashboard/profile/hot-key-ctrl-enter.svg?v=48fd4784ddb0'"),
    replacement("'/assets/images/dashboard/profile/hot-key-ctrl-enter-dark.svg'",
                "'/assets/images/dashboard/profile/hot-key-ctrl-enter-dark.svg?v=492c9a0fca1f'"),
    replacement(':label="hotKey.title"', ':label="$t(hotKey.titleKey)"'),
    replacement(':description="hotKey.description"', ':description="$t(hotKey.descriptionKey)"'),
    replacement(':alt="`Light themed image for ${hotKey.title}`"',
                ':alt="`${$t(hotKey.titleKey)}のキー操作例`"'),
    replacement(':alt="`Dark themed image for ${hotKey.title}`"',
                ':alt="`${$t(hotKey.titleKey)}のキー操作例`"')
  ],
  'public/assets/images/dashboard/profile/hot-key-enter.svg' => [
    replacement('</g>', "</g>\n<rect x=\"224\" y=\"56\" width=\"78\" height=\"28\" rx=\"6\" fill=\"#4B7DFB\"/>\n<text x=\"263\" y=\"70\" fill=\"white\" font-family=\"sans-serif\" font-size=\"12\" font-weight=\"600\" text-anchor=\"middle\" dominant-baseline=\"middle\">送信（↵）</text>")
  ],
  'public/assets/images/dashboard/profile/hot-key-enter-dark.svg' => [
    replacement('</g>', "</g>\n<rect x=\"224\" y=\"56\" width=\"78\" height=\"28\" rx=\"6\" fill=\"#4B7DFB\"/>\n<text x=\"263\" y=\"70\" fill=\"white\" font-family=\"sans-serif\" font-size=\"12\" font-weight=\"600\" text-anchor=\"middle\" dominant-baseline=\"middle\">送信（↵）</text>")
  ],
  'public/assets/images/dashboard/profile/hot-key-ctrl-enter.svg' => [
    replacement('</g>', "</g>\n<rect x=\"198\" y=\"56\" width=\"104\" height=\"28\" rx=\"6\" fill=\"#4B7DFB\"/>\n<text x=\"250\" y=\"70\" fill=\"white\" font-family=\"sans-serif\" font-size=\"11\" font-weight=\"600\" text-anchor=\"middle\" dominant-baseline=\"middle\">送信（⌘+↵）</text>")
  ],
  'public/assets/images/dashboard/profile/hot-key-ctrl-enter-dark.svg' => [
    replacement('</g>', "</g>\n<rect x=\"198\" y=\"56\" width=\"104\" height=\"28\" rx=\"6\" fill=\"#4B7DFB\"/>\n<text x=\"250\" y=\"70\" fill=\"white\" font-family=\"sans-serif\" font-size=\"11\" font-weight=\"600\" text-anchor=\"middle\" dominant-baseline=\"middle\">送信（⌘+↵）</text>")
  ],
  'app/javascript/dashboard/components/widgets/conversation/advancedFilterItems/languages.js' => [
    replacement("export const getLanguageName = (languageCode = '') => {\n  const languageObj =\n    languages.find(language => language.id === languageCode) || {};\n  return languageObj.name || '';\n};",
                "const languageDisplayNames = new Intl.DisplayNames(['ja'], { type: 'language' });\nconst localizedLanguages = languages.map(({ id }) => ({\n  id,\n  name: languageDisplayNames.of(id.replace('_', '-')) || id,\n}));\n\nexport const getLanguageName = (languageCode = '') => {\n  const languageObj =\n    localizedLanguages.find(language => language.id === languageCode) || {};\n  return languageObj.name || '';\n};"),
    replacement('export default languages;', 'export default localizedLanguages;')
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/CustomerSatisfactionPage.vue' => [
    replacement("templateButtonText: 'Please rate us'", "templateButtonText: '評価をお願いします'"),
    replacement("templateLanguage: 'en'", "templateLanguage: 'ja'"),
    replacement("button_text: buttonText = 'Please rate us'", "button_text: buttonText = '評価をお願いします'"),
    replacement("language = 'en'", "language = 'ja'"),
    replacement("      } catch (error) {\n        const errorMessage =\n          error.response?.data?.error ||\n          t('INBOX_MGMT.CSAT.TEMPLATE_CREATION.ERROR_MESSAGE');\n        useAlert(errorMessage);",
                "      } catch {\n        useAlert(t('INBOX_MGMT.CSAT.TEMPLATE_CREATION.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/FinishSetup.vue' => [
    replacement('alt="WhatsApp QR Code"', 'alt="WhatsApp用QRコード"'),
    replacement('alt="Messenger QR Code"', 'alt="Messenger用QRコード"'),
    replacement('alt="Telegram QR Code"', 'alt="Telegram用QRコード"')
  ],
  'app/javascript/dashboard/routes/dashboard/settings/profile/MfaSetupWizard.vue' => [
    replacement('const codesText = `Chatwoot Two-Factor Authentication Backup Codes\\n\\n${props.backupCodes.join(\'\\n\')}\\n\\nKeep these codes in a safe place.`;',
                'const codesText = `トイバコ 二要素認証バックアップコード\\n\\n${props.backupCodes.join(\'\\n\')}\\n\\nこれらのコードは安全な場所に保管してください。`;'),
    replacement("a.download = 'chatwoot-backup-codes.txt';", "a.download = 'toybaco-backup-codes.txt';"),
    replacement("verificationError.value = error || t('MFA_SETTINGS.SETUP.INVALID_CODE');",
                "verificationError.value = t('MFA_SETTINGS.SETUP.INVALID_CODE');"),
    replacement('alt="MFA QR Code"', 'alt="多要素認証用QRコード"')
  ],
  'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactForm.vue' => [
    replacement("        } else if (error instanceof ExceptionWithMessage) {\n          useAlert(error.data);",
                "        } else if (error instanceof ExceptionWithMessage) {\n          useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));"),
    replacement("      } catch (error) {\n        useAlert(\n          error.message\n            ? error.message\n            : this.$t('CONTACT_FORM.DELETE_AVATAR.API.ERROR_MESSAGE')\n        );\n      }",
                "      } catch {\n        useAlert(this.$t('CONTACT_FORM.DELETE_AVATAR.API.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactInfo.vue' => [
    replacement("          if (detail) {\n            useAlert(detail);", "          if (detail) {\n            useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));"),
    replacement("        } else if (error instanceof ExceptionWithMessage) {\n          useAlert(error.data);\n        } else {\n          useAlert(error.message || this.$t('CONTACT_FORM.ERROR_MESSAGE'));",
                "        } else if (error instanceof ExceptionWithMessage) {\n          useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));\n        } else {\n          useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/routes/dashboard/conversation/customAttributes/CustomAttributes.vue' => [
    replacement("  } catch (error) {\n    const errorMessage =\n      error?.response?.message || t('CUSTOM_ATTRIBUTES.FORM.UPDATE.ERROR');\n    useAlert(errorMessage);",
                "  } catch {\n    useAlert(t('CUSTOM_ATTRIBUTES.FORM.UPDATE.ERROR'));"),
    replacement("  } catch (error) {\n    const errorMessage =\n      error?.response?.message || t('CUSTOM_ATTRIBUTES.FORM.DELETE.ERROR');\n    useAlert(errorMessage);",
                "  } catch {\n    useAlert(t('CUSTOM_ATTRIBUTES.FORM.DELETE.ERROR'));")
  ],
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxChannelForm.vue' => [
    replacement("  } catch (error) {\n    useAlert(error?.message || config.errorMessage);",
                "  } catch {\n    useAlert(config.errorMessage);")
  ],
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxFacebookForm.vue' => [
    replacement("import { parseAPIErrorResponse } from 'dashboard/store/utils/api';\n", ''),
    replacement("  } catch (error) {\n    useAlert(parseAPIErrorResponse(error) || t('ONBOARDING_INBOX_SETUP.ERROR'));",
                "  } catch {\n    useAlert(t('ONBOARDING_INBOX_SETUP.ERROR'));")
  ],
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/useChannelConnect.js' => [
    replacement("import { parseAPIErrorResponse } from 'dashboard/store/utils/api';\n", ''),
    replacement("    } catch (error) {\n      useAlert(\n        parseAPIErrorResponse(error) || t('ONBOARDING_INBOX_SETUP.ERROR')\n      );",
                "    } catch {\n      useAlert(t('ONBOARDING_INBOX_SETUP.ERROR'));")
  ],
  'app/javascript/dashboard/routes/dashboard/onboarding/shared/constants.js' => [
    replacement("label: '1 - 10'", "label: '1～10名'"),
    replacement("label: '11 - 50'", "label: '11～50名'"),
    replacement("label: '51 - 200'", "label: '51～200名'"),
    replacement("label: '201 - 500'", "label: '201～500名'"),
    replacement("label: '500+'", "label: '501名以上'"),
    replacement("label: 'Aerospace & Defense'", "label: '航空・防衛'"),
    replacement("label: 'Agriculture & Food'", "label: '農業・食品'"),
    replacement("label: 'Automotive & Transportation'", "label: '自動車・運輸'"),
    replacement("label: 'Chemicals & Materials'", "label: '化学・素材'"),
    replacement("label: 'Construction & Built Environment'", "label: '建設・建築環境'"),
    replacement("label: 'Consumer Packaged Goods (CPG)'", "label: '消費財（CPG）'"),
    replacement("label: 'Education'", "label: '教育'"),
    replacement("label: 'Entertainment'", "label: 'エンターテインメント'"),
    replacement("label: 'Finance'", "label: '金融'"),
    replacement("label: 'Government & Nonprofit'", "label: '行政・非営利団体'"),
    replacement("label: 'Healthcare'", "label: '医療'"),
    replacement("label: 'Hospitality & Tourism'", "label: '宿泊・観光'"),
    replacement("label: 'Industrial & Energy'", "label: '産業・エネルギー'"),
    replacement("label: 'Legal & Compliance'", "label: '法務・コンプライアンス'"),
    replacement("label: 'Lifestyle & Leisure'", "label: 'ライフスタイル・レジャー'"),
    replacement("label: 'Logistics & Supply Chain'", "label: '物流・サプライチェーン'"),
    replacement("label: 'Luxury & Fashion'", "label: 'ラグジュアリー・ファッション'"),
    replacement("label: 'News & Media'", "label: 'ニュース・メディア'"),
    replacement("label: 'Professional Services & Agencies'", "label: '専門サービス・代理店'"),
    replacement("label: 'Real Estate & PropTech'", "label: '不動産・PropTech'"),
    replacement("label: 'Retail & E-commerce'", "label: '小売・EC'"),
    replacement("label: 'Sports'", "label: 'スポーツ'"),
    replacement("label: 'Technology'", "label: 'テクノロジー'"),
    replacement("label: 'Telecommunications'", "label: '通信'"),
    replacement("label: 'Google'", "label: 'Google（検索）'"),
    replacement("label: 'Reddit'", "label: 'Reddit（掲示板）'"),
    replacement("label: 'Twitter/X'", "label: 'X（旧Twitter）'"),
    replacement("label: 'LinkedIn'", "label: 'LinkedIn（ビジネスSNS）'"),
    replacement("label: 'Friend/Colleague'", "label: '友人・同僚'"),
    replacement("label: 'Blog/Article'", "label: 'ブログ・記事'"),
    replacement("label: 'GitHub'", "label: 'GitHub（開発者向け）'"),
    replacement("label: 'Founder/CEO'", "label: '創業者・CEO'"),
    replacement("label: 'Product Manager'", "label: 'プロダクトマネージャー'"),
    replacement("label: 'Engineering'", "label: 'エンジニアリング'"),
    replacement("label: 'Support Lead'", "label: 'サポート責任者'"),
    replacement("label: 'Marketing'", "label: 'マーケティング'"),
    replacement("label: 'Sales'", "label: '営業'"),
    replacement("label: 'Other'", "label: 'その他'", 3)
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue' => [
    replacement("message: apiError || error.message,", "message: this.$t('INBOX_MGMT.ACCOUNT_HEALTH.ERRORS.GENERIC_DESCRIPTION'),"),
    replacement("      } catch (error) {\n        useAlert(\n          error.response?.data?.error ||\n            error.message ||\n            this.$t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.REGISTER_ERROR')\n        );",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.REGISTER_ERROR'));"),
    replacement("      } catch (error) {\n        useAlert(error.message || this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));\n      }",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));\n      }"),
    replacement("      } catch (error) {\n        useAlert(\n          error.message\n            ? error.message\n            : this.$t('INBOX_MGMT.DELETE.API.AVATAR_ERROR_MESSAGE')\n        );\n      }",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.DELETE.API.AVATAR_ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/AddAgents.vue' => [
    replacement("      } catch (error) {\n        useAlert(error.message);\n      }",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/teams/Create/AddAgents.vue' => [
    replacement("      } catch (error) {\n        useAlert(error.message);\n      }",
                "      } catch {\n        useAlert(this.$t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/teams/Edit/EditAgents.vue' => [
    replacement("      } catch (error) {\n        useAlert(error.message);\n      }",
                "      } catch {\n        useAlert(this.$t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/labels/AddLabel.vue' => [
    replacement("      } catch (error) {\n        const errorMessage =\n          error.message || this.$t('LABEL_MGMT.ADD.API.ERROR_MESSAGE');\n        useAlert(errorMessage);",
                "      } catch {\n        useAlert(this.$t('LABEL_MGMT.ADD.API.ERROR_MESSAGE'));")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/ImapSettings.vue' => [
    replacement("      } catch (error) {\n        useAlert(error.message);\n      }",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.IMAP.EDIT.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/SmtpSettings.vue' => [
    replacement("      } catch (error) {\n        useAlert(\n          error.message || this.$t('INBOX_MGMT.SMTP.EDIT.ERROR_MESSAGE')\n        );\n      }",
                "      } catch {\n        useAlert(this.$t('INBOX_MGMT.SMTP.EDIT.ERROR_MESSAGE'));\n      }")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/automation/Index.vue' => [
    replacement("  } catch (error) {\n    const fallbackMessage =\n      mode === 'edit'\n        ? t('AUTOMATION.EDIT.API.ERROR_MESSAGE')\n        : t('AUTOMATION.ADD.API.ERROR_MESSAGE');\n    useAlert(error?.response?.data?.error || fallbackMessage);",
                "  } catch {\n    const fallbackMessage =\n      mode === 'edit'\n        ? t('AUTOMATION.EDIT.API.ERROR_MESSAGE')\n        : t('AUTOMATION.ADD.API.ERROR_MESSAGE');\n    useAlert(fallbackMessage);")
  ],
  'app/javascript/dashboard/routes/dashboard/settings/automation/operators.js' => [
    replacement("label: 'Equal to'", "label: '等しい'", 5),
    replacement("label: 'Not equal to'", "label: '等しくない'", 5),
    replacement("label: 'Contains'", "label: '含む'", 2),
    replacement("label: 'Does not contain'", "label: '含まない'", 2),
    replacement("label: 'Is present'", "label: '値がある'", 2),
    replacement("label: 'Is not present'", "label: '値がない'", 2),
    replacement("label: 'Is greater than'", "label: 'より大きい'", 2),
    replacement("label: 'Is less than'", "label: 'より小さい'", 2),
    replacement("label: 'Is x days before'", "label: '指定日数より前'"),
    replacement("label: 'Starts With'", "label: '次で始まる'")
  ]
}.freeze

FORBIDDEN_VISIBLE = {
  'app/javascript/dashboard/components/ModalHeader.vue' => ['alt="No image"'],
  'app/javascript/dashboard/components/auth/MfaVerification.vue' => ['parseAPIErrorResponse(error)'],
  'app/javascript/dashboard/components/widgets/conversation/EmptyState/EmptyStateMessage.vue' =>
    ['alt="No Chat dark"', 'alt="No Chat"'],
  'app/javascript/dashboard/components/widgets/conversation/OnboardingView.vue' =>
    ['image-alt="Omnichannel"', 'image-alt="Teams"', 'image-alt="Canned responses"', 'image-alt="Labels"'],
  'app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue' =>
    ['error?.response?.data?.error'],
  'app/javascript/dashboard/components/widgets/conversation/ContentTemplates/ContentTemplatesPicker.vue' =>
    ["template.category || 'utility'", 'toLocaleDateString()'],
  'app/javascript/dashboard/components/widgets/conversation/components/GalleryView.vue' =>
    ["'LLL d yyyy, h:mm a'", "? 'You'"],
  'app/javascript/dashboard/components/widgets/conversation/ShopifyOrderItem.vue' =>
    ["'MMM d, yyyy'", "Intl.NumberFormat('en'"],
  'app/javascript/dashboard/components/widgets/conversation/contextMenu/Index.vue' =>
    ["name: 'None'", "email: 'None'"],
  'app/javascript/dashboard/components/widgets/conversation/ConversationCallButton.vue' =>
    ['useAlert(error?.message'],
  'app/javascript/dashboard/components-next/Contacts/Pages/ContactsList.vue' => ['useAlert(error.data)'],
  'app/javascript/dashboard/components-next/Contacts/ContactsHeader/ContactListHeaderWrapper.vue' =>
    ['useAlert(error.data)', 'error.message ??', 'error.message ||'],
  'app/javascript/dashboard/components-next/Contacts/Pages/ContactDetails.vue' => ['error.message'],
  'app/javascript/dashboard/components-next/Contacts/VoiceCallButton.vue' =>
    ['useAlert(error?.message', 'const apiError = error?.message'],
  'app/javascript/dashboard/components-next/NewConversation/ComposeConversation.vue' =>
    ['parseAPIErrorResponse', 'ExceptionWithMessage', 'error.data'],
  'app/javascript/dashboard/components/widgets/FilterInput/FilterOperatorTypes.js' =>
    ["label: 'Equal to'", "label: 'Not equal to'", "label: 'Contains'", "label: 'Is present'"],
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactNotes.vue' => ["|| 'Bot'"],
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/components/ContactNoteItem.vue' => ["|| 'Bot'"],
  'app/javascript/dashboard/components-next/Contacts/ContactsSidebar/ContactCustomAttributeItem.vue' =>
    ['error?.response?.message'],
  'app/javascript/dashboard/components-next/Campaigns/EmptyState/CampaignEmptyStateContent.js' => [
    'Chatbot Assistance', 'Pricing Information Support', 'Product Setup Assistance',
    'General Assistance Campaign', 'Customer Feedback Request', 'Welcome New Customer',
    'New Business Welcome', 'New Member Onboarding', 'PaperLayer', 'Alexa Rivera',
    'Jamie Lee', "name: 'Chatwoot'", 'Chris Barlow', 'Hello!', 'Hi! Chatwoot',
    'Welcome aboard', 'We’re excited', 'Welcome to the team'
  ],
  'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Category/categoryEmptyStateContent.js' => [
    "name: 'Getting Started'", "name: 'Advanced Features'", "name: 'FAQs'",
    "name: 'Troubleshooting'", "name: 'Community Guidelines'",
    "name: 'Account Management'", "name: 'Security Tips'", "name: 'Integrations'",
    "name: 'Billing & Payments'", "name: 'Customization'", "name: 'Notifications'",
    "name: 'Privacy'", "name: 'Mobile App'", "name: 'Beta Features'",
    'Quick guides to help', 'Explore advanced features', 'Commonly asked questions',
    'Resolve common issues', 'Rules and practices', 'Manage your account',
    'Best practices for securing', 'Connect to third-party', 'Manage your billing',
    'Personalize and customize', 'Adjust your notification', 'Understand how your data',
    'Guides for using the mobile', 'Learn about new experimental'
  ],
  'app/javascript/dashboard/components-next/HelpCenter/CategoryCard/CategoryCard.vue' =>
    ["label: 'Edit'", "label: 'Delete'", 'No description added'],
  'app/javascript/dashboard/components-next/HelpCenter/EmptyState/Portal/portalEmptyStateContent.js' => [
    'How to get an SSL certificate', 'Setting up your first Help Center portal',
    'Best practices for organizing your Help Center content',
    'Customizing the appearance of your Help Center',
    'Integrating your Help Center with third-party tools',
    'Managing user permissions in your Help Center', 'Creating and managing FAQ sections',
    'Implementing search functionality in your Help Center',
    'Analyzing Help Center usage metrics',
    'Setting up multilingual support in your Help Center',
    'Creating interactive tutorials for your products',
    'Implementing a feedback system in your Help Center',
    'Optimizing Help Center content for SEO',
    'Creating a knowledge base for internal teams',
    "availableName: 'Michael'", "availableName: 'John'", "availableName: 'Fernando'",
    "availableName: 'Jane'", "availableName: 'Sarah'", "availableName: 'Alex'",
    "availableName: 'Emily'", "availableName: 'David'", "availableName: 'Rachel'",
    "availableName: 'Carlos'", "availableName: 'Olivia'", "availableName: 'Nathan'",
    "availableName: 'Sophia'", "availableName: 'Daniel'",
    "name: 'Setup & Configuration'", "name: 'Onboarding'", "name: 'Best Practices'",
    "name: 'Design'", "name: 'Integrations'", "name: 'Administration'",
    "name: 'Content Management'", "name: 'Features'", "name: 'Analytics'",
    "name: 'Localization'", "name: 'Education'", "name: 'User Engagement'",
    "name: 'SEO'", "name: 'Internal Resources'"
  ],
  'app/javascript/dashboard/components-next/HelpCenter/PortalSwitcher/CreatePortalDialog.vue' =>
    ["locale: 'en'", 'error?.message ||'],
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoriesPage.vue' =>
    ['error.message ||'],
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoryDialog.vue' =>
    ['error?.message ||'],
  'app/javascript/dashboard/components-next/HelpCenter/Pages/CategoryPage/EditCategoryDialog.vue' =>
    ['error?.message ||'],
  'app/javascript/dashboard/routes/dashboard/helpcenter/pages/PortalsSettingsIndexPage.vue' =>
    ['error?.message ||'],
  'app/javascript/dashboard/modules/conversations/components/MessageContextMenu.vue' =>
    ['parseAPIErrorResponse', "accountLocale || 'en'"],
  'app/javascript/shared/constants/messages.js' => %w[Conversation\ Id Contact\ name Agent\ email Inbox\ name],
  'app/javascript/shared/constants/countries.js' => ['export default countries;'],
  'app/javascript/shared/helpers/timeHelper.js' =>
    ["dateFormat = 'h:mm a'", "dateFormat = 'MMM d, yyyy'", "formatDistanceToNow(unixTime, { addSuffix: true })"],
  'app/javascript/dashboard/helper/preChat.js' =>
    ["key.includes('en')", "label: 'Email Id'", 'Please enter your email address', 'Please enter your full name'],
  'app/javascript/dashboard/helper/snoozeHelpers.js' =>
    ["locale = 'en'", 'hour12: true', "'d MMM, h.mmaaa'", "'EEE, d MMM, h:mm a'"],
  'app/javascript/dashboard/components-next/Contacts/EmptyState/contactEmptyStateContent.js' => [
    'United States', 'Passionate about', 'Product manager', 'Marketing specialist', 'SEO expert',
    'UI/UX designer', 'Entrepreneur with', 'Looking forward', 'Let’s'
  ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/components/WeeklyAvailability.vue' =>
    ['Pacific Time (US & Canada)', 'America/Los_Angeles',
     'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
  'app/javascript/v3/components/Form/Input.vue' => ['Hide password', 'Show password'],
  'app/javascript/dashboard/components/widgets/conversation/MessagesView.vue' => ['Someone is typing'],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Twitter.vue' => ['Sign in with Twitter'],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Facebook.vue' => ['alt="Facebook-logo"'],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Website.vue' => ['error.message ||'],
  'app/javascript/dashboard/routes/dashboard/settings/data/importSources.js' => ['File import'],
  'app/javascript/dashboard/components/auth/SessionLimitOverlay.vue' => ["parts.join(' on ')", 'MMMM d, yyyy', 'hh:mma'],
  'app/javascript/dashboard/routes/dashboard/settings/profile/ActiveSessions.vue' => ["parts.join(' on ')", 'formatDistanceToNow(parseISO(dateStr), { addSuffix: true })'],
  'app/javascript/dashboard/routes/dashboard/settings/profile/Index.vue' =>
    [
      'Light themed image for',
      'Dark themed image for',
      ':label="hotKey.title"',
      ':description="hotKey.description"',
      '${hotKey.title}',
      "'/assets/images/dashboard/profile/hot-key-enter.svg'",
      "'/assets/images/dashboard/profile/hot-key-enter-dark.svg'",
      "'/assets/images/dashboard/profile/hot-key-ctrl-enter.svg'",
      "'/assets/images/dashboard/profile/hot-key-ctrl-enter-dark.svg'"
    ],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/CustomerSatisfactionPage.vue' =>
    ['Please rate us', "templateLanguage: 'en'", "language = 'en'"],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/FinishSetup.vue' =>
    ['WhatsApp QR Code', 'Messenger QR Code', 'Telegram QR Code'],
  'app/javascript/dashboard/routes/dashboard/settings/profile/MfaSetupWizard.vue' =>
    ['Chatwoot Two-Factor Authentication', 'Keep these codes in a safe place', 'alt="MFA QR Code"',
     "verificationError.value = error ||"],
  'app/javascript/dashboard/routes/dashboard/conversation/contact/ContactForm.vue' =>
    ['useAlert(error.data)', 'error.message'],
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxChannelForm.vue' =>
    ['error?.message || config.errorMessage'],
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/InboxFacebookForm.vue' =>
    ['parseAPIErrorResponse'],
  'app/javascript/dashboard/routes/dashboard/onboarding/inbox-setup/useChannelConnect.js' =>
    ['parseAPIErrorResponse'],
  'app/javascript/dashboard/routes/dashboard/onboarding/shared/constants.js' => [
    "label: '1 - 10'", "label: '11 - 50'", "label: '51 - 200'",
    "label: '201 - 500'", "label: '500+'", "label: 'Aerospace & Defense'",
    "label: 'Agriculture & Food'", "label: 'Automotive & Transportation'",
    "label: 'Chemicals & Materials'", "label: 'Construction & Built Environment'",
    "label: 'Consumer Packaged Goods (CPG)'", "label: 'Education'",
    "label: 'Entertainment'", "label: 'Finance'", "label: 'Government & Nonprofit'",
    "label: 'Healthcare'", "label: 'Hospitality & Tourism'", "label: 'Industrial & Energy'",
    "label: 'Legal & Compliance'", "label: 'Lifestyle & Leisure'",
    "label: 'Logistics & Supply Chain'", "label: 'Luxury & Fashion'",
    "label: 'News & Media'", "label: 'Professional Services & Agencies'",
    "label: 'Real Estate & PropTech'", "label: 'Retail & E-commerce'",
    "label: 'Sports'", "label: 'Technology'", "label: 'Telecommunications'",
    "label: 'Other'", "label: 'Google'", "label: 'Reddit'", "label: 'Twitter/X'",
    "label: 'LinkedIn'", "label: 'Friend/Colleague'", "label: 'Blog/Article'",
    "label: 'GitHub'", "label: 'Founder/CEO'", "label: 'Product Manager'",
    "label: 'Engineering'", "label: 'Support Lead'", "label: 'Marketing'",
    "label: 'Sales'"
  ],
  'app/javascript/dashboard/routes/dashboard/settings/teams/Create/AddAgents.vue' => ['useAlert(error.message)'],
  'app/javascript/dashboard/routes/dashboard/settings/teams/Edit/EditAgents.vue' => ['useAlert(error.message)'],
  'app/javascript/dashboard/routes/dashboard/settings/labels/AddLabel.vue' => ['error.message ||'],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/ImapSettings.vue' => ['useAlert(error.message)'],
  'app/javascript/dashboard/routes/dashboard/settings/inbox/SmtpSettings.vue' => ['error.message ||'],
  'app/javascript/dashboard/routes/dashboard/settings/automation/Index.vue' =>
    ['error?.response?.data?.error'],
  'app/javascript/dashboard/routes/dashboard/settings/automation/operators.js' =>
    ["label: 'Equal to'", "label: 'Not equal to'", "label: 'Contains'", "label: 'Starts With'"],
  'app/javascript/v3/api/auth.js' => ['throwErrorMessage(error)'],
  'app/javascript/v3/views/auth/password/Edit.vue' => ['error?.message'],
  'app/javascript/v3/views/auth/reset/password/Index.vue' =>
    ['res.data.message', 'error.response.data.message'],
  'app/javascript/v3/views/auth/signup/components/Signup/Form.vue' => ['error?.message']
}.freeze

abort 'replacement/source file sets differ' unless REPLACEMENTS.keys.sort == SOURCE_SHA256.keys.sort

expected_surfaces = %w[
  auth onboarding conversations contacts inbox automation campaigns helpcenter
  captain profile data labels teams
]
abort 'major route surface set differs' unless MAJOR_ROUTE_ANCHORS.keys == expected_surfaces

captain_surface = MAJOR_ROUTE_ANCHORS.fetch('captain')
abort 'Captain must remain parked until staging confirms the feature is enabled' unless
  captain_surface.fetch(:release_state) == 'parked_pending_staging_feature_confirmation' &&
  captain_surface.fetch(:required_overlays).empty?

surface_overlays = MAJOR_ROUTE_ANCHORS.values.flat_map { |surface| surface.fetch(:required_overlays) }
classified_overlays = surface_overlays + SHARED_OVERRIDES
duplicate_classifications = classified_overlays.group_by(&:itself).select { |_path, owners| owners.length > 1 }.keys
abort "active Japanese overrides have duplicate surface/shared classifications: #{duplicate_classifications.join(', ')}" unless
  duplicate_classifications.empty?

unclassified_overlays = SOURCE_SHA256.keys - classified_overlays
unknown_classifications = classified_overlays - SOURCE_SHA256.keys
abort "active Japanese overrides are not assigned to a surface/shared bucket: #{unclassified_overlays.join(', ')}" unless
  unclassified_overlays.empty?
abort "surface/shared buckets reference unknown active Japanese overrides: #{unknown_classifications.join(', ')}" unless
  unknown_classifications.empty?

MAJOR_ROUTE_ANCHORS.each do |surface_name, surface|
  route_source = surface.fetch(:route_source)
  route = SOURCE_ROOT.join(route_source)
  abort "major route source is missing: #{surface_name} #{route_source}" unless route.file? && !route.symlink?

  route_content = route.read(encoding: Encoding::UTF_8)
  surface.fetch(:anchors).each do |anchor|
    abort "major route anchor is missing: #{surface_name} #{route_source} #{anchor.inspect}" unless
      route_content.include?(anchor)
  end

  surface.fetch(:required_overlays).each do |relative|
    abort "major route requires an unpinned override: #{surface_name} #{relative}" unless SOURCE_SHA256.key?(relative)
    abort "major route requires an override without replacements: #{surface_name} #{relative}" unless REPLACEMENTS.key?(relative)
  end
end

SOURCE_SHA256.sort.each do |relative, expected_sha|
  source = SOURCE_ROOT.join(relative)
  abort "pinned Chatwoot source file is missing: #{relative}" unless source.file? && !source.symlink?
  actual_sha = Digest::SHA256.file(source).hexdigest
  abort "pinned Chatwoot source hash mismatch: #{relative} #{actual_sha}" unless actual_sha == expected_sha

  content = source.read(encoding: Encoding::UTF_8)
  REPLACEMENTS.fetch(relative).each do |before, after, expected_count|
    actual_count = content.scan(Regexp.new(Regexp.escape(before))).length
    abort "replacement source count mismatch: #{relative} expected=#{expected_count} actual=#{actual_count} #{before.inspect}" unless
      actual_count == expected_count
    content = content.gsub(before, after)
  end
  FORBIDDEN_VISIBLE.fetch(relative, []).each do |forbidden|
    abort "visible English remains after generation: #{relative} #{forbidden.inspect}" if content.include?(forbidden)
  end

  output = OUTPUT_ROOT.join(relative)
  if action == 'verify'
    abort "generated active Japanese override is missing: #{relative}" unless output.file? && !output.symlink?
    abort "generated active Japanese override drifted: #{relative}" unless output.read(encoding: Encoding::UTF_8) == content
  else
    FileUtils.mkdir_p(output.dirname, mode: 0o755)
    output.write(content)
    output.chmod(0o644)
  end
end

puts "TOYBACO_CHATWOOT_ACTIVE_JA=#{action.upcase} files=#{SOURCE_SHA256.length}"
