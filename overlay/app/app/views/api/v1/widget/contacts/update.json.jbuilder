json.id @contact.id
json.has_email @contact.email.present?
json.has_name @contact.name.present?
json.has_phone_number @contact.phone_number.present?
json.widget_auth_token @widget_auth_token if @toybaco_http_authenticated && @widget_auth_token.to_s.start_with?('tbwp1.', 'tbwr1.')
json.widget_http_identity_changed @widget_http_identity_changed if @toybaco_http_authenticated
