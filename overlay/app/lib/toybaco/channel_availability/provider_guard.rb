# frozen_string_literal: true

# Guard concrete provider objects, never HTTP hosts shared with offered channels.
# Prepending the methods (rather than constructors) also covers retained services.
class Toybaco::ChannelAvailability::ProviderGuard < Module
  def self.install(target, methods, &)
    prepends = target.ancestors.take_while { |ancestor| ancestor != target }
    return if prepends.any?(self)

    target.prepend(new(target, methods, &))
  end

  def initialize(target, methods, &)
    super(&nil)
    methods.each do |method|
      target.instance_method(method) # Fail at boot if the pinned provider contract changes.
      define_method(method) do |*args, **kwargs, &block|
        Toybaco::ChannelAvailability.ensure_enabled!(instance_exec(&))
        super(*args, **kwargs, &block)
      end
      private(method) if target.private_method_defined?(method)
      protected(method) if target.protected_method_defined?(method)
    end
  end
end
