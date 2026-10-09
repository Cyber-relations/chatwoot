# frozen_string_literal: true

require 'rails_helper'

# devise-secure_password のパスワード要件エラーを日本語で出す契約(2026-10-08、招待リンクで英語混在の 422 が出た)。
# 文言は overlay の config/locales/secure_password.ja.yml、確認不一致は toybaco_ja.yml の errors.messages.confirmation。
RSpec.describe User, type: :model do
  around do |example|
    I18n.with_locale(:ja) { example.run }
  end

  def full_messages_for(password, confirmation = password)
    user = build(:user, password: password, password_confirmation: confirmation)
    expect(user.valid?).to be(false)
    user.errors.full_messages
  end

  def flatten_leaves(value, prefix = nil, leaves = {})
    return leaves.merge!(prefix => value) unless value.is_a?(Hash)

    value.each { |key, child| flatten_leaves(child, [prefix, key].compact.join('.'), leaves) }
    leaves
  end

  describe 'password content messages' do
    it '記号が無いと「パスワード には記号を1文字以上含めてください」を出す' do
      messages = full_messages_for('Abcdef12')

      expect(messages.grep(/\Aパスワード には記号を1文字以上含めてください/).length).to eq(1)
      # 記号一覧は gem(Support::String::CharacterCounter)の並び。空白も記号に数えられる。
      expect(messages).to include('パスワード には記号を1文字以上含めてください  ( !@#$%^&*()_+-=[]{}|"/\\.,`<>:;?~\')')
      expect(messages.grep(/must contain|translation missing/i)).to be_empty
    end

    it '英大文字・数字が無い、6文字未満のときも日本語で出す' do
      expect(full_messages_for('abcdef1!').grep(/\Aパスワード には英大文字を1文字以上含めてください/).length).to eq(1)
      expect(full_messages_for('Abcdefg!').grep(/\Aパスワード には数字を1文字以上含めてください/).length).to eq(1)
      expect(full_messages_for('Ab1!').grep(/\Aパスワード は6文字以上にしてください\z/).length).to eq(1)
      expect(%w[abcdef1! Abcdefg! Ab1!].flat_map { |password| full_messages_for(password) }.grep(/must contain|translation missing/i)).to be_empty
    end

    it '英大文字・英小文字・数字の不足は文字種の範囲まで含めた全文で出す(画面の英字 3 連続判定の根拠)' do
      # gem の dict_for_type は (keys.first..keys.last)。英字は 1 文字ずつしか並ばない。
      expect(full_messages_for('abcdef1!')).to include('パスワード には英大文字を1文字以上含めてください  (A..Z)')
      expect(full_messages_for('ABCDEF1!')).to include('パスワード には英小文字を1文字以上含めてください  (a..z)')
      expect(full_messages_for('Abcdefg!')).to include('パスワード には数字を1文字以上含めてください  (0..9)')
    end

    it '確認用が一致しないと「パスワード（確認） がパスワードと一致しません」を出す' do
      messages = full_messages_for('Abcdef1!', 'Abcdef1?')

      expect(messages).to include(match(/\Aパスワード（確認） がパスワードと一致しません/))
      expect(messages.grep(/doesn't match|translation missing/i)).to be_empty
    end

    it '要件を満たすパスワードには password / password_confirmation のエラーを付けない' do
      user = build(:user, password: 'Abcdef1!', password_confirmation: 'Abcdef1!')
      user.valid?

      expect(user.errors[:password]).to be_empty
      expect(user.errors[:password_confirmation]).to be_empty
    end

    it '空白も記号に数え、128 文字までを受け付ける(画面の規則 toybacoPasswordRules.js と同じ)' do
      longest = "Ab1!#{'a' * 124}"
      with_space = build(:user, password: 'Abcd 123', password_confirmation: 'Abcd 123')
      max_length = build(:user, password: longest, password_confirmation: longest)
      with_space.valid?
      max_length.valid?

      expect(longest.length).to eq(128)
      expect(with_space.errors[:password]).to be_empty
      expect(max_length.errors[:password]).to be_empty
    end

    it '使用できない文字と 129 文字以上も日本語で出す' do
      too_long = "Ab1!#{'a' * 125}"

      expect(full_messages_for('Abcdef1!あ')).to include('パスワード に使用できない文字が1文字含まれています (あ)')
      expect(too_long.length).to eq(129)
      expect(full_messages_for(too_long).grep(/\Aパスワード は128文字以内にしてください\z/).length).to eq(1)
    end
  end

  describe 'secure_password.ja.yml' do
    let(:japanese) { flatten_leaves(YAML.safe_load_file(Rails.root.join('config/locales/secure_password.ja.yml')).fetch('ja')) }
    let(:english) { flatten_leaves(YAML.safe_load_file(Rails.root.join('config/locales/secure_password.en.yml')).fetch('en')) }

    it '上流の en とキー集合・プレースホルダが一致し、全文言に日本語を含む' do
      expect(japanese.keys.sort).to eq(english.keys.sort)
      expect(japanese.values).to all(match(/[ぁ-んァ-ヶ一-龠]/))
      placeholder_mismatches = english.reject do |key, value|
        value.to_s.scan(/%\{\w+\}/).uniq.sort == japanese.fetch(key).to_s.scan(/%\{\w+\}/).uniq.sort
      end
      expect(placeholder_mismatches.keys).to be_empty
    end
  end
end
