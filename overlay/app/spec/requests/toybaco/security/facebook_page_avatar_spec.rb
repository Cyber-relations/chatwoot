# frozen_string_literal: true

require 'rails_helper'

# CASA 5.1.1: Facebook の page の登録は params[:page_id] を encode せずに avatar の job が取りに行く Graph API の画像の URL に
# 入れる(app/controllers/api/v1/accounts/callbacks_controller.rb:7, 17, 102-104)。page の id は数字だけなので、ほかは保存の
# 前に API の 422 で断り、URL では encode する。
RSpec.describe 'Facebook page registration avatar URL', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:path) { "/api/v1/accounts/#{account.id}/callbacks/register_facebook_page" }
  let(:page_details) { instance_double(Facebook::PageDetailsService, perform: {}) }

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(Facebook::PageDetailsService).to receive(:new).and_return(page_details)
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)
  end

  def register(page_id)
    post path, params: { user_access_token: 'synthetic-user-token', page_access_token: 'synthetic-page-token', page_id: page_id,
                         inbox_name: 'Facebook 受信箱' }, headers: admin.create_new_auth_token, as: :json
  end

  it 'registers a numeric page id and fetches the avatar from the encoded Graph API URL' do
    expect { register('1234567890') }.to change(account.facebook_pages, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(Avatar::AvatarFromUrlJob).to have_received(:perform_later)
      .with(an_instance_of(Inbox), 'https://graph.facebook.com/1234567890/picture?type=large')
  end

  it 'refuses a page id that is not digits before saving anything or fetching an avatar' do
    ['1234/../me', '1234?fields=access_token', '1234#x', 'me', '', ' 1234', '-1', '12.5'].each do |page_id|
      expect { register(page_id) }.not_to change(Channel::FacebookPage, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.keys).to eq(['error'])
    end
    expect(Avatar::AvatarFromUrlJob).not_to have_received(:perform_later)
  end
end
