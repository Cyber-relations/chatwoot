# frozen_string_literal: true

class Toybaco::ChannelAvailability::ProviderJobGuard < Module
  LOG_MESSAGE = 'Toybaco provider job skipped: channel is not offered'

  def self.install(target, method, types, handler)
    return if target.ancestors.any?(self)

    target.instance_method(method) # Fail at boot if the pinned boundary changes.
    target.prepend(new(method, types, handler))
  end

  def initialize(method, types, handler)
    super(&nil)
    define_method(method) do |*args, **kwargs, &block|
      Toybaco::ChannelAvailability.ensure_enabled!(types.call(*args))
      super(*args, **kwargs, &block)
    rescue Toybaco::ChannelAvailability::Unavailable
      handler.call(*args)
      Rails.logger.warn(Toybaco::ChannelAvailability::ProviderJobGuard::LOG_MESSAGE)
      nil
    end
  end
end
