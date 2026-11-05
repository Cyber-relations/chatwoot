# frozen_string_literal: true

module Toybaco::ChannelAvailability::WhatsappProviderGuards
  # Audited against app/ and enterprise/ in the pinned v4.18.0 source. Include
  # request methods as well as entry methods that write state before requesting.
  METHODS = {
    'Channel::Whatsapp' => %i[provider_service],
    'Whatsapp::FacebookApiClient' => %i[
      exchange_code_for_token fetch_phone_numbers fetch_all_phone_numbers fetch_message_templates
      fetch_business_profile fetch_permissions fetch_subscribed_apps fetch_phone_number debug_token
      register_phone_number deregister_phone_number phone_number_verified? subscribe_app_to_waba
      override_phone_number_callback clear_phone_number_callback_override unsubscribe_app_from_waba
    ],
    'Whatsapp::CsatTemplateService' => %i[create_template delete_template get_template_status send_template_creation_request],
    'Whatsapp::BusinessManagementTokenValidationService' => %i[perform validate_business_account_access!],
    'Whatsapp::BusinessProfileService' => %i[fetch],
    'Whatsapp::HealthService' => %i[fetch_health_status sync_health_status! fetch_graph_data],
    'Whatsapp::MediaUploadService' => %i[perform upload],
    'Whatsapp::IncomingMessageBaseService' => %i[download_attachment_file],
    'Whatsapp::IncomingMessageWhatsappCloudService' => %i[download_attachment_file],
    'Whatsapp::Providers::WhatsappCloudContactInfoRequestService' => %i[perform],
    'Whatsapp::Providers::WhatsappCloudService' => %i[
      send_message send_template sync_templates fetch_whatsapp_templates validate_provider_config?
      send_text_message send_attachment_message send_interactive_text_message
    ],
    'Whatsapp::Providers::Whatsapp360DialogService' => %i[
      send_message send_template sync_templates validate_provider_config?
      send_text_message send_attachment_message send_interactive_text_message
    ]
  }.freeze
  CALL_METHODS = %i[send_call_permission_request initiate_call update_calling_status call_api].freeze

  def self.install
    METHODS.each do |name, methods|
      guarded = methods
      guarded += CALL_METHODS if name == 'Whatsapp::Providers::WhatsappCloudService' && ChatwootApp.enterprise?
      Toybaco::ChannelAvailability::ProviderGuard.install(name.constantize, guarded) { 'whatsapp' }
    end
  end
end
