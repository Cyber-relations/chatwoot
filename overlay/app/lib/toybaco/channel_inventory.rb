# frozen_string_literal: true

# Row counts of the channel models Toybaco does not offer. Counts only: no names,
# ids, accounts, numbers, credentials or raw column values are read for output;
# rows outside each fixed bucket are counted as other.
module Toybaco::ChannelInventory
  module_function

  def lines
    totals = models.map { |model| [model, model.count] }
    totals.flat_map { |model, total| ["#{model.name} total=#{total}", *breakdown(model, total)] } +
      ["unavailable_channels_total=#{totals.sum(&:last)}"]
  end

  def models
    [Channel::Sms, Channel::Whatsapp, Channel::TwilioSms, Channel::TwitterProfile]
  end

  def breakdown(model, total)
    fixed, other_label = buckets(model)
    return [] if total.zero? || fixed.empty?

    counted = fixed.map { |conditions, label| [label, model.where(conditions).count] }
    counted << [other_label, total - counted.sum(&:last)]
    counted.reject { |_, count| count.zero? }.map { |label, count| "#{model.name} #{label} count=#{count}" }
  end

  def buckets(model)
    {
      'Channel::Sms' => [provider_buckets(%w[default]), 'provider=other'],
      'Channel::Whatsapp' => [provider_buckets(Channel::Whatsapp::PROVIDERS), 'provider=other'],
      'Channel::TwilioSms' => [twilio_buckets, 'medium=other voice_enabled=other']
    }.fetch(model.name, [[], nil])
  end

  def provider_buckets(values)
    values.map { |value| [{ provider: value }, "provider=#{value}"] }
  end

  def twilio_buckets
    %w[sms whatsapp].product([true, false]).map do |medium, voice|
      [{ medium: medium, voice_enabled: voice }, "medium=#{medium} voice_enabled=#{voice}"]
    end
  end
end
