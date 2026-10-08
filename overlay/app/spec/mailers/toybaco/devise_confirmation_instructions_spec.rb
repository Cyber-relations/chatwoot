# frozen_string_literal: true

require 'rails_helper'

# 上流は DISABLE_ENTERPRISE=true でも enterprise/app/views を view path の先頭に置く。
# 招待メールが EE ビュー(saml_enabled? を呼ぶ)へ戻ると、本番の担当者招待が Sidekiq で失敗する。
RSpec.describe Devise::Mailer, type: :mailer do # rubocop:disable RSpec/SpecFilePathFormat
  let(:account) { create(:account, name: '招待テスト店', locale: 'ja') }
  let(:inviter) { create(:user, name: '管理 花子', account: account, role: :administrator) }
  let(:invitee_email) { 'invited-staff@example.invalid' }
  let(:upstream_copy) { /saml|SSO|You're invited|invited you|Chatwoot/ }
  let(:ja_subject) { I18n.t('devise.mailer.confirmation_instructions.subject', locale: :ja) }
  let(:agent_builder) do
    AgentBuilder.new(email: invitee_email, name: '招待 次郎', inviter: inviter, account: account, role: :agent)
  end

  # 本番は toybaco:branding で BRAND_NAME をトイバコにしている。test DB は上流既定(Chatwoot)のまま。
  before do
    InstallationConfig.find_or_initialize_by(name: 'BRAND_NAME').update!(value: 'トイバコ', locked: false)
    GlobalConfig.clear_cache
  end

  after do
    Current.reset
    GlobalConfig.clear_cache
  end

  it 'delivers the queued staff invitation from the Japanese overlay view' do
    # 本番の API と同じく Current.account がある状態で招待し、Sidekiq が実行する mail job を作る。
    Current.account = account
    invitation_job = have_enqueued_job(ActionMailer::MailDeliveryJob).with(
      'Devise::Mailer', 'confirmation_instructions', 'deliver_now',
      a_hash_including(params: { account: account }, args: [a_kind_of(User), a_kind_of(String), a_kind_of(Hash)])
    )
    invitee = nil
    expect { invitee = agent_builder.perform }.to invitation_job

    delivered_before = ActionMailer::Base.deliveries.size
    expect { perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) }.not_to raise_error
    invitation = ActionMailer::Base.deliveries.drop(delivered_before).find { |delivery| delivery.to == [invitee_email] }
    expect(invitation).to be_present

    html = Nokogiri::HTML(invitation.body.decoded)
    hrefs = html.css('a[href]').map { |link| link['href'] }
    accept_link = hrefs.find { |href| href.include?('/app/auth/password/edit?reset_password_token=') }
    token = accept_link && Rack::Utils.parse_query(URI.parse(accept_link).query)['reset_password_token']
    aggregate_failures do
      expect(invitation.to).to eq([invitee_email])
      expect(invitation.subject).to eq(ja_subject)
      expect(html.text).to include("「#{account.name}」に招待されています", "#{inviter.name} さんから")
      expect(html.text).to include('招待を受け入れる', '招待者')
      expect(html.text).not_to match(upstream_copy)
      expect(token).to be_present
      expect(invitee.reload.reset_password_token).to be_present
      expect(User.with_reset_password_token(token)).to eq(invitee)
    end
  end

  it 'keeps the enterprise view path identical to the Japanese CE overlay view' do
    enterprise_view = Rails.root.join('enterprise/app/views/devise/mailer/confirmation_instructions.html.erb')
    ce_view = Rails.root.join('app/views/devise/mailer/confirmation_instructions.html.erb')

    aggregate_failures do
      expect(enterprise_view).to exist
      expect(FileUtils.compare_file(enterprise_view, ce_view)).to be(true), 'enterprise view must be byte-identical to the CE overlay view'
      expect(enterprise_view.read).not_to include('saml_enabled?')
    end
  end

  it 'keeps the plain email confirmation for an unconfirmed user without a workspace' do
    user = User.new(name: '確認 三郎', email: 'confirm-only@example.invalid', password: 'Password1!',
                    password_confirmation: 'Password1!').tap do |record|
      record.skip_confirmation_notification!
      record.save!
    end

    mail = described_class.confirmation_instructions(user, 'fixture-confirmation-token').message
    html = Nokogiri::HTML(mail.body.decoded)
    hrefs = html.css('a[href]').map { |link| link['href'] }
    aggregate_failures do
      expect(mail.to).to eq([user.email])
      expect(mail.subject).to eq(ja_subject)
      expect(html.text).to include('メールアドレスの確認', '確認 三郎 様')
      expect(html.text).not_to match(upstream_copy)
      expect(html.text).not_to include('招待')
      expect(hrefs).to include(a_string_including('/app/auth/confirmation?confirmation_token=fixture-confirmation-token'))
    end
  end
end
