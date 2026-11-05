json.access_token Toybaco::Security::PersonalApiAccess.exposed_token(@resource)
json.expiry nil
json.user do
  json.id @resource.id
  json.name @resource.name
  json.display_name @resource.display_name
  json.email @resource.email
  json.pubsub_token @resource.pubsub_token
end
