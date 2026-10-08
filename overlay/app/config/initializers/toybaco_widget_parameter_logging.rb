# frozen_string_literal: true

# The widget conversation JWT is currently accepted as cw_conversation.
# Filter that exact key from parameters and request URLs, including nested input.
# This does not change the widget handoff protocol or make its JS cookie HttpOnly.
Rails.application.config.filter_parameters += [:cw_conversation]
