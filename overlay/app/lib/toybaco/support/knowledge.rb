# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    # Only shipped procedures belong here. Product plans are not support sources.
    module Knowledge
      VERSION = '2026-09-19.1'
      ARTICLES = {
        'first_steps' => ['使い始める', '最初に使う窓口を接続し、お店情報を確認します。初回案内から続けられます。', 'start', 'growth'],
        'connection' => ['窓口を接続する', '「受信箱」で接続する媒体を選びます。接続設定は店舗の管理者が行います。', 'inboxes', 'administrator'],
        'line' => ['LINE公式を接続する', 'LINE公式の接続には、Messaging APIの情報が必要です。「受信箱」のLINEから設定します。', 'inboxes', 'administrator'],
        'gmail' => ['Googleのメールを接続する', 'Googleのアカウントを選び、表示されたメールの権限を許可します。初回案内の接続から始められます。', 'start', 'gmail'],
        'microsoft' => ['Microsoftのメールを接続する', 'Microsoftのアカウントを選び、表示されたメールの権限を許可します。組織の許可が必要な場合は店舗の管理者に確認してください。', 'start', 'microsoft'],
        'reply' => ['受信した内容に返信する', '担当の受信箱から会話を開き、返信欄へ入力します。宛先と内容を確認して送信してください。', 'conversations', 'member'],
        'posting' => ['投稿を予約する', '投稿画面で媒体・本文・日時を選びます。保存後に予約一覧へ表示されたことを確認してください。', 'posting', 'posting'],
        'facts' => ['AIが使うお店情報', '返信に使う営業時間や予約方法を確認します。初回案内のお店情報で保存できます。', 'start', 'growth_admin'],
        'ai' => ['AIの下書き', '返信欄のAIから下書きを作れます。内容を確認して採用し、送信はご自身で行ってください。', 'conversations', 'drafts'],
        'staff' => ['スタッフを追加する', '「スタッフ」で利用者を招待します。料金や追加できる人数は現在の契約内容で確認してください。', 'staff', 'administrator'],
        'billing' => ['契約・お支払い', '現在の契約と利用条件は「契約・お支払い」で確認できます。変更操作は契約者が管理者権限で行います。', 'billing', 'billing'],
        'login' => ['ログインできない', 'ログイン画面からパスワードを再設定できます。確認メールが見つからない場合は迷惑メールも確認してください。', nil, 'member'],
        'private_note' => ['お店の中だけでメモを残す', '返信欄を「プライベートメモ」に切り替えて記録します。お客様への返信に戻すときは、送信前に入力欄の種類を確認してください。', 'conversations', 'member'],
        'resolve' => ['対応が終わった会話', '対応が終わったら、会話を解決済みにします。会話の削除とは別の操作です。', 'conversations', 'member'],
        'attachments' => ['返信に画像やファイルを付ける', '返信欄で添付を選び、宛先と内容を確認して送信します。追加できない場合は、媒体の形式・容量条件と画面のエラーを確認してください。', 'conversations', 'member'],
        'reply_failed' => ['返信を送れない', '返信欄とメッセージに表示されたエラーを確認します。再送前に元の媒体でも送信済みかを確認し、同じ内容を重ねて送らないようにしてください。', 'conversations', 'member'],
        'posting_connection' => ['投稿するSNSを追加する', '投稿画面の「チャンネルを追加」から、使用するSNSを接続します。認可画面では、投稿するアカウントと求められる権限を確認してください。', 'posting', 'posting'],
        'posting_draft' => ['投稿を下書きとして残す', '投稿画面で本文・画像・動画を準備し、下書きとして保存します。下書き保存だけでは公開・予約されません。', 'posting', 'posting'],
        'posting_preview' => ['投稿内容を共有して確認する', '投稿の共有プレビューで内容を確認し、コメントできます。コメント時にログインを求められた場合はトイバコIDを使います。', 'posting', 'posting'],
        'posting_failed' => ['予約した投稿が失敗した', '投稿カレンダーの失敗表示から、理由と対処を確認します。再実行の前に、SNS側にも投稿済みでないか確認してください。', 'posting', 'posting'],
        'posting_media' => ['投稿用の画像や動画を探す', '「投稿 → メディア」でファイル名を検索し、内容を確認できます。新しく使う素材はアップロードしてください。', 'posting', 'posting'],
        'posting_settings' => ['投稿の時刻表示やテンプレート', '「投稿設定」で時刻表記・通知・投稿テンプレート・署名を設定できます。予約するときも、画面に表示された公開日時を確認してください。', 'posting', 'posting'],
        'ai_review' => ['AIの文案を確認して使う', 'AIの文案は、日時・金額・お店の対応内容を確認してから採用します。採用だけでは送信せず、最後にご自身で送信を実行します。', 'conversations', 'drafts'],
        'security' => ['接続情報の扱い', 'パスワードや接続キーは指定の設定画面にだけ入力してください。使い方の質問に貼り付ける必要はありません。', nil, 'member']
      }.freeze

      module_function

      def articles(context)
        ARTICLES.filter_map do |id, (title, answer, action, requirement)|
          next unless context.allowed?(requirement)

          { 'id' => id, 'title' => title, 'answer' => answer, 'action' => action, 'version' => VERSION }
        end
      end
    end
  end
end
