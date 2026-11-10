# frozen_string_literal: true

require 'rails_helper'

# CASA 2.1.1・6.5.1: API 型の受信箱の client API は連絡先を path の /public/api/v1/inboxes/<受信箱>/contacts/<identifier>/… で
# 指し、その identifier は訪問者の会話を読む鍵になる。Rails の Started の行などに出ても、log の最後の網(LogScrub)で伏せる。
RSpec.describe Toybaco::Security::LogScrub do
  let(:identifier) { "visitor-#{SecureRandom.hex(12)}" }

  it 'masks the contact identifier of the public inbox API path and keeps the inbox identifier and the rest of the path' do
    lines = {
      %(Started GET "/public/api/v1/inboxes/inbox-pub-1/contacts/#{identifier}" for 127.0.0.1) =>
        'Started GET "/public/api/v1/inboxes/inbox-pub-1/contacts/[FILTERED]" for 127.0.0.1',
      %(Started POST "/public/api/v1/inboxes/inbox-pub-1/contacts/#{identifier}/conversations/7/messages?page=2" for 127.0.0.1) =>
        'Started POST "/public/api/v1/inboxes/inbox-pub-1/contacts/[FILTERED]/conversations/7/messages?page=2" for 127.0.0.1',
      %(No route matches [PATCH] "/Public/API/v1/inboxes/x/contacts/#{identifier}.json") =>
        'No route matches [PATCH] "/Public/API/v1/inboxes/x/contacts/[FILTERED]"'
    }

    expect(lines.keys.map { |line| described_class.mask(line) }).to eq(lines.values)
  end

  it 'masks source_id and contact_id in the query of the public contact paths, in the ways Rack reads those keys' do
    lines = {
      %(Started POST "/public/api/v1/inboxes/inbox-pub-1/contacts?source_id=#{identifier}" for 127.0.0.1) =>
        'Started POST "/public/api/v1/inboxes/inbox-pub-1/contacts?source_id=[FILTERED]" for 127.0.0.1',
      %(Started POST "/public/api/v1/inboxes/i/contacts?name=a&%73%6f%75%72%63%65%5F%69%64=#{identifier}&source_id[]=#{identifier}" for 127.0.0.1) =>
        'Started POST "/public/api/v1/inboxes/i/contacts?name=a&%73%6f%75%72%63%65%5F%69%64=[FILTERED]&source_id[]=[FILTERED]" for 127.0.0.1',
      %(Started GET "/public/api/v1/inboxes/inbox-pub-1/contacts/#{identifier}/conversations?%63ontact_i%64=#{identifier}&page=2" for 127.0.0.1) =>
        'Started GET "/public/api/v1/inboxes/inbox-pub-1/contacts/[FILTERED]/conversations?%63ontact_i%64=[FILTERED]&page=2" for 127.0.0.1',
      %({"method":"POST","path":"/public/api/v1/inboxes/inbox-pub-1/contacts?source_id=#{identifier}","status":200}) =>
        '{"method":"POST","path":"/public/api/v1/inboxes/inbox-pub-1/contacts?source_id=[FILTERED]","status":200}'
    }

    expect(lines.keys.map { |line| described_class.mask(line) }).to eq(lines.values)
    expect(described_class.mask_public_contact("/public/api/v1/inboxes/x/contacts/#{identifier}?source_id=#{identifier}"))
      .to eq('/public/api/v1/inboxes/x/contacts/[FILTERED]?source_id=[FILTERED]')
  end

  it 'leaves other paths, including the account contact API and the public contact creation, as they are' do
    lines = ['Started GET "/api/v1/accounts/1/contacts/42" for 127.0.0.1', 'Started POST "/public/api/v1/inboxes/inbox-pub-1/contacts" for 127.0.0.1',
             'Started GET "/public/api/v1/inboxes/inbox-pub-1" for 127.0.0.1', 'Started GET "/public/api/v1/csat_survey/abc" for 127.0.0.1',
             'Started GET "/api/v1/accounts/1/contacts?source_id=abc" for 127.0.0.1',
             'Started GET "/public/api/v1/inboxes/inbox-pub-1?source_id=abc" for 127.0.0.1',
             'Started POST "/public/api/v1/inboxes/inbox-pub-1/contacts?name=a&page=2" for 127.0.0.1']

    expect(lines.map { |line| described_class.mask(line) }).to eq(lines)
  end

  it 'matches in linear time' do
    patterns = %i[PUBLIC_CONTACT_PATH PUBLIC_CONTACT_QUERY PUBLIC_CONTACT_QUERY_KEY].index_with { |name| described_class.const_get(name) }
    expect(patterns.reject { |_name, pattern| Regexp.linear_time?(pattern) }.keys).to eq([])
  end
end
