# frozen_string_literal: true

require 'rails_helper'

# request body の外部キーが店舗を越えないこと(CASA 3.1.4、2026-10-28)。他店舗の id を送ると 422(一括処理は会話を
# 変えないまま 200)で何も保存せず、応答に他店舗の名前・メールを出さない。自店舗の id は従来どおり保存する。
RSpec.describe 'Toybaco tenant foreign keys', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:other_account) { create(:account, name: "他店舗-#{SecureRandom.hex(4)}") }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_user) { create(:user, account: other_account, role: :administrator, name: "#{other_account.name}-利用者") }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: other_account, name: "#{other_account.name}-受信箱") }
  let(:other_team) { create(:team, account: other_account, name: "#{other_account.name}-チーム") }
  let(:portal) { create(:portal, account: account) }
  let(:other_portal) { create(:portal, account: other_account, name: "#{other_account.name}-ヘルプ") }
  let(:other_category) do
    create(:category, portal: other_portal, name: "#{other_account.name}-カテゴリー", slug: "other-#{SecureRandom.hex(4)}")
  end
  let(:headers) { { 'api_access_token' => admin.access_token.token } }

  def api(path)
    "/api/v1/accounts/#{account.id}#{path}"
  end

  def write(verb, path, params)
    public_send(verb, api(path), params: params, headers: headers, as: :json)
  end

  # 422 の理由がその列の照合であること(作成者の欠落など別の理由の 422 と区別する)と、他店舗の名前・メールを返さないこと。
  def expect_rejected(attribute, *foreign_texts)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['attributes']).to include(attribute)
    foreign_texts.each { |text| expect(response.body).not_to include(text) }
  end

  def own_category(name = '自店舗のカテゴリー')
    create(:category, portal: portal, name: name, slug: "own-#{SecureRandom.hex(4)}")
  end

  describe '会話の作成(POST /conversations の assignee_id・team_id)' do
    let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account)) }

    def create_conversation(extra)
      write(:post, '/conversations', { source_id: contact_inbox.source_id, inbox_id: inbox.id }.merge(extra))
    end

    it '他店舗の利用者を担当者にすると 422 で、会話を作らず、その利用者の名前とメールを返さない' do
      contact_inbox
      other_user
      expect { create_conversation(assignee_id: other_user.id) }.not_to change(Conversation, :count)
      expect_rejected('assignee_id', other_user.name, other_user.email)
    end

    it '他店舗のチームを指定すると 422 で、会話を作らず、そのチーム名を返さない' do
      contact_inbox
      other_team
      expect { create_conversation(team_id: other_team.id) }.not_to change(Conversation, :count)
      expect_rejected('team_id', other_team.name)
    end

    it '自店舗の担当者とチームは従来どおり保存して返す' do
      team = create(:team, account: account)
      create(:team_member, team: team, user: agent)
      create_conversation(assignee_id: agent.id, team_id: team.id)
      expect(response).to have_http_status(:ok)
      conversation = account.conversations.find_by!(display_id: response.parsed_body['id'])
      expect([conversation.assignee_id, conversation.team_id]).to eq([agent.id, team.id])
      expect(response.parsed_body.dig('meta', 'assignee', 'id')).to eq(agent.id)
    end
  end

  # 一括処理は job の conversation.save が validation で false を返し、その会話の担当・チーム・状態をまとめて
  # 変えない。応答は enqueue の 200 のまま(upstream の job の挙動)で、拒んだ会話は warn の記録に残す。
  describe '一括処理(POST /bulk_actions の fields)' do
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }

    before { allow(Rails.logger).to receive(:warn).and_call_original }

    def bulk_update(fields, labels = nil)
      perform_enqueued_jobs(only: BulkActionsJob) do
        write(:post, '/bulk_actions', { type: 'Conversation', ids: [conversation.display_id], fields: fields, labels: labels })
      end
      expect(response).to have_http_status(:ok)
    end

    def rejection_log(attribute, target = conversation)
      a_string_including('bulk update rejected', "account_id=#{account.id}", "conversation_id=#{target.id}", attribute)
    end

    def track_bulk_update_callbacks
      conversation
      headers
      clear_enqueued_jobs
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original
    end

    def expect_conversation_updated(*attributes)
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(Events::Types::CONVERSATION_UPDATED, anything, hash_including(conversation: conversation)).once
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(Events::Types::CONVERSATION_UPDATED, anything,
              hash_including(conversation: conversation, changed_attributes: hash_including(*attributes)))
    end

    def expect_label_activity(change_type, label, target = conversation)
      content = I18n.t("conversations.activity.labels.#{change_type}", user_name: admin.name, labels: label)
      expect(Conversations::ActivityMessageJob).to have_been_enqueued.with(target, hash_including(content: content)).once
    end

    def delete_bulk_target_after_loading(target)
      allow(Rails.logger).to receive(:info).and_call_original
      # perform_later のキーワード引数を位置引数の Hash に変えないよう、**kwargs のまま渡す。
      allow(BulkActionsJob).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do |job|
          allow(job).to receive(:records_to_updated).and_wrap_original do |load_records, *ids|
            relation = load_records.call(*ids)
            relation.load
            Conversation.find(target.id).destroy!
            relation
          end
        end
      end
    end

    def expect_deleted_bulk_target_skipped(target)
      expect(Rails.logger).to have_received(:info)
        .with('[Toybaco::TenantForeignKeys] bulk update skipped deleted conversation ' \
              "account_id=#{account.id} conversation_id=#{target.id}").once
    end

    it '他店舗の担当者・チームを含む一括更新は、その会話の担当・チーム・状態を変えず、拒んだことを記録する' do
      bulk_update(assignee_id: other_user.id, status: 'resolved')
      bulk_update(team_id: other_team.id)
      expect(conversation.reload.slice(:assignee_id, :team_id, :status))
        .to eq('assignee_id' => nil, 'team_id' => nil, 'status' => 'open')
      expect(Rails.logger).to have_received(:warn).with(rejection_log('assignee_id')).once
      expect(Rails.logger).to have_received(:warn).with(rejection_log('team_id')).once
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including(other_user.email))
    end

    it '自店舗の担当者とチームは従来どおり一括で反映する' do
      team = create(:team, account: account)
      create(:team_member, team: team, user: agent)
      bulk_update(team_id: team.id, assignee_id: agent.id, status: 'resolved')
      expect(conversation.reload.slice(:assignee_id, :team_id, :status))
        .to eq('assignee_id' => agent.id, 'team_id' => team.id, 'status' => 'resolved')
    end

    %i[assignee_id team_id].each do |attribute|
      it "他店舗の #{attribute} とラベル追加・削除の一括更新は、ラベルもフィールドも保存しない" do
        conversation.update!(label_list: %w[keep remove])
        foreign_id = attribute == :assignee_id ? other_user.id : other_team.id
        track_bulk_update_callbacks

        bulk_update({ attribute => foreign_id, :status => 'resolved' }, add: ['added'], remove: ['remove'])

        expect(conversation.reload.label_list).to contain_exactly('keep', 'remove')
        expect(conversation.slice(:assignee_id, :team_id, :status))
          .to eq('assignee_id' => nil, 'team_id' => nil, 'status' => 'open')
        expect(Rails.logger).to have_received(:warn).with(rejection_log(attribute.to_s)).once
        expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
          .with(Events::Types::CONVERSATION_UPDATED, anything, hash_including(conversation: conversation))
        expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
      end
    end

    it '自店舗の担当者・チームとラベル追加・削除をまとめて保存する' do
      conversation.update!(label_list: %w[keep remove])
      team = create(:team, account: account)
      create(:team_member, team: team, user: agent)
      track_bulk_update_callbacks

      bulk_update({ assignee_id: agent.id, team_id: team.id, status: 'resolved' }, add: ['added'], remove: ['remove'])

      expect(conversation.reload.label_list).to contain_exactly('keep', 'added')
      expect(conversation.slice(:assignee_id, :team_id, :status))
        .to eq('assignee_id' => agent.id, 'team_id' => team.id, 'status' => 'resolved')
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including('bulk update rejected'))
      expect_conversation_updated('status', 'label_list')
      expect_label_activity('added', 'added')
      expect_label_activity('removed', 'remove')
    end

    it 'open の会話に同値の status とラベルを指定しても、ラベル変更を通知し追加の活動履歴を残す' do
      expect(conversation.status).to eq('open')
      track_bulk_update_callbacks

      bulk_update({ status: 'open' }, add: ['added'])

      expect(conversation.reload.label_list).to contain_exactly('added')
      expect(conversation.status).to eq('open')
      expect_conversation_updated('label_list')
      expect_label_activity('added', 'added')
    end

    it 'fields のないラベルだけの一括追加・削除を保存する' do
      conversation.update!(label_list: %w[keep remove])
      track_bulk_update_callbacks

      bulk_update(nil, add: ['added'], remove: ['remove'])

      expect(conversation.reload.label_list).to contain_exactly('keep', 'added')
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including('bulk update rejected'))
      expect_conversation_updated('label_list')
      expect_label_activity('added', 'added')
      expect_label_activity('removed', 'remove')
    end

    it '読み込みの後に別の操作が足したラベルを、一括の追加で消さない' do
      conversations = [conversation, create(:conversation, account: account, inbox: inbox)]
      conversations.each { |record| record.update!(label_list: %w[keep]) }
      track_bulk_update_callbacks
      injected = false
      other = nil
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, *args|
        if !injected && args[0] == Events::Types::CONVERSATION_UPDATED && conversations.include?(args[2][:conversation])
          injected = true
          other_id = conversations.find { |record| record.id != args[2][:conversation].id }.id
          # 同じ接続の別オブジェクトで更新し、job が先に読み込んだ後続会話だけを古い状態にする。
          other = Conversation.find(other_id)
          other.update!(label_list: other.label_list + ['urgent'])
        end
        original.call(*args)
      end

      perform_enqueued_jobs(only: BulkActionsJob) do
        write(:post, '/bulk_actions', { type: 'Conversation', ids: conversations.map(&:display_id), labels: { add: ['added'] } })
      end

      expect(response).to have_http_status(:ok)
      expect(injected).to be(true)
      expect(other.reload.label_list).to contain_exactly('keep', 'urgent', 'added')
      first = conversations.find { |record| record.id != other.id }
      expect(first.reload.label_list).to contain_exactly('keep', 'added')
      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(Events::Types::CONVERSATION_UPDATED, anything,
              hash_including(conversation: other, changed_attributes: hash_including(
                'label_list' => [contain_exactly('keep', 'urgent'), contain_exactly('keep', 'urgent', 'added')]
              ))).once
      content = I18n.t('conversations.activity.labels.removed', user_name: admin.name, labels: 'urgent')
      expect(Conversations::ActivityMessageJob).not_to have_been_enqueued.with(other, hash_including(content: content))
    end

    it '読み込み後に削除された会話を飛ばし、残る会話のラベル追加と通知・活動履歴を一度ずつ保存する' do
      conversations = [conversation, *create_list(:conversation, 2, account: account, inbox: inbox)]
      conversations.each { |record| record.update!(label_list: %w[keep]) }
      track_bulk_update_callbacks
      delete_bulk_target_after_loading(conversation)

      perform_enqueued_jobs(only: BulkActionsJob) do
        write(:post, '/bulk_actions', { type: 'Conversation', ids: conversations.map(&:display_id), labels: { add: ['added'] } })
      end

      expect(response).to have_http_status(:ok)
      expect_deleted_bulk_target_skipped(conversation)
      conversations.drop(1).each do |record|
        expect(record.reload.label_list).to contain_exactly('keep', 'added')
        expect(Rails.configuration.dispatcher).to have_received(:dispatch)
          .with(Events::Types::CONVERSATION_UPDATED, anything, hash_including(conversation: record)).once
        expect_label_activity('added', 'added', record)
      end
    end

    it '読み込み後に削除された会話を飛ばし、残る会話の他店舗担当者とラベルの更新を拒否して記録する' do
      conversations = [conversation, *create_list(:conversation, 2, account: account, inbox: inbox)]
      conversations.each { |record| record.update!(label_list: %w[keep]) }
      foreign_id = other_user.id
      track_bulk_update_callbacks
      delete_bulk_target_after_loading(conversation)

      perform_enqueued_jobs(only: BulkActionsJob) do
        write(:post, '/bulk_actions', { type: 'Conversation', ids: conversations.map(&:display_id),
                                        fields: { assignee_id: foreign_id }, labels: { add: ['added'] } })
      end

      expect(response).to have_http_status(:ok)
      expect_deleted_bulk_target_skipped(conversation)
      conversations.drop(1).each do |record|
        expect(record.reload.label_list).to contain_exactly('keep')
        expect(record.slice(:assignee_id, :team_id, :status))
          .to eq('assignee_id' => nil, 'team_id' => nil, 'status' => 'open')
        expect(Rails.logger).to have_received(:warn).with(rejection_log('assignee_id', record)).once
        expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
          .with(Events::Types::CONVERSATION_UPDATED, anything, hash_including(conversation: record))
      end
      expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
    end

    it 'enqueue 後に自店舗のチームが削除された場合も、ラベルと状態を変更せず拒否を記録する' do
      conversation.update!(label_list: %w[keep remove])
      team = create(:team, account: account)
      expect do
        write(:post, '/bulk_actions', { type: 'Conversation', ids: [conversation.display_id],
                                        fields: { team_id: team.id, status: 'resolved' },
                                        labels: { add: ['added'], remove: ['remove'] } })
      end.to have_enqueued_job(BulkActionsJob)
      expect(response).to have_http_status(:ok)
      team.destroy!

      perform_enqueued_jobs(only: BulkActionsJob)

      expect(conversation.reload.label_list).to contain_exactly('keep', 'remove')
      expect(conversation.slice(:team_id, :status)).to eq('team_id' => nil, 'status' => 'open')
      expect(Rails.logger).to have_received(:warn).with(rejection_log('team_id')).once
    end

    # 画面のチームの「なし」は team_id 0(upstream BulkTeamActions.vue、useBulkActions.js)。
    it 'チームの「なし」(team_id 0)は割り当て済みの会話からチームを外し、拒んだ記録を残さない' do
      conversation.update!(team: create(:team, account: account))
      bulk_update(team_id: 0)
      expect(conversation.reload.team_id).to be_nil
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including('bulk update rejected'))
    end
  end

  describe 'ヘルプセンターの記事(articles の category_id・associated_article_id)' do
    let(:other_article) do
      create(:article, portal: other_portal, account: other_account, author: other_user, title: "#{other_account.name}-記事")
    end

    def article_params(extra)
      { article: { title: '自店舗の記事', content: '本文', author_id: admin.id }.merge(extra) }
    end

    it '他店舗のカテゴリーや記事を指定した作成は 422 で、記事を作らず、それらの名前を返さない' do
      other_category
      other_article
      expect { write(:post, "/portals/#{portal.slug}/articles", article_params(category_id: other_category.id)) }
        .not_to change(Article, :count)
      expect_rejected('category_id', other_category.name)
      expect { write(:post, "/portals/#{portal.slug}/articles", article_params(associated_article_id: other_article.id)) }
        .not_to change(Article, :count)
      expect_rejected('associated_article_id', other_article.title)
    end

    it '他店舗のカテゴリーへの付け替えは 422 で、記事のカテゴリーを変えない' do
      article = create(:article, portal: portal, account: account, author: admin)
      write(:patch, "/portals/#{portal.slug}/articles/#{article.id}", { article: { category_id: other_category.id } })
      expect_rejected('category_id', other_category.name)
      expect(article.reload.category_id).to be_nil
    end

    it '自店舗のカテゴリーと関連記事は従来どおり保存する' do
      category = own_category
      root = create(:article, portal: portal, account: account, author: admin)
      write(:post, "/portals/#{portal.slug}/articles", article_params(category_id: category.id, associated_article_id: root.id))
      expect(response).to have_http_status(:ok)
      created = Article.find(response.parsed_body.dig('payload', 'id'))
      expect([created.category_id, created.associated_article_id]).to eq([category.id, root.id])
    end
  end

  describe 'ヘルプセンターのカテゴリー(categories の parent_category_id・associated_category_id)' do
    def category_params(extra)
      { category: { name: '自店舗の新カテゴリー', slug: "new-#{SecureRandom.hex(4)}", locale: 'en' }.merge(extra) }
    end

    it '他店舗のカテゴリーを親・関連にすると 422 で、カテゴリーを作らず変えず、その名前を返さない' do
      other_category
      category = own_category
      expect { write(:post, "/portals/#{portal.slug}/categories", category_params(parent_category_id: other_category.id)) }
        .not_to change(Category, :count)
      expect_rejected('parent_category_id', other_category.name)
      write(:patch, "/portals/#{portal.slug}/categories/#{category.id}", { category: { associated_category_id: other_category.id } })
      expect_rejected('associated_category_id', other_category.name)
      expect(category.reload.associated_category_id).to be_nil
    end

    it '自店舗のカテゴリーは従来どおり親・関連に保存する' do
      parent = own_category('自店舗の親')
      write(:post, "/portals/#{portal.slug}/categories", category_params(parent_category_id: parent.id, associated_category_id: parent.id))
      expect(response).to have_http_status(:ok)
      created = Category.find(response.parsed_body.dig('payload', 'id'))
      expect([created.parent_category_id, created.associated_category_id]).to eq([parent.id, parent.id])
    end
  end

  describe '受信箱の担当者(inbox_members の user_ids)' do
    it '他店舗の利用者を受信箱の担当者に足すと 422 で、誰も足さず、その利用者の名前とメールを返さない' do
      agent
      other_user
      expect { write(:post, '/inbox_members', { inbox_id: inbox.id, user_ids: [agent.id, other_user.id] }) }
        .not_to change(InboxMember, :count)
      expect_rejected('user_id', other_user.name, other_user.email)
      write(:patch, '/inbox_members', { inbox_id: inbox.id, user_ids: [other_user.id] })
      expect_rejected('user_id', other_user.name, other_user.email)
      expect(inbox.reload.members).to be_empty
    end

    it '自店舗の利用者は従来どおり受信箱の担当者に足す' do
      write(:post, '/inbox_members', { inbox_id: inbox.id, user_ids: [agent.id] })
      expect(response).to have_http_status(:ok)
      expect(inbox.reload.members).to contain_exactly(agent)
    end
  end

  describe '受信箱のヘルプセンター(inboxes の portal_id)' do
    it '他店舗のヘルプセンターを受信箱に付けると 422 で、付けず、その名前と slug を返さない' do
      write(:patch, "/inboxes/#{inbox.id}", { portal_id: other_portal.id })
      expect_rejected('portal_id', other_portal.name, other_portal.slug)
      expect(inbox.reload.portal_id).to be_nil
    end

    it '自店舗のヘルプセンターは従来どおり受信箱に付けて返す' do
      write(:patch, "/inboxes/#{inbox.id}", { portal_id: portal.id })
      expect(response).to have_http_status(:ok)
      expect(inbox.reload.portal_id).to eq(portal.id)
      expect(response.parsed_body.dig('help_center', 'slug')).to eq(portal.slug)
    end
  end

  describe 'webhook の受信箱(webhooks の inbox_id)' do
    def webhook_params(inbox_id, url = 'https://hooks.example.invalid/created')
      { webhook: { url: url, subscriptions: ['conversation_created'], inbox_id: inbox_id } }
    end

    it '他店舗の受信箱を webhook に付けると 422 で、作らず変えず、その受信箱名を返さない' do
      other_inbox
      webhook = create(:webhook, account: account, inbox: inbox, url: 'https://hooks.example.invalid/existing')
      expect { write(:post, '/webhooks', webhook_params(other_inbox.id)) }.not_to change(Webhook, :count)
      expect_rejected('inbox_id', other_inbox.name)
      write(:patch, "/webhooks/#{webhook.id}", { webhook: { inbox_id: other_inbox.id } })
      expect_rejected('inbox_id', other_inbox.name)
      expect(webhook.reload.inbox_id).to eq(inbox.id)
    end

    it '自店舗の受信箱は従来どおり webhook に付ける' do
      write(:post, '/webhooks', webhook_params(inbox.id))
      expect(response).to have_http_status(:ok)
      expect(account.webhooks.find_by!(url: 'https://hooks.example.invalid/created').inbox_id).to eq(inbox.id)
    end
  end

  describe '連携の受信箱(integrations/hooks の inbox_id)' do
    def dialogflow_params(inbox_id)
      { hook: { app_id: 'dialogflow', inbox_id: inbox_id, settings: { project_id: 'toybaco-test', credentials: { type: 'service_account' } } } }
    end

    it '他店舗の受信箱を連携に付けると 422 で、作らず、その受信箱名を返さない' do
      other_inbox
      expect { write(:post, '/integrations/hooks', dialogflow_params(other_inbox.id)) }.not_to change(Integrations::Hook, :count)
      expect_rejected('inbox_id', other_inbox.name)
    end

    it '自店舗の受信箱は従来どおり連携に付ける' do
      write(:post, '/integrations/hooks', dialogflow_params(inbox.id))
      expect(response).to have_http_status(:ok)
      expect(account.hooks.find_by!(app_id: 'dialogflow').inbox_id).to eq(inbox.id)
    end
  end

  describe '自動化ルールの宛先チーム(send_email_to_team の team_ids)' do
    let(:own_team) { create(:team, account: account) }

    def email_rule_params(team_ids)
      {
        name: '宛先チームの確認', event_name: 'conversation_created',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }],
        actions: [{ action_name: 'send_email_to_team', action_params: [{ team_ids: team_ids, message: '確認してください' }] }]
      }
    end

    def saved_team_ids(rule)
      rule.reload.actions.first.dig('action_params', 0, 'team_ids')
    end

    # useEditableAutomation.js:93-99 は team_ids を team object に戻し、宛先・本文を未操作なら
    # actionQueryGenerator.js:20-25 はその object 配列を残したまま action_params を配列に包む。
    %i[name conditions].each do |attribute|
      it "宛先欄を触らず #{attribute} だけ編集した画面のチームオブジェクト配列を保存し、宛先を維持する" do
        second_team = create(:team, account: account)
        original = email_rule_params([own_team.id, second_team.id])
        rule = create(:automation_rule, account: account, **original)
        params = email_rule_params([own_team, second_team].map { |team| { id: team.id, name: team.name } })
        if attribute == :name
          params[:name] = '名前だけ変更'
        else
          params[:conditions].first[:values] = ['resolved']
        end

        write(:patch, "/automation_rules/#{rule.id}", params)

        expect(response).to have_http_status(:ok)
        expect(rule.reload.name).to eq(params[:name])
        expect(rule.conditions).to eq(params[:conditions].as_json)
        expect(rule.actions).to eq(original[:actions].as_json)
      end
    end

    it '整数・数字文字列・id を持つオブジェクトの宛先を整数配列として保存する' do
      teams = Array.new(4) { create(:team, account: account) }
      recipients = [teams[0].id, teams[1].id.to_s, { id: teams[2].id }, { id: teams[3].id.to_s }]

      write(:post, '/automation_rules', email_rule_params(recipients))

      expect(response).to have_http_status(:ok)
      expect(saved_team_ids(account.automation_rules.last)).to eq(teams.map(&:id))
    end

    it '他店舗のチームオブジェクトも 422 で拒否し、既存ルールを変更しない' do
      original = email_rule_params([own_team.id])
      rule = create(:automation_rule, account: account, **original)
      params = email_rule_params([{ id: own_team.id, name: own_team.name }, { id: other_team.id, name: other_team.name }])
      params[:name] = '保存されない名前'

      write(:patch, "/automation_rules/#{rule.id}", params)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(other_team.name)
      expect(rule.reload.name).to eq(original[:name])
      expect(rule.actions).to eq(original[:actions].as_json)
    end

    it 'id のないオブジェクトや数字以外の値を宛先から黙って除かず 422 で拒否する' do
      invalid_recipients = [{ name: 'id なし' }, { id: nil }, { id: 'invalid' }, true, 1.5, '1.5', '0x10']
      invalid_recipients.each do |recipient|
        expect { write(:post, '/automation_rules', email_rule_params([own_team.id, recipient])) }
          .not_to change(AutomationRule, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it '他店舗のチームを宛先にした作成・更新は 422 で、保存せず、そのチーム名を返さない' do
      own_team
      other_team
      expect { write(:post, '/automation_rules', email_rule_params([own_team.id, other_team.id])) }.not_to change(AutomationRule, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(other_team.name)
      rule = create(:automation_rule, account: account, actions: email_rule_params([own_team.id])[:actions])
      write(:patch, "/automation_rules/#{rule.id}", email_rule_params([other_team.id]))
      expect(response).to have_http_status(:unprocessable_content)
      expect(saved_team_ids(rule)).to eq([own_team.id])
    end

    it '照合より前に保存された他店舗の宛先チームには、実行してもメールを送らない' do
      rule = build(:automation_rule, account: account, actions: email_rule_params([own_team.id, other_team.id])[:actions])
      rule.save!(validate: false)
      conversation = create(:conversation, account: account, inbox: inbox)
      allow(TeamNotifications::AutomationNotificationMailer).to receive(:conversation_creation).and_return(nil)
      AutomationRules::ActionService.new(rule.reload, account, conversation).perform
      expect(TeamNotifications::AutomationNotificationMailer).to have_received(:conversation_creation).once
      expect(TeamNotifications::AutomationNotificationMailer).to have_received(:conversation_creation).with(conversation, own_team, '確認してください')
    end

    it '自店舗のチームを宛先にした作成は従来どおり保存する' do
      write(:post, '/automation_rules', email_rule_params([own_team.id]))
      expect(response).to have_http_status(:ok)
      expect(saved_team_ids(account.automation_rules.last)).to eq([own_team.id])
    end
  end

  # 保存時の照合(upstream attachment_concern.rb)は action_params の先頭しか見ないので、照合済みの行に他店舗の blob の id が
  # 混ざった状態を実行する。添付はそのルール・マクロ自身に付いた file だけにする。
  describe 'マクロ・自動化ルールの添付(send_attachment の blob id)' do
    def attach_own_file(record)
      record.files.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
      record.files.first.blob_id
    end

    def foreign_blob_id
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new('other store file'), filename: 'other.txt', content_type: 'text/plain').id
    end

    def sent_blob_ids(conversation)
      conversation.messages.reload.flat_map { |message| message.attachments.map { |attachment| attachment.file.blob_id } }
    end

    it 'マクロの実行は、そのマクロに付いた file だけを添付し、他店舗の blob を添付しない' do
      conversation = create(:conversation, account: account, inbox: inbox)
      macro = create(:macro, account: account, created_by: agent, visibility: :personal)
      own = attach_own_file(macro)
      macro.update!(actions: [{ action_name: 'send_attachment', action_params: [own, foreign_blob_id] }])
      Macros::ExecutionService.new(macro.reload, conversation, agent).perform
      expect(sent_blob_ids(conversation)).to eq([own])
    end

    it '自動化ルールの実行は、そのルールに付いた file だけを添付し、他店舗の blob を添付しない' do
      conversation = create(:conversation, account: account, inbox: inbox)
      rule = create(:automation_rule, account: account, actions: [{ action_name: 'add_label', action_params: ['確認'] }])
      own = attach_own_file(rule)
      rule.update!(actions: [{ action_name: 'send_attachment', action_params: [own, foreign_blob_id] }])
      AutomationRules::ActionService.new(rule.reload, account, conversation).perform
      expect(sent_blob_ids(conversation)).to eq([own])
    end
  end
end
