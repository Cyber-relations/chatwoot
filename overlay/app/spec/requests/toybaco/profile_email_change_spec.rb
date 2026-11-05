# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Profile email change reauthentication', type: :request do
  let(:account) { create(:account, locale: 'ja') }
  let(:user) { create(:user, account: account, email: 'old-address@example.invalid') }
  let(:headers) { user.create_new_auth_token }
  let(:new_email) { 'new-address@example.invalid' }

  before do
    user
    headers
    clear_enqueued_jobs
  end

  def update_profile(attributes)
    put '/api/v1/profile', params: { locale: 'ja', profile: attributes }, headers: headers, as: :json
  end

  [nil, 'incorrect-password'].each do |password|
    it "rejects an email change with #{password.nil? ? 'no' : 'an incorrect'} current password" do
      expect { update_profile(email: new_email, current_password: password, name: 'Unchanged fixture') }
        .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Invalid current password')
      expect(user.reload.email).to eq('old-address@example.invalid')
      expect(user.unconfirmed_email).to be_blank
      expect(user.name).not_to eq('Unchanged fixture')
    end
  end

  it 'keeps reconfirmation and revokes existing devices after the current password is supplied' do
    credentials = headers
    update_profile(email: new_email, current_password: 'Password1!')
    expect(response).to have_http_status(:ok)
    expect(user.reload.email).to eq('old-address@example.invalid')
    expect(user.unconfirmed_email).to eq(new_email)
    expect(user.valid_token?(credentials['access-token'], credentials['client'])).to be(false)
    expect(user.confirm).to be(true)
    expect(user.reload.email).to eq(new_email)
  end

  it 'delivers a Japanese notification to the old address as well as confirmation to the new one' do
    saved = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries, ActionMailer::Base.raise_delivery_errors]
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    user
    headers
    clear_enqueued_jobs
    previous_count = ActionMailer::Base.deliveries.size
    update_profile(email: new_email, current_password: 'Password1!')
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob)
    delivered = ActionMailer::Base.deliveries.drop(previous_count)
    notice = delivered.find { |mail| mail.to == ['old-address@example.invalid'] }
    expect(notice).to be_present
    expect(notice.subject).to eq('【トイバコ】メールアドレス変更のお知らせ')
    expect(notice.body.decoded).to include('メールアドレスの変更手続き', '心当たりがない場合')
    expect(delivered.count { |mail| mail.to == [new_email] }).to eq(1)
  ensure
    ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries, ActionMailer::Base.raise_delivery_errors = saved
  end

  it 'does not require a password or notify for unchanged email and ordinary profile edits' do
    user
    headers
    clear_enqueued_jobs
    expect { update_profile(email: user.email.upcase, display_name: 'Updated fixture') }
      .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)
    expect(response).to have_http_status(:ok)
    expect(user.reload.display_name).to eq('Updated fixture')
  end

  it 'checks the old password when changing both password and email' do
    update_profile(email: new_email, current_password: 'Password1!', password: 'ChangedPassword1!', password_confirmation: 'ChangedPassword1!')
    expect(response).to have_http_status(:ok)
    expect(user.reload.unconfirmed_email).to eq(new_email)
    expect(user.valid_password?('ChangedPassword1!')).to be(true)
  end

  describe 'unused DTA registration mutations' do
    let(:signup_catalog) do
      data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
      version = data['free_registration_version'] || data.dig('plans', 'free', 'versions').keys.max
      data['free_registration_version'] = version
      data.dig('plans', 'free', 'versions', version)['sellable'] = true
      Toybaco::PlanCatalog.new(data)
    end

    it 'keeps legacy account sign-up closed while allowing Toybaco free sign-up' do
      signup_email = 'signup-fixture@example.com'
      signup_params = { account_name: 'Signup fixture', user_full_name: 'Signup fixture',
                        email: signup_email, password: 'Password1!', accept_terms: '1' }
      allow(Toybaco::PlanCatalog).to receive(:default).and_return(signup_catalog)
      with_modified_env(ENABLE_ACCOUNT_SIGNUP: 'false', HCAPTCHA_SERVER_KEY: nil) do
        # Match main's disabled legacy signup; persisted config takes precedence over ENV.
        { 'ENABLE_ACCOUNT_SIGNUP' => false, 'HCAPTCHA_SERVER_KEY' => '' }.each do |name, value|
          InstallationConfig.find_or_initialize_by(name: name).update!(value: value, locked: false)
        end
        GlobalConfig.clear_cache
        expect { post '/api/v1/accounts', params: signup_params, as: :json }.not_to(change { [User.count, Account.count] })
        expect(response).to have_http_status(:not_found)
        expect(User.from_email(signup_email)).to be_nil

        post '/toybaco/free/signup', params: signup_params, as: :json
        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body).to eq('email' => signup_email, 'next' => 'verify_email')
        expect(User.from_email(signup_email)).to be_present
      end
    ensure
      GlobalConfig.clear_cache
    end

    passwords = [nil, 'incorrect-password', 'Password1!'].freeze
    fields = %i[email password].freeze

    %i[put patch].each do |method|
      passwords.each do |password|
        fields.each do |field|
          it "returns 404 for #{method.upcase} /auth #{field} with current_password=#{password.inspect}" do
            attributes = field == :email ? { email: new_email } : { password: 'ChangedPassword1!', password_confirmation: 'ChangedPassword1!' }
            attributes[:current_password] = password unless password.nil?
            encrypted_password = user.encrypted_password
            credentials = headers

            expect { public_send(method, '/auth', params: attributes, headers: credentials, as: :json) }
              .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)

            expect(response).to have_http_status(:not_found)
            expect(user.reload.email).to eq('old-address@example.invalid')
            expect(user.unconfirmed_email).to be_blank
            expect(user.encrypted_password).to eq(encrypted_password)
            expect(user.valid_password?('Password1!')).to be(true)
          end
        end
      end
    end

    it 'returns 404 for DELETE /auth without deleting the authenticated user' do
      credentials = headers
      expect { delete '/auth', headers: credentials, as: :json }.not_to change(User, :count)
      expect(response).to have_http_status(:not_found)
      expect(User.exists?(user.id)).to be(true)
    end

    it 'returns 404 for unauthenticated mutation requests too' do
      %i[put patch delete].each do |method|
        public_send(method, '/auth', as: :json)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
