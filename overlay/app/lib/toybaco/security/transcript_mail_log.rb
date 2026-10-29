# frozen_string_literal: true

# 上流の ConversationReplyMailer#conversation_transcript(v4.18.0 45-62 行)は、送り元と宛先のメールアドレスを
# 「Email sent from … to <宛先> with subject …」として Rails.logger.info に出す。上流と同じメールを作り、ログには会話の番号と
# 店舗の id だけを出す(CASA 6.5.1)。上流の版を上げるときは、この写しを上流の本体と照らし合わせる。
module Toybaco::Security::TranscriptMailLog
  def conversation_transcript(conversation, to_email)
    return unless smtp_config_set_or_development?

    init_conversation_attributes(conversation)

    @messages = @conversation.messages.chat.select(&:conversation_transcriptable?)

    Rails.logger.info("Conversation transcript email sent for conversation #{@conversation.display_id} " \
                      "(account #{@conversation.account_id})")
    mail({
           to: to_email,
           from: from_email_with_name,
           subject: "[##{@conversation.display_id}] #{I18n.t('conversations.reply.transcript_subject')}"
         })
  end
end
